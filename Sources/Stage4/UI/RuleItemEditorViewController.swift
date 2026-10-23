import AppKit
import Carbon.HIToolbox

/// 编辑某个 Touch Bar 按钮的「标题 / 颜色 / 动作」。
///
/// 改动会立即写回 `RuleStore`（落盘 + 通知后台注入引擎刷新），所以改完字马上能在触控栏上看到。
///
/// ## 第六阶段的排版重构
/// 之前这里把「marginally 宽度写死的 NSTextField」和「NSStackView 自动布局」混用，
/// 结果行高由 Auto Layout 猜、控件宽度互相覆盖 —— 这是底部区域重叠的根因。
/// 现在：
/// - 每一行都是 `FormRow`：标签列固定 92pt，控件列自适应，**行高是常量**；
/// - 动作部分整体交给 `ActionEditorView`（快捷键页复用同一组件）；
/// - 整个表单放在可滚动容器里（`makeFormBox`），窗口变矮只滚动、不裁切。
final class RuleItemEditorViewController: NSViewController, NSTextFieldDelegate {
    /// 编辑完成后通知父级刷新（带上被编辑按钮的 id，便于精确刷新那一行）
    var onDidEdit: ((String?) -> Void)?

    private var scope: RuleScope?
    private var itemID: String?

    // MARK: 控件

    private let titleField = NSTextField()
    private let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    private let actionEditor = ActionEditorView()

    private let titleRow: FormRow
    private let colorRow: FormRow

    private let emptyLabel = NSTextField(labelWithString: "在上方列表中选择（或新建）一个按钮后进行编辑")
    private let formLayout = VerticalFormLayout()
    private var formRows: [NSView] = []

    /// 颜色是否被用户碰过（区分「回显的占位色」与「用户真正选的颜色」）
    private enum ColorState {
        case untouched
        case changed(NSColor?)
    }
    private var colorState: ColorState = .untouched

    // MARK: - 生命周期

    init() {
        titleRow = FormRow(labelText: "显示文本", control: titleField)

        colorWell.translatesAutoresizingMaskIntoConstraints = false
        let clearButton = NSButton(title: "清除颜色", target: nil, action: nil)
        clearButton.bezelStyle = .roundRect
        let colorControls = NSStackView(views: [colorWell, clearButton])
        colorControls.orientation = .horizontal
        colorControls.alignment = .centerY
        colorControls.spacing = 12
        colorRow = FormRow(labelText: "背景颜色", control: colorControls)

        super.init(nibName: nil, bundle: nil)

        colorWell.target = self
        colorWell.action = #selector(colorDidChange(_:))
        clearButton.target = self
        clearButton.action = #selector(clearColor(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现：纯代码布局") }

    override func loadView() {
        // 顶层容器会被当作 NSScrollView 的 documentView（见 makeFormBox）→ 必须是 flipped
        view = FlippedView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        actionEditor.onDidEdit = { [weak self] in self?.commit() }
        edit(scope: nil, itemID: nil)
    }

    // MARK: - 对外接口

    func edit(scope: RuleScope?, itemID: String?) {
        // ⚠️ 必须在最前面强制加载视图：
        // 左栏 reload 时会在 `NSTableView.selectRowIndexes` 里同步抛通知，
        // 链条一路走到这里时，作为子控制器的我们可能**还没走过 viewDidLoad**
        // （子视图是懒加载的），此时 `stack` / `colorWell` 等控件全是 nil，
        // 访问隐式解包可选值会直接 SIGILL 崩溃（已在实机复现并修复）。
        // 注：AppKit 没有 UIKit 的 loadViewIfNeeded()，访问 `view` 即同步触发加载。
        _ = view

        // ⚠️ 切换编辑对象前，必须先把上一个对象的待提交改动**落盘**。
        //    `scheduleCommit()` 延迟 0.25s 执行，而它执行时取的是**当下**的 itemID ——
        //    在这 0.25s 里换掉编辑对象，旧按钮输入的文字就会被写到新按钮上。
        //    这正是「新增按钮后一编辑，旧按钮的内容跑到新按钮上」的根因。
        let isSameItem = (self.scope == scope) && (self.itemID == itemID)
        if !isSameItem { flushPendingCommit() }

        self.scope = scope
        self.itemID = itemID

        guard let scope, let itemID,
              let model = RuleStore.shared.item(in: scope, itemID: itemID) else {
            showEmpty(true)
            return
        }
        showEmpty(false)

        let dto = ActionDTO(model.action)

        // 正在打字的控件不要回填（会把光标打断）—— 但这**只**适用于同一个按钮的刷新。
        // 换了编辑对象就必须强制回填：否则文本框里留着上一个按钮的文字，
        // 用户看到的就是「我点的是新按钮，怎么跳回旧按钮了」。
        if !isSameItem || !isEditing(titleField) { titleField.stringValue = model.title }

        colorState = .untouched
        colorWell.color = model.bezelColor ?? .controlAccentColor

        actionEditor.configure(dto)
    }

    // MARK: - UI

    private func buildUI() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        titleField.bezelStyle = .roundedBezel
        titleField.delegate = self
        titleField.placeholderString = "按钮显示文本"

        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: Metrics.controlHeight).isActive = true

