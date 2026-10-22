import AppKit

/// 程序化构建主菜单栏。
///
/// accessory 应用（LSUIElement）默认没有主菜单 —— 一旦我们把策略切成 `.regular`，
/// 窗口就会缺少主菜单，导致：⌘W 关不掉窗口、文本框里 ⌘C/⌘V 失效、没有「窗口」菜单。
/// 这里按标准结构（App / Edit / Window）手工搭一个，所有 action 都指向 nil target
/// （走 responder chain），因此无需我们自己实现任何逻辑。
enum MainMenuBuilder {
    static func installIfNeeded() {
        guard NSApp.mainMenu == nil else { return }

        let mainMenu = NSMenu()

        // — App 菜单 —
        let appMenuItem = NSMenuItem(title: "btTool", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 btTool",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 btTool", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem({ item in
            item.title = "隐藏其他"
            item.action = #selector(NSApplication.hideOtherApplications(_:))
            item.keyEquivalent = "h"
            item.keyEquivalentModifierMask = [.command, .option]
            return item
        }(NSMenuItem()))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 btTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // — Edit 菜单（决定文本框能否 ⌘X/⌘C/⌘V）—
        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(menuItem("撤销", #selector(UndoAction.undo(_:)), "z"))
        editMenu.addItem(menuItem("重做", #selector(UndoAction.redo(_:)), "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("剪切", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(menuItem("拷贝", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(menuItem("粘贴", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(menuItem("全选", #selector(NSText.selectAll(_:)), "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // — Window 菜单 —
        let windowMenuItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(menuItem("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(menuItem("缩放", #selector(NSWindow.performZoom(_:)), ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem("关闭窗口", #selector(NSWindow.performClose(_:)), "w"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
        Log.info("已构建程序化主菜单")
    }

    private static func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}

/// `#selector(UndoAction.undo(_:))` 需要一个真实存在的类型
@objc protocol UndoAction {
    @objc func undo(_ sender: Any?)
    @objc func redo(_ sender: Any?)
}
