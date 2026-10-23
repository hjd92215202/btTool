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
tail -f ~/Library/Logs/btTool/btTool.log
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
        ├── EntitlementCheck.swift               # 进程签名/特权自省（托盘为何被静默丢弃）
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
        ├── ShortcutRecorderField.swift         # ★ 按键实时录制框（按什么显示什么）
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
Timer 轮询 + 变化回调刷新菜单状态（**全程只用 `AXIsProcessTrusted()`，绝不弹窗**）；
弹窗只在用户点击菜单栏「辅助功能权限：未授权 ⚠️」时才由 `checkOrPrompt(reason:)` 触发一次。AX 在这里的用途：读取前台**窗口标题**
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
tail -f ~/Library/Logs/btTool/btTool.log  # 实时日志（每次启动会清空重写）
```
> 为什么不用 `log show`：os_log 的 info/debug 级别**默认不落盘**，事后抓不到。
> 因此 `Log` 额外镜像了一份到 `~/Library/Logs/btTool/btTool.log`（目录 0700、文件 **0600**）。
> ⚠️ 旧版本放在 `/tmp/btTool.log`，那是全系统可读的共享目录，而日志里可能含
> 窗口标题 / Shell 命令 / AppleScript 源码 —— 属于隐私问题，已迁走。
> 这类敏感内容统一走 `Log.sensitive(_:_:)`：文件里只写「类型 + 长度」摘要，
> 正文进 os_log 的 debug 级（默认不落盘）；要看正文就带 `BTTOOL_LOG_VERBOSE=1` 启动。
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

## 八、第七→第九阶段：Control Strip 托盘常驻 + 点按开合（替代 0.6s 强燃）

### 1. 为什么废掉 0.6s 轮询

上一版在 `AppCoordinator` 里挂了一个 `.common` 模式的 0.6s 定时器：
只要 `NSTouchBar.isVisible == false` 就强制重注入，还配了指数退避。

问题不在实现，而在**方向**：

- 用户点叉是明确的「我现在不想看」意图，0.6s 后又弹回来是暴力骚扰；
- 每次重注入都会 `dismiss + present`，Touch Bar 会肉眼可见地闪一下；
- 用户铁了心要关时，退避会把间隔推到 5s —— 既没有“常驻”体感，又持续消耗 CPU。

BTT 的做法恰恰相反：**右侧托盘图标常驻，左侧长栏完全由用户点按控制。**
定时器、退避、`flappingCount`、`lastPresentedAt` 全部删除。

### 2. 两个私有 API，分工完全不同

| API | 位置 | 特性 |
|---|---|---|
| `NSTouchBarItem +addSystemTrayItem:` | **右侧 Control Strip** | 系统常驻管理，点叉也收不走 |
| `NSTouchBar +presentSystemModalTouchBar:…` | **左侧整条长栏** | 系统模态，点叉可收走 |

运行时探测（本机实测签名）：

```
addSystemTrayItem:                          enc=v24@0:8@16
removeSystemTrayItem:                       enc=v24@0:8@16
presentSystemModalTouchBar:placement:…      enc=v40@0:8@16q24@32
presentSystemModalTouchBar:…                enc=v32@0:8@16@24
```

两者使用**同一个 identifier**：`btTool.controlStrip.trayItem`。
系统据此把“右侧图标”与“左侧面板”识别为同一个 App 的入口与内容。

```swift
// 只注册一次；identifier 固定 → 反复启动不会在 Control Strip 堆积
let item = NSCustomTouchBarItem(identifier: .init("btTool.controlStrip.trayItem"))
let button = NSButton(frame: NSRect(x: 0, y: 0, width: 44, height: 30))
button.bezelStyle = .rounded
button.target = self
button.action = #selector(trayItemClicked(_:))
item.view = button
ObjCRuntime.sendVoid(NSTouchBarItem.self, addSystemTrayItemSelector, item)
```

`trayItem` 必须被**强引用**：`addSystemTrayItem:` 不会 retain 外部对象，
一旦释放，右侧图标会静默消失，还在系统里留下一个僵尸标识。

### 3. 点按开合状态机

```swift
private func toggleTouchBarExpansion() {
    guard AppSettings.shared.backgroundTouchBarEnabled else { return }
    guard NSApp.activationPolicy() != .regular else { return }   // 配置窗口前台不抢
    if isTouchBarExpanded || backgroundPresenter.isPresenting {
        collapseTouchBar(reason: "点按托盘图标")     // dismissSystemModalTouchBar:
    } else {
        expandTouchBar(reason: "点按托盘图标")       // presentSystemModalTouchBar:…
    }
}
```

- `isTouchBarExpanded` 是**用户意图**，`isPresenting` 是**硬件事实**（`NSTouchBar.isVisible`）。
  点叉后硬件事实变 false、意图仍是 true，所以两者取 `||` —— 再点一次一定是“重新展开”；
- 系统收回时 KVO 立刻把意图翻回 false（只同步状态，**绝不**自动 present）；
- 前台切到自己 / 打开配置窗口 → 收起；关窗后按 `wasExpandedBeforeSettings` 恢复。

### 4. 前台应用联动：只有展开时才重建

```swift
guard isTouchBarExpanded else {
    // 未展开：托盘常驻、长栏收起，只更新内存里的数据源
    return
}
// 展开态：按新前台应用的规则重建，identifier 相同则跳过（不闪）
backgroundPresenter.present(definition)
```

托盘图标不属于这条 `NSTouchBar`，所以重建长栏时它不会闪、不会掉线。

### 5. 按钮宽度

`TouchBarHost` 里给每个按钮加了硬下限：

```swift
button.translatesAutoresizingMaskIntoConstraints = false
button.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
```

低于 130pt 时 `.rounded` 按钮会被压成“胶囊”、标题截成省略号；132pt 刚好容纳 4 个中文字符，
多个按钮自左向右平铺时也不会挤在一起。

### 6. 实测（`--probe-tray`，用代码模拟托盘点击）

```
已在 Control Strip 注册常驻托盘项：btTool.controlStrip.trayItem
[TRAY] 初始 installed=true expanded=false presenting=false   ← 启动只挂托盘，不注入
展开长栏（点按托盘图标）：访达 → btTool.touchBar.finder-probe
[TRAY] 第一次点击后 expanded=true presenting=true
已销毁注入的 Touch Bar
收回长栏（点按托盘图标）
[TRAY] 第二次点击后 expanded=false presenting=false tray=true   ← 收回后托盘仍在
展开长栏（点按托盘图标）：访达 → btTool.touchBar.finder-probe
前台应用切换 → Typora（abnerworks.Typora）
前台切换 → 长栏无缝重建：Typora
[TRAY] 切换后 expanded=true presenting=true definition=btTool.touchBar.abnerworks-Typora tray=true
```

### 7. Control Strip 托盘图标：P0 已结案（真机实测定位到 **item 构造**）

#### 🟢 结论（真机实测）

托盘不显示的真实原因是**托盘 item 的构造方式**，与签名、特权、呈现模式、缓存全都无关：

|  | 旧实现（不可见） | 现实现（可见） |
| --- | --- | --- |
| 按钮 | `NSButton(frame: 44×30)` + `bezelStyle = .rounded` + `.momentaryPushIn` | `NSButton(image:target:action:)` 便捷构造，**不指定 frame、不覆盖 bezelStyle** |
| 图标 | `NSApp.applicationIconImage` = 系统**占位**图标（本项目无 .icns），且是**彩色位图** | **模板图**：`isTemplate = true`，只有形状 + alpha，颜色由系统统一给 |

现实现与 MTMR（`Toxblh/MTMR` `TouchBarController.swift:288-299`）逐行一致。

#### 🟢 对照实验证据：三种签名配置**全部可见**

同一份代码，只改签名配置，真机上字母图标 A / B / C **都看得见**：

| 产物 | Hardened Runtime | entitlements | LSUIElement | 结果 |
| --- | --- | --- | --- | --- |
| A | 关 | 无 | 0 | ✅ 可见 |
| B | 关 | 无 | 1 | ✅ 可见 |
| **C（默认构建）** | **开** | **有** | 0 | ✅ 可见 |

⇒ **Hardened Runtime、entitlements、`com.apple.private.controlstrip` 三条旧结论全部被证伪**。
以下说法已作废（保留记录以示纠错，勿再引用）：

> ~~"托盘不显示是因为缺 `com.apple.private.controlstrip`，ad-hoc 无解，属预期行为，不是 bug。"~~
> ~~"开 Hardened Runtime / 嵌入 entitlements 会影响托盘显示。"~~
> ~~"托盘依赖 `LSUIElement = 1` 或呈现模式 / TouchBarServer 缓存。"~~

#### ⚪️ 实测现象：多个第三方托盘项**互相挤占**（规律未确定，谨慎引用）

- 观察 1：C 已注册时，后开的 P（不同 identifier）与 A（同 identifier）**都未出现**；
  点击 C 展开左侧长栏后，右侧才出现 P 的托盘。
- 观察 2：更早一次观察中，btTool 注册后，先注册的 ☆ 探针图标消失。
- 🟡 两例指向的规律**相反**（先注册者保留 vs 后注册者顶替），所以
  "同一时刻是否只保留一个第三方项、保留哪个"目前**未验证**。
  已知影响：与 MTMR/Pock 同时使用时可能只显示其中一个。

#### 🔬 可观察量与它们的局限（全部实测过）

- `com.apple.controlstrip → MiniCustomized`：注册后**无变化** ⇒ 弱判据，不变 ≠ 不被接受。
- `DFRElementGetControlStripPresenceForIdentifier`：**存在但签名未知**。
  按 `-> Bool`、`-> Int32`、出参版三种形状试过，出参恒为 false、返回值高位是脏数据 ⇒ **暂不可用**；
  需反汇编确认：`image lookup -n DFRElementGetControlStripPresenceForIdentifier`。
- `log stream --predicate 'process == "TouchBarServer"'`：注册期间**只有 1 行、无 tray 相关内容**
  ⇒ 服务端不吐日志，此路不通。

### 8. 必达入口：菜单栏调试项

托盘不可用时，`present` 那条链路（436 行 AppKit 私有 API）**本身完全不受签名限制**，
所以给它补了一个一定能到达的入口，位置在「后台注入 Touch Bar」正下方：

```
关于 btTool
──────────
打开配置主窗口…                        ⌘,
后台注入 Touch Bar                     ✓/—
【调试】强行展开 / 收回左侧 Touch Bar    ← 按当前状态自动切换标题
辅助功能权限：已授权 ✅ / 未授权 ⚠️
──────────
退出 btTool                            ⌘Q
```

实现走的是原有 `Hooks` 接线（不走单例、不破坏单向数据流），并在每次 **开菜单**时刷新标题：

```swift
statusBarController.hooks.onToggleTouchBarExpansion = { [weak self] in
    self?.toggleTouchBarExpansion()          // 与托盘点击完全同一个状态机
}
statusBarController.hooks.onQueryTouchBarExpanded = { [weak self] in
    self?.isTouchBarCurrentlyExpanded ?? false   // 用户意图 OR 硬件事实
}
```

**实测（`NSMenu.performActionForItem(at:)`，等价于真实点击）**：

```
[DBG] 初始 expanded=false  菜单标题=【调试】强行展开左侧 Touch Bar
展开长栏（点按托盘图标）：loginwindow → btTool.touchBar.generic
已向系统注入 Touch Bar：btTool.touchBar.generic（items: ["计算器"]）
[DBG] 点击1后 expanded=true presenting=true 菜单标题=【调试】收回左侧 Touch Bar
已销毁注入的 Touch Bar / 收回长栏（点按托盘图标）
[DBG] 点击2后 expanded=false presenting=false 菜单标题=【调试】强行展开左侧 Touch Bar
```

### 9. 顺带修正：那个「×」的参数极性

`DFRFoundationBridge` 以前的写法是 `setSystemModalCloseBoxHidden(true)`，
但函数真名叫 `DFRSystemModalShowsCloseBoxWhenFrontMost` —— 按字面语义
**参数是「是否显示」而不是「是否隐藏」**，老代码很可能一直在反向操作。
现已按字面语义改写：

```swift
// 旧：传 true 想隐藏；新：按函数名，false = 不显示 ×
DFRFoundationBridge.setShowsSystemModalCloseBoxWhenFrontMost(false)
```

⚠️ 两点如实说明：① `DFRSetStatus` 已绑定但**不自动调用**（它的取值语义随版本变化，
副作用是把整条 Touch Bar 改显示状态，无人值守实测有打空白的风险）；
② 函数名里的 `WhenFrontMost` 意味着它可能只管「我们自己的 App 在前台」那条栏，
后台注入给别人 App 时未必生效 —— 所以**不要**把它当作“常驻”的唯一保证。

### 10. 权限弹窗纪律：把弹窗权交还给用户

**症状**（ad-hoc 开发期尤其严重）：每次 `make run` 都会连续弹出 macOS 辅助功能授权窗，
后台跑着也会莫名又冒一个 —— 看起来像"死循环"。

**定位结果**：定时器那一路其实一直是清白的（`poll()` 调的是 `AXIsProcessTrusted()`，本来不弹窗）。
真正的源头是启动流程里的一句"未授权就友好提示一下"：

```swift
if !granted { AccessibilityPermission.checkOrPrompt() }   // ❌ 每次 start() 弹一次
```

再叠加 ad-hoc 签名的特性 —— **每次重新构建都会产生新的 cdhash，TCC 眼里就是一个新 App** ——
于是"每次 make run 各弹一次"体感上就成了连锁轰炸。

**加固后的结构（不靠注释，靠类型说话）**：

| API | 行为 | 允许谁调用 |
| --- | --- | --- |
| `silentlyProbe()` → `AXIsProcessTrusted()` | 纯查询，永不打扰 | 定时器、首帧同步、任何后台路径 |
| `checkOrPrompt(reason:)` → `AXIsProcessTrustedWithOptions([prompt:true])` | 弹系统窗 | ☝️ **只有用户手势**（菜单栏点击） |

- `Monitor` 的 `tick() → report(force:)` 只能走 `silentlyProbe()`；
- `checkOrPrompt` 加了 2 秒节流 + 计数，就算将来手抖连点或被误接进循环也不会炸；
- `lastKnownValue` 初始为 `nil`（而不是 init 时先探一次），保证首帧必推一次 UI 状态；
- 启动路径改为 **`isTrusted` 纯静默**，未授权时只在日志里说明"等待用户点击菜单栏项才会弹窗"。

**实测**（本机当前处于未授权状态，正好是最恶劣的场景）：

```
辅助功能权限：未授权（等待用户点击菜单栏项才会弹窗）
← 全程没有出现任何 "按用户请求触发第 N 次辅助功能授权" 日志 ⇒ 启动期弹窗次数 = 0
```

### 11. Makefile 签名升级（含两个反直觉的坑）

按需求把默认签名换成显式 Hardened Runtime：

```make
@codesign --force --options runtime --sign - --timestamp=none \
          --entitlements Resources/btTool.entitlements $(APP_DIR) 2>/dev/null \
  || echo "⚠️ 签名失败，App 可能无法启动"
