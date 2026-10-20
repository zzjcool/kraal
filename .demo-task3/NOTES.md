# Task 3 — Liquid-glass / frosted chrome for Kraal

状态：**完成**。`./Scripts/verify.sh` → all green。未 commit / 未 push。

---

## 1. 审计结果：改动前的 chrome 其实没有玻璃

这是本轮最重要的发现，先说清楚，否则会以为只是"调了个颜色"。

改动前，sidebar / tab bar / status bar 用的都是 SwiftUI 的
`.thinMaterial` / `.regularMaterial`。这看起来是"玻璃"，但**在 Kraal 里它什么也采样不到**：

- SwiftUI `Material` 采样的是**视图树里位于其下方的兄弟视图**；
- Kraal 的窗口是不透明的 `NSWindow`（`isOpaque = true`，默认背景色）；
- 于是 material 采样到的就是窗口自己的背景色 —— 一块恒定的灰。

实测（改动前，窗口本地坐标，2x retina）：

```text
sidebar  0.125,0.125,0.125      <- 同一灰度，与窗口背后是什么无关
tab bar  0.404,0.392,0.388
terminal 0.008,0.016,0.027      <- 已经是对的：不透明、高对比
```

也就是说：**chrome 是"名义上半透明、实际不透明"**，而且因为结果是一块干净的灰，
肉眼完全看不出问题。这类 bug 不会被截图抓到（截图看起来"挺正常的灰"），
只能用窗口标志位 + 视图树来证明。

---

## 2. 真正起作用的两件事

### 2.1 窗口必须是非不透明的

`NSVisualEffectView` 只有 `blendingMode = .behindWindow` 时才去取**窗口背后**的内容。
但如果窗口本身不透明，AppKit 会把效果合成为窗口背景色之上，模糊永远到不了桌面。

所以 `KraalMacMain.makeWindow` 里三条关键设置：

```swift
window.isOpaque = false
window.backgroundColor = .clear
window.styleMask.insert(.fullSizeContentView)   // 连同 titlebarAppearsTransparent
```

这是**必要**条件——不改这三行，后面所有 material 都是装饰性的。

安全性论证（为什么把窗口变透明不会伤到终端）：每个区域都自己铺了底。
sidebar 和两个 bar 画自己的 material；**终端区域用 `.textBackgroundColor` 铺不透明底**
（`PaneLayoutView.swift:42`），所以字形对比度完全不受影响。

### 2.2 用 AppKit 的角色化 material，而不是手调 blur

新增 `Sources/KraalUI/Glass.swift`，把"角色"映射到 AppKit 的标准 material：

| 角色 | `NSVisualEffectView.Material` | 用在 |
| --- | --- | --- |
| `.sidebar` | `.sidebar` | 工作区/agent 侧边栏 |
| `.bar` | `.headerView` | tab bar、status bar |
| `.sheet` | `.underWindowBackground` | Machines / Shortcuts / Connection / Rename |
| `.hud` | `.hudWindow` | 命令面板（浮在终端之上） |

用角色而不是"每个视图手挑一个透明度"，是这份改动能保持一致的原因：这四个 material
正是 Finder / Mail / Spotlight 自己用的，跨系统版本也不会漂。而且它们自动获得系统行为：

- 深/浅色自适应；
- **辅助功能里的"降低透明度"** —— 开启后 AppKit 自动退化为不透明，不需要我们写分支；
- **"增强对比度"**；
- `state = .followsWindowActiveState`：窗口失焦时 chrome 自动变暗，和所有 Mac app 一致。

### 2.3 可读性：contrast wash

纯 material 叠在明亮壁纸上会让正文掉到不可读的对比度。所以每个角色带一个
"wash"（把窗口背景色按比例压回去）：

```text
sidebar 0.28 · bar 0.34 · sheet 0.30 · hud 0.38
```

HUD 最高是刻意的：命令面板是在你眼睛已经适应深色终端时扫一眼的东西，最需要稳的底。

---

## 3. 部署目标决定（为什么没有 `.glassEffect`）

| 事实 | 值 |
| --- | --- |
| `Package.swift` 部署目标 | **macOS 14** |
| 宿主系统 | macOS 27.0 |
| Swift | 6.4 |

`.glassEffect(_:)` 与 `GlassEffectContainer` 是 macOS 26 (Tahoe) 才有的 API。
部署目标是 macOS 14，直接用会让 14/15 的用户无法编译。

因此本轮**没有**用 `.glassEffect`，而是用 `NSVisualEffectView` —— 它在 macOS 10.10+
就存在，且是 Tahoe 液态玻璃**底层**实现的东西。这是"真系统材质"而非"假 CSS blur"，
同时不抬高部署门槛。

如果以后把部署目标提到 26，`Glass.swift` 是唯一需要改的文件：
`VisualEffectBackground` 换成 `.glassEffect()` 即可，所有调用点不用动。

