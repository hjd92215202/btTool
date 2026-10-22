# btTool —— 类 BetterTouchTool 的 macOS 效率工具（三阶段架构）

一个常驻菜单栏、监听全局事件、并能**在后台动态改写 Touch Bar** 的 macOS App。
工程已在本机（macOS 12.7 / Swift 5.7）通过 `swiftc` 全量编译并打包为 `build/btTool.app`。

---

## 一、Xcode 工程模板与初始配置

### 1. 推荐模板

| 选项 | 选择 | 原因 |
|------|------|------|
| Platform | **macOS** | — |
| Template | **App**（AppKit App Delegate，**不要** SwiftUI） | Touch Bar / 菜单栏 / 事件监听全部是 AppKit API；SwiftUI 需 `NSApplicationDelegateAdaptor` 绕一层，反而更绕 |
| Interface | **None（纯代码，无 Storyboard / XIB）** | 菜单栏 + 无窗口应用不需要 nib；纯代码便于版本管理和后续模块化 |
| Language | Swift | — |
| Deployment Target | **macOS 11.0+**（Touch Bar API 自 10.12.2 起） | 建议 11.0，`NSImage(systemSymbolName:)` 需要 11+ |

如果 Xcode 模板强制生成了 `Main.storyboard` / `MainMenu.xib`：
删除文件 → 在 Target → **Info** 中清空 `Main Interface` → 删除 Info.plist 里的 `NSMainNibFile` 键。

### 2. 必须改的构建设置（否则功能会静默失效）

| 位置 | 设置 | 说明 |
|------|------|------|
| Info.plist | **不要**写 `LSUIElement`（见下方 ⚠️） | 改为代码里 `setActivationPolicy(.accessory)`，效果相同但保留切回 regular 的能力 |
| Info.plist | `NSAccessibilityUsageDescription` | 辅助功能授权弹窗的说明文案（已写好） |
| Info.plist | `NSAppleEventsUsageDescription` / `NSInputMonitoringUsageDescription` | 控制其它 App / 模拟按键时的说明 |
| Signing & Capabilities | **移除 App Sandbox** | 沙盒会阻断全局热键、AX、私有框架注入 |
| Signing & Capabilities | Hardened Runtime 可保留，开发期建议关闭 | 关闭后 `codesign --sign -` 即可跑 |
| Build Settings | `ENABLE_HARDENED_RUNTIME = NO`（调试） | 同上 |
| Build Settings | `SKIP_INSTALL = YES` | 避免 archive 出问题 |
| General | App Category = Utilities | — |

> ⚠️ **重要**：辅助功能授权是按「签名身份 + bundle id」记录的。调试期反复改动后需要重置：
> `sudo tccutil reset Accessibility com.bttool.app`

### 3. 两种构建方式（任选）

```bash
# A. 命令行（无需打开 Xcode，便于 CI）
make            # 编译并打包 build/btTool.app
make typecheck  # 只做类型检查
make run        # 构建并打开

# B. Xcode：新建 macOS App 工程后，把 Sources/ 整个目录拖入，
#    Info.plist 用 Resources/Info.plist 的内容，入口是 Sources/Application/main.swift（显式引导）。

# 开启文件日志（已在代码里默认开启，无需额外操作）
tail -f /tmp/btTool.log
```

> ⚠️ 入口说明：工程使用**显式的 `main.swift`** 而不是 `@main`。
> 无 nib / 无 storyboard 的纯代码 AppKit 应用，`@main` 的合成入口在部分工具链下
> 不会回调 `applicationDidFinishLaunching`（现象：进程活着但一条日志都没有）。
> 同时 Info.plist 里**不要**留 `NSMainNibFile` / `NSMainStoryboardFile` 键。

---

## 二、统一架构设计

### 目录结构

