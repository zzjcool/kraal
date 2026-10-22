<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# Kraal ↔ 官方 herdr 功能差距清单

> 对照对象：`github.com/herdrdev/herdr` HEAD `a200866`（0.9.5 之后，endpoint generation 1）
> 对照方：`Sources/` 全部 Swift 模块
> 生成：2026-10-22 · 只记录**可验证的**差距，每条带我方与上游的代码位置

图例：✅ 对齐 · ⚠️ 部分/有差异 · ❌ 缺失 · 💥 疑似 bug（不只是缺功能）

---

## 0. 一句话结论

协议层和渲染层已经对得上，**差的几乎全是"客户端自己该实现的东西"**：
copy mode、滚动条、popup 浮层、通知/声音、OSC 8 链接、光标形状、鼠标增强手势。

§7 列了 9 个当时定位到的错误。**全部已修**（下表）。复核时间 2026-10-22，
对照 `origin/main`。

### §7 现状

| # | 问题 | 状态 |
| --- | --- | --- |
| 7-1 | `CellModifier` 位定义与 ratatui 0.30 不一致 | ✅ 已修（并入 #3 的 PR #32） |
| 7-2 | `pane.split` 传 `pane_id` | ✅ 已修（`AppStore.swift:368-396` 改用 `target_pane_id`） |
| 7-3 | `workspace.close` 漏 `close_group` | ✅ 已修 |
| 7-4 | 端点请求不解析 `ErrorBody` | ✅ 已修（`EndpointConnection.throwIfErrorEnvelope`） |
| 7-5 | SS3 修饰符写死 0 | ✅ 已修（SS3 与 CSI 共用参数扫描） |
| 7-6 | 粘贴没走 `paste` 语义 | ✅ 已修（`AppStore.sendPaste`，⌘V 与右键同路） |
| 7-7 | `clientShellKeyboardReportAll` 被丢弃 | ✅ 已修（驱动 `tracksRelease`） |
| 7-8 | 侧边栏 rules 用了 `when`/`value` | ✅ **已修 → PR #17** |
| 7-9 | endpoint 命令通道并发撞 `endpoint_busy` | ✅ 已修（`EndpointConnection.isBusyRefusal` + 4 次退避重试） |

下面 §7 各节保留当时的分析与取证，**已修的条目在标题上标了「已修」**，读的时候
以这张表为准。

---

## 1. 协议 / 能力协商

| 能力 | 上游 | 我方 | 判断 |
| --- | --- | --- | --- |
| endpoint gen 1 + 4 codec | `src/protocol/endpoint.rs:15-22` | `Endpoint.swift:18-26,221-241` | ✅ |
| `surface_interest` | 硬性要求 `src/client/endpoint/supervisor.rs:520-527` | `AppStore+Requests.swift:22-74`（用 method 探测，不用 capability） | ⚠️ 有意放宽；0.9.1 兼容代价是多一次握手 |
| `health_check` ping/pong | `src/client/endpoint/health.rs:3-70` | `EndpointConnection.swift` 健康循环 | ✅ |
| `presentation_effects_fence` | `activation/protocol.rs:124-150` | 未实现 | ❌ 见 §2 |
| `agent_view_projection` | `endpoint.rs:84-92` + `control.rs:29-55` | 完全未解码 | ❌ 见 §4 |
| `agent_completions` | `endpoint.rs:35-41` | 只定义了 kind 常量，从未解码 | ❌ 见 §4 |
| `surface_reuse` / `--delta` / `--scroll` | `surface_{reuse,delta,scroll}.rs` | hello 里恒 `false`（`Endpoint.swift:103-105`） | ⚠️ 未开启（带宽优化，非功能） |
| 未知 control 忽略 | `control.rs:17-67` | `EndpointConnection.swift:481-505` | ✅ |
| `methods` 白名单前置判断 | `shell/actions.rs:380-392` | 只在 `supportsSurfaceInterest` 用过一次 | ⚠️ 发请求不查 methods，失败信息不可读 |
| 请求错误码消费 | `ErrorBody{code,message}` `schema/response.rs:29-33`，客户端按 `ResponseResult` 变体分支（`shell/actions.rs:620-835`） | `AppStore+Requests.swift:67-74` 把整个 body 丢进 `lastError` 字符串 | ❌ 见 §7-4 |

