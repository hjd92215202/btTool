import AppKit

/// 应用委托（入口见同目录的 `main.swift`，显式引导而非 `@main`）
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 保持 accessory 策略（main.swift 里已设置，这里兜底）
        NSApp.setActivationPolicy(.accessory)

        // 允许用户在 Touch Bar 上长按唤出「自定触控栏」（第二阶段调试很方便）
        if #available(macOS 10.12.2, *) {
            NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        }

        AppCoordinator.shared.start()

        // 脚本 / 调试入口：`btTool --settings` 启动后直接打开配置主窗口
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                AppCoordinator.shared.showSettingsWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.stop()
    }

    /// LSUIElement 应用不会因窗口关闭而退出，这里保证「重复启动」时有个可用的入口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared.showTouchBarHostWindow()
        return false
    }
}
