import Foundation

/// `DFRFoundation` —— Apple 的私有框架（DFR = "D* Function Row"，Touch Bar 的内部代号），
/// 位于 `/System/Library/PrivateFrameworks/DFRFoundation.framework`。
///
/// 我们**不链接**它（链接私有框架会在启动时直接 dyld 崩溃），而是运行时 `dlopen` + `dlsym`：
/// - 成功 → 可以使用增强能力；
/// - 失败（SIP / 系统版本变化 / 框架被移除）→ 自动降级，App 照常运行。
///
/// 已知符号（随系统版本变化，务必做空判断）：
/// - `DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL)`：控制系统模态 Touch Bar 左侧是否显示关闭按钮。
enum DFRFoundationBridge {
    private static let candidatePaths = [
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/Versions/A/DFRFoundation",
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
    ]

    private static let handle: UnsafeMutableRawPointer? = {
        for path in candidatePaths {
            if let handle = dlopen(path, RTLD_NOW) {
                Log.info("已加载 DFRFoundation：\(path)", log: Log.touchBar)
                return handle
            }
        }
        Log.debug("DFRFoundation 不可用（SIP / 系统版本差异），相关增强能力将自动降级", log: Log.touchBar)
        return nil
    }()

    static var isLoaded: Bool { handle != nil }

    /// 通用符号查找
    static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// 符号是否存在（用于启动时自检日志，避免"以为生效其实静默失败"）
    static func hasSymbol(_ name: String) -> Bool {
        guard let handle else { return false }
        return dlsym(handle, name) != nil
    }

    // MARK: - 已实测存在的符号（macOS 12.7.6 / 21H1320 实测）

    /// 自检清单：`dlsym` 真正成功的符号才会出现在这里。
    ///
    /// ⚠️ 实测结论（重要，2026-10-23 修正）：
    /// `DFRFoundation` 里**没有**"凭空造出托盘项"的 C 函数 —— 试过的全部 miss：
    /// `DFRSystemModalRegisterIdentifier`、`DFRSystemModalUnregisterIdentifier`、
    /// `DFRTouchBarAddSystemTrayItem`、`DFRControlStripSetVisible` 等 16 个候选名。
    ///
    /// 但**存在**一个"把已注册项的**存在性**开关掉"的函数：
    /// `DFRElementSetControlStripPresenceForIdentifier`（上一轮 16 个候选恰好漏了它，
    /// 本轮补测后确认存在）。它只能开关存在性，**不能凭空创建 item** ——
    /// item 仍必须由 AppKit 的 `+addSystemTrayItem:` 注册。
    static func startupDiagnostics() {
        guard isLoaded else {
            Log.debug("DFRFoundation 未加载，跳过符号自检", log: Log.touchBar)
            return
        }
        let found = Self.candidateSymbols.filter { hasSymbol($0) }
        Log.info("DFRFoundation 可用符号：\(found.isEmpty ? "（无）" : found.joined(separator: ", "))",
                 log: Log.touchBar)
    }

    private static let candidateSymbols = [
        "DFRSetStatus",
        "DFRElementSetControlStripPresenceForIdentifier",
        "DFRSystemModalShowsCloseBoxWhenFrontMost",
        "DFRFoundationPostEventWithMouseActivity",
    ]

    /// `DFRElementSetControlStripPresenceForIdentifier(NSString *identifier, BOOL present)`
    ///
    /// 作用：向 Touch Bar Server 声明「这个 identifier 的托盘项是否在 Control Strip 里存在」。
    /// 注意**它不创建 item**，只负责存在性开关；item 必须先经 `+addSystemTrayItem:` 注册。
    ///
    /// ⚠️ 关于签名（诚实说明）：这个函数没有任何公开的类型编码可查（`nm` 读不到共享缓存镜像），
    /// 我用的验证方法是——按 `(CFString, Bool) -> Void` 连续调用 3 次，进程未崩溃，
    /// 且与社区（MTMR / Pock 系）流传的签名一致。**它没有返回值可校验**，
    /// 所以"传对了"只是不崩溃层面的证据，不是行为层面的证据。
    static func setControlStripPresence(identifier: String, present: Bool) {
        typealias Fn = @convention(c) (CFString, Bool) -> Void
        guard let function: Fn = symbol("DFRElementSetControlStripPresenceForIdentifier") else {
            Log.debug("DFRElementSetControlStripPresenceForIdentifier 不可用，跳过存在性设置",
                      log: Log.touchBar)
            return
        }
        function(identifier as CFString, present)
    }

    static var supportsControlStripPresence: Bool {
        hasSymbol("DFRElementSetControlStripPresenceForIdentifier")
    }

    /// 控制系统模态 Touch Bar 左侧是否显示关闭按钮（那个会把我们的栏收走的「×」）。
    ///
    /// ⚠️ 语义按函数名**字面**理解：`shows == true` → 显示 ×，`false` → 隐藏。
    /// 以前这里传的是 `true`（误以为代表 hidden），很可能正是无论如何都还能看到 × 的原因。
    ///
    /// ⚠️ 另一个坑：函数名里的 `WhenFrontMost` —— 它管的是「**我们自己的 App 在前台**」时那条栏的 ×，
    /// 而后台注入的场景里前台是别人的 App（Chrome/Safari…），此时这个开关大概率被 Touch Bar Server 忽略。
    /// 所以它只能锦上添花，不能作为"常驻"的唯一保证。
    static func setShowsSystemModalCloseBoxWhenFrontMost(_ shows: Bool) {
        typealias Fn = @convention(c) (Bool) -> Void
        guard let function: Fn = symbol("DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            Log.debug("DFRSystemModalShowsCloseBoxWhenFrontMost 不可用，跳过", log: Log.touchBar)
            return
        }
        function(shows)
    }

    /// `DFRSetStatus(Int32)` —— 符号**确实存在**，但它的取值语义在不同系统版本上不一致，
    /// 而且副作用是直接改变整条 Touch Bar 的显示状态（无人值守实测有可能把用户的栏打成空白）。
    ///
    /// 因此：**只绑定、不自动调用**。保留绑定是为了将来在有硬件、有人盯着时能一次性验证：
    /// `setTouchBarStatus(1)` / `(2)` 各试一次，肉眼确认哪个是"恢复系统默认"。
    static func setTouchBarStatus(_ status: Int32) {
        typealias Fn = @convention(c) (Int32) -> Void
        guard let function: Fn = symbol("DFRSetStatus") else {
            Log.debug("DFRSetStatus 不可用，跳过", log: Log.touchBar)
            return
        }
        function(status)
    }

    static var supportsStatusControl: Bool { hasSymbol("DFRSetStatus") }
    static var supportsCloseBoxControl: Bool { hasSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost") }
}
