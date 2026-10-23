import AppKit
import ApplicationServices
import Carbon.HIToolbox
import UserNotifications

// MARK: - 启动其他应用

enum WorkspaceLauncher {
    /// 通过 Bundle ID 启动应用；失败时回退到按应用名启动。
    static func open(bundleIdentifier: String, fallbackName: String? = nil) {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    Log.error("启动 \(bundleIdentifier) 失败：\(error.localizedDescription)")
                } else {
                    Log.info("已启动：\(app?.localizedName ?? bundleIdentifier)")
                }
            }
            return
        }
        guard let name = fallbackName else {
            Log.error("找不到应用：\(bundleIdentifier)")
            return
        }
        // 按名称启动（`-a` 走 LaunchServices，避免使用已废弃的 launchApplication(_:)）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        do {
            try process.run()
            Log.info("已启动（按名称）：\(name)")
        } catch {
            Log.error("启动失败（按名称）：\(name) · \(error.localizedDescription)")
        }
    }
}

// MARK: - 模拟按键（需要“输入监控 / 辅助功能”权限）

enum SyntheticEvent {
    /// 向 HID 事件流投递一次完整的按键按下+抬起。
    /// 注意：从后台进程投递键盘事件，需要用户在「系统设置 → 隐私与安全性 → 辅助功能 / 输入监控」中授权。
    static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard AccessibilityPermission.isTrusted else {
            Log.error("未获得辅助功能/输入监控权限，拒绝投递模拟按键（keyCode=\(keyCode)）")
            return
        }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            Log.error("无法创建 CGEvent")
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        Log.info("已投递模拟按键 keyCode=\(keyCode) flags=\(flags.rawValue)")
    }
}

// MARK: - 通知

/// 通知桥接层（第五阶段重点加固）。
///
/// ⚠️ 背景：自签名 / ad-hoc 签名（`codesign -s -`）的应用，通知中心常常直接返回
/// `Notifications are not allowed for this application` —— 这是**系统层面的拒绝**，
/// `requestAuthorization` 连弹窗都不会显示，直接回调 error。这是 BTT 类开源工具最常见的坑。
///
/// 因此这里做成「三段式」，任何一步失败都不会变成静默丢失：
///   ① 先查当前授权状态（`getNotificationSettings` 不会触发任何弹窗）；
///   ② 仅当状态为 `.notDetermined` 时，**在主线程**发起一次标准授权弹窗；
///   ③ 被拒 / 报错 / 投递失败，都把「标题 + 正文」完整降级写入日志（`/tmp/btTool.log`）。
enum Notifier {
    /// 即使本应用处于前台，也让通知以横幅形式弹出（UNUserNotificationCenter 默认只在前台静默）
    private final class CenterDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler:
                                        @escaping (UNNotificationPresentationOptions) -> Void) {
            if #available(macOS 11.0, *) {
                completionHandler([.banner, .list, .sound])
            } else {
                completionHandler([.alert, .sound])
            }
        }
    }

    private static let centerDelegate = CenterDelegate()
    private static var delegateInstalled = false

    private static func installDelegateOnce() {
        guard !delegateInstalled else { return }
        delegateInstalled = true
        UNUserNotificationCenter.current().delegate = centerDelegate
    }

    static func post(title: String, body: String) {
        installDelegateOnce()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver(title: title, body: body)
            case .notDetermined:
                // 授权弹窗必须在主线程发起（系统要求 UI 相关调用在 main run loop 上）
                DispatchQueue.main.async {
                    requestAuthorizationThenDeliver(title: title, body: body)
                }
            case .denied:
                fallback(title: title, body: body,
                         reason: "用户此前已拒绝通知权限（可在 系统设置 → 通知 中重新开启）")
            @unknown default:
                fallback(title: title, body: body, reason: "未知的授权状态")
            }
        }
    }

    /// 唯一一次触发系统标准授权弹窗的机会：系统对同一个 App 只会问一次，之后直接返回用户的选择
    private static func requestAuthorizationThenDeliver(title: String, body: String) {
        // 不用 precondition：这里做的是防御式重定向，宁可多一次调度也绝不让它崩掉
        guard Thread.isMainThread else {
            DispatchQueue.main.async { requestAuthorizationThenDeliver(title: title, body: body) }
            return
        }
        Log.info("尚未确定通知授权状态，正在请求系统授权弹窗…")

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    fallback(title: title, body: body,
                             reason: "requestAuthorization 失败：\(error.localizedDescription)")
                    return
                }
                guard granted else {
                    fallback(title: title, body: body,
                             reason: "系统拒绝授权（ad-hoc 签名/未付费开发者账号的常见表现）")
                    return
                }
                Log.info("✅ 通知授权通过")
                deliver(title: title, body: body)
            }
    }

    private static func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                // 注意：即使拿到了 granted=true，自签名应用仍可能在**这一步**被拒
                // （错误文案同样是 "Notifications are not allowed for this application"）
                fallback(title: title, body: body, reason: "投递失败：\(error.localizedDescription)")
            } else {
                Log.info("通知已投递：\(title)")
            }
        }
    }

    /// 降级出口：把本来该弹窗展示的内容原样写进日志，保证测试时**数据不丢失**
    private static func fallback(title: String, body: String, reason: String) {
        Log.error("⚠️ 通知未能展示：\(reason)")
        // 正文可能含隐私，降级写文件时也只留摘要
        Log.sensitive("未展示的通知标题", title)
        Log.sensitive("未展示的通知正文", body)
    }
}