```
Sources/
├── Application/
│   ├── main.swift                  # 显式启动入口 + 第一时间设为 .accessory
│   ├── AppDelegate.swift           # 应用生命周期委托
│   ├── AppCoordinator.swift        # ★ 总装：唯一持有各模块生命周期的地方
│   └── AppSettings.swift           # UserDefaults 配置
├── Support/
│   ├── Log.swift                   # os_log 统一日志（subsystem: com.bttool.app）
│   ├── AppAction.swift             # ★ 声明式动作模型（三阶段共用）
│   └── SystemBridges.swift         # 启动 App / 模拟按键 / 通知
├── Stage1/
│   ├── StatusBar/StatusBarController.swift      # 菜单栏 UI（只展示 + 转发事件）
│   └── HotKey/
│       ├── HotKey.swift                         # 热键描述
│       ├── HotKeyCenter.swift                   # ★ Carbon RegisterEventHotKey
│       └── NSEventHotKeyMonitor.swift           # 备选方案（需输入监控权限）
├── TouchBar/                       # ★ 二、三阶段的公共抽象层
│   ├── TouchBarDefinition.swift    # 数据描述 + TouchBarPresenting 协议（字段可变，供 GUI 就地编辑）
│   ├── TouchBarHost.swift          # NSTouchBar + NSTouchBarDelegate
│   └── TouchBarCatalog.swift       # 默认 Touch Bar 定义（首次启动写入 JSON 的种子数据）
├── Stage2/
│   └── TouchBarHostWindowController.swift       # key window → 前台 Touch Bar
└── Stage3/
    ├── FrontmostAppMonitor.swift   # NSWorkspace 前台应用监听（防抖 + 去重）
    ├── TouchBarRuleEngine.swift    # Bundle ID → TouchBarDefinition
    ├── AccessibilityPermission.swift            # AX 权限检测 / 引导 / 变化监听
    ├── AXWindowInspector.swift     # 读取前台窗口标题（需 AX）
    └── PrivateTouchBar/
        ├── ObjCRuntime.swift       # 类型安全的 objc_msgSend 封装
        ├── DFRFoundationBridge.swift            # dlopen 私有框架
        └── SystemModalTouchBarPresenter.swift   # ★ 后台注入核心
└── Stage4/                          # ★ 第四阶段：GUI 配置主窗口
    ├── ActivationPolicyController.swift        # regular ⇄ accessory 动态切换（含 TransformProcessType 兜底）
    ├── Model/
    │   ├── PersistentModel.swift   # ActionDTO / ItemDTO / RuleDTO + NSColor↔#RRGGBB
    │   ├── AppDescriptor.swift     # 应用图标与名称 + 虚拟键码目录 KeyCatalog
    │   └── RuleStore.swift         # ★ 唯一数据源：CRUD + JSON 持久化 + 变更通知
    └── UI/
        ├── MainMenuBuilder.swift   # 程序化主菜单（regular 策略下必需，否则 ⌘C/⌘V 失效）
        ├── UIMetrics.swift         # ★ 间距/字号常量 + FlippedView + VerticalFormLayout（显式约束链）
        ├── FormRow.swift           # 一行表单：固定 92pt 标签 + 控件（间距 ≥12pt）
        ├── ActionEditorView.swift  # 可复用动作编辑器（kind/main/detail/script/key/flags）
        ├── SettingsWindowController.swift      # 主窗口 + 单例 + 关闭回调
        ├── SettingsSplitViewController.swift   # NSSplitViewController 两栏布局
        ├── RuleListViewController.swift        # 左栏：全局 + 应用列表 + 增/删 + NSOpenPanel
        ├── RuleDetailViewController.swift      # 右栏：应用头部 + NSTabView（触控栏 / 快捷键）
        ├── TouchBarItemsViewController.swift   # 触控栏标签页：按钮列表 + 编辑器
        ├── ShortcutsViewController.swift       # 快捷键标签页：列表 + 组合键/动作编辑器
        ├── RuleItemEditorViewController.swift  # 按钮的属性编辑（标题/颜色/动作）
        └── TableCellViews.swift    # 自定义单元格（图标+文本 / 色块+两行文本 / 快捷键冲突标红）
```

### 三阶段如何融合

```
                        ┌──────────────────────────────┐
                        │   TouchBarDefinition（数据）  │
                        │   AppAction（行为）           │
                        └──────────────────────────────┘
                                     ▲ 共用
   ┌─────────────┐            ┌──────┴───────┐             ┌──────────────┐
   │ ① 菜单栏    │            │ ② 前台呈现   │             │ ③ 后台注入   │
   │ 全局快捷键  │            │ （key window）│             │ （系统模态） │
   └──────┬──────┘            └──────┬───────┘             └──────┬───────┘
          │                          │                            │
   StatusBarController      TouchBarHostWindowController   FrontmostAppMonitor
   HotKeyCenter(Carbon)        └─ TouchBarHost                └─ TouchBarRuleEngine
          │                          │                            └─ SystemModalTouchBarPresenter
          └──────────────► AppCoordinator ◄─────────────────────────┘
                        （唯一编排者 / Composition Root）
```

三个"接缝"保证后续扩展不动主干：

1. **`AppAction`** —— 快捷键、Touch Bar 按钮、规则全部只产出它，执行逻辑集中一处。
2. **`TouchBarDefinition`** —— "长什么样"与"怎么显示"彻底解耦。
3. **`TouchBarPresenting` 协议** —— 前台窗口与后台私有注入实现同一接口，
   `AppCoordinator` 用同一行 `presenter.present(definition)` 驱动两种完全不同的机制。

---

## 三、各阶段实现要点

### 阶段一：菜单栏常驻 + 全局快捷键

**菜单栏**：`NSStatusBar.system.statusItem(withLength:)`，菜单只放"关于 / 退出"及后续阶段入口。

> ⚠️ **第四阶段的重要改动**：原来用 `LSUIElement = 1`，但它会把进程**永久钉死**为 UIElement，
> 导致打开配置主窗口时 `setActivationPolicy(.regular)` 失效（拿不到 Dock 图标和主菜单）。
> 现在改为在 `main.swift` 里第一时间 `NSApp.setActivationPolicy(.accessory)` ——
> 默认表现完全一致，但保留了动态切回 regular 的能力。

**全局快捷键**用 Carbon `RegisterEventHotKey`：

