import AppKit

/// 应用总装（Composition Root）。
///
/// 唯一持有各模块生命周期的地方，也是各阶段融合的"胶水层"：
///
/// ```
///  ┌──────────────── 第一阶段 ────────────────┐
///  │ StatusBarController（菜单栏 UI）          │
///  └──────────────────────────────────────────┘
///                     │
///  ┌──────────────── 第二阶段 ────────────────┐
///  │ TouchBarHostWindowController（前台）      │
///  │   └─ TouchBarHost(NSTouchBar + Delegate) │
///  └──────────────────────────────────────────┘
///                     │
///  ┌──────────────── 第三阶段 ────────────────┐
///  │ FrontmostAppMonitor → TouchBarRuleEngine │
///  │        → SystemModalTouchBarPresenter    │
///  │           （私有 API 系统模态注入）        │
///  └──────────────────────────────────────────┘
///        三个阶段共用：TouchBarDefinition / AppAction / TouchBarPresenting
///
///  ┌──────────────── 第六阶段 ────────────────┐
///  │ 前台应用切换 → 动态注入 / 收起 Touch Bar    │
///  └──────────────────────────────────────────┘
/// ```
final class AppCoordinator {
    static let shared = AppCoordinator()

    // MARK: 模块（第一阶段）
    private let statusBarController = StatusBarController()

    // MARK: 模块（第二阶段）
    private var foregroundWindowController: TouchBarHostWindowController?

    // MARK: 模块（第三阶段）
    private let frontmostAppMonitor = FrontmostAppMonitor()
    private let ruleEngine = TouchBarRuleEngine()
    private let backgroundPresenter = SystemModalTouchBarPresenter()
    private var permissionMonitor: AccessibilityPermission.Monitor?

    // MARK: 模块（第四阶段）
    private var ruleStoreObserver: NSObjectProtocol?

    // MARK: 模块（第九阶段：Control Strip 托盘 + 点按开合）
    /// 左侧长栏当前是否处于「用户主动展开」状态。
    /// 只有在 true 时，前台应用切换才允许自动重建长栏 —— 用户没点开时绝不去碰硬件。
    private var isTouchBarExpanded = false
    /// 最后一个**不是我们自己**的前台应用。
    ///
    /// 为什么需要：我们是 `.regular` 策略时（配置窗口开着），点击自己在 Control Strip 上的
    /// 托盘项会把本进程激活 —— 于是「此刻的前台」变成 btTool 自己。而用户真正想要的，
    /// 是「我刚才在用的那个应用」的规则。长栏内容一律以这份记录为准。
    private var lastExternalInfo: FrontmostAppInfo?
    /// 上次展开长栏的时刻 —— 用来区分「用户切到配置窗口」与「点托盘把自己激活了」
    private var lastExpandTime: Date = .distantPast
    /// 打开配置窗口前的展开状态，关窗后原样恢复
    private var wasExpandedBeforeSettings = false

    /// 长栏内容会跟着哪个应用走（菜单栏显示，让「点托盘会发生什么」可预期）
    var touchBarTargetName: String? {
        let current = frontmostAppMonitor.snapshot()
        return ((current?.isSelf == false ? current : nil) ?? lastExternalInfo)?.displayName
    }

    /// 长栏是否真的在屏上（用户意图 OR 硬件事实）—— 菜单栏调试项的标题由它决定
    var isTouchBarCurrentlyExpanded: Bool { isTouchBarExpanded || backgroundPresenter.isPresenting }
    /// 应用激活 / 停用通知的观察者（用于动态维持托盘存在性）
    private var activationObservers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - 生命周期

    func start() {
        Log.info("btTool 启动（pid=\(ProcessInfo.processInfo.processIdentifier)）")
        Log.info("日志文件：\(Log.fileURL.path)   ← 终端执行 `tail -f \(Log.fileURL.path)` 实时查看")

        // ⚠️ 顺序重要：菜单必须先建好，`updateAccessibility()` 才有落点。
        //    之前是 setupAccessibility() 在前，首次刷新打到 nil 上，
        //    之后又只「上报变化」→ 已授权的机器会永远停在「检测中…」。
        installStatusBar()          // ① 菜单栏
        // 先把前台监听接上，再做权限检测：权限回调里会 `refreshNow()`，
        // 若此刻 onChange 还是 nil，这次「切到前台应用」的上报就被白白丢掉了。
        startBackgroundTouchBar()   // ③ 前台应用监听 → 动态注入
        setupAccessibility()        // ①③ 权限状态（含首帧同步 + RunLoop .common 轮询）
        observeRuleStore()          // ④ 界面改动 → 规则引擎 + Touch Bar 立即刷新
        syncForCurrentFrontmostApp()// 首帧兜底（见方法注释）

        Log.info("已加载规则：\(RuleStore.shared.rules.count) 条应用规则" +
                 "（来自 \(RuleStore.shared.fileURL.path)）")

        // 最后挂载右侧托盘：此时前台监听、规则引擎、注入器都已就绪
        installTrayItemIfNeeded()
    }

