import AppKit

/// `TouchBarHost` = 一条真实的 `NSTouchBar` + 它的数据源（`NSTouchBarDelegate`）。
///
/// 设计要点：
/// 1. **持有关系**：`NSTouchBar.delegate` 是 weak，所以 host 必须被外部强引用持有，
///    否则 item 全部消失（这是后台注入最容易踩的坑）。第二阶段由窗口控制器持有，
///    第三阶段由 `SystemModalTouchBarPresenter` 持有。
/// 2. **delegate 惰性构建**：`touchBar(_:makeItemForIdentifier:)` 里按需创建并缓存，
///    符合 Apple 的生命周期建议，也便于后续做懒加载/异步。
/// 3. 与「前台 / 后台 / 系统模态」完全解耦，两种呈现方式复用同一个类。
final class TouchBarHost: NSObject, NSTouchBarDelegate {
    let definition: TouchBarDefinition
    let touchBar: NSTouchBar
    private var cachedItems: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]

    init(definition: TouchBarDefinition) {
        self.definition = definition

        let bar = NSTouchBar()
        bar.customizationIdentifier = definition.customizationIdentifier
        bar.defaultItemIdentifiers = definition.items.map { $0.identifier }
        bar.customizationAllowedItemIdentifiers = bar.defaultItemIdentifiers
        bar.principalItemIdentifier = definition.items.first?.identifier
        self.touchBar = bar

        super.init()
        bar.delegate = self
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if let cached = cachedItems[identifier] { return cached }
        guard let index = definition.items.firstIndex(where: { $0.identifier == identifier }) else {
            return nil
        }
        let item = Self.makeItem(definition.items[index], index: index, target: self)
        cachedItems[identifier] = item
        return item
    }

    // MARK: - 构建 item

    private static func makeItem(_ model: TouchBarItemModel,
                                 index: Int,
                                 target: AnyObject) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: model.identifier)
        item.customizationLabel = model.title

        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        button.title = model.title
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        button.target = target
        button.action = #selector(TouchBarHost.itemClicked(_:))
        // 用 tag 把按钮映射回对应的 model（简单、无关联对象、无内存问题）
        button.tag = index
        if let color = model.bezelColor {
            button.bezelColor = color
        }
        item.view = button
        return item
    }

    @objc private func itemClicked(_ sender: NSButton) {
        guard definition.items.indices.contains(sender.tag) else { return }
        let model = definition.items[sender.tag]
        Log.info("Touch Bar 按钮被点击：\(model.title)（\(model.identifier.rawValue)）", log: Log.touchBar)
        model.action.run()
    }
}