| 方案 | 需要权限 | 能否拦截事件 | 后台可用 | 结论 |
|------|---------|-------------|---------|------|
| **Carbon `RegisterEventHotKey`** | ❌ 不需要 | ❌ 系统直接路由 | ✅ | ✅ 采用 |
| `NSEvent.addGlobalMonitorForEvents` | ✅ 需要"输入监控" | ✅ | ✅ | 备选（`NSEventHotKeyMonitor.swift`） |
| `CGEventTap` | ✅ 需要 | ✅ | ✅ | 不推荐，掉 tap 后失效 |

关键坑：
- C 函数指针回调**不能捕获上下文** → 用 `InstallEventHandler(..., userData:)` 传
  `Unmanaged.passUnretained(self).toOpaque()`，回调里 `fromOpaque` 取回。
- 用 `EventHotKeyID.signature`（四字符码）区分是不是自己注册的热键。
- 注册失败 `status = -9878 (errHotKeyExists)` 说明组合键被占用 —— ⌥Space 默认可能被
  Spotlight / 输入法占用，换成 `HotKey.optionCommandSpace` 即可。
- 宿主必须在主线程 RunLoop 上（AppKit 应用天然满足）。

### 阶段二：前台 Touch Bar

- `TouchBarHost` 内部创建 `NSTouchBar`，`defaultItemIdentifiers` 由 `TouchBarDefinition` 提供，
  通过 `NSTouchBarDelegate.touchBar(_:makeItemForIdentifier:)` **惰性创建并缓存** item
  （符合 Apple 生命周期建议）。
- ⚠️ `NSTouchBar.delegate` 是 **weak**，`TouchBarHost` 必须被强引用持有，否则整条栏空白。
- ⚠️ `NSTouchBar` 挂在响应链上，只有 **key window** 会被系统询问。LSUIElement 应用默认没有窗口，
  所以必须提供一个宿主窗口（可见窗口便于调试，也可做成 1×1 透明窗口）。
- 调试：Xcode → Window → **Touch Bar Simulator**（不带 Touch Bar 的 Mac 也能验证）。

### 阶段三：后台动态注入（核心突破点）

**为什么公开 API 做不到**：`NSTouchBar` 只能挂在 `NSApplication / NSWindow / NSResponder`
响应链上，而系统只会询问**前台应用**的响应链。后台进程无法介入。

**采用的机制**（BTT / Pock / MTMR 同类）：`NSTouchBar` 上的**私有类方法**

```objc
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
         systemTrayItemIdentifier:(NSString *)identifier;   // 10.12.2+
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                         placement:(long long)placement
         systemTrayItemIdentifier:(NSString *)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
```
（10.12.1 beta 曾命名为 `...SystemModalFunctionBar:...`，本项目两个名字都探测。）

它把本进程构造的 `NSTouchBar` 交给 **Touch Bar Server（DFR 守护进程）** 以"系统模态"方式展示，
并在 Control Strip 留下一个入口项 —— 这就是后台改写的根本通道。

配合私有框架 `DFRFoundation`（运行时 `dlopen` + `dlsym`，**不链接**，避免 dyld 崩溃）：
`DFRSystemModalShowsCloseBoxWhenFrontMost(false)` 隐藏左侧关闭按钮，让注入结果更像原生 Control Strip。

**代码里的 5 道安全兜底**（缺一不可）：

1. 选择器存在性用 `class_getClassMethod` 精确探测（比 `responds(to:)` 可靠），命中才调用；
2. 探测表覆盖 2 个版本命名 × 有无 `placement` 共 4 种签名；
3. `arm64` 上 `objc_msgSend` 必须 `unsafeBitCast` 成**精确函数类型**再调用（否则寄存器错乱崩溃）；
4. `systemTrayItemIdentifier` **固定不变**，否则每次切换应用都在 Control Strip 堆积一个新入口；
5. API 不可用 → `isAvailable == false` → 降级为"仅监听+日志"，绝不崩溃。

**辅助功能权限**：`AXIsProcessTrusted()` 无回调机制 → `AccessibilityPermission.Monitor` 用
Timer 轮询 + 变化回调刷新菜单状态；未授权时 `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)`
弹系统授权窗，菜单项也可一键跳到系统设置页。AX 在这里的用途：读取前台**窗口标题**
（`AXWindowInspector`）、投递模拟按键（`CGEvent`，实际是"输入监控"权限）。

**已知限制**
- 仅带 Touch Bar 的 Mac（或 Xcode 模拟器）有效；
- 私有 API 随系统版本变化，**不能上架 Mac App Store**；
- 某些全屏 / 独占 Touch Bar 的应用（如部分游戏、Keynote 演示）下可能被系统覆盖；
- macOS 13+ 的 Control Strip 行为有变化，`addSystemTrayItem:` 实验开关默认关闭。

---

## 四、第四阶段：GUI 配置主窗口

### 1. 界面结构（纯代码 `NSSplitViewController`）