// MARK: - Shell 脚本执行

/// 后台异步执行 shell 命令（例如 `pmset displaysleepnow`）。
enum ShellRunner {
    private static let queue = DispatchQueue(label: "com.bttool.shell", attributes: .concurrent)

    /// 线程安全的输出缓冲区
    private final class Buffer {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ chunk: Data) {
            lock.lock(); storage.append(chunk); lock.unlock()
        }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: storage, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    static func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.error("[Shell] 命令为空，已跳过")
            return
        }
        // 🔒 P1：这条命令如果是第一次见，先弹窗问过用户才执行（见 CommandApproval）
        guard CommandApproval.approveIfNeeded(.shell, trimmed) else { return }
        queue.async { execute(trimmed) }
    }

    /// 注意：本函数运行在后台线程，会阻塞到命令结束（这正是我们离开主线程的目的）
    private static func execute(_ command: String) {
        let task = Process()
        // 走 login shell：支持 `~/`、PATH 里的命令、管道、环境变量等
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
        } catch {
            Log.error("[Shell] 启动失败：\(error.localizedDescription)")
            Log.sensitive("Shell 命令", command)
            return
        }

        // 用 readabilityHandler 边产出边读：直接 readDataToEndOfFile 双管道会在
        // 输出超过管道缓冲区（~64KB）时死锁，这是 NSTask 的经典陷阱。
        let group = DispatchGroup()
        let stdoutBuffer = Buffer()
        let stderrBuffer = Buffer()

        for (index, pipe) in [stdoutPipe, stderrPipe].enumerated() {
            let handle = pipe.fileHandleForReading
            let buffer = index == 0 ? stdoutBuffer : stderrBuffer
            group.enter()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF
                    handle.readabilityHandler = nil
                    group.leave()
                    return
                }
                buffer.append(chunk)
            }
        }

        // 超时保护：脚本挂死时不要让后台线程永久卡住
        if group.wait(timeout: .now() + 30) == .timedOut {
            Log.error("[Shell] 读取输出超时（30s）：不再等待，命令留在后台自己跑完")
            Log.sensitive("Shell 命令", command)
            // 这里直接返回，绝不再 task.waitUntilExit() —— 否则"超时保护"等于没写：
            // 后台线程还是会一直陪着这条命令耗到它自己结束。
            return
        }
        task.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        Log.info("[Shell] 退出码=\(task.terminationStatus)")
        Log.sensitive("Shell 命令", command)
        let stdoutText = stdoutBuffer.string
        let stderrText = stderrBuffer.string
        // 命令的输出里可能含隐私内容（路径、账号、token），一律走脱敏通道
        if !stdoutText.isEmpty { Log.sensitive("Shell stdout", stdoutText) }
        if !stderrText.isEmpty { Log.sensitive("Shell stderr", stderrText) }
    }
}