**握手差异细节**：`EndpointClientHello` 缺 `endpoint_keybindings` (=false 写死,
`Endpoint.swift:100`)，因此上游「服务端下发的 keybinding profile」永远拿不到 ——
这正是 `snapshot.server_keybindings_toml` 在我方从未被读的原因（`Snapshot.swift:40`）。

---

## 2. 多机激活时序（官方 activation）

上游把「切机器」做成一次有序的租约交接，我方是 `surface.set(false)` → `set(true)`
两次裸请求（`AppStore+Requests.swift:64-74`）。

官方序列（`src/client/endpoint/activation/protocol.rs:124-150`）：

1. `ClientShellResize`（新机器的目标网格）
2. `client_shell.surface.set(true)`
3. `ClientShellFocus`
4. 等 coherent snapshot+surface
5. `endpoint.presentation.sync.v1`（token）
6. 等 `endpoint.presentation.ready.v1`

**代价**：没有 fence 时，服务端在 frozen target 期间故意不 emit window title
（`surface_interest.rs:56-60`），切机器后标题会一直到下次内容变化才回来；
mouse/sgr/keyboard 的去重状态也不会重置（`activation.rs:1035-1060`）。

**判断**：❌ 缺失。这是「切机器偶尔要过一会儿才完全对」的根因候选。

---

## 3. 终端渲染细节

| 项 | 上游 | 我方 | 判断 |
| --- | --- | --- | --- |
| OSC 8 超链接 | 每帧起始复位 + 按 cell 变更加 `]8;;`（`render_ansi.rs:934-955,616,699`） | `SurfaceANSIRenderer` 完全不发 OSC 8（`FrameData.hyperlinks` 传进来了但没用，`PaneTerminal.swift:407`） | ❌ 链接不能被 Cmd+click |
| 下划线样式 `4:2/4:3/4:4/4:5` | `render_ansi.rs:445-452` | 只发 `4`（`SurfaceANSIRenderer.swift:170-175`） | ⚠️ curly/dotted/dashed 丢失 |
| `SLOW_BLINK`/`RAPID_BLINK` 位 | bit4 → `5`，bit5 → `6`（`render_ansi.rs:428-458`） | 把 bit4 当 blink(`5`)，bit5 当 reverse（`Wire.swift:189-192`） | 💥 见 §7-1 |
| 光标形状 DECSCUSR | `CSI Ps SP q`（`render_ansi.rs:838-850`） | `CursorState.shape` 解出来了但渲染器不写（`SurfaceANSIRenderer.swift:67-79`） | ❌ 光标永远是默认方块 |
| IME 光标锚点 | `experimental.reveal_hidden_cursor_for_cjk_ime`（`render_ansi.rs:852+`） | 无 | ❌ 中文输入法候选框不跟随 |
| 同步输出 | `?2026h/l` 包帧 | ✅ `SurfaceANSIRenderer.swift:46-50,81-83` | ✅ |
| Kitty graphics | 完整 `\x1b_G` 编码 + 文件直传（`kitty_graphics.rs`） | `graphics: Data()` 恒空（`PaneTerminal.swift:408`），`SurfaceGraphicsScene` 解了不用 | ❌ 图片/图表不显示 |
| 滚动条 | `scrollbar_rect` + `ui.pane_scrollbars`（`ui/scrollbar.rs`） | `scrollbarRect` 解出来但**没有人画**（全仓 grep 只在 Decoder/Wire） | ❌ 见 §5 |
| 滚动位置指示 | copy mode 底栏 `{cur}/{total}`（`render.rs:170-176`） | 无 | ❌ |

---

## 4. Snapshot 里解出来却没人用的字段

这些字段全部在 `Snapshot.swift` 里解码，但 UI 侧零引用（`grep -c` 结果均为 0）：