---

## 4. 具体改了什么

新增：

```text
Sources/KraalUI/Glass.swift          GlassLayer 角色 + VisualEffectBackground(NSViewRepresentable)
                                     + GlassBackground(wash/rim) + .glassChrome/.glassPanel
Tests/KraalClientTests/GlassTests.swift   5 个用例，锁死材质映射与 tint 区间
```

改动（全部是 chrome，终端一行没动）：

```text
Sources/KraalUI/Theme.swift          新增 Radius / Space / Font 三组 token
Sources/KraalUI/SidebarView.swift    .thinMaterial -> .glassChrome(.sidebar)；间距 token 化
Sources/KraalUI/TabBarView.swift     tab bar + status bar -> .glassChrome(.bar)
                                     选中 tab 从"accent 25% 填充"改为 .selection + accent 描边
Sources/KraalUI/CommandPalette.swift .regularMaterial -> .glassPanel(.hud, radius 12)
Sources/KraalUI/MachinesPanel.swift  面板 + Add/Rename sheet -> .glassChrome(.sheet)
Sources/KraalUI/ShortcutsView.swift  同上 + 字号 token 化
Sources/KraalUI/ConnectionViews.swift  Connection sheet -> .glassChrome(.sheet)
Sources/KraalUI/RenamePrompt.swift   Rename sheet -> .glassChrome(.sheet)
Sources/KraalUI/PaneLayoutView.swift 焦点描边 0.55 -> 0.65（chrome 唯一贴着内容的东西，
                                     单独加粗一档补偿玻璃背景）
Sources/KraalMac/KraalMacMain.swift  isOpaque=false / backgroundColor=.clear / fullSizeContentView
                                     + 运行期 vibrancy 视图树 dump（证据用）
```

### 间距与圆角

原来各处散落 `padding(16)` `padding(14)` `padding(10)` `padding(6)` `cornerRadius(4/5/6)`。
现在收进 `KraalTheme`：

```text
Space: 2 / 4 / 6 / 8 / 12 / 16 / 20     Radius: control 6 / overlay 12 / panel 10
Font:  barLabel 11 · rowTitle 12 · rowDetail 10 · sectionHeader 10 · micro 9
```

字号刻意不统一成"一个值"：bar 标签 11、行标题 12、辅助 10 是三个不同层级。
把 terminal 排除在这套 scale 之外是刻意的 —— chrome 文字是 UI，终端文字是内容，
后者的字号由 cell metrics 决定，不该被 UI token 影响。

---

## 5. Verify

```text
$ ./Scripts/verify.sh
ok: swift build
ok: swift test
ok: swiftlint (0 violations)
ok: Kraal.app
verify: all green
```

测试 **100** 个 = 47 + 32 + 16(machines) + 5(glass，本轮新增)。

新增的 5 个 `GlassTests` 锁的是**会静默回归**的东西：

1. 四个角色分别映射到正确的 AppKit material；
2. 映射是单射（两个角色共用一个 material 会让 sidebar 和 bar 长得一样）；
3. tint 落在 0.2–0.5（低于则正文被壁纸冲淡，高于则 blur 看不见）；
4. HUD 是四者中最不透明的；
5. `blendingMode == .behindWindow` 且 `state == .followsWindowActiveState`。

第 5 条是关键：`.withinWindow` 正是 SwiftUI `Material` 已经在做的事，
也就是改动前那个"假玻璃"的成因。测试把它钉死，防止以后有人顺手改回去。

---

## 6. 运行期证据（截图无法提供，这是替代品）

### 6.1 窗口标志位

```text
[00:10:05.379] window chrome: isOpaque=false backgroundColor=0.0
               titlebarTransparent=true fullSizeContent=true
```

`isOpaque=false` + `backgroundColor` alpha `0.0` 是 material 能到达桌面的前提。

### 6.2 真实存在三个 NSVisualEffectView

在运行中的 app 里遍历 `contentView` 子树，dump 每个 `NSVisualEffectView`：

```text
[00:10:07.916] vibrancy: 3 NSVisualEffectView(s) ->
               10/behind/follows/959x24 | 10/behind/follows/959x32 | 7/behind/follows/220x722
```

格式 `<material rawValue>/<blending>/<state>/<w>x<h>`：

| 条目 | 解读 |
| --- | --- |
| `7/behind/follows/220x722` | `.sidebar`，220 宽 = `KraalTheme.sidebarWidth`，722 高 = 实际侧栏高度 |
| `10/behind/follows/959x32` | `.headerView`，959 宽 × 32 高 = **tab bar**（本轮把高度从 30 调到 32） |
| `10/behind/follows/959x24` | `.headerView`，959 × 24 = **status bar** |