```

实测生效：`CodeDirectory v=20500 flags=0x10002(adhoc,runtime) hashes=204+7`，
App 正常启动，**并且 `DFRFoundation` 依旧能 `dlopen`（Apple 签名的框架天然满足库校验）**。

⚠️ 但必须如实说明两点：

1. ~~它逼不出托盘图标~~ **（旧结论已作废）**。Hardened Runtime 只是 P0 的一个
   **未验证变量**（MTMR 不依赖它），`make build HARDENED=0` 可与之对照，见第 7 节。
2. **cdhash 变了 → TCC 授权记录作废**，需要重新到
   「系统设置 → 隐私与安全性 → 辅助功能」勾选一次 btTool。

**顺带踩到一个隐藏 bug**：原来 `Resources/btTool.entitlements` 里为了写说明、
照抄了命令行示例（含 `--force` / `--options` 这类双横线），而 **XML 注释禁止出现连续两个连字符**。
结果是：`plutil -lint` 报 OK，但 `codesign` 严格解析直接失败 ——

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 8
```

已重写该文件的注释（只讲要点、不再原样贴命令行），签名才通过。

### 12. 托盘存在性：跟随应用激活 / 停用动态维持

在 `AppCoordinator` 里接管了 `NSApplication` 的激活 / 停用通知，让托盘存在性跟着进程状态走：