| 字段 | 上游用途 | 现状 |
| --- | --- | --- |
| `configDiagnostic` | 配置错误显示在模式栏（`render.rs:75-78`） | 解了不显示 |
| `updateAvailable` / `updateInstallCommand` / `latestReleaseNotesAvailable` / `releaseNotes` | "What's New" 浮层 + 更新提示（`overlays.rs:308,424`） | 全丢 |
| `productAnnouncement` | 首次启动公告浮层（`overlays.rs:424`） | 全丢 |
| `integrationUpdatesAvailable` | 设置页 Integrations 红点 | 全丢 |
| `worktreeDirectory` | 「新建 worktree」默认根目录（`configuration.mdx`） | 全丢 |
| `serverKeybindingsToml` | `--remote-keybindings server` 时的键位源 | 全丢 |
| `agentViewLabel` | 侧栏 agent 面板表头的 accent 标签 | 全丢 |
| `agent.stateLabels` | `state_text` 显示上报的自定义标签（`ui/sidebar/tokens.rs:29-48`） | 只用 `statusWord()` 硬编码英文 |
| `agentOrder` | ✅ 已用（`AppStore+Derived.swift:62-66`） | — |

---

## 5. 交互层：完全缺失的功能

### 5.1 Copy mode（上游 ~856 行，`src/client/shell/copy_mode.rs`）

| 子功能 | 证据 | 我方 |
| --- | --- | --- |
| `prefix+[` 进入 copy mode | `copy_mode.rs:12` | ❌ |
| h/j/k/l、w/b/e/W/B/E、{/}、PgUp/PgDn、^/0/$/g/G | `copy_mode.rs:139-247` | ❌ |
| `/` `?` 搜索 + `n`/`N` + `1/12` 计数 | `copy_mode.rs:326,388,346-375` | ❌（协议 `pane.copy_search` 已实现编码，从未发送） |
| `v`/Space 字符选择、`V` 行选择 | `copy_mode.rs:643-668` | ❌ |
| `y`/Enter 复制 → `pane.selection.read` → 剪贴板 | `copy_mode.rs:130-137` | ❌ |
| 鼠标拖选 + 双击选词 + 边缘自动滚动 | `mouse.rs:206`, `word_selection.rs` | ⚠️ 只有 Ghostty 本地选区（pane 内），拖选不跨 scrollback |

**可复用的现成协议**：`pane.selection.read` / `pane.copy_motion` / `pane.copy_search`
三个方法在 `welcome.methods` 白名单里（`Tests/.../welcome.json`），
`Encoder.swift` 也能发 `paste()` —— 缺的是 UI 状态机，不是协议。

### 5.2 其它交互缺口

| 功能 | 上游证据 | 我方 |
| --- | --- | --- |
| Go To / session navigator（`prefix+g`） | `overlay_input.rs:194-281`, `aggregate_navigation.rs:281-300` | ❌ 侧栏只能点，不能按名/状态跨机器跳 |
| 快捷键帮助面板（`prefix+?`），带 `/` 过滤 | `keybind_help.rs:75-231` | ⚠️ `ShortcutsView` 是硬编码表格，读不到 config 的 keybinds |
| 设置面板（theme/indicators/sound/toast/integrations） | `settings.rs:35-229` | ❌ 我方设置只有 Machines + Terminal 两页 |
| Popup 浮层终端（popup 命令 / `type="popup"`） | `app/popup.rs`, `popup_size.rs` | ❌ `PaneSurfaceFrame.popup` 解了不画，`clientShellPopupInput` 编码存在但从未发 |
| 内嵌文本编辑器（rename 的光标移动/选区/剪贴环） | `text_editor.rs` | ⚠️ 只支持整串覆盖 |
| Navigate 模式（workspace 列表预览，Enter 才提交） | `workspace_navigation.rs:96,170` | ❌ |
| Resize 模式（`prefix+r` 后 hjkl 连续调） | `input.rs:1042-1070` | ⚠️ 只有一次性方向命令 |
| Tab 栏横向滚动按钮 / 拖拽重排 | `tabs.rs:64-197`, `mouse.rs:1300` | ❌ 只能右键 Move Left/Right |
| Workspace 拖拽重排 / 拖入组（`workspace.move_block`） | `mouse.rs:511-670` | ❌ 方法从未调用 |
| 右键透传开关（`pane.input.set`） | `context_menu.rs:72-78` | ❌ `rightClickPassthrough` 解了不用 |
| `ui.confirm_close` 关闭确认 | `actions.rs:847-852` | ❌ 我方直接关（`MacMenuBar.swift:116` 注释明说） |
| **`workspace.close` 需要 `close_group`** | `api/workspaces.rs:322-336` 返回 `workspace_group_close_required` | 💥 见 §7-3 |
| Ctrl+Hover 链接高亮 + `pane.link.activate` | `link_hover.rs:83`, `mouse.rs:841` | ❌ 方法从未调用 |
| host cursor 策略 / `redraw_on_focus_gained` | `config/model.rs:955-960` | ❌ |
| 前缀键/直接键完全可配置 | `config/keybinds.rs`（`[keys]` 全面映射） | ⚠️ 我方菜单快捷键写死在 `MenuShortcuts.swift`，不读 config |

