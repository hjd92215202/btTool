import AppKit
import Carbon.HIToolbox

/// 「按下即录制」的快捷键输入框。
///
/// ## 为什么不用 `NSPopUpButton` + 四个复选框
/// 那一套要求用户先在 100 多个键名里翻找、再逐个勾修饰键，是纯粹的体力活；
/// 而且下拉框只能表达 `KeyCatalog` 里列出的键，F13、小键盘、各国布局的符号都录不进去。
/// 录制器的信息密度更高：**按什么就显示什么**，一个控件替代五个。
///
/// ## 事件拦截的三个要点
/// 1. `performKeyEquivalent` 会先于菜单栏收到组合键（⌘Q、⌘W 也在其中），
///    录制期间必须在这里吞掉，否则按 ⌘Q 直接把 App 退了；
/// 2. `keyDown` 处理普通按键；两个入口都**绝不调用 super**，
///    否则文本系统 / 菜单会发出「哔」的警告音；
/// 3. 非编辑态时 `isEditable = false`，但必须重写 `acceptsFirstResponder`
///    并让 `becomeFirstResponder` 直接返回 true —— 一旦走 `super`，
///    NSTextField 会装 field editor，按键就被文本输入系统吃掉了。
///
/// ## 与热键注册的配合
/// 录制开始时广播 `didBeginRecording`，`AppCoordinator` 会临时注销所有 Carbon 热键：
/// 否则用户按下的组合键会被系统热键先截胡，录制框根本收不到。
/// 录制结束广播 `didEndRecording`，热键立刻恢复（新组合即时生效）。
final class ShortcutRecorderField: NSTextField {

    /// 一次录制结果。`keyCode == nil` 表示「未设置」。
    struct Combo: Equatable {
        var keyCode: CGKeyCode?
        var modifierRawValue: UInt64

        static let empty = Combo(keyCode: nil, modifierRawValue: 0)

        var isEmpty: Bool { keyCode == nil }

        /// `⌃⌥⌘A` 这样的可读字形串
        var readableDescription: String {
            guard let keyCode else { return "" }
            return ModifierFlags.glyphs(cgRawValue: modifierRawValue) + KeyNames.name(for: keyCode)
        }
    }

    /// 录制开始 / 结束（`object` 是控件本身）
    static let didBeginRecording = Notification.Name("btTool.shortcutRecorder.didBeginRecording")
    static let didEndRecording = Notification.Name("btTool.shortcutRecorder.didEndRecording")

    /// 捕获到有效组合时回调（**只**在用户真实按键时触发，`configure` 不会触发）
    var onCapture: ((Combo) -> Void)?

    /// 是否要求至少一个修饰键（全局快捷键必须为 true，模拟按键可以为 false）
    var requiresModifier = false

    private(set) var combo: Combo = .empty
    private var isRecording = false
    private var invalidResetWork: DispatchWorkItem?

    // MARK: - 构造

    init() {
        super.init(frame: .zero)

        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        placeholderString = "点击录制"
        toolTip = "点击后直接按下组合键；Esc 或 ⌫ 清除，Tab / Return 结束录制"

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现：纯代码布局") }

    // MARK: - 对外接口

    func configure(keyCode: CGKeyCode?, modifierRawValue: UInt64) {
        combo = Combo(keyCode: keyCode, modifierRawValue: modifierRawValue)
        refreshDisplay()
    }

    func configure(_ combo: Combo) {
        configure(keyCode: combo.keyCode, modifierRawValue: combo.modifierRawValue)
    }

    // MARK: - 响应链

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        // 置灰状态下不能进入录制（未选中条目时编辑器整体禁用）
        guard isEnabled else { return false }
        // ⚠️ 不调用 super：super 会安装 field editor，按键全部被文本系统消费
        isRecording = true
        placeholderString = "请按下快捷键…"
        updateBorder()
        // 已有值时仍然显示，方便用户对照着重录
        stringValue = combo.readableDescription
        NotificationCenter.default.post(name: Self.didBeginRecording, object: self)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let wasRecording = isRecording
        isRecording = false
        updateBorder()
        placeholderString = "点击录制"
        refreshDisplay()
        if wasRecording {
            NotificationCenter.default.post(name: Self.didEndRecording, object: self)
        }
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 只有真正的第一响应者才吞事件；否则整个窗口的 ⌘ 组合都会被拦掉
        guard isRecording, window?.firstResponder === self else { return false }
        guard event.type == .keyDown else { return false }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, window?.firstResponder === self else {
            super.keyDown(with: event)
            return
        }
        _ = capture(event)
    }

