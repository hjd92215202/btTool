import Foundation

/// 轻量配置中心（UserDefaults 持久化）。
/// 保持小而明确：后续要加配置界面 / JSON 导入，只需替换这一层的实现。
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let hotKeyEnabled = "btTool.hotKeyEnabled"
        static let backgroundTouchBarEnabled = "btTool.backgroundTouchBarEnabled"
        static let injectForAllApps = "btTool.injectForAllApps"
        static let experimentalControlStripItem = "btTool.experimentalControlStripItem"
    }

    private let defaults = UserDefaults.standard

    /// 是否启用全局快捷键（第一阶段）
    var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Key.hotKeyEnabled) }
    }

    /// 是否在后台动态注入 Touch Bar（第三阶段总开关）
    var backgroundTouchBarEnabled: Bool {
        didSet { defaults.set(backgroundTouchBarEnabled, forKey: Key.backgroundTouchBarEnabled) }
    }

    /// 未命中规则时，是否也给其它应用注入「通用栏」
    var injectForAllApps: Bool {
        didSet { defaults.set(injectForAllApps, forKey: Key.injectForAllApps) }
    }

    /// 实验性：尝试把入口项常驻到 Control Strip
    var experimentalControlStripItem: Bool {
        didSet { defaults.set(experimentalControlStripItem, forKey: Key.experimentalControlStripItem) }
    }

    private init() {
        defaults.register(defaults: [
            Key.hotKeyEnabled: true,
            Key.backgroundTouchBarEnabled: true,
            Key.injectForAllApps: true,
            Key.experimentalControlStripItem: false,
        ])
        hotKeyEnabled = defaults.bool(forKey: Key.hotKeyEnabled)
        backgroundTouchBarEnabled = defaults.bool(forKey: Key.backgroundTouchBarEnabled)
        injectForAllApps = defaults.bool(forKey: Key.injectForAllApps)
        experimentalControlStripItem = defaults.bool(forKey: Key.experimentalControlStripItem)
    }
}