```swift
center.addObserver(forName: NSApplication.didBecomeActiveNotification,  ...) { self?.handleAppActivated()   }
center.addObserver(forName: NSApplication.didResignActiveNotification, ...) { self?.handleAppDeactivated() }
```

🔴 **激活时是"确保存在"，绝不是"销毁"** —— 这是与需求字面描述不同的一处刻意偏离，
理由有两个（都是实测出来的）：

1. **点击 Touch Bar 上的托盘按钮本身就会激活本进程**。若按"激活 → 销毁"实现，
   点一次图标就把自己的入口拆掉一次，图标直接消失（自杀式按钮）。
2. 用户停用我们时前台正是别人的 App，那一刻恰是托盘最该在的时候。

所以默认行为是：

| 事件 | 行为 |
| --- | --- |
| 激活（`didBecomeActive`） | `ensureTrayItemInstalled()`：已注册 → 只重申 DFR 存在性；未注册 → 完整注册 |
| 停用（`didResignActive`） | 默认保持常驻；`trayItemDestroyOnDeactivate=true` 时才真的拆掉 |
| 关闭后台注入 / 退出 | 彻底销毁（先 `presence=NO`，再 `removeSystemTrayItem:`） |

`ensureTrayItemInstalled()` 必须是**幂等**的：`didBecomeActiveNotification` 触发频率不低
（点菜单栏、点托盘按钮、配置窗口…），不做去重就等于高频重复 `addSystemTrayItem` → 堆积 item。