```
┌────────────────────────────────────────────────────────────────────┐
│ btTool 配置                                            ─  □  ✕     │
├───────────────────────┬────────────────────────────────────────────┤
│ 应用          [+] [-] │  🧭 Safari浏览器                            │
│ ────────────────────  │  com.apple.Safari                           │
│ 🧭 Safari浏览器       │  Touch Bar 按钮                  [+] [-]    │
│ 🟧 Firefox            │  ┌────────────────────────────────────────┐ │
│ 🐋 Visual Studio Code │  │ ● 哈哈测试                             │ │
│ 📁 Finder             │  │ ● 前进 →      按键：]  ⌘              │ │
│ 📝 TextEdit           │  │ ● 新标签页    按键：T  ⌘              │ │
│                       │  └────────────────────────────────────────┘ │
│                       │  ┌─ 编辑选中按钮 ─────────────────────────┐ │
│                       │  │ 显示文本 [哈哈测试        ]            │ │
│                       │  │ 背景颜色 [■] [清除颜色]                │ │
│                       │  │ 触发动作 [模拟按键      ▾]             │ │
│                       │  │ 按键     [ ]           ▾]              │ │
│                       │  │ 修饰键   ⌥ ⌃ ⇧ ⌘                      │ │
│                       │  └────────────────────────────────────────┘ │
└───────────────────────┴────────────────────────────────────────────┘
```

### 2. 数据流（单向闭环）

```
 GUI 操作
   │  RuleStore.addRule / addItem / updateItem / removeItem
   ▼
 RuleStore ──写 JSON──> ~/Library/Application Support/btTool/rules.json
   │  post(RuleStore.didChangeNotification)
   ├─> RuleListViewController / RuleDetailViewController 刷新表格
   └─> AppCoordinator.observeRuleStore()
          ├─ ruleEngine.reload()                 （内存里的规则立即更新）
          └─ refreshInjection(for:)               （当前前台 App 的 Touch Bar 立即重建）
                 └─> SystemModalTouchBarPresenter.present(definition)
```

关键：**磁盘 JSON 是唯一权威数据**。首次启动把 `TouchBarRule.defaults` 写入 JSON，
之后连触发布尔/tmp都不碰硬编码（除用于兜底的 generic），所以下次启动自动加载用户配置。

### 3. 三个技术要点

**① 激活策略动态切换**（`ActivationPolicyController`）
- `showWindow` → `.regular`（Dock 图标 + 主菜单）；`windowWillClose` → `.accessory`（回到菜单栏常驻）
- ⚠️ **不能同时在 Info.plist 里写 `LSUIElement=YES`**，否则进程会被永久标记为 UIElement，
  `setActivationPolicy(.regular)` 直接失效。改为在 `main.swift` 里调用 `.accessory`，效果相同但可切回
- 兜底：若 `setActivationPolicy` 返回 false，改用 `TransformProcessType` 做进程类型转换

**② 为什么要程序化主菜单**（`MainMenuBuilder`）
accessory 应用没有主菜单。切成 `.regular` 后如果不补菜单，会出现
「⌘W 关不掉窗口、文本框里 ⌘C/⌘V 全失效」。所以按标准 `App / Edit / Window` 结构手工搭一个，
所有 action 指向 nil target，走 responder chain，无需自己写逻辑。

**③ 动作的可序列化契约**（`ActionDTO`）
`AppAction` 里的 `CGEventFlags` 不是 Codable，所以磁盘层用 `ActionDTO`（`kind + text + detail + keyCode + modifierRawValue`），
运行时再 `.action` 转成 `AppAction`。这样将来给 `AppAction` 加 shell/AppleScript/HTTP 分支也不会破坏存档格式
（配合 `version` 字段做迁移）。

### 4. 接线（怎么触发响应）

```swift
// ① 菜单栏菜单项 —— Sources/Stage1/StatusBar/StatusBarController.swift
menu.addItem(withTitle: "打开配置主窗口…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
@objc private func showSettingsWindow(_ sender: Any) { hooks.onShowSettingsWindow?() }

// ② AppCoordinator 里注入 hook —— Sources/Application/AppCoordinator.swift
statusBarController.hooks.onShowSettingsWindow = { [weak self] in
    self?.showSettingsWindow()
}
statusBarController.hooks.onShowTouchBarHost   = { [weak self] in self?.showTouchBarHostWindow() }

func showSettingsWindow() {
    let controller = SettingsWindowController.shared      // 单例，避免开多个窗口
    controller.onDidClose = { [weak self] in
        self?.handleSettingsWindowDidClose()              // 切回 accessory + 延迟 0.6s 恢复后台注入
    }
    controller.showWindow(self)
}
```
另外 AppDelegate 里加了脚本入口：`btTool --settings` 启动时直接打开配置窗口。

---

## 五、测试指南（已在 MacBookPro16,1 / macOS 12.7 实测通过）

### 0. 先确认硬件

```bash
system_profiler SPHardwareDataType | grep "Model Identifier"   # MacBookPro16,1 = 带 Touch Bar
ioreg -l | grep -ci appleDFR          # >0 表示系统识别到 Touch Bar（DFR）硬件
```
没有 Touch Bar 的机器：第 ③ 阶段只能看日志，看不到视觉效果。

### 1. 跑起来 + 看日志

```bash
make run                 # 或 make build && open build/btTool.app
tail -f /tmp/btTool.log  # 实时日志（每次启动会清空重写）
```
> 为什么不用 `log show`：os_log 的 info/debug 级别**默认不落盘**，事后抓不到。
> 因此 `Log` 额外镜像了一份到 `/tmp/btTool.log`；终端直接跑二进制时还会回显到 stderr。
> 想用系统日志也行：`log stream --level debug --predicate 'subsystem == "com.bttool.app"'`

