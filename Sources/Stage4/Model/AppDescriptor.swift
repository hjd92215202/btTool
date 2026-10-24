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

extension AppDescriptor {
    /// 列出本机已安装的应用（按名字排序、按 Bundle ID 去重）。
    ///
    /// 为什么不用 `LSCopyApplicationURLsForURL`：它在 Swift 里不允许传 nil 的 URL /
    /// role mask，而没有"列出所有应用"的等价封装。所以改成扫一层应用目录 ——
    /// 绝大多数应用就躺在下列目录的顶层（不递归是为了别把扫描搞成几秒钟的操作）。
    static func installed() -> [AppDescriptor] {
        let fm = FileManager.default
        var directories = ["/Applications",
                           "/Applications/Utilities",
                           "/System/Applications",
                           "/System/Applications/Utilities"]
        if let userApps = fm.urls(for: .applicationDirectory, in: .userDomainMask).first {
            directories.append(userApps.path)
        }

        var seen = Set<String>()
        var result: [AppDescriptor] = []
        for directory in directories {
            guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (directory as NSString).appendingPathComponent(entry)
                guard let bundle = Bundle(path: path),
                      let id = bundle.bundleIdentifier,
                      seen.insert(id).inserted else { continue }
                result.append(AppDescriptor(bundleIdentifier: id))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
