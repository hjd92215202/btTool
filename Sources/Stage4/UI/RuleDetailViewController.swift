import AppKit

/// 右栏：头部（图标 + 名称 + 说明） + `NSTabView` 双标签页。
///
/// ```
/// ┌─────────────────────────────────────────────────────────────┐
/// │ 🧭 Safari浏览器                                              │
/// │    com.apple.Safari                                          │
/// ├─────────────────────────────────────────────────────────────┤
/// │  ┌─ 触控栏 ─┐┌─ 快捷键 ─┐                                    │
/// │  └───────────────────────────────────────────┘              │
/// │   （Tab1）按钮列表 + 编辑器                                  │
/// │   （Tab2）快捷键列表 + 编辑器                                │
/// └─────────────────────────────────────────────────────────────┘
/// ```
///
/// 为什么用 `NSTabView`：把「触控栏」和「键盘快捷键」两个独立的编辑流程隔开，
/// 避免它们在同一块区域里互相挤占垂直空间（这正是之前底部控件重叠的诱因之一）。
final class RuleDetailViewController: NSViewController {
    private var scope: RuleScope?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "未选择")
    private let detailLabel = NSTextField(labelWithString: "")

    private let touchBarViewController = TouchBarItemsViewController()
    private let shortcutsViewController = ShortcutsViewController()

    // MARK: - 生命周期

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    // MARK: - 对外接口（由左栏选中时调用）

    func showScope(id: String?) {
        let scope = id.map(RuleScope.init(id:))
        self.scope = scope
        reloadHeader()
        touchBarViewController.showScope(scope)
        shortcutsViewController.showScope(scope)
    }

    // MARK: - UI

    private func buildUI() {
        nameLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        iconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let texts = NSStackView(views: [nameLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let header = NSStackView(views: [iconView, texts])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Metrics.labelGap

        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let touchBarItem = NSTabViewItem(identifier: "touchBarTab")
        touchBarItem.label = "触控栏"
        touchBarItem.viewController = touchBarViewController
        tabView.addTabViewItem(touchBarItem)

        let shortcutsItem = NSTabViewItem(identifier: "shortcutsTab")
        shortcutsItem.label = "键盘快捷键"
        shortcutsItem.viewController = shortcutsViewController
        tabView.addTabViewItem(shortcutsItem)

        for subview in [header, tabView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.padding),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.padding),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.padding),
            header.heightAnchor.constraint(equalToConstant: 40),

            tabView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.rowSpacing),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.padding),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.padding),
            // 底部也留出 padding：拒绝视觉死角
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.padding),
        ])
    }

    // MARK: - 头部

    private func reloadHeader() {
        guard let scope else {
            iconView.image = nil
            nameLabel.stringValue = "未选择"
            detailLabel.stringValue = "在左侧选择一个应用"
            return
        }

        switch scope {
        case .global:
            if #available(macOS 11.0, *) {
                iconView.image = NSImage(systemSymbolName: "globe",
                                         accessibilityDescription: "全局")
            } else {
                iconView.image = NSWorkspace.shared.icon(forFileType: "app")
            }
            nameLabel.stringValue = scope.displayName
            detailLabel.stringValue = scope.subtitle
        case .app(let bundleIdentifier):
            let descriptor = AppDescriptor(bundleIdentifier: bundleIdentifier)
            iconView.image = descriptor.icon
            nameLabel.stringValue = descriptor.name
            detailLabel.stringValue = scope.subtitle
        }
    }
}
