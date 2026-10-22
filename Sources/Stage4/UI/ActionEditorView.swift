import AppKit
import Carbon.HIToolbox

/// 动作编辑器（标题 / 正文 / 按键 / 修饰键 / 脚本）。
///
/// 这是从 `RuleItemEditorViewController` 里**抽出来**的可复用组件：
/// 「Touch Bar 按钮要绑动作」「键盘快捷键也要绑动作」，两者编辑逻辑完全一致，
/// 抽出来之后快捷键页才能零成本复用（否则要复制粘贴 200 行且两边必然走样）。
///
/// 契约：
/// - `configure(_:)` 从外部灌入数据（**不会**触发 `onDidEdit`）；
/// - 用户改动时先就地更新内部的 `dto`，再回调 `onDidEdit?()`；
/// - 外部在回调里读 `dto` 写回 `RuleStore`。
///
/// 布局：所有行都是 `FormRow`（标签宽度统一 · 行高确定），
/// 高度由 `heightConstraint` 精确控制 —— 隐藏某行时会同步重算，绝不产生重叠或留空洞。
final class ActionEditorView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    /// 当前编辑中的动作（外部在 `onDidEdit` 里读取它）
    private(set) var dto: ActionDTO
    /// 用户每次改动都会回调（文本输入有轻微防抖）
    var onDidEdit: (() -> Void)?

    // MARK: 控件

    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mainField = NSTextField()
    private let detailField = NSTextField()
    private let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scriptTextView = NSTextView()

    private let commandCheckbox = NSButton(checkboxWithTitle: "⌘", target: nil, action: nil)
    private let optionCheckbox = NSButton(checkboxWithTitle: "⌥", target: nil, action: nil)
    private let controlCheckbox = NSButton(checkboxWithTitle: "⌃", target: nil, action: nil)
    private let shiftCheckbox = NSButton(checkboxWithTitle: "⇧", target: nil, action: nil)

    private let kindRow: FormRow
    private let mainRow: FormRow
    private let detailRow: FormRow
    private let keyRow: FormRow
    private let flagsRow: FormRow
    private let scriptRow: FormRow

    private var orderedRows: [FormRow] { [kindRow, mainRow, detailRow, scriptRow, keyRow, flagsRow] }

    private let formLayout = VerticalFormLayout()
    private var pendingFlush: DispatchWorkItem?

    /// 动作区整体翻转成「顶部为原点」，与表单自上而下的直觉一致
    override var isFlipped: Bool { true }

    // MARK: - 生命周期

    init(dto: ActionDTO = ActionDTO(kind: .log, text: "Hello btTool")) {
        self.dto = dto

        let scriptScrollView = NSScrollView(frame: .zero)
        scriptScrollView.documentView = scriptTextView
        scriptScrollView.hasVerticalScroller = true
        scriptScrollView.borderType = .bezelBorder

        kindRow = FormRow(labelText: "触发动作", control: kindPopup)
        mainRow = FormRow(labelText: "参数", control: mainField)
        detailRow = FormRow(labelText: "附加", control: detailField)
        keyRow = FormRow(labelText: "按键", control: keyPopup)
        scriptRow = FormRow(labelText: "脚本", control: scriptScrollView,
                            controlHeight: Metrics.scriptHeight)

        let checkboxes = NSStackView(views: [commandCheckbox, optionCheckbox,
                                             controlCheckbox, shiftCheckbox])
        checkboxes.orientation = .horizontal
        checkboxes.spacing = 12
        checkboxes.alignment = .centerY
        flagsRow = FormRow(labelText: "修饰键", control: checkboxes)

        super.init(frame: .zero)

        buildUI(initialDTO: dto)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现：纯代码布局") }

    private func buildUI(initialDTO: ActionDTO) {
        translatesAutoresizingMaskIntoConstraints = false

        // —— 控件自身配置 ——
        kindPopup.addItems(withTitles: ActionDTO.Kind.allCases.map(\.displayName))
        kindPopup.target = self
        kindPopup.action = #selector(kindDidChange(_:))

        keyPopup.addItems(withTitles: KeyCatalog.options.map(\.name))
        keyPopup.target = self
        keyPopup.action = #selector(keyDidChange(_:))

        for field in [mainField, detailField] {
            field.bezelStyle = .roundedBezel
            field.delegate = self
        }

        scriptTextView.isRichText = false
        scriptTextView.font = NSFont.userFixedPitchFont(ofSize: 12)
        scriptTextView.isAutomaticQuoteSubstitutionEnabled = false
        scriptTextView.delegate = self
        // 内边距：拒绝视觉死角（文字贴边）
        scriptTextView.textContainerInset = NSSize(width: 6, height: 6)
        scriptTextView.autoresizingMask = [.width]

        for checkbox in [commandCheckbox, optionCheckbox, controlCheckbox, shiftCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(modifierDidChange(_:))
            checkbox.setContentHuggingPriority(.required, for: .horizontal)
        }

        // —— 布局：显式等式链（见 VerticalFormLayout 注释）——
        // 每行宽度必然撑满、行高为常量、容器高度 = 各行之和，几何完全可推导。
        orderedRows.forEach { addSubview($0) }
        formLayout.apply(rows: orderedRows, in: self)

        configure(initialDTO)
    }

    // MARK: - 对外接口

    /// 灌入数据（不触发回调）
    func configure(_ dto: ActionDTO) {
        self.dto = dto

        let kindIndex = ActionDTO.Kind.allCases.firstIndex(of: dto.kind) ?? 0
        if kindPopup.indexOfSelectedItem != kindIndex { kindPopup.selectItem(at: kindIndex) }
        mainField.stringValue = dto.text ?? ""
        detailField.stringValue = dto.detail ?? ""
        scriptTextView.string = dto.text ?? ""
        keyPopup.selectItem(at: KeyCatalog.index(of: dto.keyCode ?? CGKeyCode(kVK_Space)))

        let raw = dto.modifierRawValue ?? CGEventFlags.maskCommand.rawValue
        commandCheckbox.state = raw & CGEventFlags.maskCommand.rawValue != 0 ? .on : .off
        optionCheckbox.state = raw & CGEventFlags.maskAlternate.rawValue != 0 ? .on : .off
        controlCheckbox.state = raw & CGEventFlags.maskControl.rawValue != 0 ? .on : .off
        shiftCheckbox.state = raw & CGEventFlags.maskShift.rawValue != 0 ? .on : .off

        updatePresentation()
    }

    // MARK: - 展示层刷新

    /// 未选中任何条目时整体置灰（NSView 本身没有 isEnabled，所以这里手动级联）
    func setEditable(_ enabled: Bool) {
        for row in orderedRows {
            row.label.textColor = enabled ? .labelColor : .disabledControlTextColor
            if let control = row.control as? NSControl {
                control.isEnabled = enabled
            } else {
                row.control.subviews.forEach { ($0 as? NSControl)?.isEnabled = enabled }
            }
        }
        scriptTextView.isEditable = enabled
        scriptTextView.isSelectable = enabled
    }

    private func updatePresentation() {
        let kind = dto.kind
        let usesScriptEditor = kind == .shell || kind == .appleScript

        kindRow.isHidden = false
        mainRow.isHidden = usesScriptEditor || kind == .group
        detailRow.isHidden = !(kind == .notification || kind == .launch)
        keyRow.isHidden = kind != .syntheticKey
        flagsRow.isHidden = kind != .syntheticKey
        scriptRow.isHidden = !usesScriptEditor

        switch kind {
        case .log: mainRow.label.stringValue = "日志文本"
        case .notification:
            mainRow.label.stringValue = "通知标题"
            detailRow.label.stringValue = "通知内容"
        case .launch:
            mainRow.label.stringValue = "Bundle ID"
            detailRow.label.stringValue = "应用名(可选)"
        case .openURL: mainRow.label.stringValue = "URL"
        case .shell: scriptRow.label.stringValue = "Shell 命令"
        case .appleScript: scriptRow.label.stringValue = "AppleScript"
        case .syntheticKey:
            keyRow.label.stringValue = "按键"
            flagsRow.label.stringValue = "修饰键"
        case .group: break
        }

        // 行集合变了 → 重建约束链（隐藏行自动被跳过，高度随之精确收缩）
        formLayout.apply(rows: orderedRows, in: self)
        needsLayout = true
        superview?.needsLayout = true
    }

    // MARK: - Actions

    @objc private func kindDidChange(_ sender: NSPopUpButton) {
        guard ActionDTO.Kind.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let newKind = ActionDTO.Kind.allCases[sender.indexOfSelectedItem]
        guard newKind != dto.kind else { return }
        dto = dto.converted(to: newKind)
        configure(dto)      // 按新类型回填合理默认值
        commitNow()
    }

    @objc private func keyDidChange(_ sender: NSPopUpButton) {
        guard KeyCatalog.options.indices.contains(sender.indexOfSelectedItem) else { return }
        dto.keyCode = KeyCatalog.options[sender.indexOfSelectedItem].keyCode
        commitNow()
    }

    @objc private func modifierDidChange(_ sender: NSButton) {
        var raw: UInt64 = 0
        if commandCheckbox.state == .on { raw |= CGEventFlags.maskCommand.rawValue }
        if optionCheckbox.state == .on { raw |= CGEventFlags.maskAlternate.rawValue }
        if controlCheckbox.state == .on { raw |= CGEventFlags.maskControl.rawValue }
        if shiftCheckbox.state == .on { raw |= CGEventFlags.maskShift.rawValue }
        dto.modifierRawValue = raw
        commitNow()
    }

    // MARK: - NSTextFieldDelegate / NSTextViewDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === mainField {
            dto.text = field.stringValue
        } else if field === detailField {
            dto.detail = field.stringValue
        } else {
            return
        }
        scheduleFlush()
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitNow() }

    func textDidChange(_ notification: Notification) {
        dto.text = scriptTextView.string
        scheduleFlush()
    }

    func textDidEndEditing(_ notification: Notification) { commitNow() }

    // MARK: - 提交节流

    /// 打字时每敲一个字符就写一次 JSON 并重建 Touch Bar 太浪费；
    /// 0.25s 防抖不影响体感，但能挡掉 90% 的无意义 I/O。
    private func scheduleFlush() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFlush = nil
            self?.onDidEdit?()
        }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func commitNow() {
        pendingFlush?.cancel()
        pendingFlush = nil
        onDidEdit?()
    }
}
