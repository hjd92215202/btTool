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
/// # 🚨 头号纪律：静默检测 vs 弹窗检测，必须彻底分家
///
/// macOS 给的两条 API 长得很像，后果却天差地别：
///
/// | API | 行为 | 谁可以调 |
/// | --- | --- | --- |
/// | `AXIsProcessTrusted()` | **纯查询**，永不打扰用户 | ✅ 定时器、首帧同步、任何后台路径 |
/// | `AXIsProcessTrustedWithOptions([prompt: true])` | **弹系统授权窗**（并可能把焦点抢走） | ☝️ 只允许用户主动手势 |
///
/// 以前这里踩过一次：启动流程里有一句「未授权就 `checkOrPrompt()` 提示一下」，
/// 于是每次 `make run` 都要挨一次系统弹窗；叠加 ad-hoc 签名**（每次重新构建 = 新的 cdhash
/// = TCC 眼里换了一个新 App）**，表现为「连续、重复地弹窗轰炸」。
///
/// 现在的结构性防线：
/// - `silentlyProbe()` 是唯一的**静默**入口，`Monitor` 与 `isTrusted` 都只准走它；
/// - `checkOrPrompt()` 是唯一的**弹窗**入口，仅供用户手势调用，且自带节流（`minimumPromptInterval`）；
/// - 「定时器永远不弹窗」这件事由**代码结构**保证，而不是靠注释和自觉。
enum AccessibilityPermission {

    // MARK: - 静默检测（后台路径唯一入口）

    /// 纯静默查询：走的是 `AXIsProcessTrusted()`，**永不弹窗**。
    ///
    /// 定时器轮询、启动首帧同步、注入前的自检，一律只准调这里。
    static func silentlyProbe() -> Bool {
        AXIsProcessTrusted()
    }

    /// 当前是否已授权（同样是静默的）。
    static var isTrusted: Bool { silentlyProbe() }

    // MARK: - 弹窗（仅限用户主动手势）

    /// 两次弹窗之间的最小间隔：拦住"手抖连点"和将来万一又漏进来的重复调用。
    private static let minimumPromptInterval: TimeInterval = 2
    private static let promptQueue = DispatchQueue(label: "com.bttool.app.accessibility-prompt")
    private static var lastPromptAt: Date = .distantPast
    private static var promptRequestCount = 0

    /// 检测并（如未授权）**弹出一次系统授权窗口**，返回当前是否已授权。
    ///
    /// - Important: **只能在用户手势里调用**（例如点击菜单栏的「辅助功能权限：未授权 ⚠️」）。
    ///   后台定时器、启动流程一律禁止调用 —— 那正是曾经导致弹窗轰炸的原因。
    /// - Note: 节流 2s：同一窗口期内的重复请求会被丢弃，只保留静默结果。
    @discardableResult
    static func checkOrPrompt(reason: String) -> Bool {
        promptQueue.sync { () -> Bool in
            let now = Date()
            guard now.timeIntervalSince(lastPromptAt) >= minimumPromptInterval else {
                Log.debug("忽略重复的权限弹窗请求（来源：\(reason)，距上次 <\(minimumPromptInterval)s）")
                return silentlyProbe()
            }
            lastPromptAt = now
            promptRequestCount += 1
            Log.info("按用户请求触发第 \(promptRequestCount) 次辅助功能授权（来源：\(reason)）")

            // kAXTrustedCheckOptionPrompt 在 Swift 中被导入为 Unmanaged<CFString>
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options)
        }
    }

    /// 调试用：本进程至今真正请求过几次系统弹窗（跑一轮 `make run` 后应为 0）
    static var diagnosticPromptRequestCount: Int {
        promptQueue.sync { promptRequestCount }
    }

    /// 跳转到系统设置的辅助功能页面
    static func revealInSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 权限变化监听器（**全静默**轮询）

    /// 轮询实现：`AXIsProcessTrusted()` 没有回调机制，只能自己定时看。
    ///
    /// ## 三个曾经踩过的坑
    ///
    /// 1. **「只上报变化」会把首帧吞掉**：若 `lastKnownValue` 在 init 时就等于当前值，
    ///    启动时**已经**授权的机器永远等不到「变化」，菜单卡在「检测中…」。
    ///    → `lastKnownValue` 初始为 `nil`，首帧（force）必然推送一次。
    ///
    /// 2. **Timer 只在默认 RunLoop 模式里跑**：`Timer.scheduledTimer` 注册到 `.default`，
    ///    而**菜单展开时主 RunLoop 处于 `.eventTracking`**，默认模式的 Timer 直接停摆 ——
    ///    用户刚好是在菜单打开时看的。→ 手动 `add(_:forMode: .common)`。
    ///
    /// 3. 🔴 **轮询里绝不能出现带 Prompt 的 API**：一次 UserGesture 级别的疏忽，
    ///    乘以 1.5s 一次的定时器 = 系统弹窗轰炸，且后台巡检时用户根本没点任何东西。
    ///    → `tick()` 只能走 `silentlyProbe()`。
    final class Monitor {
        private var timer: Timer?
        private var lastKnownValue: Bool?
        var onChange: ((Bool) -> Void)?

        init() {
            // 故意不在这里预先探测：`lastKnownValue` 保持 nil，
            // 保证 start() 的首帧一定推送，UI 不会停在中间态。
        }

        func start(interval: TimeInterval = 1.5) {
            stop()

            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = 0.5
            // .common 覆盖 default + eventTracking + modalPanel，菜单打开期间也不会停摆
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer

            // 首帧同步：立刻把当前（静默读到的）状态推给 UI
            report(force: true)
        }

        private func tick() {
            report(force: false)
        }

        /// ⚠️ 这里是全局唯一允许刷新权限状态的地方 —— 并且**只允许静默查询**。
        private func report(force: Bool) {
            let current = AccessibilityPermission.silentlyProbe()
            if !force {
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
