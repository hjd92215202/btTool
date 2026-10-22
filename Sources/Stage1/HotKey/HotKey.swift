import Carbon.HIToolbox
import Foundation

/// 一个全局快捷键的描述（Carbon 风格：虚拟键码 + 修饰键掩码）。
struct HotKey: Equatable {
    /// 虚拟键码（kVK_* 常量，与键盘布局无关）
    let keyCode: UInt32
    /// Carbon 修饰键掩码（`cmdKey` / `optionKey` / `controlKey` / `shiftKey` 的组合）
    let carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 从 UI 层（CGEventFlags 语义）构造
    init(keyCode: CGKeyCode, cgFlags: CGEventFlags) {
        self.init(keyCode: UInt32(keyCode),
                  carbonModifiers: ModifierFlags.carbon(from: cgFlags.rawValue))
    }

    // MARK: 常用预设

    /// ⌥Space（注意：系统默认用它做 Spotlight / 输入法切换，可能被抢占）
    static let optionSpace = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    /// ⌥⌘Space
    static let optionCommandSpace = HotKey(keyCode: UInt32(kVK_Space),
                                           carbonModifiers: UInt32(optionKey | cmdKey))
    /// ⌃⌥Space
    static let controlOptionSpace = HotKey(keyCode: UInt32(kVK_Space),
                                           carbonModifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥T
    static let controlOptionT = HotKey(keyCode: UInt32(kVK_ANSI_T),
                                       carbonModifiers: UInt32(controlKey | optionKey))

    var readableDescription: String {
        ModifierFlags.glyphs(carbon: carbonModifiers) + KeyNames.name(for: CGKeyCode(truncatingIfNeeded: keyCode))
    }
}

// MARK: - 修饰键掩码映射（CGEventFlags ⇄ Carbon）

/// ⚠️ 这里是整个快捷键功能最容易写错的地方，务必看完注释再改。
///
/// 两套 API 用的是**两套完全不同且毫无算术关系**的位定义：
///
/// | 修饰键 | Carbon（`RegisterEventHotKey`） | CGEventFlags（CGEvent / NSEvent） |
/// |---|---|---|
/// | ⌃ Control | `controlKey` = 1<<12 = 4096 | `maskControl` = 1<<18 = 262144 |
/// | ⌥ Option  | `optionKey`  = 1<<11 = 2048 | `maskAlternate` = 1<<19 = 524288 |
/// | ⇧ Shift   | `shiftKey`   = 1<<9  = 512  | `maskShift` = 1<<17 = 131072 |
/// | ⌘ Command | `cmdKey`     = 1<<8  = 256  | `maskCommand` = 1<<20 = 1048576 |
///
/// 偏移量分别是 6 / 8 / 8 / 12 —— **不存在统一的 `>> 16` 换算**。
/// 这套数值是用 /tmp 下的探针程序在本机 `import Carbon` 后实测打印确认的，
/// 一旦有疑问，先写探针打印这四个常量再改代码，不要凭直觉改。
enum ModifierFlags {
    /// CGEventFlags.rawValue → Carbon 修饰键掩码
    static func carbon(from rawValue: UInt64) -> UInt32 {
        var result: UInt32 = 0
        if rawValue & CGEventFlags.maskControl.rawValue != 0 { result |= UInt32(controlKey) }
        if rawValue & CGEventFlags.maskAlternate.rawValue != 0 { result |= UInt32(optionKey) }
        if rawValue & CGEventFlags.maskShift.rawValue != 0 { result |= UInt32(shiftKey) }
        if rawValue & CGEventFlags.maskCommand.rawValue != 0 { result |= UInt32(cmdKey) }
        return result
    }

    /// Carbon 修饰键掩码 → CGEventFlags.rawValue
    static func cgRawValue(fromCarbon carbon: UInt32) -> UInt64 {
        var result: UInt64 = 0
        if carbon & UInt32(controlKey) != 0 { result |= CGEventFlags.maskControl.rawValue }
        if carbon & UInt32(optionKey) != 0 { result |= CGEventFlags.maskAlternate.rawValue }
        if carbon & UInt32(shiftKey) != 0 { result |= CGEventFlags.maskShift.rawValue }
        if carbon & UInt32(cmdKey) != 0 { result |= CGEventFlags.maskCommand.rawValue }
        return result
    }

    /// Carbon 掩码 → 顺序字形串（⌃⌥⇧⌘，与系统偏好设置里的显示顺序一致）
    static func glyphs(carbon: UInt32) -> String {
        var parts: [String] = []
        if carbon & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbon & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbon & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbon & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts.joined()
    }

    /// CGEventFlags.rawValue → 顺序字形串
    static func glyphs(cgRawValue: UInt64) -> String {
        glyphs(carbon: carbon(from: cgRawValue))
    }
}
