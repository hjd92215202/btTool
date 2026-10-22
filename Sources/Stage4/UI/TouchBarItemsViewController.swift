import AppKit

/// 「触控栏」标签页：某个作用域下的按钮列表 + 选中按钮的编辑器。
///
/// 作用域可能是「某个应用」，也可能是「全局（All Apps）」—— 后者编辑的是兜底通用栏，
/// 这也是为什么这里只认 `RuleScope` 而不认 Bundle ID。
final class TouchBarItemsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var scope: RuleScope?
    private var selectedItemID: String?

    private let tableView = NSTableView()
    private let emptyHint = NSTextField(labelWithString: "还没有任何按钮，点击右上角 + 添加一个")
    private let editorViewController = RuleItemEditorViewController()
    private var storeObserver: NSObjectProtocol?

    private var items: [TouchBarItemModel] {
        guard let scope else { return [] }
        return RuleStore.shared.items(in: scope)
    }

    // MARK: - 生命周期

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        editorViewController.onDidEdit = { [weak self] editedItemID in
            // 只重绘被编辑的那一行，避免整表 reloadData 打断用户焦点
            self?.reloadRow(editedItemID)
        }
        storeObserver = NotificationCenter.default.addObserver(
            forName: RuleStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reloadItems(preservingSelection: true)
            }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    // MARK: - 对外接口

    func showScope(_ scope: RuleScope?) {
        _ = view     // 子控制器视图懒加载：先确保 buildUI 跑过，再刷新数据
        self.scope = scope
        selectedItemID = nil
        // ⚠️ 不要在这里追加 `editorViewController.edit(scope:itemID:nil)`：
        // `reloadItems` 内部已经处理了「有条目 → 选中第一条」「无条目 → 清空编辑器」两种情况，
        // 再多调一次 nil 会把刚建立好的行约束链清空（实测表现为编辑区只剩第一行、其余行叠在一起）。
        reloadItems(preservingSelection: false)
    }

    // MARK: - UI

    private func buildUI() {
        let addButton = makeIconButton(symbol: NSImage.addTemplateName,
                                       tooltip: "添加一个触控栏按钮",
                                       target: self, action: #selector(addItem(_:)))
        let removeButton = makeIconButton(symbol: NSImage.removeTemplateName,
                                          tooltip: "删除选中的按钮",
                                          target: self, action: #selector(removeItem(_:)))
        let bar = makeSectionBar(title: "触控栏按钮", controls: [addButton, removeButton])
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "touchBarItemColumn"))
        column.width = 420
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.dataSource = self
        tableView.delegate = self

        emptyHint.textColor = .secondaryLabelColor
        let scrollView = makeTableScrollView(tableView: tableView, emptyHint: emptyHint)

        addChild(editorViewController)
        let editorBox = makeFormBox(title: "编辑选中按钮",
                                    contentView: editorViewController.view,
                                    height: Metrics.editorHeight)

        // ⚠️ 顺序很重要：必须先把子视图加进视图树，再激活约束，
        //    否则 AppKit 找不到「共同祖先」会直接抛运行时异常。
        for subview in [bar, scrollView, editorBox] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Metrics.sectionBarHeight),

            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            editorBox.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Metrics.rowSpacing),
            editorBox.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorBox.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorBox.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - 数据

    /// 精确刷新某一行（改标题 / 改颜色后立刻生效，无需重新选中）
    private func reloadRow(_ editedItemID: String?) {
        guard let editedItemID else { reloadItems(preservingSelection: true); return }
        guard let index = items.firstIndex(where: { $0.identifier.rawValue == editedItemID }) else {
            reloadItems(preservingSelection: true)
            return
        }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                             columnIndexes: IndexSet(integer: 0))
        emptyHint.isHidden = true
    }

    private func reloadItems(preservingSelection: Bool) {
        let models = items
        emptyHint.isHidden = !models.isEmpty
        tableView.reloadData()

        if preservingSelection, let selectedItemID,
           let index = models.firstIndex(where: { $0.identifier.rawValue == selectedItemID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return
        }
        if let first = models.first {
            select(first.identifier.rawValue, index: 0)
        } else {
            selectedItemID = nil
            editorViewController.edit(scope: scope, itemID: nil)
        }
    }

    private func select(_ itemID: String, index: Int) {
        selectedItemID = itemID
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        editorViewController.edit(scope: scope, itemID: itemID)
    }

    // MARK: - Actions

    @objc private func addItem(_ sender: Any) {
        guard let scope else { return }
        RuleStore.shared.addItem(to: scope, title: "新按钮")
        // 选中刚加的最后一项（store 的 add 会发通知触发 reload，这里补一次选中即可）
        if let last = RuleStore.shared.items(in: scope).last {
            selectedItemID = last.identifier.rawValue
            editorViewController.edit(scope: scope, itemID: last.identifier.rawValue)
        }
    }

    @objc private func removeItem(_ sender: Any) {
        guard let scope, let selectedItemID else { return }
        RuleStore.shared.removeItem(from: scope, itemID: selectedItemID)
        self.selectedItemID = nil
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TouchBarItemCell")
        let cell: ItemCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ItemCellView {
            cell = reused
        } else {
            cell = ItemCellView(frame: .zero)
            cell.identifier = identifier
        }
        guard let model = items.dropFirst(row).first else { return cell }
        cell.configure(color: model.bezelColor,
                       title: model.title,
                       subtitle: ActionDTO(model.action).summary)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let models = items
        guard tableView.selectedRow >= 0, tableView.selectedRow < models.count else { return }
        let itemID = models[tableView.selectedRow].identifier.rawValue
        guard itemID != selectedItemID else { return }
        select(itemID, index: tableView.selectedRow)
    }
}
