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

    /// 隐藏 / 显示系统模态 Touch Bar 的关闭按钮。
    /// 隐藏后，注入出来的栏更像是原生 Control Strip 的一部分（BTT / Pock / MTMR 都这么做）。
    static func setSystemModalCloseBoxHidden(_ hidden: Bool) {
        typealias Fn = @convention(c) (Bool) -> Void
        guard let function: Fn = symbol("DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            Log.debug("DFRSystemModalShowsCloseBoxWhenFrontMost 不可用，跳过", log: Log.touchBar)
            return
        }
        function(hidden)
    }
}
