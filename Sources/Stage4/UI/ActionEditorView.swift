import AppKit

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
    private let scriptTextView = NSTextView()

    /// 模拟按键的录制框（替代原来的按键下拉框 + 4 个修饰键复选框）
    private let shortcutRecorder = ShortcutRecorderField()

    /// 「启动应用」的应用下拉框
    private let appPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 下拉框第 n 项 ↔ `installedApps[n]`（`indexOfSelectedItem` 要据此换回 Bundle ID）
    private var installedApps: [AppDescriptor] = []

    private let kindRow: FormRow
    private let appRow: FormRow
    private let mainRow: FormRow
    private let detailRow: FormRow
    private let keyRow: FormRow
    private let scriptRow: FormRow

    private var orderedRows: [FormRow] { [kindRow, mainRow, appRow, detailRow, scriptRow, keyRow] }

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
        appRow = FormRow(labelText: "启动应用", control: appPopup)
        detailRow = FormRow(labelText: "附加", control: detailField)
        keyRow = FormRow(labelText: "按键组合", control: shortcutRecorder)
        scriptRow = FormRow(labelText: "脚本", control: scriptScrollView,
                            controlHeight: Metrics.scriptHeight)

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

        appPopup.target = self
        appPopup.action = #selector(appDidChange(_:))

        // 模拟按键允许无修饰键（例如只投递一个 F5），由录制器自行决定
        shortcutRecorder.requiresModifier = false
        shortcutRecorder.onCapture = { [weak self] combo in
            guard let self else { return }
            self.dto.keyCode = combo.keyCode
            self.dto.modifierRawValue = combo.modifierRawValue
            self.commitNow()
        }

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
        // 「启动应用」交给下拉框 —— 手填 Bundle ID 不仅容易拼错，还看不出那个应用装没装
        if dto.kind == .launch { rebuildAppPopup(selecting: dto.text ?? "") }
        // nil 表示「还没录过」，此时显示占位文案而不是伪造一个 Space
        shortcutRecorder.configure(keyCode: dto.keyCode,
                                   modifierRawValue: dto.modifierRawValue ?? 0)

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

        // 置灰时如果录制框正握着第一响应者，必须主动交出去，否则它仍会吞掉按键
        if !enabled, shortcutRecorder.window?.firstResponder === shortcutRecorder {
            shortcutRecorder.window?.makeFirstResponder(nil)
        }
    }

    private func updatePresentation() {
        let kind = dto.kind
        let usesScriptEditor = kind == .shell || kind == .appleScript

        kindRow.isHidden = false
        mainRow.isHidden = usesScriptEditor || kind == .group || kind == .openSettingsWindow
                            || kind == .launch
        appRow.isHidden = kind != .launch
        detailRow.isHidden = !(kind == .notification || kind == .launch)
        keyRow.isHidden = kind != .syntheticKey
        scriptRow.isHidden = !usesScriptEditor

        switch kind {
        case .log: mainRow.label.stringValue = "日志文本"
        case .notification:
            mainRow.label.stringValue = "通知标题"
            detailRow.label.stringValue = "通知内容"
        case .launch:
            appRow.label.stringValue = "启动应用"
            detailRow.label.stringValue = "应用名(可选)"
        case .openURL: mainRow.label.stringValue = "URL"
        case .shell: scriptRow.label.stringValue = "Shell 命令"
        case .appleScript: scriptRow.label.stringValue = "AppleScript"
        case .syntheticKey:
            keyRow.label.stringValue = "按键组合"
        case .group: break
        case .openSettingsWindow: break
        }

        // 行集合变了 → 重建约束链（隐藏行自动被跳过，高度随之精确收缩）
        formLayout.apply(rows: orderedRows, in: self)
        needsLayout = true
        superview?.needsLayout = true
    }

    // MARK: - 应用下拉框

    /// 重建下拉框内容并选中指定的 Bundle ID。
    /// 应用清单只在首次用到时取一次 —— LaunchServices 枚举有开销，没必要每次回填都跑。
    private func rebuildAppPopup(selecting bundleID: String) {
        if installedApps.isEmpty {
            installedApps = AppDescriptor.installed()
            appPopup.removeAllItems()
            for app in installedApps {
                appPopup.addItem(withTitle: "\(app.name)  —  \(app.bundleIdentifier)")
            }
        }
        guard appPopup.numberOfItems > 0 else { return }

        // 列表里**只有本机装了的应用**。记着一个已经卸载的应用没有意义 ——
        // 它既启动不了，还会让人误以为那个选项是可用的。
        // 当前 Bundle ID 不在列表里时（没装 / 还是空动作），下拉框保持未选中，
        // 也不替用户改数据：等他重新挑一个再写入。
        if let index = installedApps.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
            appPopup.selectItem(at: index)
        } else {
            appPopup.select(nil)
        }
    }

    @objc private func appDidChange(_ sender: NSPopUpButton) {
        guard installedApps.indices.contains(sender.indexOfSelectedItem) else { return }
        let app = installedApps[sender.indexOfSelectedItem]
        dto.text = app.bundleIdentifier
        // 顺手把应用名填进「应用名(可选)」：目标没装时用它显示一个可读的名字
        dto.detail = app.name
        detailField.stringValue = app.name
        commitNow()
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