    /// 首帧同步：把「当前前台应用」完整处理一遍。
    ///
    /// 为什么需要它：`FrontmostAppMonitor.apply()` 会按 `lastInfo` 去重，
    /// 而权限回调可能已经先触发过一次 `refreshNow()`（那时 `onChange` 还没接上），
    /// 于是紧接着的调度会被去重吞掉 —— 表现为「日志里有前台应用，但 Touch Bar 没跟上」。
    private func syncForCurrentFrontmostApp() {
        let info = frontmostAppMonitor.snapshot()
        if let info, !info.isSelf { refreshInjection(for: info) }
    }

    func stop() {
        backgroundPresenter.onTrayItemClicked = nil
        backgroundPresenter.onSystemDismissed = nil
        backgroundPresenter.removeTrayItem()

        frontmostAppMonitor.stop()
        backgroundPresenter.dismiss()
        permissionMonitor?.stop()
        permissionMonitor = nil
        if let ruleStoreObserver { NotificationCenter.default.removeObserver(ruleStoreObserver) }
        ruleStoreObserver = nil
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        activationObservers.removeAll()
        Log.info("btTool 已退出")
    }

    // MARK: - ① 菜单栏

    private func installStatusBar() {
        statusBarController.hooks.onAbout = {
            NSApp.activate(ignoringOtherApps: true)
            NSApplication.shared.orderFrontStandardAboutPanel(options: [:])
        }
        statusBarController.hooks.onShowSettingsWindow = { [weak self] in
            self?.showSettingsWindow()
        }
        statusBarController.hooks.onToggleBackgroundInjection = { [weak self] in
            self?.toggleBackgroundInjection()
        }
        // 🔧 临时调试入口：绕过 Control Strip 托盘直接开合左侧长栏（菜单打开时标题会自动刷新）
        statusBarController.hooks.onToggleTouchBarExpansion = { [weak self] in
            self?.toggleTouchBarExpansion()
        }
        statusBarController.hooks.onQueryTouchBarExpanded = { [weak self] in
            self?.isTouchBarCurrentlyExpanded ?? false
        }
        statusBarController.hooks.onQueryTouchBarTarget = { [weak self] in
            self?.touchBarTargetName
        }
        statusBarController.hooks.onRevealAccessibilitySettings = { [weak self] in
            self?.requestAccessibilityFromUserGesture()
        }
        statusBarController.hooks.onQuit = {
            NSApplication.shared.terminate(nil)
        }
        statusBarController.install()
    }

    // MARK: - ② 前台 Touch Bar（开发调试入口，已从菜单栏下线）

    /// 仍保留：Dock 图标被重新激活时（`applicationShouldHandleReopen`）用它开一扇窗，
    /// 否则用户会以为点了图标没反应。
    func showTouchBarHostWindow() {
        if foregroundWindowController == nil {
            foregroundWindowController = TouchBarHostWindowController(definition: TouchBarCatalog.foregroundDemo)
        }
        foregroundWindowController?.present()
        // 自己成为前台时，撤掉后台注入的那条，避免重复
        backgroundPresenter.dismiss()
    }

    // MARK: - ④ GUI 配置主窗口

    func showSettingsWindow() {
        // 记住展开状态：关窗后原样恢复，用户不必再点一次托盘
        wasExpandedBeforeSettings = isTouchBarExpanded
        collapseTouchBar(reason: "打开配置窗口")

        let controller = SettingsWindowController.shared
        controller.onDidClose = { [weak self] in
            self?.handleSettingsWindowDidClose()
        }
        controller.showWindow(self)
    }

