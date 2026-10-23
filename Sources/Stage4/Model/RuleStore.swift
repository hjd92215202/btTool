import AppKit
import CryptoKit
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

    /// **只读模式**标志：规则文件读不出来 / 解析失败 / 版本不兼容时置 true。
    ///
    /// 该状态下 `save()` **一律不落盘**，改动只留在内存里，用户的原文件绝不会被覆盖。
    /// 想恢复写入必须由用户显式选择 `resetToDefaults()` 或 `restoreFromBackup()`。
    private(set) var isReadOnlyMode = false
    /// 最近一次自动备份的路径（只读模式下才有意义）
    private(set) var lastBackupURL: URL?

    /// **外部修改**标志：存档内容与本程序上次写入的不一致（细节见 `load()`）。
    ///
    /// 为什么要用**内容哈希**而不是 mtime：mtime 可以被随意改回去（`touch -t`），
    /// 而"改动了什么"这件事本身就是我们想知道的。
    private(set) var wasModifiedExternally = false

    /// 存档内容摘要的存储位置：记录"本程序最后写进去的到底是什么"。
    ///
    /// 按**存档文件名**派生（`.rules.json.digest`），而不是固定叫 `.rulesDigest` ——
    /// 备份文件 `rules.json.bak-<时间戳>` 是与主存档同目录的，共用一份摘要记录会互相污染。
    private var digestURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).digest")
    }

    private init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask)[0]
            .appendingPathComponent("btTool", isDirectory: true)
        fileURL = supportDirectory.appendingPathComponent("rules.json")
        genericDefinition = TouchBarCatalog.generic
        load()
    }

    /// 仅供测试注入存档路径；生产代码一律用 `shared`。
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.genericDefinition = TouchBarCatalog.generic
        load()
    }

    // MARK: - 加载 / 保存

    /// 加载磁盘存档。
    ///
    /// 🔴 这里曾经有三条**直接覆盖用户数据**的路径（读失败 / 解析失败 / 版本过高），
    /// 它们都是 `seedDefaults()` → `save()`，既没备份也没询问，用户的真实存档当场就没了。
    /// 现在统一改成：**先备份 → 进只读模式 → 绝不覆盖**（见 `enterReadOnlyMode`）。
    func load() {
        // 每次加载都先把状态复位：上一次可能是只读模式，**这次读成功了就应当恢复写入**。
        // （漏掉这两行的话，`restoreFromBackup()` 会永远退不出只读模式 —— 是单测抓出来的）
        isReadOnlyMode = false
        lastBackupURL = nil
        // 文件不存在 = 首次运行：本来就没有可覆盖的东西，正常写入默认规则
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Log.info("未找到规则文件 → 首次运行，写入默认规则：\(fileURL.path)")
            isReadOnlyMode = false
            seedDefaults()
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            enterReadOnlyMode(reason: "规则文件存在但读取失败（权限或介质问题）")
            return
        }
        guard let snapshot = try? JSONDecoder().decode(RuleStoreSnapshot.self, from: data) else {
            enterReadOnlyMode(reason: "规则文件 JSON 解析失败")
            return
        }
        guard snapshot.version <= RuleStoreSnapshot.currentVersion else {
            enterReadOnlyMode(reason: "存档版本 \(snapshot.version) 高于本程序支持的" +
                              " \(RuleStoreSnapshot.currentVersion)（多半是更新版 btTool 写的）")
            return
        }
        guard snapshot.version >= RuleStoreSnapshot.minimumReadableVersion else {
            enterReadOnlyMode(reason: "存档版本 \(snapshot.version) 低于最低可读版本" +
                              " \(RuleStoreSnapshot.minimumReadableVersion)")
            return
        }

        // 🔒 存档里存着用户配置的动作（含 Shell / AppleScript 命令），权限收紧到 0600
        hardenFilePermissions()

        // 🔒 外部修改检测：本次读到的内容摘要 vs 本程序上次写入的摘要
        let current = Self.contentDigest(of: data)
        if let recorded = recordedDigest() {
            if recorded != current {
                wasModifiedExternally = true
                Log.error("⚠️ 规则文件在 btTool 之外被修改过（内容摘要与上次本程序写入的不一致）：\(fileURL.path)")
                Log.error("   请注意：谁能写这个文件，谁就能让 btTool 去执行他写的 Shell / AppleScript 命令。")
            }
        } else {
            // 本程序还没记录过这个文件的摘要（平时只读不写，所以 save() 从来没被调用）→
            // 先以当前内容为基准、**不**报警。漏了这一步，检测就只在"保存过一次之后"才生效，
            // 对绝大多数用户等于永远不生效（这是真机验证抓出来的）。
            recordDigest(data)
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

    /// 首次运行：写入默认规则（仅在没有现存文件时走这里）。
    func seedDefaults() {
        rules = TouchBarRule.defaults
        genericDefinition = TouchBarCatalog.generic
        globalShortcuts = TouchBarRule.defaultGlobalShortcuts
        Log.info("首次运行，已写入默认规则")
        save()
    }

    // MARK: - 只读模式（数据保护）

    /// 读不出来 / 解析失败 / 版本不兼容时的统一处理：**先备份，再进只读模式，绝不覆盖**。
    private func enterReadOnlyMode(reason: String) {
        isReadOnlyMode = true
        lastBackupURL = backupCurrentFile()
        rules = TouchBarRule.defaults
        genericDefinition = TouchBarCatalog.generic
        globalShortcuts = TouchBarRule.defaultGlobalShortcuts
        Log.error("⚠️ \(reason)：已进入**只读模式**，本次运行不会写入任何规则，原文件不会被覆盖。")
        if let backup = lastBackupURL {
            Log.error("   原文件已备份到：\(backup.path)")
        } else {
            Log.error("   ⚠️ 备份失败！请手动复制 \(fileURL.path) 后再做其它操作")
        }
        Log.error("   恢复方式：配置界面 →「用默认值重置」/「从备份恢复」。")
    }

    /// 把当前存档复制成 `rules.json.bak-<时间戳>`（同名先删），返回备份路径。
    @discardableResult
    private func backupCurrentFile() -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("rules.json.bak-" + formatter.string(from: Date()))
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return destination
        } catch {
            Log.error("备份规则文件失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 用户明确选择「用默认值重置」：退出只读模式并落盘（备份文件保留，不删除）。
    ///
    /// 必须用户显式触发 —— 否则就等于我们替用户决定扔掉他看不懂的那份存档。
    func resetToDefaults() {
        isReadOnlyMode = false
        rules = TouchBarRule.defaults
        genericDefinition = TouchBarCatalog.generic
        globalShortcuts = TouchBarRule.defaultGlobalShortcuts
        Log.info("用户确认「用默认值重置」→ 退出只读模式并写入默认规则" +
                 (lastBackupURL.map { "（原备份保留在 \($0.path)）" } ?? ""))
        save()
        lastBackupURL = nil
    }

    /// 用户明确选择「从备份恢复」：把最近的备份覆盖回主文件并重新加载。
    ///
    /// - Returns: 恢复后是否已退出只读模式（备份本身也读不出来时会重新进入只读模式）
    @discardableResult
    func restoreFromBackup() -> Bool {
        guard let backup = lastBackupURL else {
            Log.error("没有可用的备份文件，无法恢复")
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.copyItem(at: backup, to: fileURL)
        } catch {
            Log.error("从备份恢复失败：\(error.localizedDescription)")
            return false
        }
        Log.info("已从备份恢复：\(backup.path)")
        load()
        return !isReadOnlyMode
    }

    /// 记录下"本程序最后写进这个文件的到底是什么"（供外部修改检测比对）
    private func recordDigest(_ data: Data) {
        try? Self.contentDigest(of: data).write(to: digestURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: digestURL.path)
    }

    /// 上次记录的摘要；没有记录过（首次运行 / 摘要文件被删）→ nil
    private func recordedDigest() -> String? {
        guard let text = try? String(contentsOf: digestURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 存档内容的 SHA256 摘要
    static func contentDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 用户已知悉外部改动 → 以当前文件内容作为新的基准
    func acknowledgeExternalModification() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        recordDigest(data)
        wasModifiedExternally = false
        Log.info("已确认规则文件的外部改动，后续以当前内容为基准继续检测")
    }

    /// 把存档文件权限收紧到 **0600**。
    ///
    /// 存档里存着用户配置的动作（Shell 命令、AppleScript 源码），
    /// 默认的 0644 意味着同机其它用户 / 任何进程都能读到它 —— 而能写这个文件
    /// 就等于能让本程序去执行任意命令。
    private func hardenFilePermissions() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    func save() {
        // 🟢 只读模式：不落盘，但仍广播通知让 UI 反映内存里的改动
        if isReadOnlyMode {
            Log.error("当前为只读模式 → 本次改动**不会**写入磁盘" +
                      "（用户在配置界面选择「重置」后才会恢复写入）")
            NotificationCenter.default.post(name: RuleStore.didChangeNotification, object: self)
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let snapshot = RuleStoreSnapshot(version: RuleStoreSnapshot.currentVersion,
                                             rules: rules.map(TouchBarRuleDTO.init),
                                             generic: TouchBarDefinitionDTO(definition: genericDefinition),
                                             globalShortcuts: globalShortcuts)
            let data = snapshot.jsonData
            try data?.write(to: fileURL, options: .atomic)
            hardenFilePermissions()
            if let data { recordDigest(data) }
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
