import AppKit
import ObjectiveC

// MARK: - 私有 API 探测表

/// ⚠️ 以下是 **Apple 未公开（private / SPI）** 的 API。
///
/// 工作原理（第三阶段的核心突破点）：
/// `NSTouchBar` 上存在一个私有类方法
/// `+presentSystemModalTouchBar:systemTrayItemIdentifier:`
/// （macOS 10.12.1 beta 里曾命名为 `...SystemModalFunctionBar:...`，后续版本改名）。
///
/// 它的作用是：**让任意一个进程把自己构造的 NSTouchBar 交给 Touch Bar Server（DFR 守护进程）以
/// "系统模态" 方式展示**，并在 Control Strip 区域留下一个入口项（identifier 即第二个参数）。
/// 这正是 BetterTouchTool / Pock / MTMR 等工具能在后台改写 Touch Bar 的根本机制。
///
/// 为什么公开 API 做不到：
/// 公开的 `NSTouchBar` 只能挂在响应链上（NSApplication / NSWindow / NSResponder），
/// 只有**前台应用**的响应链会被系统询问；后台应用无法介入。
///
/// 风险与对策（代码里全部做了兜底）：
/// 1. 不同 macOS 版本选择器名称/签名不同 → 运行时逐个探测 `class_getClassMethod`，命中才调用；
/// 2. 系统版本不再提供该 API → `isAvailable == false`，自动降级，绝不崩溃；
/// 3. 反复 present 会在 Control Strip 堆积入口 → 使用**固定不变**的 systemTrayItemIdentifier；
/// 4. 私有 API 无法上架 Mac App Store。
private enum SystemModalTouchBarAPI {
    /// (选择器, 是否带 placement 参数)
    static let presentCandidates: [(selector: Selector, hasPlacement: Bool)] = [
        (NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"), false),
        (NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"), true),
        (NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:"), false),
        (NSSelectorFromString("presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:"), true),
    ]

    static let presentSelector: (selector: Selector, hasPlacement: Bool)? = {
        for candidate in presentCandidates {
            guard let method = class_getClassMethod(NSTouchBar.self, candidate.selector) else { continue }
            guard Self.matchesExpectedSignature(method, hasPlacement: candidate.hasPlacement) else {
                Log.debug("跳过 \(candidate.selector)：签名编码不符（实际 \(Self.typeEncoding(of: method) ?? "?"))",
                          log: Log.touchBar)
                continue
            }
            return candidate
        }
        Log.debug("未找到任何签名匹配的 present 选择器", log: Log.touchBar)
        return nil
    }()

    /// placement 取值（私有枚举，经验值：1 = 系统模态 / 覆盖 Control Strip 区域）
    static let placement: Int = 1

    // MARK: - 签名校验（arm64 崩溃的唯一可靠事前防御）

    /// Swift 无法 `try/catch` Objective-C 异常，一旦 `objc_msgSend` 的参数类型写错，
    /// arm64 下必然是 EXC_BAD_ACCESS（寄存器错乱），连崩溃栈都拿不到。
    /// 所以**调用前**必须校验私有方法的 Type Encoding：类型和参数个数都对齐才允许调用。
    ///
    /// - 返回值：`v`（void）
    /// - 隐式参数：`@`(self，类方法下是 Class) `:`(_cmd)
    /// - 显式参数：`@`(NSTouchBar) [`q`/`Q`(NSInteger placement)] `@`(NSString)
    ///
    /// ⇒ 两参数版本的期望编码是 **`v@:@@`**；三参数（带 placement）是 **`v@:@q@`**。
    ///
    /// ⚠️ `method_getTypeEncoding` 在 macOS 上会带 offset 数字（本机实测：
    /// `v32@0:8@16@24` 与 `v40@0:8@16q24@32`），所以比对前先把数字全部剔除只比类型序列。
    /// 这几个期望值是用 /tmp 下的探针程序实测打印出来的，切勿凭记忆修改。
    static func matchesExpectedSignature(_ method: Method, hasPlacement: Bool) -> Bool {
        guard let rawEncoding = typeEncoding(of: method) else { return false }
        let normalized = rawEncoding.filter { !$0.isNumber }

        let expectedEncodings = hasPlacement ? ["v@:@q@", "v@:@Q@"] : ["v@:@@"]
        let expectedArgumentCount = hasPlacement ? 5 : 4

        guard expectedEncodings.contains(normalized) else { return false }
        return method_getNumberOfArguments(method) == expectedArgumentCount
    }

    static func typeEncoding(of method: Method) -> String? {
        guard let raw = method_getTypeEncoding(method) else { return nil }
        return String(cString: raw)
    }

    /// Control Strip 常驻项（右侧托盘图标）的注册 / 注销
    static let addTrayItemSelector: Selector? = {
        let selector = NSSelectorFromString("addSystemTrayItem:")
        guard ObjCRuntime.classMethodExists(on: NSTouchBarItem.self, selector) else { return nil }
        // 签名必须是 v@:@（void + 一个对象参数），否则 arm64 上直接崩
        guard let method = class_getClassMethod(NSTouchBarItem.self, selector),
              let raw = method_getTypeEncoding(method) else { return nil }
        return String(cString: raw).filter { !$0.isNumber } == "v@:@" ? selector : nil
    }()

    static let removeTrayItemSelector: Selector? = {
        ["removeSystemTrayItem:"].map(NSSelectorFromString)
            .first { ObjCRuntime.classMethodExists(on: NSTouchBarItem.self, $0) }
    }()

    static let dismissSelector: Selector? = {
        ["dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"]
            .map(NSSelectorFromString)
            .first { ObjCRuntime.classMethodExists(on: NSTouchBar.self, $0) }
    }()

    static let minimizeSelector: Selector? = {
        ["minimizeSystemModalTouchBar:", "minimizeSystemModalFunctionBar:"]
            .map(NSSelectorFromString)
            .first { ObjCRuntime.classMethodExists(on: NSTouchBar.self, $0) }
    }()
}

// MARK: - 后台注入器

/// 第三阶段的呈现器：在应用处于后台（无窗口、非前台）时，把自定义 Touch Bar 注入系统。
///
/// 它和 `TouchBarHostWindowController`（第二阶段）实现同一个协议 `TouchBarPresenting`，
/// 因此 AppCoordinator 可以用同一行代码 `presenter.present(definition)` 驱动两种完全不同的机制。
final class SystemModalTouchBarPresenter: NSObject, TouchBarPresenting {
    /// Control Strip 常驻托盘项的标识。
    /// 🔴 必须固定且全局唯一：它是托盘图标与左侧模态栏的“绑定键”，
    /// 反复注册同一个 identifier 不会在 Control Strip 里堆积，也不会让图标闪一下再消失。
    static let trayItemIdentifier = "btTool.controlStrip.trayItem"

    /// 强引用 host —— `NSTouchBar.delegate` 是 weak，一旦 host 被释放，
    /// 系统会拿不到任何 item（表现为“注入了但整条栏是空的”）。这是最常见的坑。
    private var host: TouchBarHost?

    /// Control Strip 托盘项。必须强引用：`addSystemTrayItem:` 不 retain 外部对象，
    /// 一旦释放，右侧图标会静默消失（且系统里残留一个僵尸标识）。
    private var trayItem: NSCustomTouchBarItem?

    /// 硬件上**真的**正在显示我们这条栏（`NSTouchBar.isVisible`）。
    ///
    /// 用户点叉时系统只是把栏收走、不会通知我们，所以这里必须读可见性而不是 `host != nil`；
    /// 但**不再**用它做“自动重燃”判据 —— 新架构由用户点托盘图标决定展开/收回。
    var isPresenting: Bool { host?.touchBar.isVisible ?? false }

    /// 用户点了右侧托盘图标（由 AppCoordinator 决定展开还是收回）
    var onTrayItemClicked: (() -> Void)?

    /// 系统把展开的栏收走了（点叉 / 被其它系统模态抢占）。
    /// KVO 监听 `touchBar.isVisible`，实测同一毫秒回调；这里只用于同步“已收起”状态，
    /// 绝不再自动拉回 —— 那正是上一版 0.6s 轮询的问题所在。
    var onSystemDismissed: (() -> Void)?

    /// `isVisible` 的 KVO 观察者；每次换 host 必须重建，dismiss 时必须失效。
    private var visibilityObservation: NSKeyValueObservation?

    /// 当前已注入的那条定义的标识（用于去重，避免切换应用时 Touch Bar 无谓重建/闪烁）
    var currentDefinitionIdentifier: NSTouchBar.CustomizationIdentifier? {
        host?.definition.customizationIdentifier
    }

    /// 当前系统是否支持后台注入
    static var isAvailable: Bool {
        SystemModalTouchBarAPI.presentSelector != nil
    }

    // MARK: TouchBarPresenting

    func present(_ definition: TouchBarDefinition) {
        guard let api = SystemModalTouchBarAPI.presentSelector else {
            Log.error("当前系统不支持系统模态 Touch Bar 注入（私有 API 不可用），已跳过", log: Log.touchBar)
            return
        }

        // 🟢 P2：内容没变就别重建。present 必然是"先销毁再重新注入"，
        // 在切窗口 / 切标签页这类高频场景里会表现为长栏连续闪动。
        if isPresenting, currentDefinitionIdentifier == definition.customizationIdentifier {
            Log.debug("长栏内容未变，跳过重建：\(definition.customizationIdentifier)", log: Log.touchBar)
            return
        }

        // 先销毁上一条，避免叠加
        dismiss()

        let host = TouchBarHost(definition: definition)

        // 尝试关掉系统模态栏左侧的「×」（按函数名字面语义：false = 不显示）
        DFRFoundationBridge.setShowsSystemModalCloseBoxWhenFrontMost(false)

        let invoked = invokePresent(selector: api.selector,
                                    hasPlacement: api.hasPlacement,
                                    touchBar: host.touchBar)

        // ⚠️ 即便调用失败也要决定是否持有：不持有则本轮注入没有意义（防止泄漏），
        //    但 log 必须如实标记失败，方便排查（不会造成"看起来成功其实没成功"）。
        guard invoked else {
            DFRFoundationBridge.setShowsSystemModalCloseBoxWhenFrontMost(true)
            Log.error("调用私有 present 选择器失败（签名校验未通过），本次注入已放弃", log: Log.touchBar)
            return
        }

        self.host = host
        observeVisibility(of: host.touchBar)
        Log.info("已向系统注入 Touch Bar：\(definition.customizationIdentifier)" +
                 "（items: \(definition.items.map(\.title))）", log: Log.touchBar)
    }

    func dismiss() {
        // 先拆 KVO 再动手：dismiss 自身也会把 isVisible 打回 false，
        // 若不先失效，会被误判成“系统收走了”，状态机来回抖。
        visibilityObservation?.invalidate()
        visibilityObservation = nil

        guard let host else { return }
        // 🔴 无论私有选择器是否可用，都必须清掉强引用 —— 否则 TouchBarHost/NSTouchBar 永久泄漏，
        //    而且下次 present 会因为 dismiss() 提前返回而叠加。
        defer { self.host = nil }

        let touchBar = host.touchBar
        if let selector = SystemModalTouchBarAPI.dismissSelector {
            ObjCRuntime.sendVoid(NSTouchBar.self, selector, touchBar)
            DFRFoundationBridge.setShowsSystemModalCloseBoxWhenFrontMost(true)
            Log.info("已销毁注入的 Touch Bar", log: Log.touchBar)
        } else if let selector = SystemModalTouchBarAPI.minimizeSelector {
            ObjCRuntime.sendVoid(NSTouchBar.self, selector, touchBar)
            DFRFoundationBridge.setShowsSystemModalCloseBoxWhenFrontMost(true)
            Log.info("已收起注入的 Touch Bar（minimize）", log: Log.touchBar)
        } else {
            Log.error("dismiss / minimize 选择器均不可用，仅释放本地引用" +
                      "（系统栏由 Touch Bar Server 自行回收，不会影响本进程稳定性）", log: Log.touchBar)
        }
    }

    // MARK: - Control Strip 托盘（右侧常驻图标）

    /// 是否支持托盘常驻（不同系统版本可能只提供 present，不提供 addSystemTrayItem）
    static var canInstallTrayItem: Bool { SystemModalTouchBarAPI.addTrayItemSelector != nil }

    var isTrayItemInstalled: Bool { trayItem != nil }

    /// 把 "BT" 图标常驻到右侧 Control Strip。
    ///
    /// 和「系统模态栏」的区别：
    /// - 系统模态栏（present）是**左侧长栏**，会占满整条 Touch Bar、并且用户点叉就能收走；
    /// - 托盘项（addSystemTrayItem）是**右侧小图标**，由系统常驻管理，点叉也收不走。
    ///
    /// 两者的 identifier 保持同一个常量，系统才能把它们识别成“同一个 App 的入口与面板”。
    ///
    /// ## 两层私有 API 的分工（本轮补齐，2026-10-23 实测）
    ///
    /// 1. **AppKit 层** `+addSystemTrayItem:` —— 负责**创建** item（把 `NSTouchBarItem` 登记进去）；
    /// 2. **DFR 层** `DFRElementSetControlStripPresenceForIdentifier(id, present)` ——
    ///    负责向 Touch Bar Server **开关该项的存在性**（不创建 item，必须先有第 1 步）。
    ///
    /// 两者是串联关系：`addSystemTrayItem` 之后必须再 `presence = YES`，
    /// 拆除时反过来先 `presence = NO` 再 `removeSystemTrayItem`。
    ///
    /// ⚠️ 仍然要如实说明（macOS 12.7.6 / ad-hoc）：图标**至今没有肉眼可见的证据**。
    ///
    /// 🟢 **已推翻的旧结论**：以前这里写的是「缺 `com.apple.private.controlstrip` 导致被拦截」。
    ///    该结论**证据不足，已作废** —— 两个反证：
    ///    ① MTMR（`Toxblh/MTMR`，`TouchBarController.swift:288-299`）用的是**完全相同**的两个调用
    ///       和相同顺序，Info.plist 与 entitlements 里都没有该特权；
    ///    ② "签了它之后 spawn failed" 只能说明**受限 entitlement 需要 provisioning profile**，
    ///       推不出"托盘依赖它"。
    ///    所以现在的原因标记为 **待验证**，并在 `diagnoseTrayRegistration()` 里列出
    ///    已排除 / 未验证的变量清单。
    func installTrayItem() {
        guard let selector = SystemModalTouchBarAPI.addTrayItemSelector else {
            Log.error("addSystemTrayItem: 选择器不存在 → Control Strip 托盘不可用。" +
                      "请用菜单栏「【调试】强行展开左侧 Touch Bar」验证左侧长栏", log: Log.touchBar)
            return
        }
        guard trayItem == nil else { return }   // 幂等：重复调用不会堆叠

        DFRFoundationBridge.startupDiagnostics()

        let item = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier(Self.trayItemIdentifier))
        item.customizationLabel = "btTool"

        // ⬇︎ 对齐 MTMR 的权威写法：便捷构造器 + 模板图，**不指定 frame / 不覆盖 bezelStyle**
        //   （MTMR: NSButton(image: #imageLiteral(resourceName:"StatusImage"), target:action:)）
        let button = NSButton(image: Self.makeTrayIcon(),
                              target: self,
                              action: #selector(trayItemClicked(_:)))
        button.toolTip = "btTool：展开 / 收回自定义 Touch Bar"
        item.view = button

        ObjCRuntime.sendVoid(NSTouchBarItem.self, selector, item)
        trayItem = item
        // DFR 层：向 Touch Bar Server 声明该项存在（必须先 addSystemTrayItem，否则无对象可开关）
        DFRFoundationBridge.setControlStripPresence(identifier: Self.trayItemIdentifier, present: true)
        Log.info("已发起 Control Strip 托盘注册：\(Self.trayItemIdentifier)" +
                 "（AppKit + DFR 存在性开关都已调用，是否上屏需肉眼确认）", log: Log.touchBar)
        diagnoseTrayRegistration()
    }

    /// 幂等地确保托盘存在 —— 供「应用被激活」等高频事件调用。
    ///
    /// - 已注册 → **只重申 DFR 存在性**，绝不重复 `addSystemTrayItem:`（重复注册会堆积 item）；
    /// - 未注册 → 走完整的 `installTrayItem()`。
    ///
    /// 为什么要做成幂等：`NSApplication.didBecomeActiveNotification` 的触发频率不低
    /// （点菜单栏、点托盘按钮、配置窗口…），不做去重就等于高频重注册。
    func ensureTrayItemInstalled() {
        guard trayItem != nil else {
            Log.info("托盘未注册 → 按激活事件补注册", log: Log.touchBar)
            installTrayItem()
            return
        }
        DFRFoundationBridge.setControlStripPresence(identifier: Self.trayItemIdentifier, present: true)
        Log.debug("托盘已存在 → 仅向 Touch Bar Server 重申存在性", log: Log.touchBar)
    }

    /// 托盘注册后的诊断。**只列事实与变量，不下"属预期行为"这类结论**。
    ///
    /// 旧版在这里断言「未持有 private.controlstrip → 不显示属预期行为，不是 bug」，
    /// 那是循环论证，已作废（反证见本文件顶部）。
    private func diagnoseTrayRegistration() {
        Log.info("【P0·对照依据】MTMR(Toxblh/MTMR) TouchBarController.swift:288-299 用的是" +
                 "「addSystemTrayItem: → DFRElementSetControlStripPresenceForIdentifier」" +
                 "**完全相同**的序列，且不持有 com.apple.private.controlstrip。" +
                 "→ 缺该特权**不能**解释图标不显示。", log: Log.touchBar)
        Log.info("【P0·已对齐 MTMR 的项】调用顺序 / 主线程 / applicationDidFinishLaunching 之后 / " +
                 "accessory 激活策略 / 模板图 + NSButton(image:...) 便捷构造", log: Log.touchBar)
        Log.info("【P0·未验证的变量】① Info.plist LSUIElement 键（MTMR=1；本项目=无，靠运行时 " +
                 "setActivationPolicy(.accessory)）；② Hardened Runtime（make build HARDENED=0 可 A/B）；" +
                 "③ 系统设置→键盘→Touch Bar 呈现模式；④ TouchBarServer 缓存（sudo pkill TouchBarServer）",
                 log: Log.touchBar)
        Log.info("【P0·可观察量】注册线程=\(Thread.isMainThread ? "main" : "⚠️ 非主线程")；" +
                 "Control Strip 用户定制项=[\(Self.controlStripCustomizedItems())]",
                 log: Log.touchBar)
        Log.info("【P0·特权自省】本进程持有 com.apple.private.controlstrip：" +
                 "\(EntitlementCheck.hasControlStripEntitlement ? "是" : "否")" +
                 "（MTMR 同样为「否」，故它不能作为判据）", log: Log.touchBar)
    }

    /// 读取用户当前的 Control Strip 定制清单（`com.apple.controlstrip` → `MiniCustomized`）。
    /// 这是目前**唯一**能从外部观测"托盘项有没有被服务端接受"的指标。
    private static func controlStripCustomizedItems() -> String {
        let value = CFPreferencesCopyAppValue("MiniCustomized" as CFString,
                                              "com.apple.controlstrip" as CFString)
        guard let array = value as? [String] else { return "读取失败或为空" }
        return array.joined(separator: ", ")
    }

    /// 托盘按钮的**模板**图标。
    ///
    /// Control Strip 里的系统图标都是模板图（`isTemplate = true`：只有形状 + alpha，
    /// 颜色由系统统一给），彩色位图在深/浅色主题下都会突兀，MTMR 用的也是自绘模板图。
    ///
    /// 🔴 为什么不能再拿 `NSApp.applicationIconImage`：本项目**没有 .icns 资源**
    ///（`Resources/` 下只有 Info.plist 与 entitlements，Info.plist 里也没有 `CFBundleIconFile`），
    /// 所以那只是系统占位图标，不是我们自己的图标。
    /// 托盘按钮的**模板**图标 —— **这是 P0 真机上真正生效的修法**（详见 README 第 7 节）。
    ///
    /// 🔴 旧实现（不显示）：`NSButton(frame: 44×30)` + `bezelStyle = .rounded`
    ///    + `NSApp.applicationIconImage`。本项目**没有 .icns 资源**，
    ///    所以 `applicationIconImage` 拿到的是系统**占位**图标（且是彩色位图、非模板图）。
    /// 🟢 现实现（A/B/C 三种签名配置下都实测可见）：与 MTMR 一致的写法 ——
    ///    **模板图 + `NSButton(image:target:action:)` 便捷构造**，不指定 frame、不覆盖 bezelStyle。
    ///
    /// 模板图约定：`isTemplate = true`，只有形状 + alpha，颜色由系统统一给；
    /// 彩色位图在深/浅色主题下都会突兀。
    private static func makeTrayIcon() -> NSImage {
        if #available(macOS 11.0, *) {
            if let symbol = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                    accessibilityDescription: "btTool") {
                symbol.isTemplate = true
                return symbol
            }
        }
        // 10.15 回退：自绘模板图（纯黑 + 透明）
        let image = NSImage(size: NSSize(width: 26, height: 18))
        image.lockFocus()
        ("BT" as NSString).draw(in: NSRect(x: 0, y: 2, width: 26, height: 14),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                                 .foregroundColor: NSColor.black])
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// 销毁托盘（关闭后台注入 / 进程退出时调用）。
    ///
    /// 顺序与注册严格相反：**先关 DFR 存在性，再 `removeSystemTrayItem:`**，
    /// 否则 Server 那边会短暂残留一个已经没有 owner 的标识。
    func removeTrayItem() {
        guard let item = trayItem else { return }
        trayItem = nil
        DFRFoundationBridge.setControlStripPresence(identifier: Self.trayItemIdentifier, present: false)
        if let selector = SystemModalTouchBarAPI.removeTrayItemSelector {
            ObjCRuntime.sendVoid(NSTouchBarItem.self, selector, item)
            Log.info("已从 Control Strip 移除托盘项（DFR 存在性已先置 NO）", log: Log.touchBar)
        }
    }

    @objc private func trayItemClicked(_ sender: NSButton) {
        Log.info("Control Strip 托盘被点击", log: Log.touchBar)
        onTrayItemClicked?()
    }

    // MARK: - 系统收回侦测（只同步状态，不再自动重燃）

    /// 监听 `isVisible`。用户点叉 / 被其它系统模态抢占时 `isVisible` 立刻变 false，
    /// 我们只把“已展开”状态翻回 false，让下一次点托盘图标能重新展开。
    private func observeVisibility(of touchBar: NSTouchBar) {
        visibilityObservation?.invalidate()
        visibilityObservation = touchBar.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            guard let self, self.host != nil else { return }
            // KVO 回调跟随属性变更线程；NSTouchBar 的可见性由主线程更新，这里再兜一层。
            // 内层必须再次 weak：observation 持有闭包，强引用 self 会形成环，deinit 永远不来。
            DispatchQueue.main.async { [weak self] in
                // 必须是"同一条" bar：若期间已经换过一条，旧 bar 的延迟回调不能误报
                guard let self, self.host?.touchBar === touchBar, !touchBar.isVisible else { return }
                Log.info("系统收回了展开的 Touch Bar（点叉 / 被抢占），只剩右侧托盘", log: Log.touchBar)
                self.onSystemDismissed?()
            }
        }
    }

