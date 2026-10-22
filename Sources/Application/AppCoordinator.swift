import AppKit

/// 应用总装（Composition Root）。
///
/// 唯一持有各模块生命周期的地方，也是各阶段融合的"胶水层"：
///
/// ```
///  ┌──────────────── 第一阶段 ────────────────┐
///  │ StatusBarController（菜单栏 UI）          │
///  │ HotKeyCenter（Carbon 全局热键）→ AppAction│
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
///  │ 前台应用切换 → 动态注册/注销键盘快捷键      │
///  │  （「全局」作用域常驻，应用级随前台切换）    │
///  └──────────────────────────────────────────┘
/// ```
final class AppCoordinator {
    static let shared = AppCoordinator()

    // MARK: 模块（第一阶段）
    private let statusBarController = StatusBarController()
    private let hotKeyCenter = HotKeyCenter.shared
    /// 当前已注册的快捷键 id（切换前台 / 配置变更时需要整批注销重注册）
    private var registeredHotKeyIDs: [UInt32] = []
    /// 上一轮绑定方案的指纹：内容没变就不重复注册
    private var shortcutSignature: String = ""

    // MARK: 模块（第二阶段）
    private var foregroundWindowController: TouchBarHostWindowController?

    // MARK: 模块（第三阶段）
    private let frontmostAppMonitor = FrontmostAppMonitor()
    private let ruleEngine = TouchBarRuleEngine()
    private let backgroundPresenter = SystemModalTouchBarPresenter()
    private var permissionMonitor: AccessibilityPermission.Monitor?

    // MARK: 模块（第四阶段）
    private var ruleStoreObserver: NSObjectProtocol?

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
        startBackgroundTouchBar()   // ③ 前台应用监听 → 动态注入 + 动态快捷键
        setupAccessibility()        // ①③ 权限状态（含首帧同步 + RunLoop .common 轮询）
        observeRuleStore()          // ④ 界面改动 → 规则引擎 + 快捷键热更新
        syncForCurrentFrontmostApp()// 首帧兜底（见方法注释）

