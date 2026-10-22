import AppKit
import Carbon.HIToolbox
import Foundation
import UniformTypeIdentifiers

/// 应用描述信息（图标 + 名字），给左侧列表展示用。
struct AppDescriptor {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            self.icon = workspace.icon(forFile: url.path)
            if let bundle = Bundle(url: url) {
                let display = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                let short = bundle.infoDictionary?["CFBundleName"] as? String
                self.name = display ?? short ?? FileManager.default.displayName(atPath: url.path)
                return
            }
            self.name = FileManager.default.displayName(atPath: url.path)
        } else {
            if #available(macOS 12.0, *) {
                self.icon = workspace.icon(for: UTType.application)
            } else {
                self.icon = workspace.icon(forFileType: "app")
            }
            self.name = bundleIdentifier
        }
    }
}

/// 虚拟键码目录（供「模拟按键」「快捷键」下拉框使用）
///
/// 真值表统一来自 `Support/KeyNames.swift`（第六阶段起单源维护），
/// 这里只做一层薄封装以免触碰既有调用点。
enum KeyCatalog {
    struct Option {
        let name: String
        let keyCode: CGKeyCode
    }

    static let options: [Option] = KeyNames.entries.map { Option(name: $0.name, keyCode: $0.keyCode) }

    static func name(for keyCode: CGKeyCode) -> String { KeyNames.name(for: keyCode) }

    static func index(of keyCode: CGKeyCode) -> Int { KeyNames.index(of: keyCode) }
}
