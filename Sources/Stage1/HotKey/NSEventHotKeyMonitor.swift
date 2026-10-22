import AppKit
import Carbon.HIToolbox

/// 【备选方案】基于 `NSEvent.addGlobalMonitorForEvents` 的全局按键监听。
///
/// 与 Carbon 方案对比：
/// | 方案 | 是否需要权限 | 能否拦截事件 | 稳定性 |
/// |------|--------------|--------------|--------|
/// | Carbon RegisterEventHotKey | ❌ 不需要 | ❌（系统直接路由） | ✅ 推荐 |
/// | NSEvent 全局 monitor | ✅ 需要「输入监控」 | ✅（可修改/吞掉事件） | 一般 |
///
/// 什么时候才需要它：想监听**单个按键**（不带修饰键）、或需要改写/吞掉事件时。
/// 本工程默认不用它，仅作为可插拔实现保留。
final class NSEventHotKeyMonitor {
    private var monitor: Any?
    private var localMonitor: Any?

    /// - Parameter handler: 返回 `nil` 表示吞掉该事件（不让系统继续分发）。
    func start(mask: NSEvent.EventTypeMask,
               handler: @escaping (NSEvent) -> NSEvent?) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            _ = handler(event)
        }
        // 本应用自己成为前台时的按键（可选）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event)
        }
        Log.info("NSEvent 全局监听已启动（需要输入监控权限）", log: Log.hotKey)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
    }

    deinit { stop() }
}
