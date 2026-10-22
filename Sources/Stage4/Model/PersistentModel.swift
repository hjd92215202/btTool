import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - NSColor ↔ #RRGGBB

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "#", with: "")
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - 动作 DTO

/// `AppAction` 的可序列化描述。
///
/// `AppAction` 本身不方便 Codable（`CGEventFlags` 不是 Codable、未来还可能塞闭包），
/// 所以这里做一层显式的数据契约：磁盘只认 `ActionDTO`，运行时才转成 `AppAction`。
struct ActionDTO: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case log
        case notification
        case launch
        case openURL
        case syntheticKey
        case shell
        case appleScript
        case group

        var displayName: String {
            switch self {
            case .log: return "打印日志"
            case .notification: return "发送通知"
            case .launch: return "启动应用"
            case .openURL: return "打开 URL"
            case .syntheticKey: return "模拟按键"
            case .shell: return "执行 Shell"
            case .appleScript: return "执行 AppleScript"
            case .group: return "组合动作"
            }
        }
    }

    var kind: Kind
    /// 主参数：日志文本 / 通知标题 / Bundle ID / URL
    var text: String?
    /// 次参数：通知正文 / 备用应用名
    var detail: String?
    /// 模拟按键：虚拟键码
    var keyCode: UInt16?
    /// 模拟按键：CGEventFlags.rawValue
    var modifierRawValue: UInt64?
    /// 组合动作的子动作
    var children: [ActionDTO]?

    // MARK: DTO → AppAction

    var action: AppAction {
        switch kind {
        case .log:
            return .log(text ?? "")
        case .notification:
            return .notification(title: text ?? "", body: detail ?? "")
        case .launch:
            return .launch(bundleIdentifier: text ?? "", fallbackName: (detail?.isEmpty == true ? nil : detail))
        case .openURL:
            return .openURL(text ?? "")
        case .syntheticKey:
            let flags = CGEventFlags(rawValue: modifierRawValue ?? CGEventFlags.maskCommand.rawValue)
            return .syntheticKey(keyCode: keyCode ?? CGKeyCode(kVK_Space), flags: flags)
        case .shell:
            return .shell(text ?? "")
        case .appleScript:
            return .appleScript(text ?? "")
        case .group:
            return .group((children ?? []).map(\.action))
        }
    }

    // MARK: AppAction → DTO

    init(_ action: AppAction) {
        switch action {
        case .log(let message):
            self.init(kind: .log, text: message)
        case .notification(let title, let body):
            self.init(kind: .notification, text: title, detail: body)
        case .launch(let bundleIdentifier, let fallbackName):
            self.init(kind: .launch, text: bundleIdentifier, detail: fallbackName)
        case .openURL(let url):
            self.init(kind: .openURL, text: url)
        case .syntheticKey(let keyCode, let flags):
            self.init(kind: .syntheticKey, keyCode: keyCode, modifierRawValue: flags.rawValue)
        case .shell(let command):
            self.init(kind: .shell, text: command)
        case .appleScript(let source):
            self.init(kind: .appleScript, text: source)
        case .group(let actions):
            self.init(kind: .group, children: actions.map(ActionDTO.init))
        }
    }

    init(kind: Kind,
         text: String? = nil,
         detail: String? = nil,
         keyCode: UInt16? = nil,
         modifierRawValue: UInt64? = nil,
         children: [ActionDTO]? = nil) {
        self.kind = kind
        self.text = text
        self.detail = detail
        self.keyCode = keyCode
        self.modifierRawValue = modifierRawValue
        self.children = children
    }

    /// 切换动作类型时生成一份带合理默认值的 DTO
    func converted(to newKind: Kind) -> ActionDTO {
        var dto = ActionDTO(kind: newKind)
        switch newKind {
        case .log: dto.text = text ?? "Hello btTool"
        case .notification: dto.text = text ?? "btTool"; dto.detail = detail ?? "来自 Touch Bar 的通知"
        case .launch: dto.text = text ?? "com.apple.calculator"; dto.detail = detail ?? "Calculator"
        case .openURL: dto.text = text ?? "https://example.com"
        case .syntheticKey:
            dto.keyCode = keyCode ?? CGKeyCode(kVK_Space)
            dto.modifierRawValue = modifierRawValue ?? CGEventFlags.maskCommand.rawValue
        case .shell: dto.text = text ?? "pmset displaysleepnow"
        case .appleScript: dto.text = text ?? "tell application \"Spotify\" to playpause"
        case .group: dto.children = children ?? [ActionDTO(kind: .log, text: "Hello btTool")]
        }
        return dto
    }

    /// 一句话摘要，用于列表展示（超长脚本会被截断，避免撑爆单元格）
    var summary: String {
        switch kind {
        case .log: return "日志：\(text ?? "—")"
        case .notification: return "通知：\(text ?? "—")"
        case .launch: return "启动：\(text ?? "—")"
        case .openURL: return "URL：\(text ?? "—")"
        case .syntheticKey:
            return "按键：\(KeyCatalog.name(for: keyCode ?? 49))（\(shortcutDescription)）"
        case .shell: return "Shell：\(truncated(text))"
        case .appleScript: return "AppleScript：\(truncated(text))"
        case .group: return "组合（\(children?.count ?? 0) 步）"
        }
    }

    private func truncated(_ value: String?, limit: Int = 48) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let singleLine = value.replacingOccurrences(of: "\n", with: " ⏎ ")
        return singleLine.count > limit ? String(singleLine.prefix(limit)) + "…" : singleLine
    }

    private var shortcutDescription: String {
        let raw = modifierRawValue ?? 0
        var parts: [String] = []
        if raw & CGEventFlags.maskControl.rawValue != 0 { parts.append("⌃") }
        if raw & CGEventFlags.maskAlternate.rawValue != 0 { parts.append("⌥") }
        if raw & CGEventFlags.maskShift.rawValue != 0 { parts.append("⇧") }
        if raw & CGEventFlags.maskCommand.rawValue != 0 { parts.append("⌘") }
        return parts.isEmpty ? "无修饰键" : parts.joined()
    }
}

