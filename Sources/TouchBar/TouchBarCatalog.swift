import AppKit

/// Touch Bar 定义目录：所有「长什么样、点下去干什么」都集中在这里。
///
/// 后续要做成可配置化（JSON / 可视化编辑器），只需要把这里改成「从磁盘加载 → 产出 TouchBarDefinition」，
/// 其余所有模块（呈现器、规则引擎、快捷键）一行都不用改。
enum TouchBarCatalog {
    // MARK: 第二阶段：本应用处于前台时展示的示例 Touch Bar

    static let foregroundDemo = TouchBarDefinition(
        identifier: "btTool.touchBar.foreground",
        items: [
            TouchBarItemModel(identifier: "btTool.item.testA",
                              title: "测试A",
                              action: .log("测试A：来自前台 Touch Bar 的点击 ✅")),
            TouchBarItemModel(identifier: "btTool.item.testB",
                              title: "测试B",
                              bezelColor: .systemBlue,
                              action: .group([
                                .log("测试B：模拟动作开始执行"),
                                .notification(title: "btTool", body: "测试B 的模拟动作已执行"),
                              ])),
        ]
    )

    // MARK: 第三阶段：按前台应用注入的定义

    static let safari = TouchBarDefinition(
        identifier: "btTool.touchBar.safari",
        items: [
            TouchBarItemModel(identifier: "btTool.item.back", title: "← 后退", action: .browserBack),
            TouchBarItemModel(identifier: "btTool.item.forward", title: "前进 →", action: .browserForward),
            TouchBarItemModel(identifier: "btTool.item.newTab", title: "新标签页",
                              bezelColor: .systemBlue, action: .browserNewTab),
        ]
    )

    static let chrome = TouchBarDefinition(
        identifier: "btTool.touchBar.chrome",
        items: [
            TouchBarItemModel(identifier: "btTool.item.back", title: "← 后退", action: .browserBack),
            TouchBarItemModel(identifier: "btTool.item.forward", title: "前进 →", action: .browserForward),
            TouchBarItemModel(identifier: "btTool.item.newTab", title: "新标签页",
                              bezelColor: .systemOrange, action: .browserNewTab),
        ]
    )

    static let vscode = TouchBarDefinition(
        identifier: "btTool.touchBar.vscode",
        items: [
            TouchBarItemModel(identifier: "btTool.item.sidebar", title: "侧边栏", action: .toggleSidebar),
            TouchBarItemModel(identifier: "btTool.item.palette", title: "命令面板", action: .commandPalette),
            TouchBarItemModel(identifier: "btTool.item.terminal", title: "终端",
                              bezelColor: .systemGreen, action: .toggleTerminal),
        ]
    )

    static let finder = TouchBarDefinition(
        identifier: "btTool.touchBar.finder",
        items: [
            TouchBarItemModel(identifier: "btTool.item.desktop",
                              title: "回桌面",
                              action: .openURL("file:///Users/\(NSUserName())/Desktop")),
            TouchBarItemModel(identifier: "btTool.item.calculator",
                              title: "计算器",
                              bezelColor: .systemPurple,
                              action: .launch(bundleIdentifier: "com.apple.calculator",
                                              fallbackName: "Calculator")),
        ]
    )

    /// 兜底定义：没有命中任何规则时使用（受 AppSettings.injectForAllApps 控制）
    static let generic = TouchBarDefinition(
        identifier: "btTool.touchBar.generic",
        items: [
            TouchBarItemModel(identifier: "btTool.item.genericA",
                              title: "测试A",
                              action: .log("[通用] 测试A 被点击")),
            TouchBarItemModel(identifier: "btTool.item.genericB",
                              title: "测试B",
                              bezelColor: .systemGray,
                              action: .group([
                                .log("[通用] 测试B 模拟动作"),
                                .notification(title: "btTool", body: "通用栏：测试B 已执行"),
                              ])),
        ]
    )
}
