import AppKit

/// 右栏：头部（图标 + 名称 + 说明） + 触控栏按钮列表编辑器。
///
/// ```
/// ┌─────────────────────────────────────────────────────────────┐
/// │ 🧭 Safari浏览器                                              │
/// │    com.apple.Safari                                          │
/// ├─────────────────────────────────────────────────────────────┤
/// │   按钮列表 + 编辑器                                          │
/// │                                                             │
/// └─────────────────────────────────────────────────────────────┘
/// ```
///
/// 这里原本是 `NSTabView` 双标签（「触控栏」+「键盘快捷键」）—— 当初是为了把
/// 两个独立的编辑流程隔开，避免它们互相挤占垂直空间。
/// **全局快捷键功能删除后只剩一个页面**，标签栏就失去意义了（只剩一个标签还
/// 白占一行），所以改成把列表直接铺满剩余区域。
final class RuleDetailViewController: NSViewController {
    private var scope: RuleScope?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "未选择")
    private let detailLabel = NSTextField(labelWithString: "")

    private let touchBarViewController = TouchBarItemsViewController()

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

        addChild(touchBarViewController)
        let listView = touchBarViewController.view

        for subview in [header, listView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.padding),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.padding),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.padding),
            header.heightAnchor.constraint(equalToConstant: 40),

            listView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.rowSpacing),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.padding),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.padding),
            // 底部也留出 padding：拒绝视觉死角
            listView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.padding),
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
