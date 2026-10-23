import AppKit

/// 一个 Touch Bar 按钮的**数据描述**（与任何呈现方式无关）。
/// 字段为 `var`：第四阶段的 GUI 会就地修改它们。
struct TouchBarItemModel {
    var identifier: NSTouchBarItem.Identifier
    var title: String
    var bezelColor: NSColor?
    /// 点击后执行的动作（见 AppAction）
    var action: AppAction

    init(identifier: String,
         title: String,
         bezelColor: NSColor? = nil,
         action: AppAction) {
        self.identifier = NSTouchBarItem.Identifier(rawValue: identifier)
        self.title = title
        self.bezelColor = bezelColor
        self.action = action
    }
}

/// 一条 Touch Bar 的**数据描述**：一组 item + 一个标识。
///
/// 这是第二阶段和第三阶段的共同产物：
/// - 第二阶段 → 交给窗口（前台）呈现；
/// - 第三阶段 → 规则引擎按前台应用产出，再交给后台注入器呈现。
struct TouchBarDefinition {
    var customizationIdentifier: NSTouchBar.CustomizationIdentifier
    var items: [TouchBarItemModel]

    init(identifier: String, items: [TouchBarItemModel]) {
        // 注意：NSTouchBar.CustomizationIdentifier 在 Swift 里就是 String 的 typealias
        self.customizationIdentifier = NSTouchBar.CustomizationIdentifier(identifier)
        self.items = items
    }

    mutating func appendItem(_ item: TouchBarItemModel) { items.append(item) }

    /// 没有匹配规则时展示的**占位长栏**。
    ///
    /// 🟢 P2：以前无匹配规则时直接 `collapse` 收起 —— 表现是「点开托盘 → 切到没规则的应用 →
    /// 又自己收起来了」，看起来就像工具坏了。现在改成留一条占位栏：
    /// 至少让用户看见 btTool 还在，并且能一键跳到配置界面去补规则。
    static func placeholder(forAppNamed name: String) -> TouchBarDefinition {
        TouchBarDefinition(identifier: "btTool.touchBar.placeholder",
                           items: [TouchBarItemModel(identifier: "btTool.placeholder.openSettings",
                                                     title: "⚙ 为「\(name)」配置规则…",
                                                     action: .openSettingsWindow)])
    }
}

/// 统一呈现协议：让「窗口前台呈现」和「后台系统模态注入」拥有完全一样的调用接口，
/// 上层（AppCoordinator）因此完全不需要关心底层用的是公开 API 还是私有 API。
protocol TouchBarPresenting: AnyObject {
    var isPresenting: Bool { get }
    func present(_ definition: TouchBarDefinition)
    func dismiss()
}
