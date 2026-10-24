import Foundation

/// `make test` 的入口：把「应用源码（去掉 main.swift）+ 测试源码」编成一个可执行文件直接跑。
///
/// 为什么不用 XCTest：本工程是纯 `swiftc` 流水线，没有 Xcode 工程，
/// 引入 XCTest 就得维护一套第二构建体系；而同 module 编译还能直接测 `internal` 成员。
let runner = TestRunner()

print("==> 运行 btTool 单元测试")
print("  · RuleStore（数据保护 / 版本迁移）")
RuleStoreTests.run(runner)
print("  · 键位与修饰键转换")
ConversionTests.run(runner)
print("  · 命令门禁与外部修改检测")
SecurityTests.run(runner)
print("  · 存档 DTO 编解码")
PersistentModelTests.run(runner)
print("  · 应用枚举（启动应用下拉框的数据源）")
AppDescriptorTests.run(runner)

if runner.isSuccess {
    print("✅ 全部通过（\(runner.passed) 项断言）")
    exit(0)
} else {
    print("❌ 失败 \(runner.failures.count) 项：")
    for failure in runner.failures { print("   \(failure)") }
    exit(1)
}