---

## 6. 通知 / 声音 / 剪贴板

| 功能 | 上游 | 我方 | 判断 |
| --- | --- | --- | --- |
| `SemanticNotification` → 应用内 toast | `notification_policy.rs` | 事件解码了（`EndpointConnection.swift:417-424`），UI 无消费者 | ❌ |
| toast 位置 / delay / active-tab 抑制 | `config/model.rs:63`, `notification_policy.rs:15-63` | 无 | ❌ |
| 点击 toast / `prefix+o` 跳到来源 pane | `mouse.rs:1002-1018` | 无 | ❌ |
| 声音 done / request（`ui.sound`） | `sound.rs:26-135` | 无（`NSSound` 零引用） | ❌ |
| 系统通知（terminal-notifier / osascript） | `platform/macos.rs:756-806` | 无 | ❌ |
| 外层终端通知 OSC 9/99 | `terminal_notify.rs:11-105` | 无 | ❌ |
| BEL 转发 | `terminal_effects.rs:5-13` + `TerminalBell` | 事件解码了，无消费者 | ❌ |
| 窗口标题（`ui.window_title` 模板 + `WindowTitle` 消息） | `app/window_title.rs`, `terminal_effects.rs:15-25` | 事件解码了，`window.title` 只在启动时写一次（`KraalMacMain.swift:161`） | ❌ |
| OSC 52 剪贴板（PTY→宿主） | `ServerMessage::Clipboard` + `selection.rs:355-380` | `.clipboard` 在 switch 里被明确 `break`（`EndpointConnection.swift:442-447`） | ❌ 远端 `pbcopy` 不生效 |
| 剪贴板图片粘贴（`ClipboardImage`） | `clipboard_images.rs:63-100` | 编码有，从未发 | ❌ |
| copy_on_select | `config/model.rs:953` | 无 | ❌ |

---

## 7. 我方代码里的可疑 bug（不只是"缺功能"）

> 这些是**已有代码路径里的错误**，优先级高于新功能。

### 💥 7-1 `CellModifier` 位定义与上游不一致 → 反色被误判成闪烁
`Wire.swift:184-194` 把 bit4 标成 `blink`、bit5 标成 `reverse`、bit6 标成 `reversed`。
上游（ratatui 0.30，`render_ansi.rs:428-458` 用同一套）是
bit4=SLOW_BLINK、**bit5=RAPID_BLINK**、**bit6=REVERSED**。
结果：
- 真正反色的 cell（bit6）被我方 `reverse|reversed` 都命中 → 侥幸对了；
- RAPID_BLINK（bit5）被我方当反色 → 闪的东西大面积反色；
- 我方 `blink`(bit4) 发 `5` 恰好对，但 `rapid` 完全没发 `6`。

### ✅ 7-2（已修）`pane.split` 传 `pane_id`，上游字段是 `target_pane_id`
`AppStore.swift:303,364-368` 与 `AppStore+Derived.swift` 发的都是 `"pane_id"`。
上游 `PaneSplitParams.target_pane_id`（`api/schema/panes.rs:27`），无 `alias`、无
`deny_unknown_fields`，因此 `pane_id` 被**静默丢弃** → 服务端回退到
「当前聚焦 pane」（`app/api/panes.rs:35-47`）。
→ 在非聚焦 pane 上右键 Split 会拆错 pane；`store.focus(paneId:)` 是异步的，
   所以「先 focus 再 split」也靠不住。

