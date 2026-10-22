import AppKit

/// 菜单栏常驻 UI。
///
/// 职责边界：只做「展示 + 转发事件」，所有业务逻辑通过 `Hooks` 回调交给 AppCoordinator。
final class StatusBarController: NSObject {
    struct Hooks {
        var onAbout: (() -> Void)?
        var onShowSettingsWindow: (() -> Void)?
        var onToggleBackgroundInjection: (() -> Void)?
        var onRevealAccessibilitySettings: (() -> Void)?
        var onQuit: (() -> Void)?
    }

    var hooks = Hooks()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var menu: NSMenu?
    private var accessibilityItem: NSMenuItem?
    private var injectionItem: NSMenuItem?

    // MARK: - 安装

    func install() {
        configureButton()
        buildMenu()
        Log.info("菜单栏图标已安装")
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if #available(macOS 11.0, *),
           let symbol = NSImage(systemSymbolName: "rectangle.and.hand.point.up.left.filled",
                                accessibilityDescription: "btTool") {
            symbol.isTemplate = true
            button.image = symbol
        } else {
            button.title = "BT"
        }
        button.toolTip = "btTool"
    }

    // MARK: - 菜单

    /// 菜单结构（研发期的临时探针已全部下线）：
    ///
    /// ```
    /// 关于 btTool
    /// ─────────────────────
    /// 打开配置主窗口…            ⌘,
    /// 后台注入 Touch Bar        ✓/—
    /// 辅助功能权限：已授权 ✅ / 未授权 ⚠️（点击前往设置）
    /// ─────────────────────
    /// 退出 btTool                ⌘Q
    /// ```
    ///
    /// 被下线的研发探针：
    /// - 「显示 Touch Bar 宿主窗口…」：第二阶段调试用；宿主窗口现在只在「Dock 图标重新激活」时出现；
    /// - 「全局快捷键：⌥Space（测试：唤起计算器）」：置灰的静态提示，改由配置文件里的「快捷键」标签页驱动；
    /// - 「当前前台应用：—」：实时性没意义，排障时看 `/tmp/btTool.log` 更准。
    private func buildMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "关于 btTool", action: #selector(showAbout(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        // ⌘, 母语手感：NSMenuItem 的 keyEquivalent 默认带 ⌘ 掩码
        menu.addItem(withTitle: "打开配置主窗口…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
            .target = self

        let injection = NSMenuItem(title: "后台注入 Touch Bar",
                                   action: #selector(toggleBackgroundInjection(_:)),
                                   keyEquivalent: "")
        injection.target = self
        injectionItem = injection
        menu.addItem(injection)

        let accessibility = NSMenuItem(title: "辅助功能权限：检测中…",
                                       action: #selector(revealAccessibilitySettings(_:)),
                                       keyEquivalent: "")
        accessibility.target = self
        accessibilityItem = accessibility
        menu.addItem(accessibility)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 btTool", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        statusItem.menu = menu

        refreshInjectionItem()
    }

    // MARK: - 状态刷新（由 Coordinator 调用）

    func updateAccessibility(granted: Bool) {
        accessibilityItem?.title = granted
            ? "辅助功能权限：已授权 ✅"
            : "辅助功能权限：未授权 ⚠️（点击前往设置）"
        accessibilityItem?.toolTip = granted
            ? "已获得辅助功能权限"
            : "点击打开「系统设置 → 隐私与安全性 → 辅助功能」，勾选 btTool"
    }

    func refreshInjectionItem() {
        injectionItem?.state = AppSettings.shared.backgroundTouchBarEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func showAbout(_ sender: Any) {
        if let action = hooks.onAbout {
            action()
        } else {
            NSApplication.shared.orderFrontStandardAboutPanel(options: [:])
        }
    }

    @objc private func showSettingsWindow(_ sender: Any) {
        hooks.onShowSettingsWindow?()
    }

    @objc private func toggleBackgroundInjection(_ sender: Any) {
        hooks.onToggleBackgroundInjection?()
    }

    @objc private func revealAccessibilitySettings(_ sender: Any) {
        hooks.onRevealAccessibilitySettings?()
    }

    @objc private func quit(_ sender: Any) {
        if let action = hooks.onQuit {
            action()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }
}