### 2. 逐项验收（附预期日志）

| # | 操作 | 预期现象 / 日志 |
|---|------|----------------|
| ① | 启动 | Dock **无**图标；菜单栏右侧出现图标；日志出现 `菜单栏图标已安装` |
| ① | 点菜单栏 →「关于 / 退出」 | 弹出关于面板 / 应用退出 |
| ① | 在任意 App 里按 **⌥Space** | `🔥 全局快捷键被触发` + `已启动：计算器`，计算器被唤起 |
| ② | 菜单 →「显示 Touch Bar 宿主窗口」 | 看 Touch Bar：出现**测试A / 测试B**；点击 A→日志，点击 B→日志+通知 |
| ③ | 切到 **Safari** | `前台应用切换 → Safari浏览器` + `已向系统注入 Touch Bar：…safari（后退/前进/新标签页）` |
| ③ | 再切到 **Chrome / VS Code** | 日志里注入的定义随之切换（chrome / vscode） |
| ③ | 切到未配置的应用 | 注入 `…generic（测试A/测试B）`（因为 `injectForAllApps` 默认开） |
| ③ | 菜单 →「后台注入 Touch Bar」 | 开关切换（勾选/取消），关闭后日志出现 `已销毁注入的 Touch Bar` |
| ③ | 权限项 | 已授权显示 ✅；未授权显示 ⚠️，点击跳到系统设置 |
| ④ | 菜单 →「打开配置主窗口…」（⌘,） | Dock 出现图标 + 出现主菜单；日志 `激活策略 → .regular` |
| ④ | 左栏点 "+" 选一个 App | 新应用出现在列表；`rules.json` 里多一条（内含该 App 的 Bundle ID） |
| ④ | 右栏点 "+" 添加按钮 → 改标题/颜色/动作 | 无需切应用，日志立刻出现重新注入（内含新标题）；JSON 同步更新 |
| ④ | 选左栏 "−" 删除应用 | 列表与 JSON 同步移除 |
| ④ | 关闭窗口 | 日志 `激活策略 → .accessory`，Dock 图标消失；约 0.6s 后恢复后台注入 |
| ④ | 重启 App | 日志 `已从磁盘加载规则：…/rules.json（N 条）`，之前的修改全在 |

配置窗口也可以用脚本入口打开（便于远程/自动化测试）：

```bash
./build/btTool.app/Contents/MacOS/btTool --settings
cat ~/Library/Application\ Support/btTool/rules.json   # 直接查看/手工编辑
```

### 3. 不想手动按键？用脚本触发热键

```bash
osascript -e 'tell application "System Events" to key code 49 using {option down}'   # ⌥Space
osascript -e 'tell application "Safari" to activate'                                  # 模拟切换前台应用
```
（需要给「终端 / 你用的终端 App」授予辅助功能权限，否则 System Events 发不出按键。）

### 4. 开关后台行为（UserDefaults）

```bash
defaults write com.bttool.app btTool.injectForAllApps -bool false   # 只给规则里的 App 注入
defaults write com.bttool.app btTool.backgroundTouchBarEnabled -bool false  # 完全关闭注入
defaults write com.bttool.app btTool.experimentalControlStripItem -bool true # 打开实验开关
# 改完重启 App 生效
```

### 5. 实测记录（示例输出）

```
[INFO ][general] btTool 启动（pid=29899）
[INFO ][general] 辅助功能权限：已授权
[INFO ][general] 菜单栏图标已安装
[INFO ][hotkey] 已注册全局热键 ⌥Space（id=1）
[INFO ][workspace] 开始监听前台应用变化
[INFO ][touchbar] 已加载 DFRFoundation：/System/Library/PrivateFrameworks/DFRFoundation.framework/…
[INFO ][touchbar] 已向系统注入 Touch Bar：btTool.touchBar.generic（items: ["测试A", "测试B"]）
[INFO ][workspace] 前台应用切换 → Safari浏览器（com.apple.Safari）
[INFO ][touchbar] 已销毁注入的 Touch Bar
[INFO ][touchbar] 已向系统注入 Touch Bar：btTool.touchBar.safari（items: ["← 后退", "前进 →", "新标签页"]）
[INFO ][hotkey] 🔥 全局快捷键被触发（无论当前前台是哪个应用）
[INFO ][general] [Action] 全局快捷键触发：前台应用 = Safari浏览器
[INFO ][general] 已启动：计算器
```

### 6. 排错

| 现象 | 原因 / 处理 |
|------|------------|
| 一条日志都没有，但进程在跑 | 用了 `@main` 且 Info.plist 里有 `NSMainNibFile` → 改成显式 `main.swift`、删掉该键 |
| `注册全局热键失败，status=-9878` | ⌥Space 被 Spotlight/输入法占用 → 换 `HotKey.optionCommandSpace` |
| 注入成功但整条栏是空的 | `TouchBarHost` 被释放（`NSTouchBar.delegate` 是 weak）→ 保持强引用 |
| Control Strip 越来越长 | `systemTrayItemIdentifier` 必须是固定字符串，不要每次随机 |
| 看不到"测试A/测试B" | 确认有 key window（第二阶段需先打开宿主窗口）；第三阶段看是否命中规则 |
| 辅助功能一直不弹窗 | `sudo tccutil reset Accessibility com.bttool.app` 后重启 App |
| 模拟按键没反应 | 需要「输入监控」权限，`SyntheticEvent.post` 会直接拒绝并打日志 |