    /// 窗口关闭 → 退回 accessory；延迟一小会儿再恢复后台注入，
    /// 因为此时系统会重新激活上一个应用，`didActivateApplication` 还没到。
    private func handleSettingsWindowDidClose() {
        ActivationPolicyController.becomeAccessory()

        let restoreExpansion = wasExpandedBeforeSettings
        wasExpandedBeforeSettings = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.frontmostAppMonitor.refreshNow()
            // 关窗前是展开态 → 恢复（托盘仍在，这只是一次正常 present）
            if restoreExpansion, let info = self.frontmostAppMonitor.snapshot(), !info.isSelf {
                self.expandTouchBar(reason: "关闭配置窗口，恢复展开")
            }
        }
    }

    /// 界面上的改动及时生效：重载规则 + 立即重建当前前台的 Touch Bar
    private func observeRuleStore() {
        ruleStoreObserver = NotificationCenter.default.addObserver(
            forName: RuleStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.ruleEngine.reload()
                self.statusBarController.refreshInjectionItem()

                // 正在注入的栏要重建，否则用户得切一次应用才能看到改动
                if let info = self.frontmostAppMonitor.snapshot(), !info.isSelf {
                    self.refreshInjection(for: info)
                }
            }
    }

    /// 前台应用 / 规则变化时刷新长栏内容。
    ///
    /// 🔴 只有在「用户已经展开」时才允许碰硬件：未展开时托盘常驻、长栏收起，
    /// 数据源更新是纯内存操作 —— 这正是不再需要轮询守护的根本原因。
    private func refreshInjection(for info: FrontmostAppInfo) {
        guard isTouchBarExpanded else { return }
        guard AppSettings.shared.backgroundTouchBarEnabled, SystemModalTouchBarPresenter.isAvailable else {
            collapseTouchBar(reason: "注入能力不可用")
            return
        }
        // 没有匹配规则时**不收起**：展示占位栏（见 TouchBarDefinition.placeholder）
        let definition = ruleEngine.resolve(bundleIdentifier: info.bundleIdentifier)
            ?? TouchBarDefinition.placeholder(forAppNamed: info.displayName)
        backgroundPresenter.present(definition)
    }

    // MARK: - ③ 后台动态注入

    private func startBackgroundTouchBar() {
        if !SystemModalTouchBarPresenter.isAvailable {
            Log.error("⚠️ 当前系统不支持后台 Touch Bar 注入，第三阶段降级为「仅监听 + 日志」", log: Log.touchBar)
        }

        // 托盘点击 → 展开 / 收回（数据源由 Coordinator 决定，呈现器只管硬件）
        backgroundPresenter.onTrayItemClicked = { [weak self] in
            self?.toggleTouchBarExpansion()
        }
        // 用户点叉 / 被抢占 → 只把状态翻回「已收起」，不再自动拉回
        backgroundPresenter.onSystemDismissed = { [weak self] in
            guard let self, self.isTouchBarExpanded else { return }
            self.isTouchBarExpanded = false
            Log.info("长栏已被系统收回；再次点按入口可重新展开", log: Log.touchBar)
            self.statusBarController.updateExpansionItem()
        }

        frontmostAppMonitor.onChange = { [weak self] info in
            self?.handleFrontmostAppChange(info)
        }
        frontmostAppMonitor.start()
        observeAppActivation()
    }
    // MARK: - 托盘存在性：跟随应用激活 / 停用动态维持

    /// 接管 `NSApplication` 的激活 / 停用通知，让托盘的存在性跟着进程状态走。
    ///
    /// 这两个通知比「前台应用切换」更贴近托盘自己的生命周期：
    /// 菜单栏被点开、托盘按钮被点、配置窗口弹出 —— 本进程都会经历一次激活。
    private func observeAppActivation() {
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.handleAppActivated()
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.handleAppDeactivated()
            },
        ]
    }

    /// 激活 → **确保托盘存在**（幂等，已注册时只重申 DFR 存在性）。
    ///
    /// 🔴 这里绝不能写成「激活 → 销毁」：点击 Touch Bar 上的托盘按钮本身就属于本进程激活，
    ///    那么点一次图标就会把自己的入口拆掉一次，图标直接消失。
    private func handleAppActivated() {
        guard AppSettings.shared.backgroundTouchBarEnabled else { return }
        backgroundPresenter.ensureTrayItemInstalled()
    }

    /// 停用 → 默认保持常驻；`trayItemDestroyOnDeactivate` 打开时才真的拆掉。
    ///
    /// 另外：后台注入开关被关闭时，这里也会顺手把托盘彻底销毁，避免留幽灵入口。
    private func handleAppDeactivated() {
        guard AppSettings.shared.backgroundTouchBarEnabled else {
            backgroundPresenter.removeTrayItem()
            return
        }
        if AppSettings.shared.trayItemDestroyOnDeactivate {
            Log.info("已停用 → 按设置销毁托盘项（trayItemDestroyOnDeactivate=true）", log: Log.touchBar)
            backgroundPresenter.removeTrayItem()
        }
    }

    private func toggleBackgroundInjection() {
        let enabled = !AppSettings.shared.backgroundTouchBarEnabled
        AppSettings.shared.backgroundTouchBarEnabled = enabled
        statusBarController.refreshInjectionItem()
        Log.info("后台注入 Touch Bar：\(enabled ? "开启" : "关闭")", log: Log.touchBar)

        if enabled {
            installTrayItemIfNeeded()
            frontmostAppMonitor.refreshNow()
        } else {
            collapseTouchBar(reason: "关闭后台注入")
            backgroundPresenter.removeTrayItem()
        }
    }

    // MARK: - ⑦ Control Strip 托盘 + 点按开合（BTT 的原生机制）

    /// 挂载右侧常驻托盘。只有用户开了「后台注入 Touch Bar」才挂 —— 否则等于留了个假入口。
    private func installTrayItemIfNeeded() {
        guard AppSettings.shared.backgroundTouchBarEnabled else {
            Log.debug("后台注入已关闭，不安装 Control Strip 托盘", log: Log.touchBar)
            return
        }
        guard SystemModalTouchBarPresenter.isAvailable else {
            Log.error("私有 present API 不可用，托盘即使装上也无法展开长栏，已跳过", log: Log.touchBar)
            return
        }
        guard SystemModalTouchBarPresenter.canInstallTrayItem else {
            Log.error("当前系统不支持 addSystemTrayItem:，降级为「仅菜单控制」", log: Log.touchBar)
            return
        }
        backgroundPresenter.installTrayItem()
    }

    /// 托盘点击：已展开就收回，未展开就按当前前台应用的规则展开。
    ///
    /// 这就是 BTT 的交互模型 —— 托盘图标**永远在**，长栏的生死完全由用户点按决定；
    /// 没有定时器、没有退避、没有“点叉又弹回来”的暴力行为。
    private func toggleTouchBarExpansion() {
        guard AppSettings.shared.backgroundTouchBarEnabled else {
            Log.debug("后台注入已关闭，忽略托盘点击", log: Log.touchBar)
            return
        }
        // ⚠️ 这里原来有一行 `guard NSApp.activationPolicy() != .regular` —— 判断依据用错了：
        // 激活策略是**进程级**的（打开配置窗口时切成 regular，要等关窗才切回 accessory），
        // 而「配置窗口在前台」是**窗口级**的。后果是：只要配置窗口还开着，无论用户切到
        // 哪个应用，托盘点击都会被拒 —— 表现就是「非得把窗口关掉，托盘才好使」。
        // 以硬件真实可见性为准：点叉后 isPresenting 已经变 false，此时点击应重新展开
        if isTouchBarExpanded || backgroundPresenter.isPresenting {
            collapseTouchBar(reason: "点按托盘图标")
        } else {
            expandTouchBar(reason: "点按托盘图标")
        }
    }

    private func expandTouchBar(reason: String) {
        // 优先用「此刻不是我们的前台应用」，否则退回「最后一个不是我们的前台应用」——
        // 详见 lastExternalInfo 的说明：点击托盘的副作用可能让我们自己变成前台。
        let current = frontmostAppMonitor.snapshot()
        guard let info = (current?.isSelf == false ? current : nil) ?? lastExternalInfo else {
            Log.info("还没有可展示规则的前台应用，暂不展开长栏", log: Log.touchBar)
            return
        }
        guard let definition = ruleEngine.resolve(bundleIdentifier: info.bundleIdentifier) else {
            Log.info("「\(info.displayName)」没有匹配的规则，展开占位长栏", log: Log.touchBar)
            isTouchBarExpanded = true
            lastExpandTime = Date()
            backgroundPresenter.present(TouchBarDefinition.placeholder(forAppNamed: info.displayName))
            statusBarController.updateExpansionItem()
            return
        }
        isTouchBarExpanded = true
        lastExpandTime = Date()
        Log.info("展开长栏（\(reason)）：\(info.displayName) → \(definition.customizationIdentifier)", log: Log.touchBar)
        backgroundPresenter.present(definition)
        statusBarController.updateExpansionItem()
    }

    private func collapseTouchBar(reason: String) {
        let wasVisible = isTouchBarExpanded || backgroundPresenter.isPresenting
        isTouchBarExpanded = false
        backgroundPresenter.dismiss()
        if wasVisible {
            Log.info("收回长栏（\(reason)）", log: Log.touchBar)
        }
        statusBarController.updateExpansionItem()
    }

    /// 每次前台应用变化的核心处理流程
    private func handleFrontmostAppChange(_ info: FrontmostAppInfo?) {

        guard let info else {
            collapseTouchBar(reason: "前台应用为空")
            return
        }

        // 记住最后一个「不是自己」的前台应用（见 lastExternalInfo 的说明）
        if !info.isSelf { lastExternalInfo = info }

        // 自己成为前台（配置窗口）→ 收起长栏，托盘保持在线
        if info.isSelf {
            // ⚠️ 点击 Touch Bar 托盘会把我们自己激活（regular 策略下点击自己的托盘项），
            // 这**不是**用户切到了配置窗口。此时照常收起的话，长栏会「刚展开就灭」。
            let since = Date().timeIntervalSince(lastExpandTime)
            guard since > 1.0 else {
                Log.debug("自己被激活是点击托盘的副作用（距上次展开 \(String(format: "%.2f", since))s），不收起长栏",
                          log: Log.touchBar)
                return
            }
            collapseTouchBar(reason: "配置窗口成为前台")
            return
        }

        guard AppSettings.shared.backgroundTouchBarEnabled else {
            collapseTouchBar(reason: "后台注入已关闭")
            return
        }

        // 🔴 未展开时只更新数据源，绝不写硬件：托盘图标才是唯一入口
        guard isTouchBarExpanded else {
            Log.debug("长栏未展开（托盘常驻），切到「\(info.displayName)」仅更新数据", log: Log.touchBar)
            return
        }

        // 规则引擎：按 Bundle ID 决定展示哪一条
        guard let definition = ruleEngine.resolve(bundleIdentifier: info.bundleIdentifier) else {
            Log.debug("「\(info.displayName)」未命中规则 → 收回长栏", log: Log.touchBar)
            collapseTouchBar(reason: "「\(info.displayName)」未命中规则")
            return
        }

        // 已展示的正是这一条时不必重建（避免切换窗口时 Touch Bar 闪烁）
        if backgroundPresenter.isPresenting,
           backgroundPresenter.currentDefinitionIdentifier == definition.customizationIdentifier {
            return
        }

        // 前台切换 → 无缝重构长栏内容；托盘图标全程不受影响（它不属于这条 NSTouchBar）
        Log.info("前台切换 → 长栏无缝重建：\(info.displayName)", log: Log.touchBar)
        backgroundPresenter.present(definition)
    }

    // MARK: - 权限引导

    private func setupAccessibility() {
        // 🔴 启动这里只允许**静默**查询。以前这儿有一句「未授权就 checkOrPrompt()」，
        //    结果每次 make run 都弹一次系统授权窗（ad-hoc 每次重建 = 新 cdhash = TCC 眼里换了新 App），
        //    叠加起来就成了"疯狂重复弹窗"。现在弹窗权归用户独有。
        let granted = AccessibilityPermission.isTrusted
        Log.info("辅助功能权限：\(granted ? "已授权" : "未授权（等待用户点击菜单栏项才会弹窗）")")
        statusBarController.updateAccessibility(granted: granted)

        // 🔴 必须由 self 强引用持有：Monitor 内部只被 RunLoop 弱引用 Timer 的 block，
        //    如果这里用 `_ =` 或局部变量接住，Monitor 会被立刻释放 → Timer 失效 →
        //    菜单永远停在「检测中…」。
        permissionMonitor = AccessibilityPermission.startMonitoring { [weak self] granted in
            self?.statusBarController.updateAccessibility(granted: granted)
            if granted {
                // 拿到权限后立刻补一次完整刷新（窗口标题、Touch Bar 注入都依赖它）
                self?.frontmostAppMonitor.refreshNow()
            }
        }
    }

    /// 用户点击菜单栏「辅助功能权限：未授权 ⚠️」→ **此时才允许**弹一次系统授权窗。
    ///
    /// 只请求系统授权提示；由用户在系统提示中确认是否打开设置，避免抢先跳转。
    private func requestAccessibilityFromUserGesture() {
        if AccessibilityPermission.checkOrPrompt(reason: "菜单栏点击") {
            Log.info("已获得辅助功能权限")
            statusBarController.updateAccessibility(granted: true)
            frontmostAppMonitor.refreshNow()
            return
        }
        Log.info("尚未授权；等待用户通过系统授权提示处理")
    }
}
