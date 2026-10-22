# Kraal 技术设计文档

> 原生 iOS / macOS Herdr 客户端 · 基于 herdr endpoint 协议 + Ghostty 渲染
>
> 版本 1.0 · 2026-10-20 · 所有结论均基于对 herdr 0.9.4（本机）/ 0.9.1（远端）的实测

---

## 0. 摘要

我们构建一个**原生 Swift** 的 Herdr 客户端，iPad/iPhone 与 Mac 共用同一份代码库。它不重写终端模拟器，而是：

- **侧边栏 / 标签栏 / 布局**：SwiftUI 原生控件，数据来自 herdr 的 `shell.snapshot.v1`
- **pane 内容**：Ghostty 的 `InMemoryTerminalSession` + `TerminalSurfaceView`（Metal 渲染）
- **传输**：SSH exec 直连远端的 `herdr remote-client-bridge`（endpoint 协议，bincode 二进制帧）

实测数据（本机 unix socket / 局域网 SSH）：

| 指标 | 值 |
|---|---|
| 握手 → welcome | 22 ms |
| 握手 → snapshot（侧边栏数据） | 22 ms |
| 握手 → 首个 PaneSurface | 67 ms 本地 / **224 ms 远程** |
| PaneSurface 首帧大小（120×40） | 73 KB |
| PaneSurfacePatch 增量 | **66 B** |
| ANSI 帧（单 pane 60×40） | 2.7 KB / 增量 ~250 B |
| ANSI 与权威 surface 一致性 | **36/36 行逐字节一致** |

---

## 1. 背景与约束

### 1.1 Herdr 的架构

```
┌─────────────┐
│ herdr server│  每个 session 一个后台 daemon，持有 PTY、workspace、
│  (daemon)   │  tab、pane、agent 检测。socket: herdr.sock
└──────┬──────┘
       │
   ┌───┴────────────┬──────────────┬───────────────┐
   │                │              │               │
JSON API        endpoint 协议    terminal attach   TUI
(herdr.sock)    (herdr-client    (herdr-client    (本地渲染)
                 .sock)           .sock)
```

我们使用**后三种中的前两种**：

- `endpoint 协议` → 拿 snapshot（侧边栏数据）+ PaneSurface（分屏几何）
- `terminal attach` → 拿每个 pane 的 ANSI 字节流

### 1.2 为什么不用 JSON API 做主通道

`herdr.sock` 的 JSON API 是**一条连接一个请求**（实测：连发第二个请求即 BrokenPipe），128 个方法里没有"订阅 surface"这一项。它适合管理操作，不适合实时画面。

### 1.3 为什么不用 ANSI 作为唯一通道

`TerminalHello`（tag 0）握手只返回 `Welcome{encoding}` + `TerminalFrame{bytes}`，**不推 snapshot**（`src/server/headless.rs:1889` 确认：走 `ClientConnectionMode::TerminalPending`）。所以侧边栏、tab 列表、agent 状态全拿不到，必须另开 endpoint 连接。

### 1.4 版本要求

| | 最低 | 说明 |
|---|---|---|
| herdr server | **0.9.0** | endpoint protocol generation 1 |
| 能力探测 | `herdr-remote-output-ready:1` + `endpoint.welcome.v1` | 见 §2.4 |

实测 0.9.1 与 0.9.4 互通。

---

## 2. 连接层

### 2.1 SSH 传输

**统一用一条 SSH session，上面开多条 channel。**

```swift
// 逻辑结构
final class HerdrConnection {
    let ssh: SSHClient          // libssh2 session（一次握手完成认证）
    var endpoint: SSHChannel    // channel A: remote-client-bridge
    var terminals: [PaneID: SSHChannel]  // channel B..N: terminal attach
}
```

一次握手，N 条 channel。这是 iOS 上必须的设计——iOS 没有 `ControlMaster`，每次握手都是完整认证（含可能的 2FA）。

### 2.2 命令

```sh
# channel A —— 主通道
herdr --session <name> remote-client-bridge

# channel B..N —— 每 pane 一条
herdr --session <name> terminal session control <pane_or_terminal> --takeover --cols <W> --rows <H>
```

两者都是 **stdin/stdout 二进制管道**，不涉及 stream-local forwarding，因此不需要 `AllowStreamLocalForwarding`。**这是选择这条路线的关键原因之一**：iOS SSH 库（swift-nio-ssh / libssh2）都缺少 `direct-streamlocal` 支持，但我们用不到它。

### 2.3 SSH 参数（照抄 herdr 自己的）

```
-T -C
-o BatchMode=yes
-o NumberOfPasswordPrompts=0
-o StrictHostKeyChecking=yes
-o ConnectTimeout=10
-o ConnectionAttempts=1
-o ServerAliveInterval=15
-o ServerAliveCountMax=4
-o ForwardX11=no
```

iOS 上由 SSH 库实现等价能力：
- `-C` → libssh2 无压缩开关，需调用方在应用层考虑（首帧 73KB，可接受）
- `ServerAliveInterval` → `libssh2_keepalive_config(session, 1, 15)`
- `ControlMaster=no` → iOS 不需要，本来就是一次 session

### 2.4 握手时序