---

## 六、第五阶段：健壮性加固与功能补全（实测记录 14:07–14:09）

### 1. 通知权限：`Notifier` 三段式 + 降级（根治 *Notifications are not allowed…*）

```swift
Notifier.post(title:body:)
  ├─① getNotificationSettings()            // 不弹窗，只查询当前状态
  │    .authorized / .provisional / .ephemeral → deliver()
  │    .notDetermined → DispatchQueue.main.async { requestAuthorization([.alert,.sound,.badge]) }
  │    .denied        → fallback()
  ├─② requestAuthorization 返回 error / granted=false → fallback()
  └─③ fallback()：Log.error(原因) + Log.info("[通知降级] 标题：… ｜ 正文：…")
```

同时注入 `UNUserNotificationCenterDelegate`（`willPresent` 返回 `.banner/.list/.sound`），
否则应用处于前台时通知会被系统静默丢弃。

**实测**（本机 com.bttool.app 已被系统登记为 `.denied`，正是你遇到的场景）：

```
[ERROR][general] ⚠️ 通知未能展示：用户此前已拒绝通知权限（可在 系统设置 → 通知 中重新开启）
[INFO ][general] [通知降级] 标题：btTool 自检 ｜ 正文：这条用于验证 Notifier 降级链路
```
→ 再也不是裸错误，**内容一条不丢**。

**`Resources/Info.plist` 需要补的键**（已写入）：

| 键 | 值 | 说明 |
|---|---|---|
| `NSUserNotificationAlertStyle` | `alert` | Legacy `NSUserNotification` 的样式键；对 `UNUserNotificationCenter` 不起决定作用，但保留它是必要线索且无副作用 |
| `CFBundleIdentifier` | `com.bttool.app` | **决定性的键之一**：通知以 Bundle ID 为 key，缺失或写成 `$(PRODUCT_BUNDLE_IDENTIFIER)` 字面量必被拒（Makefile 会做变量替换） |
| `LSMultipleInstancesProhibited` | `true` | 顺带加的：禁止多实例，避免重复注册全局热键 / 重复添加菜单栏图标 |

⚠️ **必须说清楚的三件事**（这几个键是**必要不充分**条件）：

1. **一定要用 LaunchServices 启动**：`open build/btTool.app` 或拷到 `/Applications` 双击。
   直接跑 `./btTool.app/Contents/MacOS/btTool` 时系统拿不到正确的 app audit token，
   通知中心**必然**返回 not-allowed —— 这是自签名工具最常见的翻车点。
2. **ad-hoc 签名（`codesign -s -`）在部分系统版本会被通知中心拒绝**。
   用免费的 Apple Developer 账号签真证书即可解决：
   `codesign -f -s "Apple Development: you@x.com (TEAMID)" build/btTool.app`
3. **权限一旦被 `.denied`，系统不会再弹二次授权框**，只能去
   `系统设置 → 通知 → btTool` 手动打开，或删掉应用目录让系统重新登记。
   因此「降级到日志」是唯一可靠的兜底，也正是本方案的核心。

### 2. 动作模型补全：`shell` / `appleScript`

```swift
indirect enum AppAction {
    case shell(String)        // 走 /bin/zsh -lc：支持管道、PATH、~/
    case appleScript(String)  // NSAppleScript，串行队列异步执行
    ...
}
```
`ActionDTO` 同步新增 `.shell` / `.appleScript` 两个 Kind → `rules.json` 里就是
`{"kind":"shell","text":"pmset displaysleepnow"}`，GUI 下拉框里对应「执行 Shell / 执行 AppleScript」。

**ShellRunner 的两个坑（已处理）**
- ❌ 直接 `readDataToEndOfFile()` 双管道：输出 > 管道缓冲（~64KB）会**死锁**。
  ✅ 改用 `readabilityHandler` 边产出边读 + `DispatchGroup` 等待 EOF，再加 **30s 超时**保护。
- 任何启动异常都会被 catch 并 `Log.error`；非 0 退出码会连同 stderr 一起落盘。

**AppleScriptRunner 的坑（实测抓到）**
- ❌ 原先用了 `attributes: .concurrent` 的队列：`NSAppleScript` **不是线程安全的**，
  多个脚本并发编译会互相串扰 —— 同一段非法脚本一次报 `-2740`、一次报空白的 `{没有错误}`，
  连合法脚本都可能莫名报 `-1751`。✅ 改为**串行队列**后结果完全稳定：

```
[INFO ][general] [AppleScript] 执行成功：brace                      ← do shell script "whoami"
[INFO ][general] [AppleScript] 执行成功：<NSAppleEventDescriptor: 'ldt '…>  ← return current date
[ERROR][general] [AppleScript] 编译失败（错误码 -2740）："属性"不能跟在"标识符"之后 ｜ NSRange={12,17}
```
- 编译期 / 运行期错误分离诊断；标准错误键缺失时回退打印整个错误字典，绝不出现"未知错误"哑日志。