三个都是 `behind`（采样桌面而非兄弟视图）+ `follows`（失焦变暗）。
尺寸与代码里的常量一一对应，说明它们挂在了正确的三个位置上。

**为什么这比截图硬**：不透明窗口下这三个视图会退化成平坦灰色，截图上看起来
"挺正常的"，像素断言发现不了。视图树 dump 直接证明了材质存在且模式正确。
完整记录见 `vibrancy-tree.log`。

### 6.3 Task 1 / Task 2 未回归

```text
[00:10:05.411] menu: installed 5 top-level menus
[00:10:05.758] machines: loaded 6 -> nj-mac[191645f4], devcloud[0b5ecacd], nj-hw[7bfb921a],
                nj-host[413b9711], GPU机器[8048d128], host-workspace[6f165f05]
```

菜单栏仍是 5 个顶层菜单；Machines 面板仍经真实 herdr CLI 读到用户真实的 6 台机器
（未改动、未删除）。本轮只动背景与间距，命令路径一条没碰。

---

## 7. 没有截图，原因如下（不是"忘了"）

这台机器当前**屏幕已锁定**，实测：

```text
CGSSessionCopyCurrentDictionary() -> CGSSessionScreenIsLocked = 1
CGWindowList 里 loginwindow 覆盖整个屏幕
screencapture -x 抓到的是登录界面壁纸，不是 Kraal
```

我一开始没发现这点，抓到一张"看起来像 app"的图并在上面做了像素对比，
得到"sidebar 区域 0.0% 变化"的结论 —— 那个结论是**错的**，因为比较的两张图
都是登录界面。发现后已把该结论作废，没有写进本文档当作证据。

尝试过的替代通道，都受锁屏或权限限制：

- `screencapture -l <windowid>`：对 ad-hoc 签名的 Kraal 返回失败；
- `CGWindowListCreateImage`：macOS 15 起已废弃（编译告警）；
- `SCShareableContent` / `ScreenshotManager`（ScreenCaptureKit）：需要屏幕录制授权，
  且报告到的 Kraal 窗口尺寸是 140×115（锁屏下的占位），不是真实的 1180×760。

所以本章用 6.1 / 6.2 的运行期 dump 代替截图。这些数字是可以复跑的：
`grep -E "vibrancy:|window chrome:" ~/Library/Logs/Kraal.log`。

---

## 8. 文字示意（chrome 结构，非像素）

```text
┌──────────────────────────────────────────────────────────────────────┐
│  ← 这一整条是连续玻璃：titlebar 隐藏(.fullSizeContentView)，          │
│     sidebar 的 material 从红绿灯下方一直延伸到底                     │
├───────────────┬──────────────────────────────────────────────────────┤
│ ▣ sidebar     │ ┌ 959x32 .headerView ─────────────────────────────┐  │
│  220pt        │ │  ● #1  ● #2   (+)     <- 选中 tab 用 .selection │  │
│  .sidebar     │ └─────────────────────────────────────────────────┘  │
│  behind       │ ┌ 终端区域：不透明 .textBackgroundColor ─────────┐  │
│  follows      │ │  $ 字形保持锐利，没有任何模糊叠在上面           │  │
│               │ │  （这是刻意隔离：chrome 玻璃，内容不玻璃）      │  │
│  聚焦行：      │ └─────────────────────────────────────────────────┘  │
│  .selection   │ ┌ 959x24 .headerView ─────────────────────────────┐  │
│  圆角 6       │ │ w1  928×680         ⌘ 命令面板                  │  │
│               │ └─────────────────────────────────────────────────┘  │
├───────────────┴──────────────────────────────────────────────────────┤
```

浮层（各自独立窗口，所以 material 采样的是桌面 —— 真正"浮起来"）：

```text
命令面板  .hudWindow  圆角 12  rim 1px 白色 10%      ← 四者中最不透明(0.38)
Machines  .underWindowBackground  640×460            ← sheet
Shortcuts / Connection / Rename    .underWindowBackground
```

---

## 9. 已知缺口

1. **无截图**（锁屏 + 无屏幕录制授权），用运行期 vibrancy dump 替代。解锁后可一条命令复跑取证。
2. **未用 `.glassEffect`**：部署目标 macOS 14，该 API 需 macOS 26。改部署目标时只需改 `Glass.swift` 一个文件。
3. **context menu 未改造**：右键菜单是 AppKit `NSMenu` 系统渲染，已有系统材质，
   本轮未介入（自绘会破坏系统行为，不划算）。
4. **titlebar 视觉未人工确认**：隐藏 titlebar + 全尺寸内容后，红绿灯位置依赖系统默认。
   逻辑上正确（`fullSizeContent=true` 已记录），但"看起来对不对"需要解锁后人工看一眼。
5. **rim 描边仅 1px**：在 1x 非 retina 外接显示器上可能偏细，未在 1x 屏实测。