```
Client                                    Server
  │                                          │
  ├─ SSH auth ──────────────────────────────►│
  ├─ exec: terminal session control <pane> ─►│   (channel B, 可选先建)
  ├─ exec: remote-client-bridge ────────────►│   (channel A)
  │                                          │
  │◄─ frame: [u32 len][tag=20 EndpointControl]│
  │      kind="endpoint.welcome.v1"          │
  │      data=JSON{generation,server_version,│
  │           methods[40], capabilities[8]}  │
  │                                          │
  │─ frame: [u32 len][tag=20 EndpointControl]►│
  │      kind="endpoint.hello.v1"            │
  │      data=JSON{generation:1, ...}        │
  │                                          │
  │◄─ tag=20 kind="endpoint.agent-completions.v1"
  │◄─ tag=20 kind="shell.snapshot.v1"        │  ← 侧边栏数据
  │◄─ tag=8  MouseCapture
  │◄─ tag=17 ClientShellKeyboardReportAll
  │◄─ tag=6  WindowTitle
  │◄─ tag=13 PaneSurface                     │  ← 分屏几何 + 整屏 cell
  │◄─ tag=19 PaneSurfacePatch  (持续)        │  ← 增量
```

**注意顺序**：服务端先发 welcome（无需客户端 hello），但客户端必须回 hello 才会收到 snapshot。实测 welcome 在连接后立即到达。

### 2.5 帧格式

```
┌────────────────┬──────────────────────────────┐
│ u32 LE length  │ bincode payload (length bytes)│
└────────────────┴──────────────────────────────┘
```

- 单帧上限：`MAX_FRAME_SIZE = 2 MiB`；图形帧 `MAX_GRAPHICS_FRAME_SIZE = 32 MiB`
- bincode `standard()` 配置 = **varint 长度前缀**（< 251 单字节，否则 `0xFB`/`0xFC`/`0xFD`）

```
0x00..0xFA  → 值本身
0xFB + u16  → little-endian u16
0xFC + u32  → little-endian u32
0xFD + u64  → little-endian u64
```

### 2.6 能力探测与降级

```swift
enum Compatibility {
    case ok                      // generation == 1 且 codecs 有交集
    case serverTooOld(String?)   // 无 endpoint 支持
    case clientTooOld(String?)   // generation > 1
    case noCommonCodec
}
```

`welcome.capabilities` 实测值（0.9.4）：

```
surface_reuse, surface_delta, surface_scroll, surface_interest,
presentation_effects_fence, health_check, agent_view_projection, agent_completions
```

`surface_reuse / surface_delta / surface_scroll` 是三个**可选压缩编码**。第一版全部关闭（hello 里传 `false`），只收完整 `PaneSurface` + `PaneSurfacePatch`，降低实现复杂度；后续逐个开启。

### 2.7 健康检查

服务端每 5s 静默则客户端发 `EndpointControl{kind:"endpoint.health.ping.v1"}`，10s 无 `pong` 判定断线。参数来自 `herdr-client/src/limits.rs`：

```
QUIET_PING = 5s
PING_TIMEOUT = 10s
HANDSHAKE_TIMEOUT = 10s
COMMAND_TIMEOUT = 60s
MAX_RESPONSE_BYTES = 8 MiB
```

### 2.8 重连策略

**不存在透明重连**（协议规定 `boot_id` 变化即所有未完成请求失效）。客户端策略：

```
断线 → 指数退避重连（1s, 2s, 4s ... 上限 30s）
     → 重新握手 → 新 boot_id → 丢弃所有旧 surface → 拉新 snapshot
```

`boot_id` 是 fence：所有 `PaneSurface`/`PaneSurfacePatch` 都带 `boot_id`，不匹配即丢弃。

---

## 3. 协议类型（Swift）

### 3.1 枚举顺序是兼容契约

**bincode 用位置编码，枚举变体的顺序绝不可改。** 以下顺序来自 herdr 0.9.x 源码，必须逐字保持。

```swift
// 21 个客户端消息（ClientMessage），索引即 wire tag
enum ClientMessageTag: UInt32 {
    case terminalHello = 0
    case input = 1
    case clipboardImage = 2
    case resize = 3
    case detach = 4
    case attachTerminal = 5
    case attachScroll = 6
    case observeTerminal = 7
    case controlTerminal = 8
    case graphicsTransmissionResult = 9
    case graphicsTransmissionStarted = 10
    case clientShellHello = 11
    case clientShellResize = 12
    case clientShellPaneInput = 13
    case clientShellPopupInput = 14
    case clientShellEndpointRequest = 15
    case attachMouse = 16
    case clientShellHostTheme = 17
    case clientShellFocus = 18
    case clientShellMouseCapture = 19
    case endpointControl = 20      // ← 最易错：不是 11
}

// 21 个服务端消息（ServerMessage）
enum ServerMessageTag: UInt32 {
    case welcome = 0
    case terminal = 1
    case graphics = 2
    case serverShutdown = 3
    case notify = 4
    case clipboard = 5
    case windowTitle = 6
    case reloadSoundConfig = 7
    case mouseCapture = 8
    case terminalBell = 9
    case graphicsFile = 10
    case graphicsTransmissionRetired = 11
    case clientShellSnapshot = 12
    case paneSurface = 13
    case semanticNotification = 14
    case clientShellError = 15
    case directTerminalKeyboardProtocol = 16
    case clientShellKeyboardReportAll = 17
    case clientShellEndpointResponseChunk = 18
    case paneSurfacePatch = 19
    case endpointControl = 20
}
```

### 3.2 核心数据结构

