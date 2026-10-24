import Foundation

/// 覆盖「启动应用」下拉框的数据来源 —— `AppDescriptor.installed()`。
///
/// 这个列表是下拉框的全部内容：一旦枚举失败或为空，用户就**选不出任何应用**，
/// 而界面上看不到报错（只会是个空菜单），所以在这里守一道。
enum AppDescriptorTests {
    static func run(_ t: TestRunner) {
        let apps = AppDescriptor.installed()
        t.check(!apps.isEmpty, "应能枚举出已安装应用（下拉框的内容不能是空的）")

        // Safari 一定在系统里，用它当"枚举真的读到了应用目录"的探针
        guard let safari = apps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
            t.check(false, "列表里应有 Safari —— 否则说明应用目录没扫到")
            return
        }
        t.check(safari.name != "com.apple.Safari",
                "Safari 应取到可读的名字，而不是退化成 Bundle ID（实际：\(safari.name)）")

        // 下拉框里几百个应用，没排序等于没法用
        let names = apps.map(\.name)
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        t.checkEqual(names, sorted, "列表应按名字排序")

        // 去重：同一 Bundle ID 出现两次会让 indexOfSelectedItem 对不上
        let ids = apps.map(\.bundleIdentifier)
        t.checkEqual(ids.count, Set(ids).count, "Bundle ID 不应重复")
    }
}
