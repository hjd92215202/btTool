import AppKit

/// GUI 配置主窗口控制器。
///
/// 三个关键点：
/// 1. **单例**：菜单里反复点击不会出现多个窗口，状态也能保留；
/// 2. **激活策略切换**：`showWindow` 时切成 `.regular`（有 Dock 图标 + 主菜单），
///    关闭时切回 `.accessory`（回到纯菜单栏常驻）；
/// 3. **关闭回调**：通过 `onDidClose` 通知 `AppCoordinator` 恢复后台注入。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// 窗口关闭回调（由 AppCoordinator 注入）
    var onDidClose: (() -> Void)?

    /// 注意：这里用 `init()` + `super.init(window:)`，而不是 convenience init ——
    /// 因为本类同时实现了 `init(coder:)`，Swift 就不会再自动继承父类的 designated init。
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "btTool 配置"
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        contentViewController = SettingsSplitViewController()

        // ⚠️ 赋值 contentViewController 时，NSWindow 会把窗口尺寸改成「内容视图的 fitting size」——
        //    本工程的分栏最小厚度是 220 + 560，于是窗口被压成 781×528（实测值），
        //    右侧编辑区被挤得很难看。所以这里**在赋值之后**重新设定尺寸与下界。
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.contentMinSize = NSSize(width: 880, height: 640)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现：本工程不使用 Storyboard/XIB")
    }

    override func showWindow(_ sender: Any?) {
        // 先在 NSApp 层面准备好主菜单（regular 策略下必须要有）
        MainMenuBuilder.installIfNeeded()
        ActivationPolicyController.becomeRegular()

        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("已打开配置主窗口：策略=\(NSApp.activationPolicy() == .regular ? "regular" : "其它") 窗口数=\(NSApp.windows.count)")
        if let window {
            Log.info("  frame=\(window.frame) 可见=\(window.isVisible) key=\(window.isKeyWindow)")
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onDidClose?()
        Log.info("配置主窗口关闭")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 窗口成为 key window 时，确保策略仍是 regular（用户可能从别处触发）
        if NSApp.activationPolicy() != .regular {
            ActivationPolicyController.becomeRegular()
        }
    }
}
