import AppKit

/// 主配置窗口的两栏布局（左侧应用列表 / 右侧按钮编辑）。
///
/// 用 `NSSplitViewController` + `NSSplitViewItem(sidebarWithViewController:)`，
/// 左侧自动获得 macOS 的侧边栏视觉（配合 vibrancy 效果），与 BTT 的观感一致。
final class SettingsSplitViewController: NSSplitViewController {
    private let listViewController = RuleListViewController()
    private let detailViewController = RuleDetailViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        listViewController.onSelectScope = { [weak self] scopeID in
            self?.detailViewController.showScope(id: scopeID)
        }

        let listItem = NSSplitViewItem(sidebarWithViewController: listViewController)
        listItem.minimumThickness = 220
        listItem.maximumThickness = 360
        listItem.canCollapse = false
        addSplitViewItem(listItem)

        let detailItem = NSSplitViewItem(viewController: detailViewController)
        // 右栏要塞下「列表 + 编辑区」两坨内容，给一个明确的下限，窄了就直接让窗口出现滚动条
        detailItem.minimumThickness = 560
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
        splitView.isVertical = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 初次显示时把分隔条放到 260pt，之后由用户拖拽决定
        splitView.setPosition(260, ofDividerAt: 0)
    }
}