**已修**：`AppStore.swift:396` 发 `target_pane_id`，并带注释记下这次的取证
（`target_pane_id: wS:p1` 才会在 `wS:t1` 里建 pane）。

### ✅ 7-3（已修）`workspace.close` 漏发 `close_group`，worktree 组关不掉
曾经只发 `workspace_id`。上游在组内 ≥2 个 workspace 且 `close_group=false` 时
直接返回 `workspace_group_close_required`（`app/api/workspaces.rs:330-336`）。

修法与**实测的 daemon 行为**（0.9.5，2026-10-22）：

- 请求永远带 `close_group`（首次 `false`，用户确认后 `true`）；
- 拒绝走 `AppStore.callReturningErrorCode` 把 code 交回调用方，而不是折成一行
  字符串；`workspace_group_close_required` / `confirmation_required` 都触发
  **确认对话框**，其余仍按错误上报；
- 只有 **main checkout**（`is_linked_worktree == false`）会被拒绝，关 linked
  worktree 本来就不受此限（`app/actions.rs:899-917`）。所以判断「是否成组」
  必须问 daemon，不能靠侧边栏的分组显示；
- 对话框挂在 `RootView` 根部：侧边栏右键菜单是 SwiftUI、File 菜单是 AppKit，
  挂在任一侧都会对另一侧不可见。

实测 A/B（daemon 为准）：`close_group=false` → `workspace_group_close_required`
且 `workspace list` 仍是 `['w1','w3','w5']`；`close_group=true` → `{"type":"ok"}`
且只剩 `['w3']`。`gui.sh close-workspace-group` 钉住了前半段（请求带 flag、
拒绝被识别、没有误关）。

### ✅ 7-4（已修）端点请求不解析 `ErrorBody` / `ResponseResult`
`AppStore+Requests.swift:67-74` 把响应 body 当透明数据丢掉，所有失败都变成
`"<method>: <raw>"`。后果：
- 无法区分 `workspace_group_close_required` / `confirmation_required`
  （`app/api/panes.rs:1981-1987`）这类**需要用户确认**的错误；
- `pane.split` / `tab.create` 的成功响应里带着新的 `pane_id` / `tab_id`
  （`api/schema/response.rs:59-`），我方拿不到，只能等快照 —— 新建后立刻要
  对它做操作（聚焦、设置 ratio）时会有竞态。

**已修**：`EndpointConnection.throwIfErrorEnvelope` 把 `{"error":{code,message}}`
转成 `BridgeError.daemon(method:code:message)`，`AppStore.call` 会记日志并
把 code 露出来。

### ✅ 7-5（已修）`parseCSI` 把修饰符写死为 0（SS3 分支）
`TerminalInputDecoder.swift:177` `let modifiers: UInt8 = 0`，`ss3Event` 全部收到 0。
xterm 的 SS3 形如 `ESC O 1;5 P`（F1+Ctrl），我方只解析 3 字节 `ESC O <final>`，
所以**带修饰的 F1–F4 会丢修饰符，甚至把 `1;5` 当文本打进 pane**。
（CSI 分支正确走 `modifiers(fromXterm:)`，只有 SS3 这条路径有问题。）

**修法**：SS3 与 CSI 共用同一段「参数 + final byte」扫描，只是 final 交给
`ss3Event`。`ss3Event` 按 CSI 的同一规则读 `;N` 并调
`modifiers(fromXterm:)`。`ESC O P`（无参数）与 `ESC O 1;1 P`（xterm 写「无修饰」）
都必须是 m0 —— 测试两种都钉了。

### ✅ 7-6（已修）粘贴路径没走 `paste` 事件
`KraalMacMain.swift:456-463` 的 Paste 直接 `sendInput(Data(text.utf8))`，
经 `TerminalInputDecoder` 变成一串 `textCommit`。上游 `ClientPaneInputEvent::Paste`
（`wire.rs:145-147`）是给 bracketed paste 用的独立语义，我方 `Encoder.swift:307`
能编码但**没有任何调用点** → 多行粘贴进 shell 会被逐行执行。

**修法**：新增 `AppStore.sendPaste(_:to:)`（不解码，否则粘贴文本里的字面 ESC
会变成方向键）。两个入口都改走 `AppCommand.paste`：⌘V 原来是
`NSText.paste` → responder chain（pane 里没有视图实现它，等于什么都没发生），
右键菜单原来直接 `sendInput`。经 `AppCommand` 统一后两处同路。