### 3. 后台注入：签名校验（**本次最关键的修复**）

原先 `invokePresent` 里两套 `unsafeBitCast` 签名是**凭经验猜**的。本次加了
`method_getTypeEncoding` 事前校验 —— 结果**当场发现猜错了**：

```
[DEBUG][touchbar] 跳过 presentSystemModalTouchBar:systemTrayItemIdentifier:：签名编码不符（实际 v32@0:8@16@24)
[DEBUG][touchbar] 跳过 presentSystemModalTouchBar:placement:systemTrayItemIdentifier:：签名编码不符（实际 v40@0:8@16q24@32)
[ERROR][touchbar] ⚠️ 当前系统不支持后台 Touch Bar 注入   ← 注入直接失效
```

用探针程序实测后确认（去掉 offset 数字后）：

| 场景 | Type Encoding | 你要在 Swift 里写的 typealias |
|---|---|---|
| 无 placement | `v@:@@` | `(AnyClass, Selector, NSTouchBar, NSString) -> Void` |
| 带 placement | `v@:@q@` | `(AnyClass, Selector, NSTouchBar, **Int**, NSString) -> Void` |

> `Int`（而非 `Int64`）才能与 `NSInteger` 严格对齐；`q`/`Q`（有符号/无符号）都接受。
> 修正后实测恢复：`已向系统注入 Touch Bar：btTool.touchBar.generic（items: ["测试A","测试B"]）`

Swift **无法 try/catch Objective-C 异常**，所以 arm64 下签名写错必崩且无栈；
「调用前校验签名」是唯一可靠的事前防御（`present` 前后各校验一次，防运行时被 swizzle）。
`dismiss()` 用 `defer { self.host = nil }` —— 无论私有选择器存在与否都释放强引用，杜绝泄漏 + 叠加；
类析构时 `deinit { dismiss() }` 兜底。

### 4. GUI 联动润色

| 改动 | 说明 |
|---|---|
| 标题/颜色即时生效 | `commit()` 后回调 `onDidEdit(itemID)` → `tableView.reloadData(forRowIndexes:)` **只重绘那一行**，色块和名字立刻变，无需重新选中 |
| 0.25s 防抖 | 打字走 `scheduleCommit()`（离散控件如颜色/下拉框走 `commitNow()` 立即提交），避免每敲一个字符就重写 JSON 并重建一次 Touch Bar |
| 颜色脏标记 | `ColorState`：必须通过 `colorDidChange` 才算用户选择；否则「只是改个标题」会把回显的强调色误写成按钮颜色 |
| 焦点保护 | `isEditing(_:)` 判断 firstResponder（含 field editor），表格刷新时不会覆盖用户正在输入的控件 |
| 多行脚本区 | Shell / AppleScript 自动切换到 `NSTextView` 编辑区（单行 NSTextField 太挤） |
| 添加应用防重 | 重复 → `NSAlert` 提示 + 自动选中并滚动到已存在的那条；非 `.app` 包 / 读不到 Bundle ID → 各自给出针对性提示文案 |

---

## 七、第六阶段：菜单净化、布局重建与键盘快捷键

### 1. 菜单栏只留一条"有用"的主线

研发期的探针（显示宿主窗口 / 置灰的热键提示 / 当前前台应用）全部下线：

```
关于 btTool
─────────────────────────
打开配置主窗口…            ⌘,
后台注入 Touch Bar         ✓ / —
辅助功能权限：已授权 ✅ / 未授权 ⚠️（点击前往系统设置）
─────────────────────────
退出 btTool                ⌘Q
```

- 辅助功能那一项的标题是**动态**的：`updateAccessibility(granted:)` 由 Coordinator 推送，
  不再出现「检测中…」这种中间态（见下一条）。
- 「显示 Touch Bar 宿主窗口」仅保留在 `applicationShouldHandleReopen` 里作为兜底，
  菜单上不再暴露调试入口。

### 2. 辅助功能检测卡死：两个根因，缺一不可

```swift
// ① 必须由 self 强引用持有 —— 这是本次的"真凶"
permissionMonitor = AccessibilityPermission.startMonitoring { [weak self] granted in … }
// 若写成 _ = startMonitoring { … } 或局部变量：Monitor 立刻释放，
// Timer 的 block 里 self 为 nil → 永不轮询 → 菜单永远停在「检测中…」。

// ② Timer 必须进 .common 模式 —— 菜单展开时主 RunLoop 处于 .eventTracking
let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
RunLoop.main.add(timer, forMode: .common)   // scheduledTimer 只注册 .default，菜单一开就停摆
poll(forceReport: true)                      // ③ 首帧同步，已授权时也要上报一次
```

第三条同样关键：`poll()` 平时「只上报变化」，而 `lastKnownValue` 在 init 时就等于当前值，
启动即已授权的机器永远等不到"变化"。`forceReport` 让 `start()` 立刻推一次。

### 3. 配置窗口布局：从 NSStackView 到显式约束链

**症状**：底部编辑区的输入框、下拉框、标签互相重叠，控件宽度塌成 237pt。

