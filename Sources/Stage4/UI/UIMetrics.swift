import AppKit

/// 全局统一的排版度量。
///
/// 为什么要把这些常量单独抽出来：
/// 之前每行控件都是「各自算 intrinsic size + 宽度写死 + 父 stack 猜高度」，
/// 于是出现了经典的灾难级重叠 —— 输入框压住下拉菜单、标签文字和控件互相覆盖。
/// 现在所有行都遵守同一套栅格：
///
/// ```
/// ┌─ row ────────────────────────────────────────────────┐
/// │ [ label  92pt ][ 12pt gap ][ control  (自由拉伸) ]    │  ← 高度恒为 controlHeight + 8
/// └──────────────────────────────────────────────────────┘
///      ↑ 行与行之间固定 12pt
/// ```
///
/// 每行的**高度是确定值**（`rowHeight`），
/// 所以包含这些行的容器可以精确算出自己需要多高，不需要依赖 Auto Layout 去猜。
enum Metrics {
    /// 容器四周留白（拒绝视觉死角）
    static let padding: CGFloat = 16
    /// 行与行的垂直间距
    static let rowSpacing: CGFloat = 12
    /// 标签与控件之间的水平间距
    static let labelGap: CGFloat = 12
    /// 标签列固定宽度（保证所有控件的左边缘严格对齐）
    static let labelWidth: CGFloat = 92
    /// 标准控件高度
    static let controlHeight: CGFloat = 24
    /// 普通行的行高 = 控件高 + 上下各 3pt 呼吸空间
    static let rowHeight: CGFloat = controlHeight + 6
    /// 多行脚本输入区的高度
    static let scriptHeight: CGFloat = 96
    /// 脚本行的行高
    static let scriptRowHeight: CGFloat = scriptHeight + 6
    /// 分组 bar 高度
    static let sectionBarHeight: CGFloat = 28
    /// 底部编辑区高度
    static let editorHeight: CGFloat = 296
}

// MARK: - 坐标翻转容器

/// 顶部为原点的容器视图。
///
/// ## 为什么必须有它（本次「控件重叠」的真正元凶之一）
/// `NSScrollView` 的 `NSClipView` 是 **flipped** 的，而默认的 `NSView`/`NSStackView` 是
/// **non-flipped**（原点在左下角）。把一个 non-flipped 的视图当 `documentView`，
/// 内容会以左下角对齐到裁剪区 —— 实测表现就是「内容整体被挂到可视区下方、行跑到负 y」，
/// 叠加上表单高度不定，看起来就像控件互相压住。
///
/// 只要文档视图是 flipped 的，内容就从左上角开始、自上而下排布，滚动行为才符合直觉。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 竖向表单行的**精确**布局器。
///
/// ## 为什么不用 NSStackView
/// 竖向 `NSStackView` 的 `alignment = .width` 在嵌套场景（stack 套 stack、装进 NSScrollView 的
/// documentView）里并不可靠：实测把编辑区放进滚动容器后，整个表单宽度塌成 237pt、
/// 行被挤到右侧 —— 因为它会按 intrinsic width 反推，而不是老实撑满父视图。
///
/// 这里改成显式等式链，几何完全可推导：
///
/// ```
/// row0.top    == container.top
/// row0.lead   == container.lead ; row0.trail == container.trail   ← 宽度必然撑满
/// row1.top    == row0.bottom + 12
/// ...
/// last.bottom == container.bottom                                  ← 容器高度 = 各行之和
/// ```
///
/// 行高本身是常量（`FormRow.rowHeight`），所以容器高度精确可知；
/// 行被隐藏时重建一次约束链即可，不会残留空洞。
final class VerticalFormLayout {
    private var constraints: [NSLayoutConstraint] = []