**实测差异**（`scripts` 未覆盖的部分）：`TerminalInputDecoder` 会把连续文本合并成
**一个** `textCommit`，所以差别不在事件数量，而在 wire tag（1 vs 3）与 daemon
侧的语义——所以测试钉的是 tag。

### ✅ 7-7（已修）`clientShellKeyboardReportAll` 被丢弃

### ⚠️ 7-7 `clientShellKeyboardReportAll` 被丢弃
`EndpointConnection.swift:442-447` 把 tag17 归进"byte-level terminal traffic"直接
`break`。上游用它在 prefix/navigate 模式下要求宿主上报所有按键
（`render.rs:205-226`），并在重放时重发（`surface_interest.rs:801`）。
我方不需要 prefix 模式，但 **Kitty keyboard 模式的 pane 是否拿到 key release
完全取决于这个开关**；丢掉的直接后果是需要 release 的 TUI 收到不完整事件。

**修法**：事件改成 `ConnectionEvent.keyboardReportAll(enabled:)`，存进
`AppStore.keyboardReportAll`，`sendInput` 每次把它写进新的
`TerminalInputDecoder.reportsAllKeys`，由后者决定所有 `key` 事件的
`tracksRelease`（7 处硬编码 `false` 全部替换）。

**未做**：`directTerminalKeyboardProtocol`（kitty flags / modifyOtherKeys）仍在
"byte-level traffic" 分组里被忽略。Kraal 不把键盘协议转发给宿主终端，而是自己
编码按键；把它接上需要改按键编码器（非 Latin-1 键怎么发），是独立的一块，不在
issue #20 的验收范围内。

### ✅ 7-8（已修 · PR #17）侧边栏 rules 用了不存在的 `when`/`value` 键
`SidebarConfig.swift:160` 读 `ruleTable["when"]` + `["value"]`；
上游是内联条件键 `equals` / `contains` / `starts_with` / `gt` / `lt`
（`config/sidebar/rules.rs:26-47`，`deny_unknown_fields`）。
→ **任何用官方文档写法写的 config.toml，其 rules 全被静默忽略**（我方 `continue`
  跳过），且 `DESIGN.md:611-613` 记的正是那个错误格式。

**已修（PR #17）**：改为读内联键，并补齐上游的校验 —— 每条规则恰好一个条件、
数值阈值收 `Double` 且拒非有限值、数值条件拒 `ignore_case`、支持 `hide`
（token 连分隔符一起消失）、只应用第一条命中（不再逐条叠加）。
`ignore_case` 保持 ASCII-only，与上游 `eq_ignore_ascii_case` 一致。

### ✅ 7-9（已修）endpoint 命令通道是「单条串行」，我方并发发送 → 大量请求被 `endpoint_busy` 丢弃

上游服务端每个连接同一时刻只允许**一条** endpoint 命令在飞
（`src/server/headless/endpoint_requests.rs:59-66`），第二条直接回
`endpoint_busy`「this endpoint is still processing another command」。
官方客户端为此建了一个 lane：`queued` + `in_flight`，一次只放一条，60 s 超时
（`src/client/endpoint_commands.rs:8-40`，`ENDPOINT_COMMAND_TIMEOUT = 60s`）。

我方 `EndpointConnection.request()`（`EndpointConnection.swift:221-256`）按 requestId
**并发挂 continuation**，没有任何串行化；`AppStore.call()` 又是每个动作一个独立
`Task`（`AppStore.swift:303,337,345,364-368` …），所以两次点击就会同时发两条。

而 `KraalMacMain.swift:73-77` 在**每一次按键**都执行：

```swift
self.store.sendInput(data, to: paneId)
self.store.focus(paneId: paneId)     // → pane.focus 端点请求
```

→ 打字时每条按键都产生一条 `pane.focus`，互相撞成 `endpoint_busy`；
`tab.focus` 之后紧跟的 `client_shell.surface.set`（`AppStore.swift:326-333`
+ `reprojectSurface()`）同样是两条连续命令，也可能撞。
被丢弃的 `pane.focus` 意味着**点击/键入后 daemon 的聚焦 pane 可能不是我方认为的
那个**，这会让 §7-2 的「拆错 pane」在真实使用中更容易命中。

