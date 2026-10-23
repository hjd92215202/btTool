import AppKit
import CryptoKit
import Foundation

/// Shell / AppleScript 动作的**执行确认 + 白名单**门禁。
///
/// ## 🔴 为什么必须有这道门
///
/// 规则文件里可以存任意命令，而规则文件是**磁盘上的一个普通文件**。
/// 谁能写这个文件，谁就能让 btTool 以当前用户的身份执行任意 Shell / AppleScript ——
/// 这是标准的**权限提升路径**：从「能改我的配置」直接跳到「能执行任意命令」。
/// 所以不能只防"用户自己手滑"，要防"别人替我改了配置"。
///
/// ## 策略：按**命令内容**的哈希建白名单
///
/// - 首次遇到某条命令 → 弹窗把**正文**摆给用户看，三选一：允许并记住 / 仅此一次 / 取消；
/// - 选「允许并记住」→ 该命令的哈希进白名单，之后静默放行；
/// - 命令内容**改一个字符哈希就变** → 重新弹窗。这一点是刻意设计的：
///   否则「批准过 `rm -rf ~/tmp`、后来被改成 `rm -rf ~` 却因为还是同一条规则而放行」
///   这种提权就成立；
/// - 白名单文件 0600：它记录了用户信任过哪些命令，本身就是敏感信息。
enum CommandApproval {
    enum Kind: String, Codable, CaseIterable {
        case shell
        case appleScript

        var displayName: String {
            switch self {
            case .shell: return "Shell 命令"
            case .appleScript: return "AppleScript"
            }
        }
    }

    /// 弹窗里用户的选择
    enum Decision {
        /// 放行，并且记住（写进白名单）
        case approveAndRemember
        /// 只放行这一次，不进白名单
        case approveOnce
        /// 拒绝执行
        case deny
    }

    /// 白名单存储路径（`~/Library/Application Support/btTool/approvedCommands.json`，0600）。
    /// 声明为 `var` 是为了让单测能临时指到临时目录。
    static var fileURL: URL = {
        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("btTool", isDirectory: true)
        return supportDirectory.appendingPathComponent("approvedCommands.json")
    }()

    // MARK: - 门禁入口

    /// 检查这条命令能不能执行；不在白名单里就弹窗问。
    ///
    /// - Returns: 是否放行
    @discardableResult
    static func approveIfNeeded(_ kind: Kind, _ content: String) -> Bool {
        let digest = digest(of: kind, content)
        lock.lock()
        let known = approvedDigests.contains(digest)
        lock.unlock()
        if known { return true }

        // 第一次见这条命令：把正文摆出来问用户（弹窗必须落在主线程）
        Log.info("[安全] 首次执行\(kind.displayName)，已弹窗询问用户")
        Log.sensitive(kind.displayName, content)
        switch askOnMainThread(kind: kind, content: content) {
        case .approveAndRemember:
            remember(digest)
            Log.info("[安全] 用户选择「允许并记住」，该\(kind.displayName)已加入白名单")
            return true
        case .approveOnce:
            Log.info("[安全] 用户选择「仅此一次」，不加入白名单")
            return true
        case .deny:
            Log.info("[安全] 用户取消了这段\(kind.displayName)的执行")
            return false
        }
    }

    /// 仅供测试：这条命令当前是否在白名单里（不弹窗）
    static func isApproved(_ kind: Kind, _ content: String) -> Bool {
        approvedDigests.contains(digest(of: kind, content))
    }

    /// 仅供测试：重新读取磁盘上的白名单（换了 `fileURL` 之后用）
    static func reload() {
        lock.lock()
        approvedDigests = load()
        lock.unlock()
    }

    // MARK: - 哈希

    /// 命令的指纹 = SHA256("<kind>:<正文>")。
    ///
    /// 带上 kind 前缀是为了让「同样的字符串分别作为 Shell 命令和 AppleScript」互不相认。
    static func digest(of kind: Kind, _ content: String) -> String {
        let input = Data("\(kind.rawValue):\(content)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 弹窗

    /// 弹 NSAlert 必须在主线程；本函数可能被后台队列调用，所以做一次跳转。
    private static func askOnMainThread(kind: Kind, content: String) -> Decision {
        if Thread.isMainThread { return ask(kind: kind, content: content) }
        return DispatchQueue.main.sync { ask(kind: kind, content: content) }
    }

    private static func ask(kind: Kind, content: String) -> Decision {
        let alert = NSAlert()
        alert.messageText = "允许执行这段\(kind.displayName)吗？"
        alert.informativeText = """
        这是我们第一次见到它 —— 来源是 Touch Bar 按钮 / 全局快捷键的规则配置，\
        或者是**被外部程序改动过的规则文件**。

        请确认下面这段内容是你自己写的、且你信任它：
        """
        alert.alertStyle = .warning
        alert.accessoryView = makeScrollableText(content)
        alert.addButton(withTitle: "允许并记住")
        alert.addButton(withTitle: "仅此一次")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .approveAndRemember
        case .alertSecondButtonReturn: return .approveOnce
        default: return .deny
        }
    }

    /// 命令可能很长，用可滚动的文本框摆出来（不截断 —— 截断就看不到末尾的恶意部分了）
    private static func makeScrollableText(_ content: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 132))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 132))
        text.string = content
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.userFixedPitchFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11)
        text.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = text
        return scroll
    }

    // MARK: - 白名单持久化

    private struct Snapshot: Codable {
        var approved: [String]
    }

    private static let lock = NSLock()
    private static var approvedDigests: Set<String> = CommandApproval.load()

    private static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return [] }
        return Set(snapshot.approved)
    }

    private static func remember(_ digest: String) {
        lock.lock()
        approvedDigests.insert(digest)
        let all = approvedDigests
        lock.unlock()
        save(all)
    }

    private static func save(_ digests: Set<String>) {
        let snapshot = Snapshot(approved: digests.sorted())
        guard let data = try? JSONEncoder().encode(snapshot) else {
            Log.error("[安全] 命令白名单序列化失败")
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            // 白名单本身也敏感（记录了用户信任过什么），权限收紧到 0600
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: fileURL.path)
        } catch {
            Log.error("[安全] 保存命令白名单失败：\(error.localizedDescription)")
        }
    }
}