// MARK: - 作用域

/// 一条配置的作用范围。
///
/// - `.global`：写在「全局（所有应用）」下 —— Touch Bar 对应兜底栏，快捷键**常驻全局**；
/// - `.app(id)`：只有该 Bundle ID 处于前台时才生效（Touch Bar 换栏 + 快捷键动态注册/注销）。
///
/// 之所以用「哨兵 ID」而不是 String 特判散落各处：让列表、详情、编辑器三处
/// 只依赖一个 `String` 主键，避免把可选值 / 协议改造扩散到整个 UI 层。
enum RuleScope: Equatable, Hashable {
    case global
    case app(String)

    /// 与真实 Bundle ID 外观一致但不可能冲突的哨兵值（真实 Bundle ID 不会等于它，
    /// 因为它没有第二段的点分结构且前缀受控）
    static let globalIdentifier = "btTool.scope.global"

    var id: String {
        switch self {
        case .global: return RuleScope.globalIdentifier
        case .app(let bundleIdentifier): return bundleIdentifier
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .global: return nil
        case .app(let value): return value
        }
    }

    var isGlobal: Bool { self == .global }

    /// UI 展示名（注意：会查询 NSWorkspace，别放在高频绘制路径里）
    var displayName: String {
        switch self {
        case .global: return "全局（所有应用）"
        case .app(let bundleIdentifier): return AppDescriptor(bundleIdentifier: bundleIdentifier).name
        }
    }

    var subtitle: String {
        switch self {
        case .global: return "未命中应用规则时生效 · 快捷键常驻全局"
        case .app(let bundleIdentifier): return bundleIdentifier
        }
    }

    init(id: String) {
        self = (id == RuleScope.globalIdentifier) ? .global : .app(id)
    }
}

// MARK: - 键盘快捷键 DTO

/// 「物理快捷键 → 动作」的可序列化描述。
///
/// 和 `ActionDTO` 一样：`KeyboardShortcutDTO` 是**磁盘契约**，
/// 运行时才转成 `AppAction` / `HotKey`（Carbon 注册所需的类型无法 Codable）。
struct KeyboardShortcutDTO: Codable, Equatable {
    var id: String
    /// 虚拟键码（与 `KeyCatalog` 同源）
    var keyCode: UInt16
    /// 修饰键：`CGEventFlags.rawValue`（与 ActionDTO.syntheticKey 保持同一种位定义）
    var modifierRawValue: UInt64
    var action: ActionDTO

    init(id: String = UUID().uuidString,
         keyCode: UInt16,
         modifierRawValue: UInt64,
         action: ActionDTO) {
        self.id = id
        self.keyCode = keyCode
        self.modifierRawValue = modifierRawValue
        self.action = action
    }