错误本身也被 §7-4 吞掉了，所以现场表现是「偶尔点了没反应 / 焦点跳错」，无声无息。

**已修**：`EndpointConnection.isBusyRefusal` 识别 `endpoint_busy`，`AppStore.call`
带 4 次递增退避重试（`20/40/60 ms`），并给每次调用记 `call: ok / BUSY / FAILED`
日志。重试是安全的：拒意味着什么都没做。

修法（两件事都要）：
1. `EndpointConnection` 里加一条 lane：`request()` 排队，一条在飞，完成后放行下一条
   （对齐 `endpoint_commands.rs`），`client_shell.surface.set` 与我们自己重投影用的
   成对调用要**在 lane 内成组**，否则 `set(false)` 会被 `set(true)` 挤掉；
2. `focus(paneId:)` 先比对 `snapshot.focusedPaneId == paneId` 就直接返回，
   不要每个按键都发一次 —— 这条独立于 lane，本来就该有。

---

## 8. 显式未做但有意的取舍

| 项 | 上游 | 我方 | 说明 |
| --- | --- | --- | --- |
| prefix 模式（tmux 风格） | `input.rs:610-737` | 用 macOS 菜单快捷键替代 | 合理：原生客户端有菜单 |
| 移动端单列布局（≤64 列） | `mobile.rs` | 无 | macOS 不需要；iOS 阶段必须补 |
| 欢迎页 onboarding | `ui/onboarding.rs` | 无 | 无 daemon 时用连接面板代替 |
| `agent.start` / `agent.prompt` / `agent.wait` | `cli/agent.rs` | 无 | 不在 endpoint 白名单内，属 CLI |
| 插件 UI | 无（上游也没有） | 无 | 对齐 |
| 块选择（矩形） | 无（只有 Character/Linewise） | 无 | 对齐；别按直觉加 |

---

## 9. 建议的补齐顺序

### 第一批：bug（改动小、收益立现）

1. §7-9 endpoint 命令串行化 lane + `focus` 去重（**最高优先**：它让其它所有
   动作都变成"偶尔失败"，而且错误被 §7-4 吞掉，现场无从诊断）
2. §7-4 加一层 `ErrorBody`/`ResponseResult` 解码，把 `code` 暴露给 UI
   （修了它，`endpoint_busy` 这类问题才能看见）
3. §7-2 `pane.split` → `target_pane_id`
4. ~~§7-3 `workspace.close` 带 `close_group`~~ ✅ 已修
5. §7-1 modifier 位对齐 + `rapid_blink` 发 `6`
6. §7-8 侧边栏 rules 改成官方内联键（同时修 `DESIGN.md:611`）

### 第二批：一眼可见的缺失

1. 光标形状 `CSI Ps SP q`（`SurfaceANSIRenderer`，~10 行）
2. OSC 8 超链接（渲染器 + Cmd+click → `pane.link.activate`）
3. 滚动条：`scrollbar_rect` 画出来 + 拖 thumb → `pane.scroll`
4. 窗口标题：消费 `.windowTitle` + `ui.window_title` 模板
5. 通知/声音/BEL：`SemanticNotification` → toast，`TerminalBell` → `NSSound.beep`
6. 粘贴走 `.paste`（bracketed paste 语义）

### 第三批：交互厚度

1. copy mode（先做 `prefix+[` 等价入口 + 选区复制，用现成三个 pane 方法）
2. Popup 浮层渲染（`PaneSurfaceFrame.popup` → SwiftUI overlay + `popupInput`）
3. 右键透传 `pane.input.set` + `rightClickPassthrough`
4. Tab 拖拽重排 / workspace 拖拽 + `workspace.move_block`
5. 快捷键面板改成读 config 的 `[keys]`

### 第四批：协议深度

1. `presentation.sync/ready` fence（§2）
2. `agent_view_projection` / `agent_completions`
3. `surface_scroll` 编码（滚动时带宽收益最大）
4. `configDiagnostic` / 更新提示 / release notes 浮层