**实测**（连续触发 3 次激活事件）：

```
已发起 Control Strip 托盘注册：btTool.controlStrip.trayItem（AppKit + DFR 存在性开关都已调用）
托盘已存在 → 仅向 Touch Bar Server 重申存在性      ← ×3，未出现第二次「已发起…注册」
```

托盘点按 → 状态机同样实测通过：

```
[DBG] ===== 模拟托盘点按 1（应展开）=====
展开长栏（点按托盘图标）：CodeBuddy CN → btTool.touchBar.generic
[DBG] 点按1后 expanded=true presenting=true installed=true
[DBG] ===== 模拟托盘点按 2（应收回）=====
收回长栏（点按托盘图标）
[DBG] 点按2后 expanded=false presenting=false installed=true      ← 托盘全程在线
```

---

## 九、第八阶段：快捷键实时录制器（按什么显示什么）

### 1. 一个控件替代五个

旧交互：在 100 多项的 `NSPopUpButton` 里翻键名 + 勾 ⌘⌥⌃⇧ 四个复选框。
问题不只是慢——下拉框只能表达 `KeyCatalog` 列出的键，F13、小键盘、非 US 布局的符号根本录不进去。

新组件 `ShortcutRecorderField: NSTextField`：

```
┌─ 组合键 ────────────────────────────────────┐
│ [ 点击录制 ]  ← 点一下变蓝框，直接按下组合键      │
│ [ ⌃⌥⌘A     ]  ← 松开即回显，立刻落盘并热更新      │
└─────────────────────────────────────────────┘
```