    // MARK: 运行时视图

    /// Carbon 注册所需的修饰键掩码（转换规则见 `ModifierFlags`）
    var carbonModifiers: UInt32 { ModifierFlags.carbon(from: modifierRawValue) }

    var hotKey: HotKey { HotKey(keyCode: UInt32(keyCode), carbonModifiers: carbonModifiers) }

    /// 形如 `⌃⌥A`
    var readableDescription: String { hotKey.readableDescription }

    var actionSummary: String { action.summary }

    // MARK: 默认项

    /// 新增快捷键时的默认组合：⌃⌥ + 某个未被占用的键
    static func defaultShortcut(existing: [KeyboardShortcutDTO]) -> (keyCode: UInt16, modifierRawValue: UInt64) {
        let controlOption = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        let used = Set(existing.map { "\($0.modifierRawValue)-\($0.keyCode)" })
        let preferred: [UInt16] = [UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_D),
                                   UInt16(kVK_ANSI_F), UInt16(kVK_ANSI_G), UInt16(kVK_Space),
                                   UInt16(kVK_ANSI_T), UInt16(kVK_ANSI_R)]
        for key in preferred where !used.contains("\(controlOption)-\(key)") {
            return (key, controlOption)
        }
        return (UInt16(kVK_Space), controlOption)
    }
}

// MARK: - Item / Definition / Rule DTO

struct TouchBarItemDTO: Codable {
    var identifier: String
    var title: String
    var colorHex: String?
    var action: ActionDTO

    init(model: TouchBarItemModel) {
        identifier = model.identifier.rawValue
        title = model.title
        colorHex = model.bezelColor?.hexString
        action = ActionDTO(model.action)
    }

    var model: TouchBarItemModel {
        TouchBarItemModel(identifier: identifier,
                          title: title,
                          bezelColor: colorHex.flatMap { NSColor(hex: $0) },
                          action: action.action)
    }
}

struct TouchBarDefinitionDTO: Codable {
    var identifier: String
    var items: [TouchBarItemDTO]

    init(definition: TouchBarDefinition) {
        identifier = definition.customizationIdentifier
        items = definition.items.map(TouchBarItemDTO.init)
    }

    var model: TouchBarDefinition {
        TouchBarDefinition(identifier: identifier, items: items.map(\.model))
    }
}

struct TouchBarRuleDTO: Codable {
    var bundleIdentifiers: [String]
    var definition: TouchBarDefinitionDTO
    /// 仅在该应用处于前台时生效的键盘快捷键（v2 新增；v1 存档缺失时按 [] 迁移）
    var shortcuts: [KeyboardShortcutDTO] = []

    init(rule: TouchBarRule) {
        bundleIdentifiers = Array(rule.bundleIdentifiers)
        definition = TouchBarDefinitionDTO(definition: rule.definition)
        shortcuts = rule.shortcuts
    }

    var model: TouchBarRule {
        TouchBarRule(bundleIdentifiers: Set(bundleIdentifiers),
                     definition: definition.model,
                     shortcuts: shortcuts)
    }

    // MARK: 前向兼容（v1 → v2）

    /// v1 存档里没有 `shortcuts` 字段。Swift 合成的 decoder 遇到缺 key 会直接 throw，
    /// 导致整个解码失败 → 用户配置被回滚成默认值。这里主动兜住。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifiers = try container.decode([String].self, forKey: .bundleIdentifiers)
        definition = try container.decode(TouchBarDefinitionDTO.self, forKey: .definition)
        shortcuts = try container.decodeIfPresent([KeyboardShortcutDTO].self, forKey: .shortcuts) ?? []
    }
}

/// 磁盘上的完整快照
struct RuleStoreSnapshot: Codable {
    /// v1：只有 rules + generic
    /// v2：新增每个规则的 `shortcuts` 与全局的 `globalShortcuts`
    static let currentVersion = 2
    /// 仍可读取的最低版本（我们在 decode 层做了前向兼容，所以老版本也能读）
    static let minimumReadableVersion = 1

    var version: Int
    var rules: [TouchBarRuleDTO]
    /// 兜底（通用）Touch Bar，未命中任何规则时使用
    var generic: TouchBarDefinitionDTO?
    /// 「全局（所有应用）」作用域下的快捷键（v2 新增）
    var globalShortcuts: [KeyboardShortcutDTO]?

    var jsonData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}
