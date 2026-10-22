import AppKit

/// 第二阶段的 Touch Bar 宿主窗口。
///
/// 为什么需要一个窗口：
/// `NSTouchBar` 的响应链起点是「当前 key window」。我们的应用是 LSUIElement（无 Dock 图标、
/// 默认没有窗口），如果没有任何窗口处于 key 状态，系统就无从询问我们的 Touch Bar。
/// 因此这里提供一个**可选的**宿主窗口：`makeTouchBar()` 返回我们自己的 NSTouchBar。
/// 窗口本身可有可无（也可做成 1x1 透明窗口），保留可见窗口更利于调试和演示。
final class TouchBarHostWindow: NSWindow {
    /// 由窗口控制器注入
    weak var touchBarHost: TouchBarHost?

    override func makeTouchBar() -> NSTouchBar? {
        touchBarHost?.touchBar
    }
}

final class TouchBarHostWindowController: NSWindowController, NSWindowDelegate {
    private let host: TouchBarHost

    init(definition: TouchBarDefinition) {
        self.host = TouchBarHost(definition: definition)

        let window = TouchBarHostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "btTool · Touch Bar 宿主"
        window.touchBarHost = host
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        buildContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现：本工程不使用 Storyboard/XIB")
    }

    /// 让窗口成为前台，从而让系统询问（并展示）我们的 Touch Bar
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(self)
        window?.makeKeyAndOrderFront(nil)
        Log.info("已展示 Touch Bar 宿主窗口，Touch Bar 将显示：\(host.definition.items.map(\.title))",
                 log: Log.touchBar)
    }

    // MARK: - NSResponder（Touch Bar 入口）

    override func makeTouchBar() -> NSTouchBar? {
        host.touchBar
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Log.info("Touch Bar 宿主窗口关闭（前台 Touch Bar 随之消失）", log: Log.touchBar)
    }

    // MARK: - UI

    private func buildContentView() {
        guard let window else { return }
        let label = NSTextField(wrappingLabelWithString: """
            btTool · 第二阶段演示

            1. 请确认此窗口处于最前（它是 key window）；
            2. 此时看你的 Touch Bar，应出现「测试A / 测试B」两个按钮；
            3. 点击它们，会在控制台输出日志（测试B 还会发一条通知）。

            提示：带 Touch Bar 的 Mac 或开启「Touch Bar 模拟」的 Xcode 才能看到效果。
            """)
        label.isSelectable = true
        label.font = NSFont.systemFont(ofSize: 13)
        label.frame = NSRect(x: 24, y: 24, width: window.frame.width - 48, height: window.frame.height - 48)
        label.autoresizingMask = [.width, .height]
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(label)
    }
}