```swift
// ---- 帧 ----
struct FrameData {
    var cells: [CellData]
    var width: UInt16
    var height: UInt16
    var cursor: CursorState?
    var hyperlinks: [String]
    var graphics: [UInt8]
}

struct CellData {
    var symbol: String        // 一个 grapheme cluster，可能为空（skip）
    var fg: UInt32            // 见 §3.3 颜色编码
    var bg: UInt32
    var modifier: UInt16
    var skip: Bool            // true = 不画（宽字符的续格）
    var hyperlink: UInt32?    // FrameData.hyperlinks 的索引
}

struct CursorState {
    var x: UInt16
    var y: UInt16
    var visible: Bool
    var shape: CursorShapeParam
}

// ---- 整个 tab 的渲染表面 ----
struct PaneSurfaceFrame {
    var bootId: String
    var projectionRevision: UInt64
    var surfaceRevision: UInt64
    var frame: FrameData                 // 合成的整屏 cell
    var panes: [PaneSurfacePane]         // 每个 pane 的矩形
    var splits: [PaneSurfaceSplit]       // 分隔条
    var popup: ClientShellPopupSurface?
    var graphics: SurfaceGraphicsScene
}

struct PaneSurfacePane {
    var paneId: String
    var contentRevision: UInt64
    var rect: SurfaceRect                // 外框（含边框）
    var innerRect: SurfaceRect           // ← 内容区，实际用它
    var scrollbarRect: SurfaceRect?
    var scroll: PaneSurfaceScrollMetrics?
    var focused: Bool
    var mouseReporting: Bool             // ← 决定是否合成鼠标事件
    var sgrPixelMouse: Bool
    var alternateScreenActive: Bool
    var pixelWidth: UInt32
    var pixelHeight: UInt32
}

// ---- 侧边栏数据 ----
struct ClientShellSnapshot {
    var bootId: String
    var revision: UInt64
    var focusedWorkspaceId: String?
    var focusedTabId: String?
    var focusedPaneId: String?
    var workspaces: [ClientShellWorkspace]
    var tabs: [ClientShellTab]
    var panes: [ClientShellPane]
    var agents: [ClientShellAgent]
    var agentOrder: [String]
    var tabBarRight: [ClientShellTabStatusSegment]
    var tabBarRightSeparator: String
    var commands: [ClientShellCommand]
    // 其余：configDiagnostic / productAnnouncement / updateAvailable /
    //       serverKeybindingsToml / releaseNotes / worktreeDirectory ...
}

struct ClientShellWorkspace {
    var workspaceId: String
    var activeTabId: String
    var newWorkspaceCwd: String
    var number: Int
    var label: String
    var customLabel: Bool
    var branch: String?
    var gitAheadBehind: (Int, Int)?
    var tokens: [(String, String)]
    var worktree: ClientShellWorktree?
    var focused: Bool
    var agentStatus: AgentStatus
}

struct ClientShellAgent {
    var paneId: String
    var workspaceId: String
    var tabId: String
    var name: String?
    var displayAgent: String?
    var agent: String?                   // "pi" / "claude" / "codex" ...
    var title: String?
    var terminalTitle: String?
    var terminalTitleStripped: String?
    var agentStatus: AgentStatus
    var stateChangeSeq: UInt64
    var stateLabels: [(String, String)]
    var tokens: [(String, String)]
    var focused: Bool
}

enum AgentStatus: String {
    case idle, working, blocked, done, unknown
}
```

### 3.3 颜色编码（易错点）

`fg` / `bg` 是 `u32`，**不是 ARGB**：

```
命名色     0 .. 16          （索引调色板 0–16）
索引色     0x01_00_00_XX     （XX = 0..255）
24-bit RGB 0x02_RR_GG_BB     （注意不是 0xAARRGGBB）
```

### 3.4 输入事件

```swift
enum ClientPaneInputEvent {
    case key(code: ClientKeyCode, modifiers: UInt8, kind: ClientKeyKind,
             repeatCount: UInt16, shiftedCodepoint: UInt32?,
             generatedText: String?, tracksRelease: Bool,
             physicalKeyId: UInt32?, windowsRecord: WindowsKeyRecord?)
    case textCommit(String)     // ← 软键盘 / IME 用这个
    case mouse(kind: ClientMouseKind, position: ClientMousePosition,
               geometry: ClientMouseGeometry?, modifiers: UInt8, lines: UInt16)
    case paste(String)
}

enum ClientKeyCode {         // 顺序即编码
    case backspace, enter, left, right, up, down, home, end,
         pageUp, pageDown, tab, backTab, delete, insert, esc,
         char(Character), f(UInt8), null
}

enum ClientMouseKind {
    case down(ClientMouseButton), up(ClientMouseButton), drag(ClientMouseButton),
         moved, scrollUp, scrollDown, scrollLeft, scrollRight
}

enum ClientMousePosition {
    case cell(column: UInt16, row: UInt16)
    case pixels(x: UInt32, y: UInt32, column: UInt16, row: UInt16)
}
```

**`down(.right)` 就是右键**，可以直接合成。

### 3.5 API 请求（40 个方法，来自 welcome.methods）

```
client_shell.surface.set    command.invoke             integration.install
integration.list            layout.set_split_ratio     pane.clear
pane.close                  pane.copy_motion           pane.copy_search
pane.edit_scrollback        pane.focus                 pane.focus_direction
pane.input.set              pane.link.activate         pane.link.resolve
pane.rename                 pane.resize                pane.scroll
pane.selection.read         pane.split                 pane.swap
pane.zoom                   product_announcement.dismiss
release_notes.dismiss       server.reload_config       tab.close
tab.create                  tab.focus                  tab.move
tab.rename                  workspace.close            workspace.create
workspace.focus             workspace.move             workspace.move_block
workspace.rename            worktree.create            worktree.list
worktree.open               worktree.remove
```

