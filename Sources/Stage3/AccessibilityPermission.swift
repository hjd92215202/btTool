import AppKit
import ApplicationServices
import Foundation

/// 辅助功能（Accessibility）权限检测与引导。
///
/// 为什么需要它：
/// 1. 读取前台应用的**窗口标题**只能通过 AX API（NSWorkspace 只能拿到应用级别信息）；
/// 2. 从后台投递模拟按键（CGEvent）需要「输入监控」权限；
/// 3. 后续若要直接操作其他应用的 UI / 做更激进的注入，同样依赖 AX。
///
/// 注意：`AXIsProcessTrusted()` 的结果**不会**实时回调给我们，
/// 所以下面用 Timer 轮询 + 变化回调来驱动 UI 刷新（这是业界通用做法）。
enum AccessibilityPermission {
    /// 是否已获得辅助功能权限（不会弹窗）
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 检测并（如未授权）**弹出系统授权窗口**，返回当前是否已授权。
    /// - Important: 系统只会为「已签名且位于 /Applications」的构建弹窗一次，
    ///   调试期可反复删除授权记录：`sudo tccutil reset Accessibility com.bttool.app`
    @discardableResult
    static func checkOrPrompt() -> Bool {
        // kAXTrustedCheckOptionPrompt 在 Swift 中被导入为 Unmanaged<CFString>
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 跳转到系统设置的辅助功能页面
    static func revealInSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 权限变化监听器（轮询实现）
    ///
    /// ## 两个曾经让菜单栏「永远停在检测中…」的坑
    ///
    /// 1. **「只上报变化」**：`lastKnownValue` 在 init 时就等于当前值，
    ///    如果启动时**已经**授权，之后永远不会有「变化」，回调一次都不会触发。
    ///    → 现在 `start()` 里立刻上报一次当前值（首帧同步）。
    ///
    /// 2. **Timer 只在默认 RunLoop 模式里跑**：`Timer.scheduledTimer` 注册到 `.default` 模式，
    ///    而**菜单展开时主 RunLoop 处于 `.eventTracking` 模式**，
    ///    默认模式的 Timer 会直接停摆 —— 用户刚好是在菜单打开时看的，自然永远等不到刷新。
    ///    → 现在手动 `add(_:forMode: .common)`，跟踪模式与默认模式都会派发。
    final class Monitor {
        private var timer: Timer?
        private var lastKnownValue: Bool
        var onChange: ((Bool) -> Void)?

        init() {
            lastKnownValue = AccessibilityPermission.isTrusted
        }

        func start(interval: TimeInterval = 1.5) {
            stop()

            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.poll()
            }
            timer.tolerance = 0.5
            // .common 覆盖 default + eventTracking + modalPanel，菜单打开期间也不会停摆
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer

            // 首帧同步：立刻把当前状态推给 UI，绝不留下「检测中…」这种中间态
            poll(forceReport: true)
        }

        private func poll(forceReport: Bool = false) {
            let current = AccessibilityPermission.isTrusted
            if !forceReport {
                guard current != lastKnownValue else { return }
                Log.info("辅助功能权限变化 → \(current ? "已授权" : "未授权")")
            }
            lastKnownValue = current
            onChange?(current)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        deinit { stop() }
    }

    static func startMonitoring(interval: TimeInterval = 1.5,
                                onChange: @escaping (Bool) -> Void) -> Monitor {
        let monitor = Monitor()
        monitor.onChange = onChange
        monitor.start(interval: interval)
        return monitor
    }
}
