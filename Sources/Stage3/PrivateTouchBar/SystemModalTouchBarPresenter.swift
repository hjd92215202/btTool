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
final class SystemModalTouchBarPresenter: TouchBarPresenting {
    /// Control Strip 上我们那个入口项的标识。
    /// 🔴 必须固定！否则每次切换前台应用都会在系统里新增一个条目，用户会发现 Control Strip 越来越长。
    static let systemTrayItemIdentifier = "btTool.controlStrip"

    /// 强引用 host —— `NSTouchBar.delegate` 是 weak，一旦 host 被释放，
    /// 系统会拿不到任何 item（表现为“注入了但整条栏是空的”）。这是最常见的坑。
    private var host: TouchBarHost?

    var isPresenting: Bool { host != nil }

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

        // 先销毁上一条，避免叠加
        dismiss()

        let host = TouchBarHost(definition: definition)

        // 隐藏系统模态栏左侧的关闭按钮，让注入结果更像原生 Control Strip
        DFRFoundationBridge.setSystemModalCloseBoxHidden(true)

        let invoked = invokePresent(selector: api.selector,
                                    hasPlacement: api.hasPlacement,
                                    touchBar: host.touchBar)

        // ⚠️ 即便调用失败也要决定是否持有：不持有则本轮注入没有意义（防止泄漏），
        //    但 log 必须如实标记失败，方便排查（不会造成"看起来成功其实没成功"）。
        guard invoked else {
            DFRFoundationBridge.setSystemModalCloseBoxHidden(false)
            Log.error("调用私有 present 选择器失败（签名校验未通过），本次注入已放弃", log: Log.touchBar)
            return
        }

        self.host = host
        Log.info("已向系统注入 Touch Bar：\(definition.customizationIdentifier)" +
                 "（items: \(definition.items.map(\.title))）", log: Log.touchBar)

        if AppSettings.shared.experimentalControlStripItem {
            tryRegisterControlStripItem()
        }
    }

    func dismiss() {
        guard let host else { return }
        // 🔴 无论私有选择器是否可用，都必须清掉强引用 —— 否则 TouchBarHost/NSTouchBar 永久泄漏，
        //    而且下次 present 会因为 dismiss() 提前返回而叠加。
        defer { self.host = nil }

        let touchBar = host.touchBar
        if let selector = SystemModalTouchBarAPI.dismissSelector {
            ObjCRuntime.sendVoid(NSTouchBar.self, selector, touchBar)
            DFRFoundationBridge.setSystemModalCloseBoxHidden(false)
            Log.info("已销毁注入的 Touch Bar", log: Log.touchBar)
        } else if let selector = SystemModalTouchBarAPI.minimizeSelector {
            ObjCRuntime.sendVoid(NSTouchBar.self, selector, touchBar)
            DFRFoundationBridge.setSystemModalCloseBoxHidden(false)
            Log.info("已收起注入的 Touch Bar（minimize）", log: Log.touchBar)
        } else {
            Log.error("dismiss / minimize 选择器均不可用，仅释放本地引用" +
                      "（系统栏由 Touch Bar Server 自行回收，不会影响本进程稳定性）", log: Log.touchBar)
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
        let identifier = Self.systemTrayItemIdentifier as NSString
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

    /// 【实验性】尝试把入口项常驻到 Control Strip。
    ///
    /// `NSTouchBarItem` 上曾存在 `+addSystemTrayItem:` / `+removeSystemTrayItem:` 私有类方法。
    /// 不同系统上行为差异很大（有的版本会直接把整条栏常驻，有的版本无效），
    /// 因此默认关闭，由 `AppSettings.experimentalControlStripItem` 控制。
    private func tryRegisterControlStripItem() {
        let selector = NSSelectorFromString("addSystemTrayItem:")
        guard ObjCRuntime.classMethodExists(on: NSTouchBarItem.self, selector) else {
            Log.debug("addSystemTrayItem: 不存在，跳过 Control Strip 常驻实验", log: Log.touchBar)
            return
        }

        let item = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier(rawValue: Self.systemTrayItemIdentifier + ".tray"))
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 64, height: 30))
        button.title = "BT"
        button.bezelStyle = .rounded
        button.bezelColor = .controlAccentColor
        item.view = button

        ObjCRuntime.sendVoid(NSTouchBarItem.self, selector, item)
        Log.info("已尝试注册 Control Strip 常驻入口项（实验性）", log: Log.touchBar)
    }
}