`Combo`（`keyCode: CGKeyCode?` + `modifierRawValue`）与 `KeyboardShortcutDTO` / `ActionDTO.syntheticKey`
共用同一套 `CGEventFlags.rawValue` 位定义，**没有引入第二套数据模型**。

### 2. 三个必须踩准的点

```swift
override func becomeFirstResponder() -> Bool {
    guard isEnabled else { return false }
    isRecording = true
    updateBorder()                       // 边框变 accent 色
    NotificationCenter.default.post(name: Self.didBeginRecording, object: self)
    return true                          // ⚠️ 不调用 super
}
```

- **不调用 `super.becomeFirstResponder()`**：一旦调用，`NSTextField` 会安装 field editor，
  按键先被文本输入系统消费，录制器再也看不到；
- **两个入口都要吞**：`performKeyEquivalent` 先于菜单栏拿到 ⌘Q / ⌘W，不吞就会直接退出；
  `keyDown` 处理普通键。两者都**绝不调用 super**，因此不会出现系统「哔」的警告音；
- **只在自己是真正第一响应者时吞**：

```swift
guard isRecording, window?.firstResponder === self else { return false }
```

否则整个窗口的所有 ⌘ 组合都会被这个控件拦掉。

另外三个细节：

| 按键 | 行为 | 原因 |
|---|---|---|
| Esc / ⌫ / ⌦ | 清空组合 | 给「不想绑了」一条退路 |
| Tab / Return（无修饰键） | 结束录制、交出焦点 | 否则键盘导航被彻底锁死 |
| 只按修饰键 | 实时预览 `⌃⌥…` | 让用户知道系统确实收到了 |

`ShortcutsViewController` 里把 `requiresModifier = true`：无修饰键的组合运行时会被
`AppCoordinator.bindShortcuts` 拒绝，录制阶段就用红框拦下，避免「录了却用不了」。
模拟按键（`ActionEditorView`）则允许裸键（例如只投递 F5）。

### 3. 与 Carbon 热键的冲突（不处理就会「按了没反应」）

`RegisterEventHotKey` 注册的组合由系统先处理，事件根本到不了窗口 —— 用户想重录
`⌃⌥L` 时，录制框收不到任何按键。所以：

```swift
// 录制开始：整批注销
registeredHotKeyIDs.forEach { hotKeyCenter.unregister($0) }
shortcutSignature = "recording"        // 让结束时的重绑不被指纹去重挡掉

// 录制结束：按当前前台强制重绑（新组合即时生效）
bindShortcuts(for: frontmostAppMonitor.snapshot(), force: true)
```

同时 `bindShortcuts` 在挂起期间直接返回（只置脏签名），否则「提交 → store 通知 → 绑定」
会和「录制结束 → 重绑」撞在一起，Carbon 日志里出现两条重复注册。

### 4. 接线（没有改动任何动作模型）

```swift
// ActionEditorView（模拟按键）
shortcutRecorder.onCapture = { [weak self] combo in
    self?.dto.keyCode = combo.keyCode
    self?.dto.modifierRawValue = combo.modifierRawValue
    self?.commitNow()                  // 复用原有落盘 + 热更新链路
}

// ShortcutsViewController（键盘快捷键）
recorder.onCapture = { [weak self] combo in
    self?.draftKeyCode = combo.keyCode
    self?.draftModifiers = combo.modifierRawValue
    self?.commit()                     // 复用原有 updateShortcut
}
```

原先的 `keyPopup`、`flagsRow`（4 个复选框）、快捷键页的 `previewLabel` 一并删除，
`orderedRows` 少一行，`VerticalFormLayout` 自动把高度收回去（不会留空洞）。

### 5. 实测

```
[REC] 录制前 combo=⌃⌥A
[hotkey] 进入按键录制：已临时注销全部热键（否则组合键会被 Carbon 先吞掉）
[REC] 已成为第一响应者，准备投递 ⌃⌥K
[hotkey] 已注册全局热键 ⌃⌥K（id=2）          ← 只注册一次
[hotkey] 按键录制结束：已恢复热键绑定
[REC] 录制后 combo=⌃⌥K 文本=⌃⌥K
[REC] 落盘结果 = ⌃⌥K (keyCode=40 raw=786432)  ← K + ⌃⌥
[REC] 仍持有焦点=false                        ← 录完自动退出，⌘Q 恢复可用
```

模拟按键路径（独立 `ActionEditorView`，不碰存档）：

