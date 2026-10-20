# Task 1 — Herdr GPUI 对等入口交互（菜单栏 / 右键 / New）

状态：**完成**。仅 Task 1（未做 machines 管理页、未做毛玻璃主题）。

---

## 1. 盘点：怎么对照 herdr-gpui

本机没有 `herdr-gpui` 仓库源码，所以对照证据来自**已编译的桌面端二进制**：

```bash
strings -a /Applications/Herdr.app/Contents/MacOS/Herdr \
  | grep -E "^New |Split (Right|Down)|^Close |Focus (Left|Right|Up|Down)"
```

这不是猜的：Herdr 的二进制里把每个 action 以 `<id><Title>` 成对存放，可完整提取：

| 提取到的片段 | 对应 action id | 菜单标题 |
|---|---|---|
| `split_rightSplit Right` | `split_right` | Split Right |
| `split_downSplit Down` | `split_down` | Split Down |
| `close_paneClose Pane` | `close_pane` | Close Pane |
| `close_tabClose Tab` | `close_tab` | Close Tab |
| `new_tabNew Tab` | `new_tab` | New Tab |
| `new_workspaceNew Workspace` | `new_workspace` | New Workspace |
| `rename_tabRename Tab` | `rename_tab` | Rename Tab |
| `rename_paneRename Pane` | `rename_pane` | Rename Pane |
| `rename_workspaceRename Workspace` | `rename_workspace` | Rename Workspace |
| `toggle_zoom` / `clear_pane` / `focus_left…` / `swap_pane_*` / `resize_pane_*` | 同名 | Toggle Pane Zoom / Clear Pane / Focus Left… |
| `next_tab` / `previous_tab` / `move_tab_previous` / `move_tab_next` | 同名 | Next Tab / Previous Tab / Move Tab Left / Right |
| `focus_tab_1`…`focus_tab_9`、`focus_workspace_1`…`_9` | 同名 | Focus Tab N / Focus Workspace N |

同时也提取到了 herdr-gpui 的**原生菜单栏结构**（用 `NSMenu` + `setMainMenu:`，确证为真 AppKit 菜单）：

```
Herdr  About Herdr  Command Palette  Keyboard Shortcuts  Check for Updates...
       Hide Herdr  Hide Others  Quit Herdr
File   New Workspace  New Worktree...  New Tab  Go To ▸  Close Pane...  Close Tab...
       Reopen Closed Tab
Edit   Cut  Paste  Select All
View   Increase/Decrease/Reset Font Size  Toggle Full Screen  Toggle Zen Mode
       Split Vertically (Right)  Split Horizontally (Down)  Next Tab  Previous Tab
       Back  Forward  Toggle Pane Zoom  Clear Pane  Find  Copy Mode
       Open Scrollback in Editor  Toggle Sidebar  Toggle Status Bar  Reconnect
Window New Window  Cycle Through Windows  Close Window
```

右键菜单证据（同样来自二进制）：`close-tabClose tab`、`tab-actionsTab actions`、
`New Browser Tab`、`Close Others`、`Close Group`、`Split Right`、`menu.show-hereShow Here`。

### 对 daemon 能力做了核对（避免接上不存在的功能）

用 `kraal probe` 的 welcome 拿到 40 个 method，并逐个试探参数形状：

```bash
kraal call --method pane.focus_direction   # -> missing field `direction`
kraal call --method pane.focus_direction --param 'direction=nope'
# -> unknown variant `nope`, expected one of `left`, `right`, `up`, `down`
kraal call --method tab.move               # -> missing field `tab_id`
kraal call --method tab.move --param 'tab_id=w1:t1'  # -> missing field `insert_index`
```

结论：`pane.focus_direction` / `pane.swap` / `pane.resize` / `pane.rename` /
`tab.move` / `tab.rename` / `workspace.move` / `workspace.rename` / `pane.clear` /
`server.reload_config` 全部**真实可用**，所以菜单项不是空壳。

---

## 2. Kraal 缺什么 → 实现了什么

Kraal 改动前的真实状态（侦察确认，非估计）：

- 全仓 **0** 处 `NSMenu` / `mainMenu` / `.commands` / `MenuBarExtra`。app 是手写
  `NSApplication.run()`、无 nib → **连 ⌘Q、⌘C/⌘V 都不存在**。
- 只有 4 处零散 `.contextMenu`：tab 仅 `Close Tab`；workspace 的 `Rename…` 是
  `Button("Rename…") {}`（**空实现，点了没反应**）；pane 行 4 项。
- **pane 本体右键完全无反应**：`sendMouse` 在 `mouseReporting == false` 时直接
  `return`，没有降级到原生菜单（DESIGN.md:719 要求降级，代码没实现）。
