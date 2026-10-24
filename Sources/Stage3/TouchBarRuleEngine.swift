import AppKit
import Carbon.HIToolbox
import Foundation

/// 一条规则：命中这些 Bundle ID → 展示这条 Touch Bar。
struct TouchBarRule {
    var bundleIdentifiers: Set<String>
    var definition: TouchBarDefinition

    /// GUI 里一条规则对应一个应用，取第一个作为主键
    var primaryBundleIdentifier: String {
        bundleIdentifiers.first ?? ""
    }

    /// 内置默认规则（仅在首次启动时会被写入 `~/Library/Application Support/btTool/rules.json`，
    /// 之后一切以磁盘 JSON 为准）
    static let defaults: [TouchBarRule] = {
        let safari = TouchBarRule(bundleIdentifiers: ["com.apple.Safari",
                                                      "com.apple.SafariTechnologyPreview"],
                                  definition: TouchBarCatalog.safari)
        let chrome = TouchBarRule(bundleIdentifiers: ["com.google.Chrome",
                                                      "com.microsoft.edgemac",
                                                      "com.brave.Browser",
                                                      "org.mozilla.firefox"],
                                  definition: TouchBarCatalog.chrome)
        let vscode = TouchBarRule(bundleIdentifiers: ["com.microsoft.VSCode",
                                                      "com.microsoft.VSCodeInsiders"],
                                  definition: TouchBarCatalog.vscode)
        let finder = TouchBarRule(bundleIdentifiers: ["com.apple.finder"],
                                  definition: TouchBarCatalog.finder)

        return [safari, chrome, vscode, finder]
    }()

}

/// 规则引擎：Bundle ID → TouchBarDefinition。
///
/// 第四阶段之后，规则不再硬编码，而是从 `RuleStore`（JSON 持久化）读取；
/// 界面上的每一次增删改都会触发 `RuleStore.didChangeNotification`，
/// 由 `AppCoordinator` 调用 `reload()` 让其立即生效。
final class TouchBarRuleEngine {
    private(set) var rules: [TouchBarRule]

    init(rules: [TouchBarRule]? = nil) {
        self.rules = rules ?? RuleStore.shared.rules
    }

    /// 重新装载持久化数据
    func reload() {
        rules = RuleStore.shared.rules
        Log.info("规则引擎已重载：\(rules.count) 条", log: Log.workspace)
    }

    func addRule(_ rule: TouchBarRule) {
        rules.insert(rule, at: 0)
    }

    /// - Returns: 命中的定义；未命中且未开启「对所有应用注入」时返回 nil（此时应销毁已注入的栏）
    func resolve(bundleIdentifier: String?) -> TouchBarDefinition? {
        guard let bundleIdentifier else { return nil }
        if let matched = rules.first(where: { $0.bundleIdentifiers.contains(bundleIdentifier) }) {
            return matched.definition
        }
        return AppSettings.shared.injectForAllApps ? RuleStore.shared.genericDefinition : nil
    }

    /// 给 UI 展示用
    func ruleName(for bundleIdentifier: String?) -> String {
        guard let bundleIdentifier,
              let matched = rules.first(where: { $0.bundleIdentifiers.contains(bundleIdentifier) }) else {
            return AppSettings.shared.injectForAllApps ? "通用（兜底）" : "无"
        }
        return matched.definition.customizationIdentifier
    }
}
