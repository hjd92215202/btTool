import Foundation

/// P1 安全项：命令执行门禁（哈希白名单）+ 存档外部修改检测。
///
/// 这两个功能保护的是同一条威胁路径：**谁能写规则文件，谁就能让 btTool 执行任意命令**。
/// 所以它们的共同要求是 —— 命令内容改一个字节，指纹就必须变，否则提权攻击成立。
enum SecurityTests {
    static func run(_ t: TestRunner) {
        // ① 命令指纹的三条性质
        let digest = CommandApproval.digest(of: .shell, "echo hi")
        t.checkEqual(CommandApproval.digest(of: .shell, "echo hi"),
                     digest,
                     "同样的命令必须得到同样的指纹")
        t.check(CommandApproval.digest(of: .shell, "echo hi!") != digest,
                "内容改一个字符，指纹就必须变（否则批准的 echo hi 会被换成别的命令）")
        t.check(CommandApproval.digest(of: .appleScript, "echo hi") != digest,
                "同样内容作为不同类型，指纹必须不同")
        t.checkEqual(digest.count, 64, "SHA256 的十六进制长度应为 64")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("btToolTests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // ② 白名单的持久化（临时目录，不碰用户的真实白名单）
        let originalURL = CommandApproval.fileURL
        CommandApproval.fileURL = directory.appendingPathComponent("approvedCommands.json")
        CommandApproval.reload()
        defer {
            CommandApproval.fileURL = originalURL
            CommandApproval.reload()
        }
        t.check(!CommandApproval.isApproved(.shell, "say hi"), "没批准过的命令应返回 false")

        let approved = CommandApproval.digest(of: .shell, "say hi")
        if let data = try? JSONSerialization.data(withJSONObject: ["approved": [approved]]) {
            try? data.write(to: CommandApproval.fileURL)
        }
        CommandApproval.reload()
        t.check(CommandApproval.isApproved(.shell, "say hi"),
                "写进白名单的命令应被识别为已批准")
        t.check(!CommandApproval.isApproved(.shell, "say 别的"),
                "不在白名单里的命令应返回 false")

        // ③ 存档的外部修改检测 + 权限
        let file = directory.appendingPathComponent("rules.json")

        // 首次运行：本程序自己写入 → 记录摘要 → 不报外部修改
        let first = RuleStore(fileURL: file)
        t.check(!first.wasModifiedExternally, "本程序自己写入的存档不应报外部修改")

        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        t.checkEqual((permissions as? NSNumber)?.int16Value,
                     Int16(0o600),
                     "存档文件权限应为 0600（里面存着可执行命令）")

        // 在 btTool 之外改写这个文件（模拟"别人替我改了配置"）
        let tampered = RuleStoreSnapshot(version: RuleStoreSnapshot.currentVersion,
                                         rules: [],
                                         generic: nil)
        try? tampered.jsonData?.write(to: file)

        let second = RuleStore(fileURL: file)
        t.check(second.wasModifiedExternally, "存档被外部改写后应报外部修改")
        t.check(!second.isReadOnlyMode, "内容本身是合法 v2，不应进只读模式")

        second.acknowledgeExternalModification()
        t.check(!second.wasModifiedExternally, "用户确认之后应清除外部修改标志")

        let third = RuleStore(fileURL: file)
        t.check(!third.wasModifiedExternally,
                "确认之后应以当前内容为新基准，不再重复报警")

        // ④ 首次见到一个「本程序没保存过」的文件：只建立基准，不误报
        //    （否则装上带此检测的版本后，第一次启动就会对已有存档报警）
        let untouched = directory.appendingPathComponent("external-rules.json")
        try? Data(#"{"version":2,"rules":[],"generic":{"identifier":"g1","items":[]}}"#.utf8)
            .write(to: untouched)
        let baseline = RuleStore(fileURL: untouched)
        t.check(!baseline.wasModifiedExternally,
                "首次见到该文件时不报警，只把它记为基准")

        // 之后被外部改动 → 必须报
        try? Data(#"{"version":2,"rules":[],"generic":{"identifier":"g2","items":[]}}"#.utf8)
            .write(to: untouched)
        let afterTamper = RuleStore(fileURL: untouched)
        t.check(afterTamper.wasModifiedExternally,
                "基准建立之后被外部改动，必须报警")
    }
}