- 快捷键靠 `.opacity(0)` 里塞隐藏 `Button`，只有 ⌘K / ⌘B / ⌘1..⌘9。

### 已实现

**A. 原生菜单栏（新建 `MacMenuBar.swift`，5 个顶层菜单）**

| 菜单 | 条目 |
|---|---|
| Kraal | About / **Command Palette ⌘K** / **Keyboard Shortcuts ⌘/** / Reload Config / Hide / Hide Others / Quit ⌘Q |
| File | **New Workspace ⌘N**、**New Tab ⌘T** / Rename Workspace、Rename Tab、Rename Pane / **Close Pane ⇧⌘W**、**Close Tab ⌘W**、Close Workspace |
| Edit | Undo ⌘Z、Redo ⇧⌘Z / Cut ⌘X、**Copy ⌘C**、**Paste ⌘V**、Select All ⌘A / Clear Pane |
| View | Toggle Sidebar ⌘B、Toggle Status Bar ⇧⌘B / **Split Right ⌘D**、**Split Down ⇧⌘D** / **Focus Pane ▸**、**Swap Pane ▸** / Toggle Pane Zoom ⇧⌘↵ / Prev·Next Workspace ⌘[ ⌘] / Prev·Next Tab ⇧⌘[ ⇧⌘] / Prev·Next Pane ⌥⌘[ ⌥⌘] |
| Window | Minimize ⌘M、Zoom、Close Window ⌘W |

**B. 右键菜单（新建 `ContextMenus.swift`，三种行各一套）**

- **Tab**：Focus Tab / Split Right、Split Down / Rename Tab… / Move Tab Left·Right / New Tab / Close Tab
- **Pane**：Focus Pane / Split Right、Split Down / Zoom（按状态显示 Unzoom<Pane>）/
  Focus Pane Direction ▸、Swap Pane ▸、Resize Pane ▸ / Clear Pane / Rename Pane… / Close Pane
- **Workspace**：Focus Workspace / New Tab、New Workspace / Rename Workspace… /
  Move Workspace Up·Down / Close Workspace

**C. New 类入口**（三处，与 herdr-gpui 对齐）

1. File 菜单 → New Workspace ⌘N / New Tab ⌘T
2. tab 栏 `+` 按钮（原有，保留）
3. 侧栏 `+` 按钮 → New workspace（原有）；workspace 右键新增 New Tab / New Workspace

**D. 其它同类入口**

- 快捷键参考面板（`ShortcutsView.swift`，⌘/ 打开，与菜单共用同一张快捷键表）
- 重命名对话框（`RenamePrompt.swift`）：SwiftUI 右键路径用 sheet，AppKit 菜单路径用
  `NSAlert`，都基于同一个 `CommandPrompt`
- 菜单项**按状态禁用**（`validateMenuItem`）：无 pane 时禁用 pane 项、只有一个 pane
  时禁用 Swap、tab 在首/末位时禁用 Move Left/Right

**E. 修掉一个真实缺陷**

`pane.split` 原来只发 `pane_id`，没有 `direction`。加了 `SplitOrientation` 后，
Split Right 与 Split Down 才真正区分开（之前两者行为相同）。

---

## 3. 关键文件

新增：

```
Sources/KraalMac/MacMenuBar.swift        NSMenu 构建、validateMenuItem、重命名 NSAlert
Sources/KraalMac/MenuShortcuts.swift     快捷键表（表驱动，避免 29 分支 switch）
Sources/KraalUI/AppCommands.swift        AppCommand（48 个动作）+ CommandEnvironment + perform 分发
Sources/KraalUI/ContextMenus.swift       PaneContextMenu / TabContextMenu / WorkspaceContextMenu
Sources/KraalUI/RenamePrompt.swift       SwiftUI 重命名 sheet
Sources/KraalUI/ShortcutsView.swift      快捷键参考面板
Sources/KraalUI/WindowActions.swift      AppKit → SwiftUI 的单向意图通道
Sources/KraalUI/AppStore+Actions.swift   动作层（focus_direction/swap/rename/move/clear…）
Sources/KraalUI/AppStore+Derived.swift   派生状态（actionPaneId/actionTabId/zoomLabel…）
Sources/KraalUI/AppStore+Terminal.swift  几何与输入（从 AppStore.swift 拆出以满足 400 行限制）
```

修改：

```
Sources/KraalMac/KraalMacMain.swift       安装菜单栏、注入 WindowActions
Sources/KraalUI/AppStore.swift            拆分（491→400 行以内）、splitPane 支持 direction
Sources/KraalUI/RootView.swift            接入 WindowActions、状态栏可隐藏、快捷键面板
Sources/KraalUI/SidebarView.swift         三处 contextMenu 换成共享组件（含修掉的空 Re- 
                                          name 实现）
Sources/KraalUI/TabBarView.swift          tab 右键换成 TabContextMenu
```

### 一个必须说明的设计取舍

菜单栏接管快捷键后，`RootView` 里原有的隐藏 Button（⌘K / ⌘B / ⌘1..⌘9）会与菜单项**重复触发**——
AppKit 给菜单项 key equivalent 优先处理权，两边都注册会执行两次。所以那些隐藏按钮已移除，
只留 Esc 关面板（菜单没有对手）。这个坑写在 `RootView.swift` 的注释里。

---

## 4. 如何手动演示

**准备**（用隔离沙箱，不要连正在用的 herdr）：

```bash
# 隧道（若已断则重建）
sudo -u zzj ssh -N -L /tmp/kraal-mine/herdr-client.sock:/tmp/kraal-zzj-iso/herdr-client.sock devcloud &

cd /Users/zzj/code/kraal
./Scripts/build-app.sh          # debug 包默认指向 /tmp/kraal-mine/…
open build/Kraal.app
```

**演示 1 — 菜单栏存在**（改动前完全没有）

1. 启动后看屏幕顶部菜单栏，应有 `Kraal · File · Edit · View · Window`
2. 打开 **File** → 可见 New Workspace / New Tab / Rename … / Close Pane·Tab·Workspace
3. 打开 **Edit** → 有 Cut / Copy / Paste / Select All（改动前连 ⌘C 都没有）

**演示 2 — New 入口三条路**

1. `File ▸ New Tab` 或按 **⌘T** → tab 栏多一个 tab
2. `File ▸ New Workspace` 或 **⌘N** → 侧栏多一个 workspace
3. 侧栏右上 `+` 按钮 → 同样新建 workspace

**演示 3 — 右键菜单**

1. **tab 上右键** → Focus Tab / Split Right / Split Down / Rename Tab… / Move Tab Left / Move Tab Right / New Tab / Close Tab
   - 在第一个 tab 上右键时 `Move Tab Left` 应是**灰的**
2. **侧栏 workspace 行右键** → Focus Workspace / New Tab / New Workspace / Rename Workspace… / Move Workspace Up·Down / Close Workspace
   - 点 `Rename Workspace…` 会弹出输入框（改动前是空实现，点了没反应）
3. **侧栏 pane/agent 行右键** → 含 Focus Pane Direction ▸ / Swap Pane ▸ / Resize Pane ▸ 子菜单
   - 只有一个 pane 时 `Swap Pane` 下的项是**灰的**

**演示 4 — 分屏方向真的不同了**

1. 按 **⌘D** → 向右分屏
2. 再按 **⇧⌘D** → 向下分屏（改动前两者发的是同一个请求）

**演示 5 — 快捷键面板**

1. 按 **⌘/** → 弹出 Keyboard Shortcuts，分四组（Workspaces & Panes / Navigation / Application / Terminal）

**验证日志**：

```bash
grep "menu: installed" ~/Library/Logs/Kraal.log
# 期望: menu: installed 5 top-level menus
```

---

## 5. Build / Verify 结果

```
$ ./Scripts/verify.sh
==> tests
✔ Test run with 47 tests in 9 suites passed
✔ Test run with 32 tests in 6 suites passed
ok: swift test
==> lint
ok: swiftlint (0 violations)
==> app bundle
==> Done: /Users/zzj/code/kraal/build/Kraal.app
ok: Kraal.app
verify: all green
```

运行时确证：

```
[23:16:23.787] menu: installed 5 top-level menus
[23:16:25.xxx] welcome: 0.9.5 gen=1
```

## 6. 截图 / 证据文件

```
/tmp/kraal-demo-task1/full-menu.png   整屏截图（含菜单栏区域，144 KB）
/tmp/kraal-demo-task1/fm.jpg          同图缩小版（27 KB）
```

说明：这轮按要求**没有**再跑 vision/截图 LLM 判读。菜单栏存在性的判据是运行日志
`menu: installed 5 top-level menus` —— 该日志在 `NSApplication.shared.mainMenu = mainMenu`
之后打印，`mainMenu.items.count == 5` 即菜单已真正挂载。
（`osascript`/System Events 读不到 `menu bar 1`，这是该无 nib 进程在 AX 层的限制，
不代表菜单缺失；手动点击可验证。）

## 7. 未做（明确排除）

- machines 管理页（Task 2）
- 毛玻璃主题大改（Task 3）
- worktree 菜单（`worktree.*` 方法可用，但属新功能面，未在本次 parity 范围）
- 拖拽排序 tab/workspace（菜单与右键已提供 Move Left/Right/Up/Down）