```
[REC][AE] 初始=⌘A
[REC][AE] 录制后 dto.keyCode=40 raw=393216 文本=⌃⇧K
```

`393216 = control(262144) + shift(131072)`，位定义与 `CGEventFlags` 完全一致。

---

## 十、后续演进建议

- ~~`TouchBarCatalog` / `TouchBarRule` 改为读取 JSON~~（第四阶段已完成：`RuleStore` + `rules.json`）；
- ~~`AppAction` 扩展出 `shell` / `appleScript`~~（第五阶段已完成，剩 `http` 分支）；
- ~~键盘快捷键（全局 / 应用级动态注册）~~（第六阶段已完成）、~~按键录制器~~（第八阶段已完成）；下一步可做「冲突矩阵视图」；
- ~~点叉后的常驻重燃~~（已废弃，改为 Control Strip 托盘 + 点按开合）；下一步可在系统唤醒 / 切换登录用户后补一次「托盘存在性校准」；
- Touch Bar item 类型从 `NSButton` 扩展到 `NSScrubber`、`NSSlider`、`NSPopoverTouchBarItem`；
- 第三阶段加"按窗口标题 / 时间段 / 外接显示器"的多维匹配（扩展 `TouchBarRuleEngine` 入参即可）；
- 若要上架，第三阶段必须换成官方支持路径（例如只在自家窗口内展示，或用 Shortcuts / 脚本扩展）。

## 十一、审查清单：P0 / P1 / P2

### P0（Control Strip 托盘图标不显示）—— 已结案

**元凶是托盘 item 的构造方式**，与签名、特权、LSUIElement、呈现模式、TouchBarServer 缓存都无关。

- 旧构造（44×30 + `bezelStyle` + `applicationIconImage` 占位图）→ 不可见；
- 新构造（模板图 + `NSButton(image:target:action:)`）→ A/B/C 三种签名配置下**全部可见**；
- 三条旧结论（`--options runtime` 能逼出图标 / 缺 `com.apple.private.controlstrip` / ad-hoc 无解）
  经 A/B/C 对照实验证伪。
- 遗留：多个第三方托盘项互相挤占的现象存在，但两例观察指向相反，**规律未确定**，
  暂不作为结论引用。

### P1（数据安全与隐私）—— 已完成

| 项 | 处理 |
|---|---|
| 规则存档被覆盖 | 读失败 / 解析失败 / 版本过高 / 版本过旧 → **先备份** `rules.json.bak-<时间戳>` → 进只读模式，`save()` 一律不落盘；出口是菜单里的「用默认值重置 / 从备份恢复」 |
| 命令执行无确认 | 按**命令内容哈希**建白名单（`approvedCommands.json`，0600）：首次弹窗三选「允许并记住 / 仅此一次 / 取消」；内容改一个字符哈希就变 → 重新问 |
| 存档被外部篡改 | 以**内容 SHA256** 比对（不是 mtime —— mtime 能被 `touch` 改回去），不一致就在菜单里告警 |
| 存档文件权限 | 0600（里面存着 Shell / AppleScript 命令） |
| 日志隐私 | `/tmp/btTool.log` → `~/Library/Logs/btTool/btTool.log`（目录 0700 / 文件 0600）；窗口标题、Shell 命令与输出、通知正文走 `Log.sensitive`，文件里只留摘要，正文进 os_log 的 debug 级；要看正文带 `BTTOOL_LOG_VERBOSE=1` |
| 日志句柄 | 单个常驻 FileHandle + 串行队列（原来每条日志都 open/close 一次，还用了一把与队列无关的锁保护 `prepared`）；2 MB 轮转到 `.1` |
| entitlements | `disable-library-validation` 与 `automation.apple-events` 全部移除（废弃文件已删，Makefile 不再传 `--entitlements`）。代价：AppleScript 动作首触会弹 TCC |
| 主线程卡死 | `AXWindowInspector` 三处加 `AXUIElementSetMessagingTimeout(0.3)` |
| 回归测试 | `make test` —— 59 项断言：存档迁移与损坏恢复、键位/修饰键转换、命令门禁与外部修改、DTO 编解码 |

### P2（体验与健壮性）—— 已完成 7 项

1. 规则保存时 `Set` 导致顺序随机 → 保存时排序输出（保留 `Set` 用于 O(1) 匹配，不必改成数组）；
2. 无匹配规则时收起长栏 → 改为展示**占位长栏**（「⚙ 为「X」配置规则…」，点一下直接开配置窗口）；
3. 重建长栏导致闪烁 → 差量逻辑下沉到 presenter：内容未变则跳过「销毁 + 重新注入」；
4. Shell 超时形同虚设（超时后仍 `task.waitUntilExit()`）→ 超时即返回，命令留在后台自己跑完；
5. 快捷键冲突文案 → 命中 `eventHotKeyExistsErr` 时列出常见抢占者
   （⌘Space / ⌃Space / ⇧⌘3/4 / ⌘Tab / ⌃↑ / ⌥⌘D）；
