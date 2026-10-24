import AppKit
import Carbon.HIToolbox

/// 声明式的动作模型。
///
/// 这是整个架构里最重要的“接缝”：前台 Touch Bar 按钮、后台注入的 Touch Bar 按钮，
/// 三者都只产出 `AppAction`，执行逻辑集中在一处，后续要加脚本执行 / HTTP / AppleScript 只需扩展一个 case。
indirect enum AppAction {
    /// 打日志（最安全的测试动作）
    case log(String)
    /// 唤起某个应用
    case launch(bundleIdentifier: String, fallbackName: String? = nil)
    /// 打开 URL（也可用于 x-apple.systempreferences: 深链）
    case openURL(String)
    /// 发一条用户通知
    case notification(title: String, body: String)
    /// 投递模拟按键（需要辅助功能/输入监控权限）
    case syntheticKey(keyCode: CGKeyCode, flags: CGEventFlags)
    /// 后台异步执行一段 Shell 命令（走 `/bin/zsh -lc`，支持管道、PATH、`~/`）
    case shell(String)
    /// 后台异步执行一段 AppleScript 源码
    case appleScript(String)
    /// 打开配置主窗口（无匹配规则时的占位长栏用它）
    case openSettingsWindow
    /// 组合动作
    case group([AppAction])

    func run() {
        switch self {
        case .log(let message):
            Log.info("[Action] \(message)")
        case .launch(let bundleIdentifier, let fallbackName):
            WorkspaceLauncher.open(bundleIdentifier: bundleIdentifier, fallbackName: fallbackName)
        case .openURL(let string):
            guard let url = URL(string: string) else {
                Log.error("非法 URL：\(string)")
                return
            }
            NSWorkspace.shared.open(url)
        case .notification(let title, let body):
            Notifier.post(title: title, body: body)
        case .syntheticKey(let keyCode, let flags):
            SyntheticEvent.post(keyCode: keyCode, flags: flags)
        case .shell(let command):
            ShellRunner.run(command)
        case .appleScript(let source):
            AppleScriptRunner.run(source)
        case .openSettingsWindow:
            AppCoordinator.shared.showSettingsWindow()
        case .group(let actions):
            actions.forEach { $0.run() }
        }
    }
}

// MARK: - 常用按键封装

extension AppAction {
    /// ⌘[ ：Safari / Chrome 的“上一页”
    static var browserBack: AppAction {
        .syntheticKey(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), flags: .maskCommand)
    }
    /// ⌘] ：Safari / Chrome 的“下一页”
    static var browserForward: AppAction {
        .syntheticKey(keyCode: CGKeyCode(kVK_ANSI_RightBracket), flags: .maskCommand)
    }
    /// ⌘T：新建标签页
    static var browserNewTab: AppAction {
        .syntheticKey(keyCode: CGKeyCode(kVK_ANSI_T), flags: .maskCommand)
    }
    /// ⌘B：VS Code 切换侧边栏
    static var toggleSidebar: AppAction {
        .syntheticKey(keyCode: CGKeyCode(kVK_ANSI_B), flags: .maskCommand)
    }
    /// ⇧⌘P：VS Code 命令面板
    static var commandPalette: AppAction {
        .syntheticKey(keyCode: CGKeyCode(kVK_ANSI_P), flags: [.maskCommand, .maskShift])
    }
    /// ⌃` ：VS Code 终端
    static var toggleTerminal: AppAction {
        .syntheticKey(keyCode: CGKeyCode(kVK_ANSI_Grave), flags: .maskControl)
    }
}