    deinit {
        // 对象被回收时兜底清理，避免 host 悬挂在 Touch Bar Server 里
        dismiss()
    }

    // MARK: - 私有 API 调用

    /// 执行一次 present。**返回是否真的调用了**（签名校验不通过时会拒绝调用并 return false）。
    ///
    /// 为什么每个分支都要单独写 typealias：
    /// arm64 上 `objc_msgSend` 直接从寄存器取参，**没有任何栈上的隐式修正**。
    /// 函数类型必须与方法真实签名逐位一致：
    ///   - 第 1/2 个隐式参数永远是 `AnyClass`(x0) + `Selector`(x1)，与 OC 的 (id self, SEL _cmd) 同宽；
    ///   - `NSTouchBar` / `NSString` 都是单个 ObjC 指针（x2…）；
    ///   - placement 是 `NSInteger`（64 位环境下 = `Int`，与先前的 `Int64` 同宽，
    ///     但用 `Int` 才能和 NSInteger 的类型定义保持严格一致）；
    ///   - 返回值必须声明为 `Void`：原方法返回 void，若误写成对象返回类型，
    ///     Swift 会按 "返回值已 retain" 处理（甚至试图 release），导致随机崩溃。
    @discardableResult
    private func invokePresent(selector: Selector, hasPlacement: Bool, touchBar: NSTouchBar) -> Bool {
        guard let raw = ObjCRuntime.msgSend else {
            Log.error("无法定位 objc_msgSend", log: Log.touchBar)
            return false
        }

        // 二次校验：即便外部已经在 presentSelector 里筛过一次，
        // 真正调用前再确认一次 method 仍然存在且签名匹配（防止运行时被 swizzle）。
        guard let method = class_getClassMethod(NSTouchBar.self, selector),
              SystemModalTouchBarAPI.matchesExpectedSignature(method, hasPlacement: hasPlacement) else {
            Log.error("方法或签名已变化，拒绝调用 \(selector)：" +
                      "\(SystemModalTouchBarAPI.typeEncoding(of: class_getClassMethod(NSTouchBar.self, selector)!) ?? "?")",
                      log: Log.touchBar)
            return false
        }

        // 必须显式桥接成 NSString —— 私有 API 的参数编码是 '@'，传 Swift String 桥接后也是 '@'，
        // 但显式转换可以避免任何 autorelease 时机问题。
        // 与托盘项同一个 identifier：系统据此把“右侧图标”和“左侧长栏”绑成一对
        let identifier = Self.trayItemIdentifier as NSString
        let cls: AnyClass = NSTouchBar.self

        if hasPlacement {
            typealias PresentWithPlacement = @convention(c) (AnyClass, Selector, NSTouchBar, Int, NSString) -> Void
            let fn = unsafeBitCast(raw, to: PresentWithPlacement.self)
            fn(cls, selector, touchBar, SystemModalTouchBarAPI.placement, identifier)
        } else {
            typealias PresentPlain = @convention(c) (AnyClass, Selector, NSTouchBar, NSString) -> Void
            let fn = unsafeBitCast(raw, to: PresentPlain.self)
            fn(cls, selector, touchBar, identifier)
        }
        return true
    }

}
