import AppKit

/// 当前前台应用的信息快照。
struct FrontmostAppInfo: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    /// 聚焦窗口的标题（需要辅助功能权限，未授权时为 nil）
    let focusedWindowTitle: String?

    var displayName: String {
        localizedName ?? bundleIdentifier ?? "未知应用"
    }

    var isSelf: Bool {
        processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}

/// 监听系统前台应用的变化（Safari → VS Code → Chrome …）。
///
/// 实现说明：
/// - 主路径：`NSWorkspace` 的 `didActivateApplicationNotification` 等通知（**不需要任何权限**）；
/// - 增强：拿到前台 app 后，再用 Accessibility API 读取它的聚焦窗口标题（需要权限，缺失时自动降级）；
/// - 防抖：快速切换应用（⌘Tab 连按）会产生多次通知，这里合并为一次回调，避免 Touch Bar 抖动。
final class FrontmostAppMonitor {
    /// 前台应用变化回调（主线程）
    var onChange: ((FrontmostAppInfo?) -> Void)?

    /// 防抖间隔
    var debounceInterval: TimeInterval = 0.25

    /// 是否尝试读取聚焦窗口标题（需要辅助功能权限）
    var resolvesWindowTitle: Bool = true

    private var observers: [NSObjectProtocol] = []
    private var pendingWork: DispatchWorkItem?
    private var lastInfo: FrontmostAppInfo?

    func start() {
        guard observers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,    // 主路径：某应用被激活
            NSWorkspace.didDeactivateApplicationNotification,  // 某应用失去前台
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,   // 前台应用退出后需要重新判定
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            }
            observers.append(observer)
        }

        Log.info("开始监听前台应用变化", log: Log.workspace)
        scheduleRefresh()
    }

    func stop() {
        pendingWork?.cancel()
        pendingWork = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        Log.info("停止监听前台应用变化", log: Log.workspace)
    }

    /// 立即同步一次（不防抖）
    func refreshNow() {
        apply(info: currentInfo())
    }

    /// 只取快照，不触发回调（第四阶段在窗口关闭后主动重建 Touch Bar 时用）
    func snapshot() -> FrontmostAppInfo? {
        currentInfo()
    }

    // MARK: - 内部

    private func scheduleRefresh() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWork = nil
            self.apply(info: self.currentInfo())
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func apply(info: FrontmostAppInfo?) {
        // 去重：内容没变就不重复回调（避免无意义的 Touch Bar 重建）
        guard info != lastInfo else { return }
        lastInfo = info

        if let info {
            Log.info("前台应用切换 → \(info.displayName)" +
                     "（\(info.bundleIdentifier ?? "无 BundleID")）",
                     log: Log.workspace)
            // 窗口标题是敏感内容（可能是文件名 / 邮件标题 / 网页标题，甚至带账号信息）：
            // 文件里只留摘要，正文走 os_log 的 debug 级（默认不落盘）
            if let title = info.focusedWindowTitle {
                Log.sensitive("当前窗口标题", title, log: Log.workspace)
            }
        } else {
            Log.info("无前台应用信息", log: Log.workspace)
        }
        onChange?(info)
    }

    private func currentInfo() -> FrontmostAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let title = (resolvesWindowTitle && AccessibilityPermission.isTrusted)
            ? AXWindowInspector.focusedWindowTitle(pid: pid)
            : nil
        return FrontmostAppInfo(processIdentifier: pid,
                                bundleIdentifier: app.bundleIdentifier,
                                localizedName: app.localizedName,
                                focusedWindowTitle: title)
    }

    deinit { stop() }
}
