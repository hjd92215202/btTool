import AppKit
import UniformTypeIdentifiers

/// 左栏：作用域列表（「全局」 + 各应用规则） + 增/删按钮。
///
/// 列表的第一行固定是「全局（所有应用）」：
/// - 它的触控栏 = 未命中应用规则时的**兜底通用栏**；
/// - 它的快捷键 = **常驻全局**注册，不随前台应用切换。
final class RuleListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// 选中变化回调（把作用域 id 交给右栏）
    var onSelectScope: ((String?) -> Void)?

    /// 一行的展示数据（缓存图标与名字，避免每行都在绘制时查询 NSWorkspace）
    private struct Entry {
        let scopeID: String
        let name: String
        let icon: NSImage
    }

    private let tableView = NSTableView()
    private var entries: [Entry] = []
    private var storeObserver: NSObjectProtocol?

    private var selectedScopeID: String? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < entries.count else { return nil }
        return entries[tableView.selectedRow].scopeID
    }

    // MARK: - 生命周期

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        storeObserver = NotificationCenter.default.addObserver(
            forName: RuleStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reload(preservingSelection: true)
            }
        reload()
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    // MARK: - UI

    private func buildUI() {
        let addButton = makeIconButton(symbol: NSImage.addTemplateName,
                                       tooltip: "从 /Applications 选择一个 App 添加规则",
                                       target: self, action: #selector(addApplication(_:)))
        let removeButton = makeIconButton(symbol: NSImage.removeTemplateName,
                                          tooltip: "删除选中的应用规则",
                                          target: self, action: #selector(removeApplication(_:)))

        let bar = makeSectionBar(title: "作用域", controls: [addButton, removeButton])
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "scopeColumn"))
        column.width = 240
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        for subview in [bar, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),

            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - 数据

    private func reload(preservingSelection: Bool = false) {
        let previous = selectedScopeID

        var result: [Entry] = [Entry(scopeID: RuleScope.global.id,
                                     name: "全局（所有应用）",
                                     icon: Self.globalIcon())]
        result.append(contentsOf: RuleStore.shared.rules.map { rule in
            let bundleID = rule.primaryBundleIdentifier
            let descriptor = AppDescriptor(bundleIdentifier: bundleID)
            return Entry(scopeID: RuleScope.app(bundleID).id,
                         name: descriptor.name,
                         icon: descriptor.icon)
        })
        entries = result
        tableView.reloadData()

        var targetIndex: Int? = nil
        if preservingSelection, let previous,
           let index = entries.firstIndex(where: { $0.scopeID == previous }) {
            targetIndex = index
        } else if !entries.isEmpty {
            targetIndex = 0
        }
        if let targetIndex {
            tableView.selectRowIndexes(IndexSet(integer: targetIndex), byExtendingSelection: false)
        }
        onSelectScope?(selectedScopeID)
    }

    private static func globalIcon() -> NSImage {
        if #available(macOS 11.0, *),
           let symbol = NSImage(systemSymbolName: "globe", accessibilityDescription: "全局") {
            return symbol
        }
        // 兜底：不查 NSWorkspace（避免 deprecated / 查询开销），直接用系统通用应用图标
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    // MARK: - Actions

    @objc private func addApplication(_ sender: Any) {
        guard let url = AppPicker.chooseApplication() else { return }

        // ① 先判定是不是真正的 .app 包（用户可能点到 Alias / 磁盘映像里的安装器）
        guard AppPicker.validate(url) else {
            AppPicker.showAlert(message: "这不是一个有效的应用程序包",
                                informative: "请选择一个扩展名为 .app 的应用；如果是替身（Alias），请先「显示原身」再选取。")
            return
        }

        // ② 读取 Bundle ID 失败要给出友好提示（常见于损坏/未签名的包）
        guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            AppPicker.showAlert(message: "无法读取该应用的 Bundle Identifier",
                                informative: "“\(url.lastPathComponent)” 的包信息不完整，btTool 无法为其建立规则。")
            return
        }

        let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? FileManager.default.displayName(atPath: url.path)

        // ③ 重复添加：不静默失败 —— 弹提示，并把已存在的那条选中 + 滚动可见（视觉提示）
        guard RuleStore.shared.addRule(bundleIdentifier: bundleIdentifier, preferredName: name) else {
            AppPicker.showAlert(message: "“\(name)” 已经在列表中",
                                informative: "已为你选中并高亮这条规则，直接在右侧编辑即可。")
            highlight(scopeID: RuleScope.app(bundleIdentifier).id)
            return
        }

        highlight(scopeID: RuleScope.app(bundleIdentifier).id)
    }

    /// 选中并滚动到指定条目（新添加 / 已存在时都用它做视觉反馈）
    private func highlight(scopeID: String) {
        reload(preservingSelection: false)
        guard let index = entries.firstIndex(where: { $0.scopeID == scopeID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        view.window?.makeFirstResponder(tableView)
        onSelectScope?(scopeID)
    }

    @objc private func removeApplication(_ sender: Any) {
        guard let scopeID = selectedScopeID else { return }
        let scope = RuleScope(id: scopeID)
        guard !scope.isGlobal else {
            AppPicker.showAlert(message: "「全局」作用域不能删除",
                                informative: "它承载了兜底触控栏与常驻全局的快捷键；如果不需要，清空里面的条目即可。")
            return
        }
        guard let bundleIdentifier = scope.bundleIdentifier else { return }
        RuleStore.shared.removeRule(bundleIdentifier: bundleIdentifier)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(rawValue: "IconTitleCell")
        let cell: IconTitleCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? IconTitleCellView {
            cell = reused
        } else {
            cell = IconTitleCellView(frame: .zero)
            cell.identifier = identifier
        }
        let entry = entries[row]
        cell.configure(icon: entry.icon, title: entry.name)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectScope?(selectedScopeID)
    }
}

// MARK: - /Applications 选取 + 提示框

enum AppPicker {
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.message = "选择一个要添加规则的应用"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 基本合法性校验：必须是目录形态的 bundle，且包内有 Info.plist / Contents 结构
    static func validate(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return url.pathExtension.lowercased() == "app"
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }

    static func showAlert(message: String, informative: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }
}
