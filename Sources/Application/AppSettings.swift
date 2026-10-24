import Foundation

/// 轻量配置中心（UserDefaults 持久化）。
/// 保持小而明确：后续要加配置界面 / JSON 导入，只需替换这一层的实现。
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let backgroundTouchBarEnabled = "btTool.backgroundTouchBarEnabled"
        static let injectForAllApps = "btTool.injectForAllApps"
        static let trayItemDestroyOnDeactivate = "btTool.trayItemDestroyOnDeactivate"
    }

    private let defaults = UserDefaults.standard

    /// 是否在后台动态注入 Touch Bar（第三阶段总开关）
    var backgroundTouchBarEnabled: Bool {
        didSet { defaults.set(backgroundTouchBarEnabled, forKey: Key.backgroundTouchBarEnabled) }
    }

    /// 未命中规则时，是否也给其它应用注入「通用栏」
    var injectForAllApps: Bool {
        didSet { defaults.set(injectForAllApps, forKey: Key.injectForAllApps) }
    }

    /// 应用**停用**时是否真的销毁托盘项（字面版「激活注册 / 停用销毁」）。
    ///
    /// 默认 `false`：托盘的目标就是常驻，而用户停用我们的 App 时前台正是别人的 App ——
    /// 那一刻恰恰是托盘最该在的时候。另外**点击托盘按钮本身就会激活本进程**，
    /// 若把「激活 → 销毁」接上，点一次图标就自杀一次。
    /// 想验证字面行为（每次停用时真的拆掉）就把它改成 true。
    var trayItemDestroyOnDeactivate: Bool {
        didSet { defaults.set(trayItemDestroyOnDeactivate, forKey: Key.trayItemDestroyOnDeactivate) }
    }

    private init() {
        defaults.register(defaults: [
            Key.backgroundTouchBarEnabled: true,
            Key.injectForAllApps: true,
            Key.trayItemDestroyOnDeactivate: false,
        ])
        backgroundTouchBarEnabled = defaults.bool(forKey: Key.backgroundTouchBarEnabled)
        injectForAllApps = defaults.bool(forKey: Key.injectForAllApps)
        trayItemDestroyOnDeactivate = defaults.bool(forKey: Key.trayItemDestroyOnDeactivate)
    }
}