请求走 `ClientShellEndpointRequest{boot_id, request}`（tag 15），`request` 是 JSON 字符串：

```json
{"id":"r1","method":"tab.create","params":{"label":"logs"}}
```

响应走 `ClientShellEndpointResponseChunk{boot_id, request_id, final_chunk, data}`（tag 18），可能分多块。

**注意**：方法名以 welcome 返回的为准，服务端会校验。实测直接调 `pane.list` 会返回 `unsupported_method`——因为 `pane.list` 属于 JSON API，不在 endpoint 的 40 个方法里。pane 列表从 snapshot 拿。

---

## 4. 渲染架构

### 4.1 分层

```
┌─────────────────────────────────────────────────────┐
│  SwiftUI 外层                                        │
│  ┌──────────┬────────────────────────────────────┐  │
│  │ Sidebar  │  TabBar                            │  │
│  │ (native) ├────────────────────────────────────┤  │
│  │          │  PaneLayoutView (按 inner_rect 摆) │  │
│  │          │  ┌──────────┬──────────┐           │  │
│  │          │  │ Ghostty  │ Ghostty  │           │  │
│  │          │  │ Surface  │ Surface  │           │  │
│  │          │  └──────────┴──────────┘           │  │
│  └──────────┴────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 4.2 pane 内容：Ghostty `InMemoryTerminalSession`

```swift
import GhosttyTerminal

final class PaneTerminal: ObservableObject {
    let session: InMemoryTerminalSession
    let state = TerminalViewState()
    private let channel: SSHChannel

    init(paneID: String, channel: SSHChannel, cols: Int, rows: Int) {
        self.channel = channel
        self.session = InMemoryTerminalSession(
            write: { data in
                // ghostty 要发给 PTY 的字节 → 通过 SSH 送回去
                channel.write(data)
            },
            resize: { vp in
                // 网格尺寸变了 → 通知 herdr
                // endpoint: ClientShellEndpointRequest pane.resize
                // 或 terminal control 的 terminal.resize
            }
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    }

    func feed(_ data: Data) { session.receive(data) }   // ← herdr ANSI 从这里进来
}

struct PaneView: View {
    @ObservedObject var pane: PaneTerminal
    var body: some View {
        TerminalSurfaceView(context: pane.state)
    }
}
```

**关键点**：
- `receive()` 只入队，不阻塞；解析在内部 worker 上
- `write` 闭包是 ghostty → 外部的唯一出口（按键、粘贴、鼠标编码后的字节）
- `resize` 闭包必须实现，否则尺寸不同步
- 隐藏的 pane 设 `terminal.isSurfaceVisible = false`（保留 grid/scrollback，只停渲染）

### 4.3 分屏布局

从 `PaneSurface.panes[].innerRect` 得到每个 pane 的内容区，按比例换算到 SwiftUI 坐标：

```swift
func layout(_ surface: PaneSurfaceFrame, in size: CGSize) -> [PaneID: CGRect] {
    let cols = CGFloat(surface.frame.width)
    let rows = CGFloat(surface.frame.height)
    return surface.panes.reduce(into: [:]) { acc, p in
        let r = p.innerRect          // ← 用 innerRect，不是 rect
        acc[p.paneId] = CGRect(
            x: CGFloat(r.x) / cols * size.width,
            y: CGFloat(r.y) / rows * size.height,
            width: CGFloat(r.w) / cols * size.width,
            height: CGFloat(r.h) / rows * size.height
        )
    }
}
```

**为什么用 `innerRect`**：实测 `rect` 含 1 格边框，`innerRect` 才是内容区。直接把 `innerRect` 的 `w`/`h` 用作 `TerminalHello` 的 `cols`/`rows`。

> ⚠️ `ui.pane_borders` 可配置为 `auto` / `always` / 永不画。**不要假设 inset 恒为 1**，必须读 `innerRect`。

### 4.4 为什么 pane 用 Ghostty 而不是自己画 cell

| | Ghostty 渲染 | 自己画 cell 网格 |
|---|---|---|
| 开发量 | ~0（接线即可） | 巨大（字形图集、宽字符、emoji、box drawing、下划线、光标、图片协议） |
| 质量 | = Ghostty 本体 | 需要追赶多年 |
| IME / 选择 / 复制 | 白送 | 要自己写 |
| 触摸滚动 | 白送（`TerminalSurface+TouchSelection`） | 要自己写 |
| kitty graphics | 白送 | 要自己写（协议很复杂） |
| 分屏几何 | 需要 endpoint 配合 | 协议直接给 |

**实测验证**：herdr 输出的 ANSI 喂给标准 VT 解析器（pyte），与 herdr 自己渲染的 cell 网格**逐字节 36/36 行完全一致**。所以 Ghostty 渲染的结果与桌面端 herdr 一致。

### 4.5 为什么侧边栏用 SwiftUI 而不是 cell 绘制

herdr 的 TUI 侧边栏是用 ratatui 画字符画出来的。我们不需要像素级还原，而是**用原生控件做出更好的体验**：

- 原生滚动（`ScrollView` + 惯性 + 橡皮筋）
- 原生手势（滑动删除 workspace、长按菜单）
- 原生辅助功能（VoiceOver、动态字体、深色模式）
- iPad 上可以用 `NavigationSplitView` 三栏

数据来自 `shell.snapshot.v1`，字段齐全（见 §3.2）。

---

## 5. 侧边栏布局引擎（config.toml 兼容）

### 5.1 配置语法

herdr 的 `config.toml` 支持二维行布局：

```toml
# Spaces（workspace 列表）—— 默认值
ui.sidebar.spaces.rows = [["state_icon", "workspace"], ["branch", "git_status"]]

# Agents 列表 —— 默认值
ui.sidebar.agents.rows = [["state_icon", "machine", "workspace", "tab"], ["agent"]]

# 按 agent 类型覆盖
ui.sidebar.agents.rows_by_agent = { claude = [["state_icon", "agent"]], codex = [...] }

# 行间距
ui.sidebar.agents.row_gap = 0
ui.sidebar.spaces.row_gap = 0
```

**可用 token**（来自 `src/config/sidebar.rs`）：

```swift
enum AgentSidebarToken {
    case stateIcon, stateText, machine, workspace, tab, pane, agent
    case terminalTitle, terminalTitleStripped
    case custom(String)          // $metadata_key
    case styled(inner: AgentSidebarToken, style: TokenStyle, rules: [StyleRule])
}

enum SpaceSidebarToken {
    case stateIcon, stateText, workspace, branch, gitStatus
    case custom(String)
    case styled(inner: SpaceSidebarToken, style: TokenStyle, rules: [StyleRule])
}
```

**条件样式规则**：

```toml
ui.sidebar.agents.rows = [
  ["state_icon", { token = "agent", bold = true, fg = "red", rules = [
      { contains    = "claude", fg = "purple" },
      { equals      = "codex",  fg = "green"  },
      { starts_with = "pi",     dim = true    },
  ]}]
]
```

**条件是内联键**，不是 `{ when = "...", value = "..." }`。上游 `RawRule` 是
`deny_unknown_fields`（`src/config/sidebar/rules.rs`），用后一种写法写的规则一条也不会生效 ——
Kraal 曾经按那种写法解析，导致照官方文档写的 `config.toml` 里 rules 被静默忽略。

支持的条件：`equals` / `contains` / `starts_with` / `gt` / `lt`，每条规则**恰好一个**；
文本条件可加 `ignore_case`（仅 ASCII），数值条件不允许。
可选 `hide = true`：命中的 token 连同它的分隔符一起从行里消失。
只应用**第一条**命中的规则，它只覆盖自己设置的字段，其余继承 token 的默认样式。
上限：**16 行 × 每行 16 token × 16 条规则**。

### 5.2 数据驱动设计

**核心原则：UI 层只认规格，不认来源。**

```swift
// 引擎输出
struct SidebarRowSpec {
    var tokens: [SidebarTokenSpec]
}
struct SidebarTokenSpec {
    var kind: SidebarTokenKind
    var baseStyle: TokenStyle               // fg / bold / dim
    var rules: [StyleRule]
}

// 三个来源 → 同一个规格
enum SidebarSpecSource {
    case builtin(SidebarKind)               // 硬编码默认
    case toml(TOMLTable)                    // 解析 ui.sidebar.*
}

func resolveSpec(_ source: SidebarSpecSource) throws -> [SidebarRowSpec]
```

**渲染层**（SwiftUI）：

```swift
struct SidebarRowView: View {
    let spec: SidebarRowSpec
    let context: RowContext      // workspace/agent 的数据 + 主题