// MARK: - AppleScript 执行

/// 后台异步执行 AppleScript（例如 `tell application "Spotify" to playpause`）。
enum AppleScriptRunner {
    /// 🔴 必须是**串行**队列：NSAppleScript 不是线程安全的。
    /// 实测用并发队列时，多个脚本同时编译会互相串扰（同一段非法脚本
    /// 一会儿返回 -2740 的真实编译错误，一会儿返回空的 {"没有错误"}），
    /// 结果不可复现。串行既规避了这个问题，也保证脚本按录入顺序执行。
    private static let queue = DispatchQueue(label: "com.bttool.applescript")

    static func run(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.error("[AppleScript] 脚本为空，已跳过")
            return
        }
        // 🔒 P1：同上，首次见到的脚本必须先经用户确认
        guard CommandApproval.approveIfNeeded(.appleScript, trimmed) else { return }
        // NSAppleScript 的编译+执行可能耗时数百毫秒，绝不能放在主线程
        queue.async {
            guard let script = NSAppleScript(source: trimmed) else {
                Log.error("[AppleScript] 无法创建脚本对象")
                Log.sensitive("AppleScript 源码", trimmed)
                return
            }

            // ① 显式编译：先拿到语法错误的精确定位（带 NSRange）。
            //    只在「确实有错误码」时才中止 —— 实测某些版本/并发场景下会返回
            //    errorNumber=0 且文案为「没有错误」的字典，那并不是真错误，
            //    继续走 execute 才能拿到真正的诊断。
            var compileError: NSDictionary?
            script.compileAndReturnError(&compileError)
            if let compileError, let number = compileError[NSAppleScript.errorNumber] as? Int, number != 0 {
                let number = compileError[NSAppleScript.errorNumber] as? Int
                let range = compileError[NSAppleScript.errorRange] as? NSRange
                Log.error("[AppleScript] 编译失败\(number.map { "（错误码 \($0)）" } ?? "")：" +
                          "\(Self.message(in: compileError))" +
                          (range.map { " ｜ 出错位置 NSRange=\(NSStringFromRange($0))" } ?? ""))
                return
            }

            // ② 运行期
            var runtimeError: NSDictionary?
            let result = script.executeAndReturnError(&runtimeError)
            if let runtimeError {
                let number = runtimeError[NSAppleScript.errorNumber] as? Int
                let appName = runtimeError[NSAppleScript.errorAppName] as? String
                Log.error("[AppleScript] 执行失败\(number.map { "（错误码 \($0)）" } ?? "")：" +
                          "\(Self.message(in: runtimeError))" +
                          (appName.map { " ｜ 目标应用：\($0)" } ?? ""))
                return
            }

            // NSAppleEventDescriptor 不一定能转成字符串（比如 date/record），回退到 description
            let value = result.stringValue ?? Self.shortened(result.description)
            Log.info("[AppleScript] 执行成功：\(value)")
        }
    }

    /// 取出错误文案：标准键缺失时（实测某些 -17xx 错误就没有 NSAppleScript.errorMessage）
    /// 回退到整个字典的 description，保证日志里永远有可查的信息。
    private static func message(in dictionary: NSDictionary) -> String {
        if let message = dictionary[NSAppleScript.errorMessage] as? String, !message.isEmpty {
            return message
        }
        if let brief = dictionary[NSAppleScript.errorBriefMessage] as? String, !brief.isEmpty {
            return brief
        }
        return shortened(dictionary.description, limit: 200)
    }

    /// description 可能非常长，截断一下避免刷屏
    private static func shortened(_ text: String?, limit: Int = 160) -> String {
        guard let text, !text.isEmpty else { return "(无返回值)" }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
