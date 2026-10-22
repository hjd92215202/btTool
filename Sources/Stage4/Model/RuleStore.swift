import AppKit
import Foundation

/// 规则的**唯一数据源**（Single Source of Truth）。
///
/// 之前规则是硬编码在 `TouchBarRule.defaults` 里的；第四阶段之后：
/// - 首次启动：把默认规则落成 JSON（用户能在界面里看到它们）；
/// - 之后：一切增删查改都走这里，改动立即落盘并广播 `didChangeNotification`；
/// - 下游（`TouchBarRuleEngine` / `AppCoordinator`）监听通知重新装载，
///   于是后台注入引擎下一次启动就能自动用上用户的自定义规则。
///
/// 第六阶段的两个变化：
/// 1. 数据入口统一为 `RuleScope`：「全局（All Apps）」与「某个具体应用」走同一套 API，
///    这样左右栏 UI 不必区分两种数据形态；
/// 2. `version` 升到 2（新增 `shortcuts` / `globalShortcuts`），
///    并在 `TouchBarRuleDTO` 的自定义 decoder 里做前向兼容，保证 v1 存档**不会被回滚**。
final class RuleStore {
    static let shared = RuleStore()

    /// 数据变化通知（含持久化成功）
    static let didChangeNotification = Notification.Name("com.bttool.ruleStoreDidChange")

    /// 存储路径：~/Library/Application Support/btTool/rules.json
    let fileURL: URL

    private(set) var rules: [TouchBarRule] = []
    private(set) var genericDefinition: TouchBarDefinition
    /// 「全局（所有应用）」作用域下的快捷键 —— 常驻注册，不随前台应用切换而注销
    private(set) var globalShortcuts: [KeyboardShortcutDTO] = []

