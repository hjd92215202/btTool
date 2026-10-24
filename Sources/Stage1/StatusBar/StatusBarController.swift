import AppKit

/// 菜单栏常驻 UI。
///
/// 职责边界：只做「展示 + 转发事件」，所有业务逻辑通过 `Hooks` 回调交给 AppCoordinator。
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Hooks {
        var onAbout: (() -> Void)?
        var onShowSettingsWindow: (() -> Void)?
        var onToggleBackgroundInjection: (() -> Void)?
        var onRevealAccessibilitySettings: (() -> Void)?
        var onQuit: (() -> Void)?
        /// 【调试】绕过 Control Strip 托盘，直接开合左侧长栏
        var onToggleTouchBarExpansion: (() -> Void)?
        /// 【调试】查询长栏当前是否展开（菜单打开时刷新标题用）
        var onQueryTouchBarExpanded: (() -> Bool)?
        /// 查询长栏内容会跟随哪个应用（菜单里显示，让「点托盘会发生什么」可预期）
        var onQueryTouchBarTarget: (() -> String?)?
    }

    var hooks = Hooks()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var menu: NSMenu?
    private var accessibilityItem: NSMenuItem?
    private var injectionItem: NSMenuItem?
    private var expansionItem: NSMenuItem?
    /// P1：只读模式自救入口（存档能正常读写时全部隐藏）
    private var readOnlyItem: NSMenuItem?
    private var resetItem: NSMenuItem?
    private var restoreItem: NSMenuItem?
    /// P1：外部修改提示（存档被 btTool 之外的进程改过才显示）
    private var externalItem: NSMenuItem?
    /// 长栏内容会跟着哪个应用走（菜单里显示，让「点托盘会发生什么」可预期）
    private var targetItem: NSMenuItem?

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
    /// 【调试】强行展开 / 收回左侧 Touch Bar   （临时入口，等价点右侧托盘图标）
    /// 辅助功能权限：已授权 ✅ / 未授权 ⚠️（点击前往设置）
    /// ─────────────────────
    /// 退出 btTool                ⌘Q
    /// ```
    ///
    /// 被下线的研发探针：
    /// - 「显示 Touch Bar 宿主窗口…」：第二阶段调试用；宿主窗口现在只在「Dock 图标重新激活」时出现；
    /// - 「全局快捷键：⌥Space（测试：唤起计算器）」：置灰的静态提示，已随全局快捷键功能一并下线；
    /// - 「当前前台应用：—」：实时性没意义，排障时看 `~/Library/Logs/btTool/btTool.log` 更准。
    private func buildMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "关于 btTool", action: #selector(showAbout(_:)), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        // 🟢 长栏内容跟着哪个应用走 —— 让「点托盘会发生什么」可预期
        let target = NSMenuItem(title: "长栏目标：—", action: nil, keyEquivalent: "")
        target.isEnabled = false
        targetItem = target
        menu.addItem(target)

        // ⌘, 母语手感：NSMenuItem 的 keyEquivalent 默认带 ⌘ 掩码
        menu.addItem(withTitle: "打开配置主窗口…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
            .target = self

        let injection = NSMenuItem(title: "后台注入 Touch Bar",
                                   action: #selector(toggleBackgroundInjection(_:)),
                                   keyEquivalent: "")
        injection.target = self
        injectionItem = injection
        menu.addItem(injection)

        // 🔧 临时调试入口：接管 Control Strip 托盘的职责。
        //    ad-hoc 签名的包在 macOS 12 上注册托盘项会被静默丢弃（见 presenter 诊断日志），
        //    所以提供一个必达入口，直接 present / dismiss 左侧长栏。
        let expansion = NSMenuItem(title: "【调试】强行展开左侧 Touch Bar",
                                   action: #selector(toggleTouchBarExpansion(_:)),
                                   keyEquivalent: "")
        expansion.target = self
        expansion.toolTip = "绕过右侧 Control Strip 托盘，直接 present / dismiss 左侧系统模态长栏"
        expansionItem = expansion
        menu.addItem(expansion)

        let accessibility = NSMenuItem(title: "辅助功能权限：检测中…",
                                       action: #selector(revealAccessibilitySettings(_:)),
                                       keyEquivalent: "")
        accessibility.target = self
        accessibilityItem = accessibility
        menu.addItem(accessibility)

        // 🟢 P1 数据保护：存档读不出来时的**自救入口**，只在只读模式下显示
        let readOnly = NSMenuItem(title: "⚠️ 规则未保存（只读模式）",
                                  action: nil,
                                  keyEquivalent: "")
        readOnly.isEnabled = false
        readOnly.isHidden = true
        readOnlyItem = readOnly
        menu.addItem(readOnly)

        let reset = NSMenuItem(title: "用默认值重置并恢复写入…",
                               action: #selector(resetRulesToDefaults(_:)),
                               keyEquivalent: "")
        reset.target = self
        reset.isHidden = true
        resetItem = reset
        menu.addItem(reset)

        let restore = NSMenuItem(title: "从备份恢复…",
                                 action: #selector(restoreRulesFromBackup(_:)),
                                 keyEquivalent: "")
        restore.target = self
        restore.isHidden = true
        restoreItem = restore
        menu.addItem(restore)

        let external = NSMenuItem(title: "⚠️ 规则文件被外部修改过",
                                  action: #selector(showExternalModificationAlert(_:)),
                                  keyEquivalent: "")
        external.target = self
        external.isHidden = true
        externalItem = external
        menu.addItem(external)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 btTool", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        self.menu = menu
        // 每次打开菜单都刷新调试项标题（展开 ↔ 收回），避免显示过期状态
        menu.delegate = self
        statusItem.menu = menu

        refreshInjectionItem()
        updateExpansionItem()
    }

    // MARK: - NSMenuDelegate

    /// 每次打开菜单前刷新各状态项，避免显示过期信息。
    ///
    /// ⚠️ 这里原来是个空壳：类声明了 `NSMenuDelegate`、也设置了 `menu.delegate`，
    /// 但一个 delegate 方法都没实现（协议方法全是 optional，编译器不吭声）——
    /// 于是「长栏目标」「调试项标题」永远停留在 install() 时的初始值。
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshInjectionItem()
        updateExpansionItem()
        refreshTargetItem()
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

    /// 按真实上屏状态刷新调试项文案（"展开" / "收回"）
    func updateExpansionItem() {
        guard let expansionItem else { return }
        let expanded = hooks.onQueryTouchBarExpanded?() ?? false
        expansionItem.title = expanded
            ? "【调试】收回左侧 Touch Bar"
            : "【调试】强行展开左侧 Touch Bar"
    }

    // MARK: - 长栏目标

    /// 刷新「长栏内容会跟着哪个应用走」这行说明。
    ///
    /// 这比原来那行「长栏不可用」有用：它告诉用户**点托盘会发生什么**。
    /// 而原来那行依赖的判断本身就是错的（用进程级的激活策略当窗口级状态用，
    /// 详见 AppCoordinator.toggleTouchBarExpansion 里的说明）。
    private func refreshTargetItem() {
        targetItem?.title = "长栏目标：\(hooks.onQueryTouchBarTarget?() ?? "—（还没有别的前台应用）")"
    }

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

    /// 【调试】绕过托盘，直接驱动 `AppCoordinator.toggleTouchBarExpansion()`
    @objc private func toggleTouchBarExpansion(_ sender: Any) {
        hooks.onToggleTouchBarExpansion?()
    }

    /// P1：只读模式下，只有用户**明确选择**「用默认值重置」才恢复写入。
    ///
    /// 为什么必须弹确认：一旦重置，内存里那些没落盘的改动就没了。
    /// 用户的原文件我们不碰（进只读模式时已备份），所以必须由他自己决定。
    @objc private func resetRulesToDefaults(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "用默认值重置规则？"
        alert.informativeText = "当前的规则改动不会被保存。你的原文件已备份，可随时从备份恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RuleStore.shared.resetToDefaults()
    }

    /// P1：把最近一次自动备份覆盖回主文件。备份本身也读不出来时会重新进入只读模式。
    @objc private func restoreRulesFromBackup(_ sender: Any) {
        NSApp.activate(ignoringOtherApps: true)
        if RuleStore.shared.restoreFromBackup() {
            let alert = NSAlert()
            alert.messageText = "已恢复"
            alert.informativeText = "已从备份文件恢复规则，现在可以正常保存了。"
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "恢复失败"
            alert.informativeText = "备份文件本身也读不出来，或没有可用备份。"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// P1：提示规则文件被外部改动过。
    ///
    /// 这条提示本身不是"洁癖"：别人能改这个文件，就等价于能让 btTool 执行他写的
    /// Shell / AppleScript 命令 —— 所以必须让用户看见。
    @objc private func showExternalModificationAlert(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "规则文件在 btTool 之外被修改过"
        alert.informativeText = """
        有人（或某个程序）在 btTool 之外改动了规则文件，改动内容已经生效。

        能改这个文件，就等价于能让 btTool 执行任意 Shell / AppleScript 命令，
        所以请确认这些改动是你自己做的。若不是，建议：
        · 用默认值重置规则；
        · 检查文件权限（我们已把存档设为 0600）。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "我知道了")
        alert.addButton(withTitle: "在访达中显示")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() != .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([RuleStore.shared.fileURL])
        }
        RuleStore.shared.acknowledgeExternalModification()
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
