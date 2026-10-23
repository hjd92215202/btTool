import Foundation

/// 极简断言框架。
///
/// 本工程刻意不引入 XCTest（`make` 是纯 `swiftc` 流水线，没有 Xcode 工程），
/// 所以 `make test` 会把「应用源码（去掉 main.swift）+ 测试源码」编成一个可执行文件直接跑，
/// 测试与被测代码在**同一个 module** 里，可以直接访问 `internal` 成员。
final class TestRunner {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    func check(_ condition: Bool,
               _ message: String,
               file: String = #file,
               line: Int = #line) {
        if condition {
            passed += 1
            return
        }
        let source = URL(fileURLWithPath: file).lastPathComponent
        failures.append("\(source):\(line) \(message)")
        print("  ❌ \(source):\(line) \(message)")
    }

    func checkEqual<T: Equatable>(_ actual: T,
                                  _ expected: T,
                                  _ message: String,
                                  file: String = #file,
                                  line: Int = #line) {
        check(actual == expected,
              "\(message)（期望：\(expected)，实际：\(actual)）",
              file: file,
              line: line)
    }

    var isSuccess: Bool { failures.isEmpty }
}