6. Shell 的 stdout / stderr 直接进日志 → 改走脱敏通道；
7. ~~修饰键未设进 `CGEvent.flags`~~ / ~~`applicationShouldHandleReopen`~~
   —— **这两项核对后发现代码里本来就是对的，未改动**。

### 补：两处「静默失败」（真机验证抓出来，已修）

1. **编辑新按钮会改到已有按钮** —— `commit()` 被节流延后 0.25s，而这个延迟闭包
   **不记得自己属于哪个按钮**，执行时取的是当下的 `itemID`：新建按钮后，
   排队中的那次提交带着旧按钮的文字写进了新按钮。
   修法：切换编辑对象前先 `flushPendingCommit()`；延迟闭包捕获并校验 `itemID`（双保险）；
   新增后同步表格选中行（原来只换编辑器不换行高亮，列表与编辑器状态不一致）。
2. **配置窗口开着时，托盘怎么点都不展开**（真机验证抓出来的**真凶**）：
   ```swift
   guard NSApp.activationPolicy() != .regular else { return }   // 注释写着「配置窗口在前台」
   ```
   注释说的是**窗口级**状态，判的却是**进程级**的激活策略 —— 而策略是打开配置窗口时
   切成 `.regular`、**关窗才切回** `.accessory`。于是只要配置窗口还开着，无论用户切到
   哪个应用，托盘点击必然被拒，表现就是「非得把窗口关掉托盘才好使」。已删除该判断。

   顺带修掉三处同源问题：
   - `expandTouchBar` 改用「最后一个不是自己的前台应用」解析规则 —— 我们是 `.regular` 时
     点自己的托盘项会把本进程激活，「此刻的前台」不可靠；
   - `handleFrontmostAppChange` 的 `isSelf` 分支加 1s 宽限期，否则点托盘把自己激活
     会让长栏「刚展开就灭」；
   - 菜单里那行「长栏不可用」也依赖了同一套错误判断（用进程级策略当窗口级状态），
     改为始终显示「长栏目标：<应用名>」—— 告诉用户点托盘会发生什么。


## 十二、构建与分发

### 命令一览

```
make            # 构建 build/btTool.app
make typecheck  # 只做类型检查（最快）
make test       # 回归测试（62 项断言）
make run        # 构建后打开
make verify     # 产物自检：签名 / Bundle ID / 最低系统 / 版本
make dist       # 打分发用 zip（公证只收 zip / dmg / pkg）
make notarize   # 公证 + 装订（需要 Developer ID，见下）
```

### Deployment Target 为什么是 macOS 11.0

依据是**代码实际用到的 API**，不是拍脑袋：`NSImage(systemSymbolName:)` 自 macOS 11 起才有。

⚠️ 顺带修掉一处不一致：`Info.plist` 里原本写的是 **10.15**，与代码依赖不符 —— 在 10.15 上
会直接「Symbol not found」崩在启动阶段。现在 `Info.plist` 与编译参数 `-target`
取同一个值（`DEPLOYMENT_TARGET`），不再各说各话。

> 未实测项：11.0 是**从 API 可用性推断**的下限，没有 11.x 真机可验证。
> 已实测的是 macOS **12.7.6**（本机），编译 SDK 13.1。

### 架构为什么默认只要 x86_64

Touch Bar 是 Intel Mac（2016–2020）独有的硬件：Apple Silicon 上没有 `TouchBarServer`，
连 DFR 这套私有 API 都不存在 —— 在那里本工具只能走「不支持，降级为日志」分支。
所以 arm64 切片对我们没有用处，只会让体积翻倍：

| 架构 | 二进制 | 分发 zip |
|---|---|---|
| x86_64（默认） | 942K | 312K |
| universal | 1.8M | 604K |

确有需要时 `make build ARCH=universal`（分别编译两个切片再 `lipo -create` 合并，
**已实际验证可构建**：`Architectures in the fat file: x86_64 arm64`）。

### 公证：本机当前跑不通

`security find-identity -v -p codesigning` 的结果是 **0 个身份** —— 没有 Developer ID 证书，
所以 `make notarize` 现在必然失败。公证要三样东西，缺一不可：

1. **Developer ID Application 证书**（Xcode → Settings → Accounts 添加账号后下载）
2. **钥匙串里的公证凭证**：跑一次 `make notary-profile`，它会把命令摆出来
   （用的是 App 专用密码，在 appleid.apple.com 生成，不是 Apple ID 密码）
3. **App 本身用 Developer ID 签名** —— ad-hoc 的 `-` 过不了公证

```bash
make clean && make notarize SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)"
```

`notarize` 会先做前置检查，**缺哪样就直接说哪样，并以非 0 退出**，而不是把 notarytool
的原始报错甩出来让人猜。当前直接跑的结果是：