        Log.info("已加载规则：\(RuleStore.shared.rules.count) 条应用规则 · " +
                 "\(RuleStore.shared.globalShortcuts.count) 条全局快捷键" +
                 "（来自 \(RuleStore.shared.fileURL.path)）")
    }

    /// 首帧同步：把「当前前台应用」完整处理一遍。
    ///
    /// 为什么需要它：`FrontmostAppMonitor.apply()` 会按 `lastInfo` 去重，
    /// 而权限回调可能已经先触发过一次 `refreshNow()`（那时 `onChange` 还没接上），
    /// 于是紧接着的调度会被去重吞掉 —— 表现为「日志里有前台应用，但快捷键一条都没注册」。
    private func syncForCurrentFrontmostApp() {
        let info = frontmostAppMonitor.snapshot()
        bindShortcuts(for: info)
        if let info, !info.isSelf { refreshInjection(for: info) }
    }

    func stop() {
        registeredHotKeyIDs.forEach { hotKeyCenter.unregister($0) }
        registeredHotKeyIDs.removeAll()
        hotKeyCenter.unregisterAll()
        frontmostAppMonitor.stop()
        backgroundPresenter.dismiss()
        permissionMonitor?.stop()
        permissionMonitor = nil
        if let ruleStoreObserver { NotificationCenter.default.removeObserver(ruleStoreObserver) }
        ruleStoreObserver = nil
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
        statusBarController.hooks.onRevealAccessibilitySettings = {
            AccessibilityPermission.revealInSystemSettings()
        }
        statusBarController.hooks.onQuit = {
            NSApplication.shared.terminate(nil)
        }
        statusBarController.install()
    }

    // MARK: - ⑤ 键盘快捷键（全局 / 前台应用）

    /// 按当前前台应用重建快捷键注册表。
    ///
    /// 语义（与 GUI 的「快捷键」标签页一一对应）：
    /// - 「全局（All Apps）」作用域：**常驻**注册，任何应用在前台都生效；
    /// - 应用作用域：只有该应用在前台时才注册，切走立刻注销 —— 这样 ⌘ 组合不会互相污染；
    /// - 组合重复时**先到先得**（全局优先），后来者被忽略并打日志（GUI 里会标红）。
    ///
    /// 幂等：先算「本轮应有的绑定」指纹，与上一轮相同就直接返回，
    /// 避免每次窗口焦点变化都做一遍「全注销 + 全注册」（Carbon 注册是有成本的，
    /// 反复注册还会让系统日志里刷出一堆 RegisterEventHotKey）。
    private func bindShortcuts(for info: FrontmostAppInfo?, force: Bool = false) {
        let enabled = AppSettings.shared.hotKeyEnabled
        var plan: [(shortcut: KeyboardShortcutDTO, scope: String)] = []
        if enabled {
            plan.append(contentsOf: RuleStore.shared.globalShortcuts.map { ($0, "全局") })
            if let bundleIdentifier = info?.bundleIdentifier,
               let rule = RuleStore.shared.rule(bundleIdentifier: bundleIdentifier) {
                plan.append(contentsOf: rule.shortcuts.map { ($0, rule.primaryBundleIdentifier) })
            }
        }

        let signature = (enabled ? "on" : "off") + "#" + plan.map {
            "\($0.scope):\($0.shortcut.id):\($0.shortcut.keyCode):\($0.shortcut.modifierRawValue)"
        }.joined(separator: "|")
        guard force || signature != shortcutSignature else { return }
        shortcutSignature = signature

        registeredHotKeyIDs.forEach { hotKeyCenter.unregister($0) }
        registeredHotKeyIDs.removeAll()

        guard enabled else {
            Log.info("快捷键总开关关闭（btTool.hotKeyEnabled = false），已清空全部绑定", log: Log.hotKey)
            return
        }

        var occupied: Set<String> = []
        for entry in plan {
            let shortcut = entry.shortcut
            let comboKey = "\(shortcut.modifierRawValue)-\(shortcut.keyCode)"

            // 🛑 无修饰键的全局按键会拦截整块键盘，坚决拒绝
            guard shortcut.carbonModifiers != 0 else {
                Log.error("拒绝注册无修饰键的快捷键（会吞掉全局按键）：\(shortcut.readableDescription)", log: Log.hotKey)
                continue
            }
            guard occupied.insert(comboKey).inserted else {
                Log.error("快捷键组合重复，已忽略：\(shortcut.readableDescription)（作用域：\(entry.scope)）", log: Log.hotKey)
                continue
            }

            let identifier = hotKeyCenter.register(shortcut.hotKey) { [weak self] in
                self?.run(shortcut: shortcut, scope: entry.scope)
            }
            if let identifier { registeredHotKeyIDs.append(identifier) }
        }

        if plan.isEmpty {
            Log.debug("当前作用域没有配置快捷键", log: Log.hotKey)
        } else {
            Log.info("快捷键已绑定 \(registeredHotKeyIDs.count)/\(plan.count) 条" +
                     "（前台：\(info?.displayName ?? "无")）", log: Log.hotKey)
        }
    }

    private func run(shortcut: KeyboardShortcutDTO, scope: String) {
        Log.info("⌨️ 快捷键触发：\(shortcut.readableDescription)（作用域：\(scope)）", log: Log.hotKey)
        shortcut.action.action.run()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.frontmostAppMonitor.refreshNow()
            if let info = self.frontmostAppMonitor.snapshot(), !info.isSelf {
                self.refreshInjection(for: info)
            }
        }
    }

    /// 界面上的改动及时生效：重载规则 + 重绑快捷键 + 立即重建当前前台的 Touch Bar
    private func observeRuleStore() {
        ruleStoreObserver = NotificationCenter.default.addObserver(
            forName: RuleStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.ruleEngine.reload()
                self.statusBarController.refreshInjectionItem()
                // 快捷键可能被增删改 → 立刻重绑（不必等下一次切换应用）
                self.bindShortcuts(for: self.frontmostAppMonitor.snapshot())

                // 正在注入的栏要重建，否则用户得切一次应用才能看到改动
                if let info = self.frontmostAppMonitor.snapshot(), !info.isSelf {
                    self.refreshInjection(for: info)
                }
            }
    }

    /// 按当前前台应用重新计算并呈现（无论之前有没有在展示）
    private func refreshInjection(for info: FrontmostAppInfo) {
        guard AppSettings.shared.backgroundTouchBarEnabled, SystemModalTouchBarPresenter.isAvailable else {
            backgroundPresenter.dismiss()
            return
        }
        guard let definition = ruleEngine.resolve(bundleIdentifier: info.bundleIdentifier) else {
            backgroundPresenter.dismiss()
            return
        }
        backgroundPresenter.present(definition)
    }

    // MARK: - ③ 后台动态注入

    private func startBackgroundTouchBar() {
        if !SystemModalTouchBarPresenter.isAvailable {
            Log.error("⚠️ 当前系统不支持后台 Touch Bar 注入，第三阶段降级为「仅监听 + 日志」", log: Log.touchBar)
        }

        frontmostAppMonitor.onChange = { [weak self] info in
            self?.handleFrontmostAppChange(info)
        }
        frontmostAppMonitor.start()
    }

    private func toggleBackgroundInjection() {
        let enabled = !AppSettings.shared.backgroundTouchBarEnabled
        AppSettings.shared.backgroundTouchBarEnabled = enabled
        statusBarController.refreshInjectionItem()
        Log.info("后台注入 Touch Bar：\(enabled ? "开启" : "关闭")", log: Log.touchBar)

        if enabled {
            frontmostAppMonitor.refreshNow()
        } else {
            backgroundPresenter.dismiss()
        }
    }

    /// 每次前台应用变化的核心处理流程
    private func handleFrontmostAppChange(_ info: FrontmostAppInfo?) {
        // 快捷键必须跟着前台应用走 —— 放在最前面，保证即使 Touch Bar 关闭也会正确切换
        bindShortcuts(for: info)

        guard let info else {
            backgroundPresenter.dismiss()
            return
        }

        // 自己成为前台 → 交给第二阶段的窗口 Touch Bar，撤掉注入的那条
        if info.isSelf {
            Log.debug("前台是我们自己，跳过注入", log: Log.touchBar)
            backgroundPresenter.dismiss()
            return
        }

        guard AppSettings.shared.backgroundTouchBarEnabled else {
            backgroundPresenter.dismiss()
            return
        }

        // 规则引擎：按 Bundle ID 决定展示哪一条
        guard let definition = ruleEngine.resolve(bundleIdentifier: info.bundleIdentifier) else {
            Log.debug("「\(info.displayName)」未命中规则且未开启全局注入 → 不注入", log: Log.touchBar)
            backgroundPresenter.dismiss()
            return
        }

        // 已展示的正是这一条时不必重建（避免切换窗口时 Touch Bar 闪烁）
        if backgroundPresenter.isPresenting,
           backgroundPresenter.currentDefinitionIdentifier == definition.customizationIdentifier {
            return
        }

        backgroundPresenter.present(definition)
    }

    // MARK: - 权限引导

    private func setupAccessibility() {
        let granted = AccessibilityPermission.isTrusted
        Log.info("辅助功能权限：\(granted ? "已授权" : "未授权")")
        statusBarController.updateAccessibility(granted: granted)

        if !granted {
            // 首次启动弹一次系统授权窗口（未签名的调试构建可能不弹，菜单里提供了手动入口）
            AccessibilityPermission.checkOrPrompt()
        }

        // 🔴 必须由 self 强引用持有：Monitor 内部只被 RunLoop 弱引用 Timer 的 block，
        //    如果这里用 `_ =` 或局部变量接住，Monitor 会被立刻释放 → Timer 失效 →
        //    菜单永远停在「检测中…」。
        permissionMonitor = AccessibilityPermission.startMonitoring { [weak self] granted in
            self?.statusBarController.updateAccessibility(granted: granted)
            if granted {
                // 拿到权限后立刻补一次完整刷新（窗口标题、注入、快捷键都依赖它）
                self?.frontmostAppMonitor.refreshNow()
            }
        }
    }
}
