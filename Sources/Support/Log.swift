import Foundation
import os

/// 一条日志通道（os_log 通道 + 可读的分类名）。
struct LogChannel {
    let osLog: OSLog
    let name: String
}

/// 统一日志出口。所有模块都走这里。
///
/// 双通道输出：
/// 1. `os_log`（subsystem = com.bttool.app），可在 Console.app 里过滤查看；
/// 2. **文件镜像** `~/Library/Logs/btTool/btTool.log`。
///
/// ## 🔒 P1 隐私修复（旧路径是 `/tmp/btTool.log`）
///
/// - **位置**：`/tmp` 是全系统可读可猜的共享目录，任何用户/进程都能 `cat` 到
///   窗口标题、Shell 命令、AppleScript 源码。现在放到用户自己的
///   `~/Library/Logs/btTool/`，目录 0700、文件 **0600**。
/// - **脱敏**：涉及上述内容的日志必须走 `Log.sensitive(_:_:)`，
///   它写进文件的是「类型 + 长度」摘要，正文只进 os_log 的 debug 级（默认不落盘）。
///   真要看正文就设环境变量 `BTTOOL_LOG_VERBOSE=1` 显式开启。
/// - **句柄**：只开**一个**常驻 `FileHandle`，全部可变状态都在同一个串行队列里访问
///   （旧实现每条日志都 open/close 一次，还用了一把与队列无关的 `NSLock` 保护 `prepared`）。
/// - **轮转**：超过 2 MB 自动滚到 `btTool.log.1`，不会无限增长。
enum Log {
    static let subsystem = "com.bttool.app"

    static let general   = LogChannel(osLog: OSLog(subsystem: subsystem, category: "general"),   name: "general")
    static let touchBar  = LogChannel(osLog: OSLog(subsystem: subsystem, category: "touchbar"),  name: "touchbar")
    static let workspace = LogChannel(osLog: OSLog(subsystem: subsystem, category: "workspace"), name: "workspace")

    /// 文件镜像路径：`~/Library/Logs/btTool/btTool.log`（**不再**放 /tmp）
    static let fileURL: URL = {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("btTool", isDirectory: true)
        return logs.appendingPathComponent("btTool.log")
    }()

    /// 轮转阈值
    private static let maxFileSize: UInt64 = 2 * 1024 * 1024

    static func info(_ message: String, log: LogChannel = Log.general) {
        os_log(.info, log: log.osLog, "%{public}@", message)
        append(level: "INFO ", category: log.name, message: message)
    }

    static func debug(_ message: String, log: LogChannel = Log.general) {
        os_log(.debug, log: log.osLog, "%{public}@", message)
        append(level: "DEBUG", category: log.name, message: message)
    }

    static func error(_ message: String, log: LogChannel = Log.general) {
        os_log(.error, log: log.osLog, "%{public}@", message)
        append(level: "ERROR", category: log.name, message: message)
    }

    /// **敏感内容专用出口**：窗口标题 / Shell 命令 / AppleScript 源码等。
    ///
    /// 文件里只留「类型 + 长度」摘要；正文进 os_log 的 debug 级（默认不落盘）。
    /// 需要排查时设 `BTTOOL_LOG_VERBOSE=1` 才会把正文也写进文件。
    static func sensitive(_ kind: String, _ value: String, log: LogChannel = Log.general) {
        os_log(.debug, log: log.osLog, "%{public}@", "\(kind): \(value)")
        let summary = "\(kind)（内容已脱敏，长度 \(value.count)）"
        if isVerboseEnabled {
            append(level: "DEBUG", category: log.name, message: "\(kind)：\(value)")
        } else {
            append(level: "DEBUG", category: log.name, message: summary)
        }
    }

    /// 是否输出敏感正文（环境变量 `BTTOOL_LOG_VERBOSE=1`，只读一次）
    private static let isVerboseEnabled: Bool =
        ProcessInfo.processInfo.environment["BTTOOL_LOG_VERBOSE"] != nil

    // MARK: - 文件镜像

    private static let queue = DispatchQueue(label: "com.bttool.log.file")
    /// 常驻句柄（只在 `queue` 上访问）
    private static var handle: FileHandle?
    private static var prepared = false

    private static func append(level: String, category: String, message: String) {
        queue.async {
            let line = "\(timestamp()) [\(level)][\(category)] \(message)\n"
            let data = Data(line.utf8)

            // ① 终端启动时直接回显到 stderr，最直观
            FileHandle.standardError.write(data)

            // ② 镜像到文件（用 open / Finder 启动时只能看这里）
            if !prepared { prepareFile() }
            guard let handle else {
                FileHandle.standardError.write(Data("[Log] 日志文件不可用：\(fileURL.path)\n".utf8))
                return
            }
            handle.seekToEndOfFile()
            handle.write(data)
            rotateIfNeeded()
        }
    }

    /// 一次性准备：建目录（0700）→ 滚动/新建文件（0600）→ 打开**一个**常驻句柄。
    /// 只在 `queue` 上执行，所以不需要额外的锁。
    private static func prepareFile() {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory,
                                                   withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // 每次启动把上一轮日志滚到 .1，保证本轮干净（旧行为是直接清空）
                rotateWithoutHandle()
            } else {
                FileManager.default.createFile(atPath: fileURL.path,
                                               contents: Data(),
                                               attributes: [.posixPermissions: 0o600])
            }
            handle = FileHandle(forWritingAtPath: fileURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: fileURL.path)
        } catch {
            FileHandle.standardError.write(Data("[Log] 日志目录准备失败：\(error.localizedDescription)\n".utf8))
        }
        prepared = true
    }

    private static func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
              size > maxFileSize else { return }
        copyToBackup()
        // 句柄保持不变，把内容截断后继续追加
        handle?.seek(toFileOffset: 0)
        handle?.truncateFile(atOffset: 0)
        append(level: "INFO ", category: "general",
               message: "日志文件超过 2 MB 已轮转，旧档保留为 btTool.log.1")
    }

    /// 启动时滚动（此时还没有句柄）：上一轮日志 → `btTool.log.1`，当前文件清空
    private static func rotateWithoutHandle() {
        copyToBackup()
        try? Data().write(to: fileURL)
    }

    /// 把当前文件另存为 `btTool.log.1`（0600）
    private static func copyToBackup() {
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
