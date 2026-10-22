import AppKit

/// 动态切换激活策略：菜单栏常驻（accessory）⇄ 常规带 Dock 图标的应用（regular）。
///
/// 为什么要这么做：LSUIElement / accessory 应用**没有自己的主菜单**，
/// 配置窗口里就没法用 ⌘C/⌘V 编辑文本、也没法 ⌘W 关闭窗口。
/// BTT 一类工具的做法是：打开配置窗口时临时变成 regular（有 Dock 图标 + 主菜单），
/// 关闭后再退回 accessory。
///
/// ⚠️ 关键前提：Info.plist **不能**同时写死 `LSUIElement=YES`，否则系统会在启动时
/// 就把进程标记为 UIElement，`setActivationPolicy(.regular)` 会被忽略。
/// 本项目改为在 `main.swift` 里第一时间调用 `setActivationPolicy(.accessory)`，
/// 效果与 LSUIElement 一致，但保留了后续切换成 regular 的能力。
enum ActivationPolicyController {
    static func becomeRegular() {
        guard NSApp.activationPolicy() != .regular else { return }
        let ok = NSApp.setActivationPolicy(.regular)
        if !ok || NSApp.activationPolicy() != .regular {
            // 兜底：直接调用 LaunchServices 的进程类型转换
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
            let status = TransformProcessType(&psn, UInt32(kProcessTransformToForegroundApplication))
            Log.info("setActivationPolicy(.regular) 未生效，改用 TransformProcessType：status=\(status)")
        } else {
            Log.info("激活策略 → .regular（显示 Dock 图标 + 主菜单）")
        }
        MainMenuBuilder.installIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func becomeAccessory() {
        guard NSApp.activationPolicy() != .accessory else { return }
        let ok = NSApp.setActivationPolicy(.accessory)
        if !ok || NSApp.activationPolicy() != .accessory {
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
            let status = TransformProcessType(&psn, UInt32(kProcessTransformToUIElementApplication))
            Log.info("setActivationPolicy(.accessory) 未生效，改用 TransformProcessType：status=\(status)")
        } else {
            Log.info("激活策略 → .accessory（隐藏 Dock 图标，回到菜单栏）")
        }
    }
}