    /// 按顺序重新铺设（自动跳过隐藏行）
    func apply(rows: [NSView], in container: NSView, spacing: CGFloat = Metrics.rowSpacing) {
        NSLayoutConstraint.deactivate(constraints)
        constraints.removeAll()

        let visible = rows.filter { !$0.isHidden }
        var previous: NSView?
        for row in visible {
            row.translatesAutoresizingMaskIntoConstraints = false
            constraints.append(row.leadingAnchor.constraint(equalTo: container.leadingAnchor))
            constraints.append(row.trailingAnchor.constraint(equalTo: container.trailingAnchor))
            if let previous {
                constraints.append(row.topAnchor.constraint(equalTo: previous.bottomAnchor,
                                                            constant: spacing))
            } else {
                constraints.append(row.topAnchor.constraint(equalTo: container.topAnchor))
            }
            previous = row
        }
        if let last = previous {
            // 高度由内容决定：最后一行贴底
            constraints.append(container.bottomAnchor.constraint(equalTo: last.bottomAnchor))
        } else {
            constraints.append(container.heightAnchor.constraint(equalToConstant: 0))
        }
        NSLayoutConstraint.activate(constraints)
        container.superview?.needsLayout = true
    }
}

// MARK: - 工厂方法

func makeSectionLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
}

func makeSecondaryLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    return label
}

/// 一行「标题 + 右侧若干按钮」的 bar（左栏顶栏 / 列表顶栏公用）
///
/// - Note: 这里用 NSStackView 是安全的：它的方向是水平的，且所有子视图都参与了 hugging 优先级的设置，
///   `NSView()` 占位撑开中间空白。
func makeSectionBar(title: String, controls: [NSView]) -> NSStackView {
    let bar = NSStackView()
    bar.orientation = .horizontal
    bar.alignment = .centerY
    bar.spacing = 6
    bar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    bar.addArrangedSubview(makeSectionLabel(title))

    let spacer = NSView()
    spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
    bar.addArrangedSubview(spacer)

    controls.forEach { bar.addArrangedSubview($0) }
    return bar
}

func makeIconButton(symbol: NSImage.Name, tooltip: String, target: Any?, action: Selector) -> NSButton {
    let button = NSButton(image: NSImage(named: symbol)!, target: target, action: action)
    button.bezelStyle = .roundRect
    button.imagePosition = .imageOnly
    button.toolTip = tooltip
    button.widthAnchor.constraint(equalToConstant: 26).isActive = true
    button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return button
}

/// 创建一个「标题 + 表单」的分组框。
///
/// ## 一个踩过的坑（务必别再套 NSScrollView）
/// 最初这里把表单放进 `NSScrollView` 里指望「窗口变矮时可滚动」。实测结果很糟：
/// 文档视图的 `translatesAutoresizingMaskIntoConstraints` 会被 `documentView = ` 赋值打回 true，
/// 宽度约束全部失效 → 整块表单塌成 ~237pt 的 intrinsic 宽度、行挤在右侧；
/// 再加上非 flipped 文档视图被钉在裁剪区左下角，视觉上就是「控件重叠 + 错位」。
///
/// 现在的做法：**定高盒子 + 顶对齐**，表单用 `VerticalFormLayout` 的等式链精确排布，
/// 内容区高度按「最高的那种动作形态」预留（见 `Metrics.editorHeight`），
/// 于是既不会裁切，也不会错位。
func makeFormBox(title: String, contentView: NSView, height: CGFloat) -> NSBox {
    let box = NSBox()
    box.title = title
    box.boxType = .custom
    box.titlePosition = .atTop
    box.contentViewMargins = NSSize(width: Metrics.padding, height: Metrics.padding)
    box.translatesAutoresizingMaskIntoConstraints = false

    guard let boxContentView = box.contentView else { return box }

    contentView.translatesAutoresizingMaskIntoConstraints = false
    boxContentView.addSubview(contentView)

    NSLayoutConstraint.activate([
        contentView.topAnchor.constraint(equalTo: boxContentView.topAnchor),
        contentView.leadingAnchor.constraint(equalTo: boxContentView.leadingAnchor),
        contentView.trailingAnchor.constraint(equalTo: boxContentView.trailingAnchor),
        // 只允许「不超过」：内容多高就是多高，多余的空白留在下方（顶对齐）
        contentView.bottomAnchor.constraint(lessThanOrEqualTo: boxContentView.bottomAnchor),
    ])

    box.heightAnchor.constraint(equalToConstant: height).isActive = true
    return box
}

/// 创建一个「整表 + 空状态提示」的滚动容器
func makeTableScrollView(tableView: NSTableView, emptyHint: NSView) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.drawsBackground = true

    emptyHint.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(emptyHint)
    NSLayoutConstraint.activate([
        emptyHint.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
        emptyHint.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        emptyHint.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 12),
        emptyHint.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -12),
    ])
    return scrollView
}