```
==> 公证前置检查
❌ 当前是 ad-hoc 签名（--sign -），公证不接受。
   先查到你的 Developer ID 证书名，然后这样跑：
     make clean && make notarize SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)"
```

⚠️ 换成 Developer ID 签名会改变 cdhash，**之前勾过的「辅助功能 / 输入监控」授权会失效，
需要重新勾选** —— 这是 Apple 按签名身份记 TCC 授权的必然结果，不是本工具的问题。

### 签名改动：README 里没提的细节

现在 `codesign` 用的还是 ad-hoc（`--sign -`）+ Hardened Runtime（`--options runtime`）。
`make verify` 的自检输出：

```
build/btTool.app: valid on disk
Identifier=com.bttool.app
TeamIdentifier=not set        ← ad-hoc 签名没有 Team ID，公证后会填上
Runtime Version=13.1.0
最低系统：11.0
版本：1.0
```

### 用 GitHub Actions 构建 / 发布

`.github/workflows/release.yml`：打 `v*` tag 自动构建并发布 Release，也支持手动触发
（打 tag 之前先验证 CI 能不能跑通）。

参考过一个 Tauri 项目的工作流，但**没有照搬**，差异如下：

| Tauri 那套的做法 | btTool 的处理 | 原因 |
|---|---|---|
| `matrix: [macos-latest, windows-latest]` | 只要 `macos-latest` | Touch Bar 是 macOS 独有硬件，别的平台没意义 |
| `--target universal-apple-darwin` | 只构建 x86_64 | 见上一节；而且这是 Rust 的概念，Swift 里是分别编译再 `lipo` |
| `tauri-apps/tauri-action` | 直接调 `make` | 原生 Swift 项目，不需要 Tauri 工具链 |

**为什么在 Apple Silicon runner 上能编出 x86_64**：DFR 那套私有 API 是运行时
`dlopen` + `dlsym`，**不参与链接** —— 所以"没有 Touch Bar 的机器"照样能编译。
Intel runner（`macos-13`）已下线，只能走交叉编译这条路。

⚠️ **CI 的边界**：能保证编译通过、逻辑测试通过、打包成功；
**验证不了 Touch Bar 功能** —— runner 上没有那块硬件，真机验证仍然得本地做。

公证用的 secrets（**没配就自动跳过公证**，产出 ad-hoc 签名的包）：

| Secret | 内容 |
|---|---|
| `DEVELOPER_ID_CERT` | Developer ID Application 证书（p12）的 base64 |
| `DEVELOPER_ID_CERT_PASSWORD` | p12 的导出密码 |
| `KEYCHAIN_PASSWORD` | CI 上临时钥匙串的密码（随便设一个） |
| `NOTARY_APPLE_ID` | Apple ID |
| `NOTARY_TEAM_ID` | Team ID |
| `NOTARY_APP_PASSWORD` | App 专用密码（appleid.apple.com 生成） |

```bash
base64 -i DeveloperID.p12 | pbcopy     # 结果粘进 DEVELOPER_ID_CERT
```

没配证书时产出的包**能下载**，但别人的 Gatekeeper 会拦 —— 细节见下面一节。

### Gatekeeper 与 ad-hoc 签名（没有开发者账号时会遇到什么）

本机实测：

```
$ spctl -a -vv build/btTool.app
build/btTool.app: rejected
$ codesign -dv build/btTool.app
Signature=adhoc
TeamIdentifier=not set
```

**关键在于 Gatekeeper 什么时候介入**：它只在文件带 `com.apple.quarantine` 属性
（也就是"系统认为这个文件来自网络"）时才检查。于是两种场景结果完全不同：

| 场景 | 隔离属性 | 结果 |
|---|---|---|
| 本机 `make build` / `make run`，或把产物拖进 Applications | 没有 | 双击**直接打开**，不会被拦 |
| 别人从 GitHub Release 下载 | 有（浏览器下载时打上） | 弹「来自身份不明的开发者」，**打不开** |

⚠️ 更正一个常见说法：网上流传的「右键 → 打开」绕过，通常只对**有 Developer ID 签名**的
App 有效 —— 系统认得出"是谁签的"，才会给「仍要打开」这个入口。我们是 ad-hoc 签名
（`Signature=adhoc`、`TeamIdentifier=not set`），系统连签名者是谁都不知道，
**一般不给这个入口**。

确定有效的办法是移除隔离属性：

```bash
xattr -dr com.apple.quarantine btTool.app
```

要彻底消除这件事只有两条路：加入 Apple 开发者计划（$99/年，才能公证），或者只在本机用。

已知风险：交叉编译 x86_64 时，若 runner 的 toolchain 没有预编译的 x86_64 Swift 标准库，
会**现场构建**（本机反向编译时见过 `did not find a prebuilt standard library for target
arm64 ... building it may take a few minutes`），耗时几分钟 —— 不是卡死，别急着取消。
