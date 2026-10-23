import Carbon
import Foundation

/// 键位 / 修饰键的转换。
///
/// `ModifierFlags` 里的四个 Carbon 常量是**在本机用探针程序 `import Carbon` 实测打印确认**的
/// （见 `Sources/Stage1/HotKey/HotKey.swift` 的注释）。这些用例负责在有人凭直觉改动时立刻报错。
enum ConversionTests {
    static func run(_ t: TestRunner) {
        // CGEventFlags.rawValue → Carbon 掩码
        t.checkEqual(
            ModifierFlags.carbon(from: CGEventFlags.maskCommand.rawValue
                                     | CGEventFlags.maskShift.rawValue),
            UInt32(cmdKey | shiftKey),
            "⌘⇧ 应映射为 cmdKey|shiftKey")

        // Carbon 掩码 → CGEventFlags.rawValue
        t.checkEqual(ModifierFlags.cgRawValue(fromCarbon: UInt32(optionKey)),
                     CGEventFlags.maskAlternate.rawValue,
                     "optionKey 应反向映射回 maskAlternate")

        t.checkEqual(ModifierFlags.carbon(from: 0), UInt32(0), "没有任何修饰键时应映射为 0")

        // 往返一致性：四个键逐个走一遍 CG → Carbon → CG
        for flags in [CGEventFlags.maskCommand,
                      CGEventFlags.maskShift,
                      CGEventFlags.maskAlternate,
                      CGEventFlags.maskControl] {
            let carbon = ModifierFlags.carbon(from: flags.rawValue)
            t.checkEqual(ModifierFlags.cgRawValue(fromCarbon: carbon),
                         flags.rawValue,
                         "\(flags) 的 CG↔Carbon 往返应一致")
        }

        // 字形串顺序必须与「系统偏好设置」一致：⌃⌥⇧⌘
        let all = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue
        t.checkEqual(ModifierFlags.glyphs(cgRawValue: all), "⌃⌥⇧⌘", "四键组合的字形顺序应为 ⌃⌥⇧⌘")

        // KeyNames
        t.checkEqual(KeyNames.name(for: CGKeyCode(kVK_Space)), "Space", "kVK_Space 的显示名")
        t.checkEqual(KeyNames.name(for: CGKeyCode(kVK_Escape)), "Escape ⎋", "kVK_Escape 的显示名")
    }
}