    /// 只按修饰键时给出实时预览（`⌃⌥…`），松手回到提示文案
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        guard combo.isEmpty else { return }
        let raw = Self.modifierRawValue(from: event.modifierFlags)
        stringValue = raw == 0 ? "" : ModifierFlags.glyphs(cgRawValue: raw)
        placeholderString = raw == 0 ? "请按下快捷键…" : "再按一个键"
    }

    // MARK: - 捕获

    private func capture(_ event: NSEvent) -> Bool {
        let raw = Self.modifierRawValue(from: event.modifierFlags)
        let keyCode = CGKeyCode(event.keyCode)

        // Esc / ⌫：清空（无修饰键时）
        if raw == 0, Self.isClearKey(keyCode) {
            apply(.empty)
            finishRecording()
            return true
        }

        // Tab / Return：当作「结束录制」的导航键，不录制（否则焦点再也走不出去）
        if raw == 0, Self.isNavigationKey(keyCode) {
            finishRecording()
            return true
        }

        if requiresModifier, raw == 0 {
            flashInvalid()
            return true
        }

        apply(Combo(keyCode: keyCode, modifierRawValue: raw))
        finishRecording()
        return true
    }

    private func apply(_ combo: Combo) {
        self.combo = combo
        refreshDisplay()
        onCapture?(combo)
    }

    /// 录完立刻退出录制态：否则录制框会一直吞掉 ⌘Q / ⌘W，用户连窗口都关不掉
    private func finishRecording() {
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        } else {
            isRecording = false
            updateBorder()
            placeholderString = "点击录制"
            refreshDisplay()
            NotificationCenter.default.post(name: Self.didEndRecording, object: self)
        }
    }

    // MARK: - 展示

    private func refreshDisplay() {
        invalidResetWork?.cancel()
        invalidResetWork = nil
        stringValue = combo.readableDescription
        textColor = combo.isEmpty ? .secondaryLabelColor : .labelColor
    }

    private func flashInvalid() {
        invalidResetWork?.cancel()
        layer?.borderColor = NSColor.systemRed.cgColor
        layer?.borderWidth = 2
        placeholderString = "需要至少一个修饰键（⌘⌥⌃⇧）"

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateBorder()
            self.placeholderString = "请按下快捷键…"
        }
        invalidResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func updateBorder() {
        layer?.borderWidth = isRecording ? 2 : 1
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : .separatorColor).cgColor
        layer?.backgroundColor = (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.10)
            : NSColor.textBackgroundColor).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    // MARK: - 工具

    private static func modifierRawValue(from flags: NSEvent.ModifierFlags) -> UInt64 {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        var raw: UInt64 = 0
        if device.contains(.control) { raw |= CGEventFlags.maskControl.rawValue }
        if device.contains(.option) { raw |= CGEventFlags.maskAlternate.rawValue }
        if device.contains(.shift) { raw |= CGEventFlags.maskShift.rawValue }
        if device.contains(.command) { raw |= CGEventFlags.maskCommand.rawValue }
        return raw
    }

    private static func isClearKey(_ keyCode: CGKeyCode) -> Bool {
        keyCode == CGKeyCode(kVK_Escape)
            || keyCode == CGKeyCode(kVK_Delete)
            || keyCode == CGKeyCode(kVK_ForwardDelete)
    }

    private static func isNavigationKey(_ keyCode: CGKeyCode) -> Bool {
        keyCode == CGKeyCode(kVK_Tab)
            || keyCode == CGKeyCode(kVK_Return)
            || keyCode == CGKeyCode(kVK_ANSI_KeypadEnter)
    }
}