    var body: some View {
        VStack(alignment: .leading, spacing: spec.rowGap) {
            ForEach(spec.tokens.indices, id: \.self) { i in
                tokenView(spec.tokens[i], context)
            }
        }
    }
}
```

这样：
- 默认布局也是数据（不是 if-else 分支）
- TOML 解析器独立可测
- 未来加新 token 只改 `tokenView` 的一个 case

### 5.3 配置来源

herdr 的配置在**客户端本地**（`~/.config/herdr/config.toml`），不在服务端。iOS 上需要：

1. **iCloud Drive 同步**（`~/.config/herdr/config.toml` → iCloud 容器）
2. **手动导入**（文件选择器）
3. **从 SSH 读远端**（`ssh host cat ~/.config/herdr/config.toml`）—— 只有用户明确要求时

第一版做 2 + 3，第二版做 1。

### 5.4 命令面板

`snapshot.commands` 里是用户在 config.toml 定义的自定义命令。实测：

```json
[
  {"command_id":"cmd_..._1_0","binding_label":"prefix+f",
   "action":"PluginAction","description":"Port Forward: Add / open panel"},
  {"command_id":"cmd_..._1_1","binding_label":"prefix+shift+f",
   "action":"PluginAction","description":"Port Forward: List forwards"}
]
```

通过 `command.invoke`（40 个方法之一）执行。**这是免费的自定义命令面板。**

---

## 6. 输入与交互

### 6.1 两条输入路径

| 路径 | 协议 | 延迟 | 用途 |
|---|---|---|---|
| **annssi attach channel** | `ClientMessage::Input{data}`（tag 1，纯字节） | 最低 | pane 内的键盘输入 |
| **endpoint** | `ClientPaneInputEvent`（tag 13） | 有排队 | 需要语义时（鼠标、粘贴、特殊键） |

**推荐**：键盘输入走 attach channel（`ClientMessage::Input`），因为它是纯管道，不受 endpoint 的 `permits_partial_input` 排队影响（herdr-gpui 正是在这里踩了 155ms 的坑，见其 issue #583）。

鼠标/右键走 endpoint，因为需要 `ClientPaneInputEvent::Mouse` 的语义化坐标。

### 6.2 键盘

iOS 软键盘 → `TextCommit(String)` 或 `ClientMessage::Input{data: utf8}`。

**注意 IME**：中文/日文输入法在 composition 阶段不应发送，等确定后再发。ghostty 的 `TerminalSurface` 已处理 `preedit`/`markedText`，走它的 `sendKey` / `paste` API 即可。

### 6.3 鼠标合成（右键 / 点击 / 拖拽 / 滚轮）

```swift
// 右键菜单
func rightClick(at cell: (UInt16, UInt16), in pane: PaneSurfacePane) {
    guard pane.mouseReporting else {
        // pane 没开鼠标上报 → 调 herdr 自己的 pane 菜单
        // endpoint: command.invoke 或 pane 相关方法
        return
    }
    let kind = ClientMouseKind.down(.right)
    let pos = ClientMousePosition.cell(column: cell.0, row: cell.1)
    send(.mouse(kind: kind, position: pos, geometry: nil, modifiers: 0, lines: 0))
    send(.mouse(kind: .up(.right), ...))
}
```

**`pane.mouseReporting` 决定行为**：
- `true` → 应用自己处理鼠标（vim、tmux、herdr 的 TUI），我们转发
- `false` → Herdr/应用不处理，我们显示原生菜单

`pane.sgrPixelMouse == true` 时用 `ClientMousePosition.pixels` 提供更高精度。

### 6.4 分屏拖拽

`PaneSurface.splits[]` 给了 `hitRect`（可拖拽区域）和 `pos`（分隔条位置）。

```swift
// 拖拽结束
let newRatio = clamp(dragPosition / totalSize, 0.1, 0.9)
// endpoint: layout.set_split_ratio { tab_id, path, ratio }
```

`path: Vec<bool>` 是 BSP 树的路径（true=first, false=second），从 split 的 `path` 字段直接拿。

### 6.5 iOS 触摸映射

| 触摸手势 | 映射 |
|---|---|
| 单击 | `Mouse.down(.left)` + `up(.left)` |
| 双击 | 两次 click，或 ghostty 的选择扩展 |
| 长按 | 右键（`down(.right)`）或原生选择菜单 |
| 双指滑动 | `Mouse.scrollUp/Down`（ghostty 自带 momentum） |
| 捏合 | 字号缩放（本地，不发给远端） |

ghostty 的 `TerminalSurface+TouchSelection.swift` 已实现大部分，我们复用。

---

## 7. iOS / macOS 差异处理

### 7.1 尺寸协商

**实测确认**：每条 endpoint 连接独立协商 `surface_size`，互不影响。

```
[A] 120x40 → surface cells=4800
[B]  80x24 → surface cells=1920
```

所以 iOS（窄）和 macOS（宽）可以各自用适合自己的尺寸。

但**注意**：`ClientShellPaneInput` 会触发 `promote_client_to_foreground` + `claim_shell_tab_geometry`，即**发输入的那条连接会夺取 tab 尺寸所有权**。所以：

- 单一客户端时无影响
- 多客户端（macOS + iOS 同时连）时，谁打字谁决定尺寸

产品层要处理：iOS 上打字会让 macOS 的终端 resize。**建议**：在 iOS 上默认用「只读 + 按需接管」模式，用户点「接管」才发输入。

### 7.2 iPad vs iPhone 布局

| | iPhone | iPad | Mac |
|---|---|---|---|
| 侧边栏 | 抽屉（`sheet` / 滑动） | 固定栏（可折叠） | 固定栏 |
| 分屏 pane | 单 pane 全屏 + 切换器 | 按 `innerRect` 真实分屏 | 按 `innerRect` |
| 宽高比 | 窄，建议强制单列 | 灵活 | 灵活 |
| 键盘 | 软键盘 + 工具栏 | 硬件键盘 | 硬件键盘 |

**iPhone 上显示真实分屏没有意义**（宽度不够），改为「一次一个 pane + 顶部切换器」，但数据层仍然完整（知道有多少 pane、哪个 focused）。

### 7.3 macOS 特殊能力

- **本地连接**：`~/.config/herdr/herdr-client.sock` 直连，无需 SSH
- **ControlMaster**：可以复用系统 ssh 的连接
- **多窗口**：`WindowGroup` 支持多窗口，每个窗口不同 tab
- **菜单栏 / 快捷键**：完整 `Commands` 支持

### 7.4 后台与推送（Phase 2）

iOS 进后台约 5s 后挂起，`beginBackgroundTask` 实测只有 **25–30s**。所以：
- 后台不保活长连接
- 「agent blocked 时通知」需要 APNs relay（主机侧插件加密 → relay 转发密文 → App 解密）
- 第一版不做，App 前台时全功能

---

## 8. 状态管理

### 8.1 状态机

```swift
enum ConnectionState {
    case idle
    case connecting(progress: ConnectProgress)
    case handshaking
    case awaitSnapshot
    case live(Snapshot, Surface?)       // ← 正常态
    case reconnecting(attempt: Int, nextRetry: Date)
    case failed(Error)
}

enum ConnectProgress {
    case sshAuth
    case spawningBridge
    case handshake
    case receivingSnapshot
}
```

### 8.2 数据流（单向）

```
SSH channel bytes
      │
      ▼
FrameDecoder  ──►  ServerMessage
      │
      ▼
ProtocolClient (actor)  ──►  events
      │
      ▼
AppStore (@MainActor)  ──►  @Published state
      │
      ▼
SwiftUI Views
```

`ProtocolClient` 是 actor，保证帧解码串行；`AppStore` 在主线程，SwiftUI 直接订阅。

### 8.3 每个 pane 的独立状态

```swift
@MainActor
final class PaneModel: ObservableObject {
    let paneId: String
    var terminal: PaneTerminal            // ghostty
    var lastFrameAt: Date
    var isConnected: Bool
}
```

`AppStore` 持有 `[PaneID: PaneModel]`，pane 关闭时销毁（释放 SSH channel + ghostty surface）。

---

## 9. 目录结构

```text
Kraal/
├── Package.swift
├── Sources/
│   ├── KraalProtocol/               # 纯协议层，零 UI 依赖，可单测
│   │   ├── Wire.swift              # 21+21 枚举、所有 struct
│   │   ├── Bincode.swift           # varint + 编解码
│   │   ├── Frame.swift             # u32 长度帧
│   │   ├── Surface.swift           # PaneSurfaceFrame / Patch 校验
│   │   └── Endpoint.swift          # hello / welcome
│   ├── KraalTransport/             # SSH + 连接管理
│   │   ├── SSHClient.swift
│   │   ├── BridgeChannel.swift
│   │   ├── TerminalChannel.swift
│   │   └── ReconnectPolicy.swift
│   ├── KraalClient/                # 高层客户端
│   │   ├── ConnectionManager.swift  # 状态机
│   │   ├── ProtocolClient.swift   # actor
│   │   ├── SnapshotStore.swift
│   │   └── APIRequest.swift       # 40 个方法
│   ├── KraalSidebar/               # 侧边栏引擎
│   │   ├── SidebarSpec.swift       # 数据模型
│   │   ├── TOMLParser.swift        # config.toml
│   │   ├── TokenResolver.swift     # token → 文本
│   │   └── StyleRules.swift
│   └── KraalUI/                    # SwiftUI
│       ├── SidebarView.swift
│       ├── TabBarView.swift
│       ├── PaneLayoutView.swift
│       ├── PaneView.swift          # ghostty 包装
│       └── CommandPalette.swift
├── Tests/
│   ├── KraalProtocolTests/
│   │   ├── BincodeTests.swift
│   │   ├── FrameDecodeTests.swift  # 用真实抓包做 fixture
│   │   └── SurfacePatchTests.swift
│   └── KraalSidebarTests/
│       └── TOMLParserTests.swift
└── Fixtures/
    ├── welcome.json                # 真实 welcome
    ├── snapshot.json               # 真实 snapshot
    ├── surface_120x40.bin          # 真实首帧
    └── captured.ansi               # 真实 ANSI 帧
```

**关键设计**：`KraalProtocol` 零依赖，可以在 Linux CI 上跑测试。`KraalUI` 只依赖 `KraalClient` 和 GhosttyKit。

---

## 10. 实施计划

### M0：协议内核（3–5 天）

- [ ] `Bincode.swift`：varint 读写
- [ ] `Frame.swift`：u32 长度帧
- [ ] `Wire.swift`：21+21 枚举 + 全部 struct
- [ ] `Endpoint.swift`：hello/welcome
- [ ] `Surface.swift`：FrameData / PaneSurfaceFrame / Patch
- [ ] 单测：用真实抓包 `surface_120x40.bin` 解码，断言 cells 数 = 4800，文本内容匹配

**验收**：`swift test` 全绿，且能把 fixture 解码成正确文本。

### M1：连接与握手（2–3 天）

- [ ] `SSHClient`：libssh2 封装（或 swift-nio-ssh）
- [ ] `BridgeChannel`：exec `remote-client-bridge` + 握手
- [ ] `ProtocolClient` actor：帧循环、事件分发
- [ ] macOS 本地 socket 支持（不经 SSH）

**验收**：macOS 上连本机，打印出 snapshot 的 workspace 列表 + surface 的 40 行文本。

### M2：Ghostty 渲染（3–5 天）

- [ ] 集成 `libghostty-spm`
- [ ] `TerminalChannel`：exec `terminal session control`，收 ANSI
- [ ] `PaneTerminal`：`InMemoryTerminalSession` 接线
- [ ] 单 pane `TerminalSurfaceView` 显示

**验收**：macOS 上显示一个真实 pane，能打字、能滚动。

### M3：布局与侧边栏（1–2 周）

- [ ] `PaneLayoutView`：按 `innerRect` 摆 N 个 ghostty view
- [ ] `SidebarView`：workspace / agent 列表
- [ ] `TabBarView`
- [ ] 状态管理（AppStore）

**验收**：macOS 上完整复现 herdr 的一屏，侧边栏可点、可切换。

### M4：侧边栏配置引擎（3–5 天）

- [ ] TOML 解析
- [ ] token 解析（16 个）
- [x] rules 条件样式（内联条件键 + `ignore_case` + `hide`，见 §5.1）
- [ ] `rows_by_agent` 覆盖

**验收**：导入一个自定义 config.toml，侧边栏布局随之变化。

### M5：交互（1 周）

- [ ] 鼠标合成（右键 / 点击 / 拖拽 / 滚轮）
- [ ] 分屏拖拽（`layout.set_split_ratio`）
- [ ] 命令面板（`command.invoke`）
- [ ] 快捷键

**验收**：能用鼠标操作 pane 内的 vim，能拖动分屏。

### M6：iOS 适配（1–2 周）

- [ ] libssh2 单 session 多 channel
- [ ] iPhone 单 pane 模式 + 切换器
- [ ] 软键盘 + 工具栏
- [ ] 触摸手势映射
- [ ] iPad 分屏

**验收**：iPhone 上连远端 herdr，能看 agent 状态、能发 prompt。

### M7：打磨（持续）

- [ ] 重连与错误恢复
- [ ] 性能优化（滚动、大 surface）
- [ ] 主题（`theme.custom.*` 的 61 个 token）
- [ ] APNs 推送（Phase 2）

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **herdr 上游协议变更** | 高 | 协议层独立包 + fixture 回归测试；welcome 的 generation 协商；忽略未知字段 |
| **ghostty 的 ANSI 兼容性** | 中 | 已实测 36/36 行一致；用 pyte 做交叉验证的自动化测试 |
| **libssh2 多 channel 并发** | 中 | **待验证**（见 §12）；备选：每 pane 一次握手 |
| **takeover 冲突** | 高 | 桌面端已 attach 时，iOS 要么抢、要么只读（只读被拒）；需产品化提示 |
| **iOS 后台断连** | 中 | 明确告知用户；Phase 2 加推送 |
| **`innerRect` 与边框配置** | 低 | 不硬编码 inset，读 `innerRect` |
| **大 surface 性能** | 中 | 关闭 `surface_reuse/delta/scroll` 先跑通；后续开启；按需 `client_shell.surface.set active=false` 冻结非活跃 tab |

---

## 12. 待验证清单

| # | 项 | 方法 | 影响 |
|---|---|---|---|
| 1 | libssh2 单 session 开 6 个 exec channel 并发 | 写 Swift/Python 测试 | 决定 iOS 是 1 次还是 N 次握手 |
| 2 | `terminal session control` 的 `--cols/--rows` 是否改远端 PTY | 远端起 `tput cols` 观测 | 影响桌面端尺寸 |
| 3 | 三个 optional codec 开启后的收益 | 对比 patch 大小 | 优化项 |
| 4 | Ghostty `InMemoryTerminalSession` 喂 herdr ANSI 的实际渲染 | 跑通 M2 | 核心假设，已在 pyte 上验证 |

---

## 附录 A：实测数据速查

### A.1 时间

| 操作 | 本机 socket | 远程 SSH（局域网） |
|---|---|---|
| enable → welcome | 22 ms | ~50 ms |
| → snapshot | 22 ms | ~50 ms |
| → PaneSurface | 67 ms | **224 ms** |
| PaneSurfacePatch | 0.06 ms | ~10 ms |

### A.2 体积

| 数据 | 大小 |
|---|---|
| welcome | 1,054 B |
| snapshot（12 ws / 15 panes / 7 agents） | 11,791 — 15,349 B |
| PaneSurface 120×40 | 70,608 — 73,521 B |
| PaneSurfacePatch | 66 B |
| ANSI 首帧（60×40 pane） | 1,404 — 2,746 B |
| ANSI 增量 | ~250 B |

### A.3 ANSI 序列分布（典型帧）

```
[18;40H      ×2      CUP
[?25h        ×2      光标显示
[?2026h      ×1      同步输出开始
[?25l        ×1      光标隐藏
]8;;\x1b\\   ×1      OSC 8 超链接
[2J          ×1      清屏
[0;38;2;...  ×1      24-bit RGB
```

全部是标准 VT 序列，无私有扩展。

---

## 附录 B：关键源码索引

| 内容 | 路径 |
|---|---|
| wire 类型（21+21 枚举 + 全部 struct） | `herdr-gpui/crates/herdr-protocol/src/wire.rs`（697 行） |
| bincode 编解码 | `herdr-gpui/crates/herdr-protocol/src/codec.rs`（79 行） |
| 握手类型 | `herdr-gpui/crates/herdr-protocol/src/endpoint.rs`（64 行） |
| surface patch 校验 | `herdr-gpui/crates/herdr-protocol/src/frame.rs`（90 行） |
| optional codec | `herdr-gpui/crates/herdr-protocol/src/surface_{delta,scroll,reuse}.rs` |
| SSH bridge 脚本 | `herdr-gpui/crates/herdr-client/src/ssh.rs` |
| 生产超时参数 | `herdr-gpui/crates/herdr-client/src/limits.rs` |
| 连接 worker 循环 | `herdr-gpui/crates/herdr-client/src/session.rs`（910 行） |
| 客户端输入策略（那个 155ms 的 bug） | `session.rs::permits_partial_input` |
| herdr 侧边栏配置 | `herdrdev/herdr: src/config/sidebar.rs`（729 行） |
| herdr 侧边栏 token 定义 | 同上 `AgentSidebarToken` / `SpaceSidebarToken` |
| herdr ANSI 渲染器 | `herdrdev/herdr: src/protocol/render_ansi.rs`（2,493 行） |
| 输入丢弃条件 | `herdrdev/herdr: src/server/headless/client_views.rs:493` `shell_client_views_pane` |
| endpoint 握手处理 | `herdrdev/herdr: src/server/client_transport.rs:670` |
| 上游溯源与许可证 | `herdr-gpui/crates/herdr-protocol/NOTICE.md` |

---

## 附录 C：许可证

- **herdr**（`herdrdev/herdr`）：Apache-2.0
- **herdr-gpui**（`penso/herdr-gpui`）：Apache-2.0，协议实现基于 herdr 0.9.1 commit `856b64b`
- **libghostty-spm**（`Lakr233/libghostty-spm`）：MIT（注意：曾静态链入 LGPL 的 libintl，1.6.x 后以 `-Di18n=false` 修复，需审查具体版本）
- **Ghostty**：MIT（core），其 shell integration 脚本是 GPLv3（`libghostty-spm` 特意自带 MIT 版本）

我们照抄协议实现时，需在 NOTICE 中保留 herdr / herdr-gpui 的 Apache-2.0 归属。
