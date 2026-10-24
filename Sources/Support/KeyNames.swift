import Carbon.HIToolbox
import Foundation

/// 虚拟键码 → 人类可读名称的**唯一真值表**。
///
/// 为什么要有这张表：
/// 1. 之前 `HotKey`（Stage1）和 `KeyCatalog`（Stage4）各维护了一份名称逻辑，容易不一致
///    （Stage1 那份已随**全局快捷键**功能一起删除，现在只剩这一张表）；
/// 2. 旧版 `HotKey.name(for:)` 用 `kVK_ANSI_A ... kVK_ANSI_Z` 做**区间运算** —— 这是错的：
///    `kVK_ANSI_*` 按 QWERTY **物理**布局排列，**不是连续值**
///    （A=0x00, S=0x01, D=0x02, … T=0x11，中间还夹着数字键 0x12+）。
///    区间换算出 `"A" + offset` 会得到诸如 `⌃⌘+` 之类的鬼名字。
///
/// 现在 UI 下拉框（「模拟按键」动作）用这一张表；本文件同时也放修饰键掩码换算
/// —— `ModifierFlags` 是 CGEventFlags 与 Carbon 两套位定义之间的桥，被
/// `ShortcutRecorderField`（模拟按键录制控件）依赖。
enum KeyNames {
    struct Entry {
        let keyCode: CGKeyCode
        let name: String
    }

    /// 顺序即 UI 下拉框里的展示顺序（常用键在前）
    static let entries: [Entry] = [
        // 功能键
        Entry(keyCode: CGKeyCode(kVK_Space), name: "Space"),
        Entry(keyCode: CGKeyCode(kVK_Return), name: "Return ↵"),
        Entry(keyCode: CGKeyCode(kVK_Tab), name: "Tab ⇥"),
        Entry(keyCode: CGKeyCode(kVK_Escape), name: "Escape ⎋"),
        Entry(keyCode: CGKeyCode(kVK_Delete), name: "Delete ⌫"),
        Entry(keyCode: CGKeyCode(kVK_ForwardDelete), name: "Del ⌦"),
        Entry(keyCode: CGKeyCode(kVK_Home), name: "Home ⇱"),
        Entry(keyCode: CGKeyCode(kVK_End), name: "End ⇲"),
        Entry(keyCode: CGKeyCode(kVK_PageUp), name: "PgUp ⇞"),
        Entry(keyCode: CGKeyCode(kVK_PageDown), name: "PgDn ⇟"),
        Entry(keyCode: CGKeyCode(kVK_LeftArrow), name: "←"),
        Entry(keyCode: CGKeyCode(kVK_RightArrow), name: "→"),
        Entry(keyCode: CGKeyCode(kVK_UpArrow), name: "↑"),
        Entry(keyCode: CGKeyCode(kVK_DownArrow), name: "↓"),
        Entry(keyCode: CGKeyCode(kVK_F1), name: "F1"),
        Entry(keyCode: CGKeyCode(kVK_F2), name: "F2"),
        Entry(keyCode: CGKeyCode(kVK_F3), name: "F3"),
        Entry(keyCode: CGKeyCode(kVK_F4), name: "F4"),
        Entry(keyCode: CGKeyCode(kVK_F5), name: "F5"),
        Entry(keyCode: CGKeyCode(kVK_F6), name: "F6"),
        Entry(keyCode: CGKeyCode(kVK_F7), name: "F7"),
        Entry(keyCode: CGKeyCode(kVK_F8), name: "F8"),
        Entry(keyCode: CGKeyCode(kVK_F9), name: "F9"),
        Entry(keyCode: CGKeyCode(kVK_F10), name: "F10"),
        Entry(keyCode: CGKeyCode(kVK_F11), name: "F11"),
        Entry(keyCode: CGKeyCode(kVK_F12), name: "F12"),
        // 符号键（⌘[ / ⌘] 是浏览器前进后退，必须有）
        Entry(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), name: "["),
        Entry(keyCode: CGKeyCode(kVK_ANSI_RightBracket), name: "]"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Grave), name: "`"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Minus), name: "-"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Equal), name: "="),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Semicolon), name: ";"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Quote), name: "'"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Comma), name: ","),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Period), name: "."),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Slash), name: "/"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Backslash), name: "\\"),
        // ⚠️ 字母必须逐个列出（kVK_ANSI_A…Z 非连续，见文件头说明）
        Entry(keyCode: CGKeyCode(kVK_ANSI_A), name: "A"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_B), name: "B"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_C), name: "C"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_D), name: "D"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_E), name: "E"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_F), name: "F"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_G), name: "G"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_H), name: "H"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_I), name: "I"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_J), name: "J"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_K), name: "K"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_L), name: "L"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_M), name: "M"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_N), name: "N"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_O), name: "O"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_P), name: "P"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Q), name: "Q"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_R), name: "R"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_S), name: "S"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_T), name: "T"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_U), name: "U"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_V), name: "V"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_W), name: "W"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_X), name: "X"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Y), name: "Y"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_Z), name: "Z"),
        // ⚠️ 数字同样不连续
        Entry(keyCode: CGKeyCode(kVK_ANSI_0), name: "0"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_1), name: "1"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_2), name: "2"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_3), name: "3"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_4), name: "4"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_5), name: "5"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_6), name: "6"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_7), name: "7"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_8), name: "8"),
        Entry(keyCode: CGKeyCode(kVK_ANSI_9), name: "9"),
    ]

    private static let lookup: [CGKeyCode: String] = {
        var result: [CGKeyCode: String] = [:]
        for entry in entries {
            // 真值表里有极个别重复键码时保留第一个即可
            if result[entry.keyCode] == nil { result[entry.keyCode] = entry.name }
        }
        return result
    }()

    static func name(for keyCode: CGKeyCode) -> String {
        lookup[keyCode] ?? "#\(keyCode)"
    }

    static func index(of keyCode: CGKeyCode) -> Int {
        entries.firstIndex { $0.keyCode == keyCode } ?? 0
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
