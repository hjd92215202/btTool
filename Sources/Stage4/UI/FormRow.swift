import AppKit

/// 一行标准的「右对齐标签 + 控件」表单行。
///
/// ## 为什么手写约束而不用 NSStackView
/// 之前用 `NSStackView` 拼每行，再塞进一个纵向 stack 里：父 stack 用 `alignment: .leading`
/// 时行宽取决于子视图 intrinsic width，而多个控件的 intrinsic 与固定宽度常量打架，
/// 最终谁飘到哪全看 Auto Layout 的优先级推理结果 —— 这就是「控件重叠」的根因。
///
/// 现在这一行的几何关系被**完全钉死**：
///
/// ```
/// leading ──[label 宽 92]── 12pt ──[control]── trailing
/// 垂直方向：control 居中，行高 = controlHeight + 6（脚本行 = scriptHeight + 6）
/// ```
///
/// 于是「每行的左边缘一定对齐」「行高一定是已知常量」，
/// 容器就能精确算出自己的高度，不需要 Auto Layout 去猜。
final class FormRow: NSView {
    let label: NSTextField
    let control: NSView

    /// 行高（容器靠它精确计算自己的高度）
    let rowHeight: CGFloat

    /// - Parameters:
    ///   - labelText: 标签文案（之后可以直接改 `row.label.stringValue`）
    ///   - control: 控件
    ///   - controlHeight: 控件高度；决定这一行的高度
    init(labelText: String,
         control: NSView,
         controlHeight: CGFloat = Metrics.controlHeight) {
        self.control = control
        self.rowHeight = controlHeight + 6

        let textField = NSTextField(labelWithString: labelText)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.alignment = .right
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.textColor = .labelColor
        textField.lineBreakMode = .byTruncatingTail
        // ⚠️ 不要把 hugging / compression 设成 .required：
        //    那会生成「宽度 == intrinsic(96)」/「宽度 >= intrinsic」的必需约束，
        //    和下面写死的 92pt 宽度等式直接打架，AppKit 会静默拆掉宽度约束，
        //    实测标签会左右各溢 2pt。这里保持默认优先级，让显式宽度说了算。
        self.label = textField

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textField)
        addSubview(control)

        NSLayoutConstraint.activate([
            // 标签：固定宽度，紧贴左边缘
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.widthAnchor.constraint(equalToConstant: Metrics.labelWidth),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            // 控件：紧跟标签之后 12pt，右边缘贴住父视图 —— 宽度自适应，不写死
            control.leadingAnchor.constraint(equalTo: textField.trailingAnchor,
                                             constant: Metrics.labelGap),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.heightAnchor.constraint(equalToConstant: controlHeight),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),

            // 行高固定，这样外层容器可以精确算高
            heightAnchor.constraint(equalToConstant: rowHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现：纯代码布局") }
}