        // 显式等式链：宽度撑满、行高常量、整体高度 = 各行之和（不再依赖 NSStackView 猜）
        formRows = [titleRow, colorRow, actionEditor]
        formRows.forEach { view.addSubview($0) }
        formLayout.apply(rows: formRows, in: view)
    }

    private func showEmpty(_ empty: Bool) {
        emptyLabel.isHidden = !empty
        formRows.forEach { $0.isHidden = empty }
        if empty {
            formLayout.apply(rows: [], in: view)
        } else {
            formLayout.apply(rows: formRows, in: view)
        }
    }

    /// 该控件此刻是否正被用户编辑（NSTextField 编辑时 firstResponder 是 field editor）
    private func isEditing(_ control: NSView) -> Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        if responder === control { return true }
        if let textView = responder as? NSTextView,
           let delegate = textView.delegate as AnyObject?,
           delegate === control {
            return true
        }
        return false
    }

    // MARK: - 写回模型

    private func commit() {
        guard let scope, let itemID,
              RuleStore.shared.item(in: scope, itemID: itemID) != nil else { return }

        let title = titleField.stringValue
        let explicitColor = colorState
        let dto = actionEditor.dto

        RuleStore.shared.updateItem(in: scope, itemID: itemID) { item in
            item.title = title.isEmpty ? "未命名" : title
            // 只有用户真的动过颜色才写回，避免「改个标题却凭空多出颜色」
            if case .changed(let color) = explicitColor {
                item.bezelColor = color
            }
            item.action = dto.action
        }

        // 立刻让右栏表格的那一行重绘（标题 + 色块即时变化）
        onDidEdit?(itemID)
    }

    // MARK: - Actions

    @objc private func colorDidChange(_ sender: NSColorWell) {
        colorState = .changed(sender.color)
        commit()
    }

    @objc private func clearColor(_ sender: Any) {
        guard let scope, let itemID else { return }
        colorState = .changed(nil)
        RuleStore.shared.updateItem(in: scope, itemID: itemID) { $0.bezelColor = nil }
        onDidEdit?(itemID)
    }

    func controlTextDidChange(_ obj: Notification) { scheduleCommit() }
    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    // MARK: - 提交节流

    private var pendingCommit: DispatchWorkItem?

    private func scheduleCommit() {
        pendingCommit?.cancel()
        // 捕获此刻的编辑对象：即便将来因时序问题漏了 flush，
        // 这个延迟闭包也不会把输入写到**别的**按钮上（双保险）。
        let capturedItemID = itemID
        let work = DispatchWorkItem { [weak self] in
            self?.pendingCommit = nil
            guard self?.itemID == capturedItemID else { return }
            self?.commit()
        }
        pendingCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 把排队中的改动**立即**提交到当前编辑对象，并取消那个延迟闭包。
    /// 必须在切换编辑对象之前调用（见 `edit(scope:itemID:)`）。
    private func flushPendingCommit() {
        guard let work = pendingCommit else { return }
        pendingCommit = nil
        work.cancel()
        commit()
    }
}