**四个叠加的根因**（逐个排除才定位到）：

| # | 根因 | 处理 |
|---|---|---|
| 1 | `NSStackView(alignment: .width)` 在「嵌套 + 滚动容器」里不保证等宽 | 换成 `VerticalFormLayout`：手写等式约束链 |
| 2 | `scrollView.documentView = view` 会把 `translatesAutoresizingMaskIntoConstraints` **打回 true** | 赋值后再显式关闭 |
| 3 | 非 flipped 的文档视图被钉在裁剪区**左下角**，内容自下而上堆 | 统一用 `FlippedView`（`isFlipped = true`） |
| 4 | `TouchBarItemsViewController.showScope` 末尾多调了一次 `edit(scope:itemID:nil)`，把刚建好的约束链清空 | 删除该调用 |

```swift
// VerticalFormLayout：不依赖 NSStackView，隐藏行自动跳过
leading == container.leading
trailing == container.trailing
child.top == previous.bottom + spacing      // 首行 == container.top
container.bottom == last.bottom             // 空集时 height == 0
```

`makeFormBox(title:contentView:height:)` 也去掉了内部的 `NSScrollView`：
分组框给**固定高度** + 内容顶对齐（`bottom >= contentView.bottom`），高度由内部行数算出来，
彻底避免"滚动容器 + 栈视图"的双重不确定性。

`FormRow` 的标签固定 92pt，并**删除** `setContentHuggingPriority(.required)` /
`setContentCompressionResistancePriority(.required)` —— 它们会和固定宽度等式打架，把标签挤出去 2pt。

**实测**（`--settings` 打开后遍历视图树，两个标签页各测一次）：

```
FormRow frame=(297.0, 268.0, 667.0, 30.0)
FormRow frame=(297.0, 226.0, 667.0, 30.0)
ActionEditorView frame=(297.0, 142.0, 667.0, 72.0)
=== 冲突 === 0
```

所有行 `width` 一致、左边缘对齐 `x=297`、行距 12pt、Auto Layout 冲突 0 条。
窗口尺寸也不再被 `contentViewController` 的 fitting size 压缩（赋值后再 `setContentSize(1000×700)`）。

### 4. 键盘快捷键：全局常驻 / 应用随前台切换

数据模型（`rules.json` v2，v1 存档可无损读取）：

```json
{
  "globalShortcuts": [
    { "id": "g1", "keyCode": 37, "modifierRawValue": 786432,
      "action": { "kind": "log", "text": "全局快捷键生效" } }
  ],
  "rules": [
    { "bundleIdentifiers": ["com.apple.Safari"],
      "shortcuts": [ { "id": "s1", "keyCode": 17, "modifierRawValue": 786432, "action": { … } } ] }
  ]
}
```

- `modifierRawValue` 直接复用 `CGEventFlags.rawValue`，与 `ActionDTO.syntheticKey` 同一套位定义；
- 右栏用 `NSTabView`（`.topTabsBezelBorder`）分成「触控栏 (Touch Bar)」与「键盘快捷键 (Shortcuts)」，
  作用域来自左栏选中的应用；左栏第一行固定为「全局（所有应用）」；
- 注册语义（`AppCoordinator.bindShortcuts`）：
  - 「全局」**常驻**；应用级只在该应用前台时注册，切走立即注销；
  - 组合重复 → 先到先得（全局优先），后来者在列表里**标红**并打日志；
  - **无修饰键一律拒绝**（会吞掉整块键盘）；
  - 用「作用域 + id + keyCode + 修饰键」算指纹，内容没变就不做「全注销 + 全注册」；
- 启动期兜底：`syncForCurrentFrontmostApp()` 绕过 `FrontmostAppMonitor` 的去重，
  避免"权限回调先 `refreshNow()`、`onChange` 还没接上"导致首帧一条都没绑。

**实测**：`⌃⌥L` 全局常驻 → 切 Safari 注册 `⌃⌥T`（与其重复的 `⌃⌥L` 被忽略并报错）→ 切回 Finder 自动注销 Safari 那条。

> 本轮同时删除了 `--selfcheck` / `--uidump` 两个调试入口及其方法，
> `make typecheck`（39 个文件）与 `make build` 均通过。

---

## 八、后续演进建议

- ~~`TouchBarCatalog` / `TouchBarRule` 改为读取 JSON~~（第四阶段已完成：`RuleStore` + `rules.json`）；
- ~~`AppAction` 扩展出 `shell` / `appleScript`~~（第五阶段已完成，剩 `http` 分支）；
- ~~键盘快捷键（全局 / 应用级动态注册）~~（第六阶段已完成）；下一步可做「按键录制器」（直接按下组合键采集，替代下拉框）与冲突矩阵视图；
- Touch Bar item 类型从 `NSButton` 扩展到 `NSScrubber`、`NSSlider`、`NSPopoverTouchBarItem`；
- 第三阶段加"按窗口标题 / 时间段 / 外接显示器"的多维匹配（扩展 `TouchBarRuleEngine` 入参即可）；
- 若要上架，第三阶段必须换成官方支持路径（例如只在自家窗口内展示，或用 Shortcuts / 脚本扩展）。
