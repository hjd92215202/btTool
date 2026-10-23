import AppKit
import Carbon.HIToolbox

/// 「键盘快捷键」标签页。
///
/// ## 生效时机（务必和运行时的注册逻辑保持一致）
/// - 「全局」作用域：常驻注册，任何应用在前台都能触发；
/// - 「某应用」作用域：只有它处于前台时才会被 `AppCoordinator` 动态注册；
/// - 组合重复时，**先出现者优先**（全局优先于应用），后者会被忽略并在列表里标红提示。
final class ShortcutsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var scope: RuleScope?
    private var selectedShortcutID: String?

    private let tableView = NSTableView()
    private let emptyHint = NSTextField(labelWithString: "还没有任何快捷键，点击右上角 + 添加一条")
    private var storeObserver: NSObjectProtocol?

    // 编辑器控件：录制框一个控件替代「下拉框 + 4 个复选框 + 预览标签」
    private let recorder = ShortcutRecorderField()
    private let actionEditor = ActionEditorView()

    private var editorRows: [FormRow] = []
    private var formRows: [NSView] = []
    private let formLayout = VerticalFormLayout()

    /// 当前编辑中的组合（keyCode + 修饰键），与 `selectedShortcutID` 一一对应
    private var draftKeyCode: UInt16 = UInt16(kVK_Space)
    private var draftModifiers: UInt64 = CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue

    private var shortcuts: [KeyboardShortcutDTO] {
        guard let scope else { return [] }
        return RuleStore.shared.shortcuts(in: scope)
    }

    // MARK: - 生命周期

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        actionEditor.onDidEdit = { [weak self] in self?.commit() }
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
        // 同 RuleItemEditorViewController：子控制器的视图是懒加载的，
        // 通知链在 viewDidLoad 之前回调到这里会踩空 → 访问 `view` 强制同步加载。
        _ = view
        self.scope = scope
        selectedShortcutID = nil
        reloadItems(preservingSelection: false)
        updateEditor()
    }

    // MARK: - UI

    private func buildUI() {
        let addButton = makeIconButton(symbol: NSImage.addTemplateName,
                                       tooltip: "添加一条键盘快捷键",
                                       target: self, action: #selector(addShortcut(_:)))
        let removeButton = makeIconButton(symbol: NSImage.removeTemplateName,
                                          tooltip: "删除选中的快捷键",
                                          target: self, action: #selector(removeShortcut(_:)))
        let bar = makeSectionBar(title: "键盘快捷键", controls: [addButton, removeButton])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "shortcutColumn"))
        column.width = 420
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self

        emptyHint.textColor = .secondaryLabelColor
        let scrollView = makeTableScrollView(tableView: tableView, emptyHint: emptyHint)

        let editorBox = makeFormBox(title: "编辑选中的快捷键",
                                    contentView: buildEditorContent(),
                                    height: Metrics.editorHeight)

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

    private func buildEditorContent() -> NSView {
        // 全局 / 应用级快捷键没有修饰键会被运行时拒绝注册，所以录制时就挡住
        recorder.requiresModifier = true
        recorder.onCapture = { [weak self] combo in
            guard let self, self.selectedShortcutID != nil, let keyCode = combo.keyCode else { return }
            self.draftKeyCode = keyCode
            self.draftModifiers = combo.modifierRawValue
            self.commit()
        }

        let comboRow = FormRow(labelText: "组合键", control: recorder)
        editorRows = [comboRow]

        // flipped 容器作为 NSScrollView 的 documentView（非 flipped 会被钉在裁剪区左下角）
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        formRows = editorRows + [actionEditor]
        formRows.forEach { documentView.addSubview($0) }
        formLayout.apply(rows: formRows, in: documentView)
        return documentView
    }

    // MARK: - 数据刷新

    private func reloadItems(preservingSelection: Bool) {
        let items = shortcuts
        emptyHint.isHidden = !items.isEmpty
        tableView.reloadData()

        if preservingSelection, let selectedShortcutID,
           let index = items.firstIndex(where: { $0.id == selectedShortcutID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return
        }
        if let first = items.first {
            select(first.id, index: 0)
        } else {
            selectedShortcutID = nil
            updateEditor()
        }
    }

    private func select(_ id: String, index: Int) {
        selectedShortcutID = id
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updateEditor()
    }

    /// 把当前选中的快捷键数据灌入编辑器（或清空）
    private func updateEditor() {
        guard let scope, let id = selectedShortcutID,
              let shortcut = RuleStore.shared.shortcuts(in: scope).first(where: { $0.id == id }) else {
            draftKeyCode = UInt16(kVK_Space)
            draftModifiers = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
            recorder.configure(.empty)
            actionEditor.configure(ActionDTO(kind: .log, text: "Hello btTool"))
            setEditorEnabled(false)
            return
        }
        draftKeyCode = shortcut.keyCode
        draftModifiers = shortcut.modifierRawValue
        recorder.configure(keyCode: shortcut.keyCode, modifierRawValue: shortcut.modifierRawValue)
        actionEditor.configure(shortcut.action)
        setEditorEnabled(true)
    }

    private func setEditorEnabled(_ enabled: Bool) {
        editorRows.forEach { $0.label.textColor = enabled ? .labelColor : .disabledControlTextColor }
        recorder.isEnabled = enabled
        if !enabled, recorder.window?.firstResponder === recorder {
            recorder.window?.makeFirstResponder(nil)
        }
        actionEditor.setEditable(enabled)
    }

    // MARK: - 冲突判定

    /// 是否被更靠前的条目抢先占用（同作用域内重复 / 被「全局」覆盖）
    private func isConflicted(_ shortcut: KeyboardShortcutDTO) -> Bool {
        let key = "\(shortcut.modifierRawValue)-\(shortcut.keyCode)"
        var seen: Set<String> = []
        // 应用作用域要把全局的组合也算进「已占用」
        var prior: [KeyboardShortcutDTO] = []
        if scope?.isGlobal == false { prior.append(contentsOf: RuleStore.shared.globalShortcuts) }
        prior.append(contentsOf: shortcuts)
        for candidate in prior {
            let candidateKey = "\(candidate.modifierRawValue)-\(candidate.keyCode)"
            if candidate.id == shortcut.id { break }
            seen.insert(candidateKey)
        }
        return seen.contains(key)
    }

    // MARK: - Actions

    @objc private func addShortcut(_ sender: Any) {
        guard let scope else { return }
        guard let id = RuleStore.shared.addShortcut(to: scope) else { return }
        // addShortcut 内部已 save（会广播通知），这里补一次选中即可
        if let index = RuleStore.shared.shortcuts(in: scope).firstIndex(where: { $0.id == id }) {
            select(id, index: index)
        }
    }

    @objc private func removeShortcut(_ sender: Any) {
        guard let scope, let selectedShortcutID else { return }
        RuleStore.shared.removeShortcut(from: scope, shortcutID: selectedShortcutID)
        self.selectedShortcutID = nil
    }

    /// 写回 RuleStore（无论改的是组合键还是动作，都收敛到这里）
    private func commit() {
        guard let scope, let id = selectedShortcutID else { return }
        let keyCode = draftKeyCode
        let modifiers = draftModifiers
        let dto = actionEditor.dto
        RuleStore.shared.updateShortcut(in: scope, shortcutID: id) { shortcut in
            shortcut.keyCode = keyCode
            shortcut.modifierRawValue = modifiers
            shortcut.action = dto
        }
        // 组合键可能引发冲突，全文刷新以更新红色提示
        reloadItems(preservingSelection: true)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { shortcuts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(rawValue: "ShortcutCell")
        let cell: ShortcutCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ShortcutCellView {
            cell = reused
        } else {
            cell = ShortcutCellView(frame: .zero)
            cell.identifier = identifier
        }
        guard let shortcut = shortcuts.dropFirst(row).first else { return cell }
        cell.configure(shortcut: shortcut, conflicted: isConflicted(shortcut))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let items = shortcuts
        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else { return }
        let id = items[tableView.selectedRow].id
        guard id != selectedShortcutID else { return }
        select(id, index: tableView.selectedRow)
    }
}
