import AppKit

// 显式启动入口。
//
// 为什么不用 `@main`：
// 无 nib / 无 storyboard 的纯代码 AppKit 应用，`@main` 的合成入口在某些工具链/配置下
// 不会回调 `applicationDidFinishLaunching`（表现为进程活着但没有任何输出）。
// 显式引导是最确定的写法，也方便以后在这里插入启动参数解析、单例互斥等逻辑。
//
// 🔴 第四阶段要点：这里第一时间把激活策略设为 `.accessory`（等价于 LSUIElement 的
// 「不显示 Dock 图标/主菜单」效果）。之所以不用 Info.plist 的 LSUIElement 键，
// 是因为该键会把进程永久钉死为 UIElement，导致打开配置窗口时无法切换成 `.regular`。

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
