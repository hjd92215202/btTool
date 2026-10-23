import AppKit
import Foundation

/// `RuleStore` 的数据保护与版本迁移。
///
/// 这几个用例专门盯住**曾经会直接覆盖用户存档**的三条路径：
/// 读失败 / 解析失败 / 版本过高。以前它们都是 `seedDefaults()` → `save()`，
/// 既没备份也没询问，用户的真实存档当场就没了。
enum RuleStoreTests {
    static func run(_ t: TestRunner) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("btToolTests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")

        // ① 首次运行：没有文件 → 正常写入默认规则，且**不是**只读模式
        do {
            let store = RuleStore(fileURL: file)
            t.check(!store.isReadOnlyMode, "首次运行不应进入只读模式")
            t.check(FileManager.default.fileExists(atPath: file.path), "首次运行应写入默认规则文件")
            t.check(!store.rules.isEmpty, "首次运行应载入内置默认规则")
        }

        // ② 内容损坏 → 只读 + 备份 + **不覆盖**（旧行为：直接把损坏文件覆盖成默认值）
        do {
            try Data("这根本不是 JSON".utf8).write(to: file)
            let before = try Data(contentsOf: file)
            let store = RuleStore(fileURL: file)
            t.check(store.isReadOnlyMode, "JSON 解析失败应进入只读模式")
            t.check(store.lastBackupURL != nil, "解析失败时应自动备份原文件")

            // `addItem(to: .global)` 落在 genericDefinition 上，不在 rules 上
            let countBefore = store.genericDefinition.items.count
            store.addItem(to: .global, title: "不该落盘")
            t.checkEqual(try? Data(contentsOf: file),
                         before,
                         "只读模式下的改动不得写入原文件")
            t.checkEqual(store.genericDefinition.items.count,
                         countBefore + 1,
                         "只读模式下的改动仍应保留在内存中")
            if let backup = store.lastBackupURL {
                t.checkEqual(try? Data(contentsOf: backup),
                             before,
                             "备份内容应与原文件逐字节一致")
            }
        } catch {
            t.check(false, "用例②前置写文件失败：\(error)")
        }

        // ③ 版本过高 → 只读 + 备份 + **不覆盖**（旧行为：直接 seedDefaults 覆盖）
        do {
            let future = RuleStoreSnapshot(version: RuleStoreSnapshot.currentVersion + 1,
                                           rules: [],
                                           generic: nil,
                                           globalShortcuts: nil)
            try future.jsonData?.write(to: file)
            let before = try Data(contentsOf: file)
            let store = RuleStore(fileURL: file)
            t.check(store.isReadOnlyMode, "存档版本过高应进入只读模式")
            t.check(store.lastBackupURL != nil, "版本过高时应自动备份原文件")
            t.checkEqual(try? Data(contentsOf: file),
                         before,
                         "版本过高时不得用默认值覆盖原文件")

            // 用户明确选择重置 → 退出只读模式并落盘
            store.resetToDefaults()
            t.check(!store.isReadOnlyMode, "resetToDefaults 之后应退出只读模式")
        } catch {
            t.check(false, "用例③前置写文件失败：\(error)")
        }

        // ④ v1 → v2 迁移：老存档读得出来，且读完立刻按当前版本写回
        do {
            try makeV1Archive().write(to: file)
            let store = RuleStore(fileURL: file)
            t.check(!store.isReadOnlyMode, "v1 存档应可正常读取，不进只读模式")
            t.check(!store.rules.isEmpty, "v1 存档里的应用规则应被读出来")
            t.checkEqual(store.globalShortcuts.count, 0,
                         "v1 存档没有 globalShortcuts 字段，应迁移为空数组")
            if let data = try? Data(contentsOf: file),
               let snapshot = try? JSONDecoder().decode(RuleStoreSnapshot.self, from: data) {
                t.checkEqual(snapshot.version,
                             RuleStoreSnapshot.currentVersion,
                             "读完 v1 存档后应立即按当前版本写回")
            } else {
                t.check(false, "迁移后应能读出 v2 存档")
            }
        } catch {
            t.check(false, "用例④前置写文件失败：\(error)")
        }

        // ⑤ 从备份恢复：模拟用户自己去修好了那份存档
        do {
            try Data("坏掉的存档".utf8).write(to: file)
            let store = RuleStore(fileURL: file)
            t.check(store.isReadOnlyMode, "损坏存档应进入只读模式")
            if let backup = store.lastBackupURL {
                try makeV2Archive().write(to: backup)
                t.check(store.restoreFromBackup(), "从修好的备份恢复后应退出只读模式")
                t.check(!store.isReadOnlyMode, "恢复后不应再是只读模式")
                t.check(!store.rules.isEmpty, "恢复后应读到备份里的规则")
            } else {
                t.check(false, "应存在可用于恢复的备份")
            }
        } catch {
            t.check(false, "用例⑤失败：\(error)")
        }

        // ⑥ 存档输出的顺序必须是**确定的**
        //    （Set 的遍历顺序取决于内部哈希布局，不排序就会让每次保存都在随机重排）
        do {
            let rule = TouchBarRule(bundleIdentifiers: ["com.apple.Terminal",
                                                        "com.apple.Safari",
                                                        "com.apple.Mail"],
                                    definition: TouchBarDefinition(identifier: "btTool.touchBar.sort",
                                                                   items: []),
                                    shortcuts: [])
            t.checkEqual(TouchBarRuleDTO(rule: rule).bundleIdentifiers,
                         ["com.apple.Mail", "com.apple.Safari", "com.apple.Terminal"],
                         "存档里的顺序应是确定的字典序")
        }
    }

    // MARK: - 测试用的存档构造

    /// 手工构造一份 **v1** 存档：没有 `shortcuts` / `globalShortcuts` 字段。
    private static func makeV1Archive() -> Data {
        Data("""
        {
          "version": 1,
          "rules": [
            {
              "bundleIdentifiers": ["com.apple.Safari"],
              "definition": {
                "identifier": "btTool.touchBar.com-apple-Safari",
                "items": []
              }
            }
          ],
          "generic": {
            "identifier": "btTool.touchBar.generic",
            "items": []
          }
        }
        """.utf8)
    }

    private static func makeV2Archive() -> Data {
        guard let first = TouchBarRule.defaults.first else { return Data() }
        let snapshot = RuleStoreSnapshot(
            version: RuleStoreSnapshot.currentVersion,
            rules: [TouchBarRuleDTO(rule: first)],
            generic: TouchBarDefinitionDTO(definition: TouchBarCatalog.generic),
            globalShortcuts: [])
        return snapshot.jsonData ?? Data()
    }
}