    private init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask)[0]
            .appendingPathComponent("btTool", isDirectory: true)
        fileURL = supportDirectory.appendingPathComponent("rules.json")
        genericDefinition = TouchBarCatalog.generic
        load()
    }

    // MARK: - 加载 / 保存

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            seedDefaults()
            return
        }
        guard let snapshot = try? JSONDecoder().decode(RuleStoreSnapshot.self, from: data) else {
            Log.error("规则文件解析失败，为避免覆盖用户的旧配置，**放弃写入**并改用内置默认值启动：\(fileURL.path)")
            rules = TouchBarRule.defaults
            genericDefinition = TouchBarCatalog.generic
            globalShortcuts = TouchBarRule.defaultGlobalShortcuts
            return
        }
        guard snapshot.version >= RuleStoreSnapshot.minimumReadableVersion,
              snapshot.version <= RuleStoreSnapshot.currentVersion else {
            Log.error("不支持的规则版本 \(snapshot.version)，已按上述策略降级处理")
            seedDefaults()
            return
        }

        rules = snapshot.rules.map(\.model)
        genericDefinition = snapshot.generic?.model ?? TouchBarCatalog.generic
        // v1 存档没有这个 key → nil → []
        globalShortcuts = snapshot.globalShortcuts ?? []
        let migrated = snapshot.version < RuleStoreSnapshot.currentVersion
        Log.info("已从磁盘加载规则：\(fileURL.path)（\(rules.count) 条应用规则 · " +
                 "\(globalShortcuts.count) 条全局快捷键\(migrated ? " · 已从 v\(snapshot.version) 迁移" : "")）")
        if snapshot.version == RuleStoreSnapshot.currentVersion { return }
        // 迁移：读完立刻按新版本写回，下次就不用再走兼容分支了
        Log.info("正在把存档从 v\(snapshot.version) 升级到 v\(RuleStoreSnapshot.currentVersion)")
        save()
    }

    /// 首次运行：写入默认规则；也用于「恢复默认设置」
    func seedDefaults() {
        rules = TouchBarRule.defaults
        genericDefinition = TouchBarCatalog.generic
        globalShortcuts = TouchBarRule.defaultGlobalShortcuts
        Log.info("首次运行 / 配置损坏，已写入默认规则")
        save()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let snapshot = RuleStoreSnapshot(version: RuleStoreSnapshot.currentVersion,
                                             rules: rules.map(TouchBarRuleDTO.init),
                                             generic: TouchBarDefinitionDTO(definition: genericDefinition),
                                             globalShortcuts: globalShortcuts)
            try snapshot.jsonData?.write(to: fileURL, options: .atomic)
            Log.debug("规则已保存到 \(fileURL.path)（\(rules.count) 条）")
        } catch {
            Log.error("保存规则失败：\(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: RuleStore.didChangeNotification, object: self)
    }

    // MARK: - 规则（应用）CRUD

    func rule(bundleIdentifier: String) -> TouchBarRule? {
        rules.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }

    @discardableResult
    func addRule(bundleIdentifier: String, preferredName: String? = nil) -> Bool {
        guard rule(bundleIdentifier: bundleIdentifier) == nil else {
            Log.info("规则已存在，跳过：\(bundleIdentifier)")
            return false
        }
        let identifier = "btTool.touchBar." + bundleIdentifier
            .replacingOccurrences(of: ".", with: "-")
        let definition = TouchBarDefinition(identifier: identifier, items: [])
        rules.append(TouchBarRule(bundleIdentifiers: [bundleIdentifier], definition: definition))
        Log.info("新增应用规则：\(preferredName ?? bundleIdentifier)（\(bundleIdentifier)）")
        save()
        return true
    }

    func removeRule(bundleIdentifier: String) {
        guard let index = rules.firstIndex(where: { $0.bundleIdentifiers.contains(bundleIdentifier) }) else { return }
        rules.remove(at: index)
        Log.info("删除应用规则：\(bundleIdentifier)")
        save()
    }

    // MARK: - Touch Bar 按钮（按作用域）

    func items(in scope: RuleScope) -> [TouchBarItemModel] {
        switch scope {
        case .global: return genericDefinition.items
        case .app(let bundleIdentifier):
            return rule(bundleIdentifier: bundleIdentifier)?.definition.items ?? []
        }
    }

    func item(in scope: RuleScope, itemID: String) -> TouchBarItemModel? {
        items(in: scope).first { $0.identifier.rawValue == itemID }
    }

    func addItem(to scope: RuleScope, title: String = "新按钮") {
        let item = TouchBarItemModel(identifier: "btTool.item.\(UUID().uuidString)",
                                     title: title,
                                     bezelColor: nil,
                                     action: .log("Hello btTool"))
        switch scope {
        case .global:
            genericDefinition.appendItem(item)
        case .app(let bundleIdentifier):
            guard let index = index(ofRule: bundleIdentifier) else { return }
            rules[index].definition.appendItem(item)
        }
        Log.info("新增按钮：\(title)（作用域：\(scope.displayName)）")
        save()
    }

    func removeItem(from scope: RuleScope, itemID: String) {
        switch scope {
        case .global:
            guard let index = genericDefinition.items.firstIndex(where: { $0.identifier.rawValue == itemID }) else { return }
            genericDefinition.items.remove(at: index)
        case .app(let bundleIdentifier):
            guard let ruleIndex = index(ofRule: bundleIdentifier),
                  let itemIndex = rules[ruleIndex].definition.items.firstIndex(where: {
                      $0.identifier.rawValue == itemID
                  }) else { return }
            rules[ruleIndex].definition.items.remove(at: itemIndex)
        }
        save()
    }

    /// 就地修改某个按钮。GUI 里所有编辑最终都收敛到这里。
    func updateItem(in scope: RuleScope, itemID: String, mutate: (inout TouchBarItemModel) -> Void) {
        switch scope {
        case .global:
            guard let index = genericDefinition.items.firstIndex(where: { $0.identifier.rawValue == itemID }) else { return }
            mutate(&genericDefinition.items[index])
        case .app(let bundleIdentifier):
            guard let ruleIndex = index(ofRule: bundleIdentifier),
                  let itemIndex = rules[ruleIndex].definition.items.firstIndex(where: {
                      $0.identifier.rawValue == itemID
                  }) else { return }
            mutate(&rules[ruleIndex].definition.items[itemIndex])
        }
        save()
    }

    // MARK: - 键盘快捷键（按作用域）

    func shortcuts(in scope: RuleScope) -> [KeyboardShortcutDTO] {
        switch scope {
        case .global: return globalShortcuts
        case .app(let bundleIdentifier):
            return rule(bundleIdentifier: bundleIdentifier)?.shortcuts ?? []
        }
    }

    /// - Returns: 新快捷键的 id（便于 UI 选中它）
    @discardableResult
    func addShortcut(to scope: RuleScope) -> String? {
        let existing = shortcuts(in: scope)
        let combo = KeyboardShortcutDTO.defaultShortcut(existing: existing)
        let shortcut = KeyboardShortcutDTO(keyCode: combo.keyCode,
                                           modifierRawValue: combo.modifierRawValue,
                                           action: ActionDTO(kind: .log, text: "快捷键已触发"))
        switch scope {
        case .global:
            globalShortcuts.append(shortcut)
        case .app(let bundleIdentifier):
            guard let index = index(ofRule: bundleIdentifier) else { return nil }
            rules[index].shortcuts.append(shortcut)
        }
        Log.info("新增快捷键：\(shortcut.readableDescription)（作用域：\(scope.displayName)）")
        save()
        return shortcut.id
    }

    func removeShortcut(from scope: RuleScope, shortcutID: String) {
        switch scope {
        case .global:
            guard let index = globalShortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
            globalShortcuts.remove(at: index)
        case .app(let bundleIdentifier):
            guard let ruleIndex = index(ofRule: bundleIdentifier),
                  let index = rules[ruleIndex].shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
            rules[ruleIndex].shortcuts.remove(at: index)
        }
        save()
    }

    func updateShortcut(in scope: RuleScope,
                        shortcutID: String,
                        mutate: (inout KeyboardShortcutDTO) -> Void) {
        switch scope {
        case .global:
            guard let index = globalShortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
            mutate(&globalShortcuts[index])
        case .app(let bundleIdentifier):
            guard let ruleIndex = index(ofRule: bundleIdentifier),
                  let index = rules[ruleIndex].shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
            mutate(&rules[ruleIndex].shortcuts[index])
        }
        save()
    }

    // MARK: - 内部

    private func index(ofRule bundleIdentifier: String) -> Int? {
        rules.firstIndex { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }
}
