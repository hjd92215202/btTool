import ApplicationServices
import Foundation

/// 用 Accessibility API 读取**任意应用**的聚焦窗口标题。
///
/// 这一层是第三阶段「按前台应用做精细化定制」的关键增强：
/// NSWorkspace 只能告诉你「用户现在在 Safari」，而 AX 能告诉你「用户现在在 Safari 的哪个窗口/标签页」，
/// 从而做到「同一个 App、不同窗口 → 不同 Touch Bar」。
///
/// ⚠️ 调用前请务必先用 `AccessibilityPermission.isTrusted` 判断，未授权时直接返回 nil，
///    否则 macOS 会静默失败（甚至弹出系统授权框打断用户）。
enum AXWindowInspector {
    /// AX 调用的等待上限（秒）。
    ///
    /// 🔴 不设超时时，`AXUIElementCopyAttributeValue` 碰上**无响应的应用**会一直等下去，
    /// 而 `FrontmostAppMonitor.currentInfo()` 是在**主线程**上调它的 —— 结果是整个 App 卡死。
    /// 设了超时，最坏情况只是拿不到标题（返回 nil），主线程不会被拖住。
    private static let messagingTimeout: Float = 0.3

    static func focusedWindowTitle(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        var focusedWindowValue: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(application,
                                                         kAXFocusedWindowAttribute as CFString,
                                                         &focusedWindowValue)
        guard windowStatus == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let window = focusedWindowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        var titleValue: CFTypeRef?
        let titleStatus = AXUIElementCopyAttributeValue(window,
                                                        kAXTitleAttribute as CFString,
                                                        &titleValue)
        guard titleStatus == .success else { return nil }
        return titleValue as? String
    }

    /// 可选：读取当前聚焦窗口里正在编辑的文本控件值（示例，展示 AX 的可扩展能力）
    static func focusedElementDescription(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application,
                                                   kAXFocusedUIElementAttribute as CFString,
                                                   &value)
        guard status == .success, let element = value else { return nil }
        return CFCopyDescription(element) as String?
    }
}
