import Foundation
import os

/// 一条日志通道（os_log 通道 + 可读的分类名）。
struct LogChannel {
    let osLog: OSLog
    let name: String
}

/// 统一日志出口。三个阶段的所有模块都走这里。
///
/// 双通道输出：
/// 1. `os_log`（subsystem = com.bttool.app），可在 Console.app 里过滤查看；
/// 2. **文件镜像** `/tmp/btTool.log` —— 因为 os_log 的 info/debug 级别默认不落盘，
///    `log show` 事后抓不到，测试时直接用 `tail -f /tmp/btTool.log` 最省事。
///    每次启动会清空该文件，保证日志干净。
enum Log {
    static let subsystem = "com.bttool.app"

    static let general   = LogChannel(osLog: OSLog(subsystem: subsystem, category: "general"),   name: "general")
    static let hotKey    = LogChannel(osLog: OSLog(subsystem: subsystem, category: "hotkey"),    name: "hotkey")
    static let touchBar  = LogChannel(osLog: OSLog(subsystem: subsystem, category: "touchbar"),  name: "touchbar")
    static let workspace = LogChannel(osLog: OSLog(subsystem: subsystem, category: "workspace"), name: "workspace")

    /// 文件镜像路径
    static let fileURL = URL(fileURLWithPath: "/tmp/btTool.log")

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

    // MARK: - 文件镜像

    private static let queue = DispatchQueue(label: "com.bttool.log.file")
    private static let lock = NSLock()
    private static var prepared = false

    private static func append(level: String, category: String, message: String) {
        queue.async {
            let line = "\(timestamp()) [\(level)][\(category)] \(message)\n"
            let data = Data(line.utf8)

            // ① 终端启动（./btTool）时直接回显到 stderr，最直观
            FileHandle.standardError.write(data)

            // ② 镜像到文件（用 open/Finder 启动时只能看这里）
            prepareOnce()
            guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
                FileHandle.standardError.write(Data("[Log] 无法写入 \(fileURL.path)\n".utf8))
                return
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    /// 首次写日志时清空旧文件（相当于"每次启动一份新日志"）
    private static func prepareOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !prepared else { return }
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
        prepared = true
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
