# Kraal 2：对齐 herdr-core（Herdr 2）

> 决策：2026-11-02 · 依据 herdr-core `0.1.16`（本机实测）、herdr-app `0.1.11`、
> 协议 generation 1。本文是**目标**，执行拆单见 issue 与 [ROADMAP.md](ROADMAP.md)。

---

## 0. 一句话

Kraal 从「Herdr 1 的另一种客户端」改成「**herdr-core 的 Swift 原生客户端**」：
服务端只认 `hc`，布局归客户端，终端字节用 Ghostty 原生渲染，行为对齐官方
`herdr-app`；我们保留的差异只有 **Swift/AppKit/SwiftUI + Ghostty + 不做 JS mods**。

---

## 1. 为什么必须换：两代架构不是同一件事

| | Herdr 1（Kraal 现在） | Herdr 2（herdr-core + herdr-app） |
|---|---|---|
| 服务端 | daemon 持有 workspace/tab/pane 与**合成后的屏幕** | `hc` 只是终端运行时：**扁平终端列表**，不画、不布局 |
| 协议 | 自定义 bincode，`herdr-client.sock`，一条连接一个命令 | **JSON-RPC 2.0**（一行一条）；`hello{framed:true}` 后二进制帧 |
| 画面 | 服务端发 cell 网格 + patch，客户端重编码成 ANSI | 服务端发**程序原始 PTY 字节**，客户端自己跑 VT |
| 布局 | 服务端权威，客户端只读 | **客户端权威**，存进 core 的 `doc`（每台机器一份） |
| 远端 | 自己起 SSH 桥 + `herdr remote-client-bridge` | core 自己 SSH：`machine add` → 终端地址 `machine/t7` |
| Agent 状态 | 服务端识别 + 快照字段 | 只认程序自报的 **OSC 7501**；不再猜屏幕 |
| 参考实现 | herdr / herdr-gpui / rootshell / Rex | 只有 `herdr-core` + `herdr-app` |

结论：**旧的协议层、屏幕合成层、服务端布局模型整体作废**，不是改字段能救的。
官方也明确写了 Herdr 2 是 fresh code（`herdr-core/AGENTS.md`），不从 Herdr 1 抄。

---

## 2. 目标架构

```
                    ┌──────────────────────────────┐
   Kraal (Swift)    │  SwiftUI chrome              │  spaces / tabs / panes / sidebar
                    │  ─────────────────────────   │
                    │  HcClient (JSON-RPC + framed)│  hello / events / doc / machine
                    │  ─────────────────────────   │
                    │  Ghostty (libghostty-spm)    │  raw VT in / key bytes out
                    └──────────────┬───────────────┘
                                   │ unix socket  (HC_SESSION / HC_SOCKET)
                          ┌────────▼────────┐
                          │  herdr-core hc  │  终端、PTY、OSC 7501、doc、machines
                          └────────┬────────┘
                                   │ ssh <target> hc connect（core 自己做）
                            ┌──────┴──────┐
                        远程机器 core   远程机器 core
```

- **本地**：一条 unix socket 连接（`~/.local/state/herdr-core/<session>/<session>.sock`；
  也接受 `HC_SOCKET` / `HC_SESSION`）。没有 IPC 兼容层、没有双协议。
- **远端**：Kraal **不实现 SSH 桥**。机器是 core 的概念：`machine.add` 之后，
  远端终端以 `machine/t7` 出现在同一条 `terminal.list` / `events` 里。
  唯一例外是 **iOS / 未纳管的 core**：用 `ssh host hc connect`（纯字节管道）作为传输。
- **布局**：Kraal 自己持有 space/tab/pane 树；持久化到 core 的
  `doc {name:"herdr-app"}`（与官方客户端同一份），每台机器一份。
- **渲染**：`terminal.attach` 的 DATA 直接写进 Ghostty；滚动、选择、链接、鼠标模式、
  kitty graphics 全部由 Ghostty 负责。不再有 cell→ANSI、diff、图形编码。

---

## 3. 仍是我们自己的东西（刻意保留的差异）

1. **Swift / AppKit / SwiftUI**：原生窗口、菜单栏、多窗口、系统集成。
2. **Ghostty**：与官方同源（libghostty），但用 `libghostty-spm` 的 Swift API。
3. **不做 JS mods**：官方把面板/菜单/对话框都交给 mods；Kraal 用原生 SwiftUI 实现
   同一批能力（侧栏、tab 栏、命令面板、设置、帮助）。这是产品差异，不是缺口。
4. **iOS**：同一份模型 + `ssh hc connect`，这是官方 app 没有的形态。

---

## 4. 硬性决策

**D1 · 单一协议。** 只支持 herdr-core generation 1。不保留 Herdr 1 兼容层，
不读旧 socket，不做迁移桥。旧 daemon 用户不在支持范围内。

**D2 · 布局归客户端。** core 没有 workspace/tab/split 概念，Kraal 自己建模
（`Space` / `Tab` / `Node` 树）。不再向服务端查询「布局」。

**D3 · 与官方共享布局文档。** 读写 `doc name="herdr-app"`，使用官方 schema
（[`app/src/mirror.rs`](https://github.com/herdrdev/herdr-app/blob/master/src/mirror.rs)
的 `Document { spaces: [{id,name,folder,tabs:[{id,name,root:Node}]}] }`）。
Kraal 只**渲染** terminal 内容与 row/column 容器；不认识的内容（mod、float、stack、
外观字段）必须**逐字节原样带回**，不能因为「我们不支持」而丢掉官方客户端的布局。
写用 CAS + 最新胜出，不合并。单屏私有状态（焦点、zoom、settled、recent）存本地
`view.json`，不进共享文档。

> 这条是「对齐官方客户端」最硬的一条：两个客户端连同一台机器时，看到同一组
> space/tab/pane。做不到就退化成「自用格式」，那就不叫对齐。

**D4 · 远端是 core 的 machine，不是我们的 SSH。** 只用 `machine.add/list/connect/
rename/rm`；错误态 `needs_update` / `needs_login` / `unreachable` 原样呈现。
`temporary` 机器不进 UI。iOS 走 `ssh host hc connect`。

**D5 · 渲染是原生 VT。** `attach{ncols,nrows,history}` 的首帧是 VT 重放（CAN 开头、
带 reset prologue、可选 scrollback），后续是原始字节。Kraal 只做三件事：
`receive` 给 Ghostty、把 CREDIT 发回去、把 RESIZE/FOCUS/FACTS 发过去。
**删除** cell 网格、patch、`SurfaceANSIRenderer`、`GraphicsEncoder`、鼠标坐标映射。

**D6 · 状态只信 OSC 7501。** 不做屏幕文本识别、不做 agent 品牌表。
`status` / `records` / `turn` / `reported` 由 core 提供；`herdr.seen` / `herdr.pinned`
标签是跨客户端共享状态，按官方 `docs/labels.md` 的规则读写（只升不降、每个 turn 一次）。

**D7 · 不做 mods。** 文档里出现的 mod 节点保留但不执行；UI 上显示占位。
命令面（`space.*` / `tab.*` / `pane.*` / `agent.*`）对齐官方动作名与参数，
让脚本和 agent 在两边写法一致。

**D8 · 版本门禁。** 连接后 `hello`：generation 必须 = 1；版本低于我们的最低值、
或缺少必需方法（`terminal.run/list/kill/label/attach/keep`、`doc.get/set`、
`events.subscribe`）时，显示 setup 屏并给明确指引，**不尝试降级运行**。

---

## 5. 存量代码：保留 / 删除 / 新增

按文件逐项分类（scout 复核，未实际删除；数字是行数量级）。

| 层 | 处理 | 说明 |
|---|---|---|
| `KraalProtocol` 5.8k | **删 ~5.2k** | Bincode/Wire/Decoder/Encoder/Snapshot/Surface/CellBuffer/GraphicsEncoder/SurfaceANSIRenderer/TerminalInputDecoder 全部作废 |
| 同上 | 留 ~0.6k | `ANSIToHTML`、`GhosttyTheme`、`Frame` 的定长校验思路 |
| `KraalTransport` 1.6k | 改 ~1.0k | `UnixSocket` 直接复用；`HerdrDiscovery` → HC_SESSION/HC_SOCKET 路径规则；SSH 只保留 `hc connect` 一种形态 |
| `KraalModel` 1.0k（新增） | 新增 | 纯 Swift 的 space/tab/pane 模型：命名、焦点历史、split/close/move/zoom/settle、recent、`view.json`；不依赖 AppKit/Ghostty |
| `KraalClient` 1.0k | 重写 | `EndpointConnection` → `HcConnection`（JSON-RPC id + 帧通道 + 流 credit） |
| `KraalSidebar` 1.4k | 删 ~1.0k | `ui.sidebar.*` 规格与 token 解析是 Herdr 1 的；行模型可留 |
| `KraalUI` 18.0k | 改 ~5k / 留 ~11k | 布局视图、cell 画布、滚动条、快捷键快照解析删除；主题/调色板/设置/命令表/侧栏外壳保留改造 |
| `KraalTerminalView` 2.7k | 删 ~2.0k | 裁剪/差分/park/图形编码删除；`InMemoryTerminalSession` 接线保留（`PaneTerminal.swift:549` 就是原始字节入口） |
| `KraalMac` 1.6k | 基本保留 | 启动器、菜单栏、注入缝 |
| `KraalCLI` 1.3k | 重写 | 对齐 `herdr-app ls/status/do/commands/shot`，给 gui.sh 当断言工具 |
| `KraalGUIDriver` 2.7k | **完整保留** | 不依赖仓库内任何 target，AX 驱动与像素断言照样用 |
| `Tests/` 26.2k | 删 ~20k | 协议/表面/侧栏/移植测试随实现删除；几何、主题、调色板、日志成本类测试保留 |

**净效果**：少约 10k 行源码、约 20k 行测试，换一条更薄、更接近官方语义的链路。
性能问题 #192/#193/#49/#50/#54 是「cell→ANSI 编码」这条链的产物，链路消失即消失；
新的预算见 §7 M3。

---

## 6. 对齐清单（验收口径）

「对齐」指行为可观察地一致，不是代码长得像。

| 面 | 必须一致 |
|---|---|
| 模型 | space/tab/pane 的 id、默认命名（space 跟随目录、tab 用序号）、focus 历史、zoom、settle、recent |
| 持久化 | `doc name="herdr-app"` schema、每机器一份、CAS 冲突最新胜出、未知节点原样保留；`view.json` 私有 |
| 终端 | 创建带 `herdr.space`/`herdr.tab` 标签；无标签 worker 不进布局；关闭 pane 结束终端；`keep` 语义 |
| 侧栏 | `working/blocked/done/idle` 判定、priority 顺序、pinned 置顶、子 agent 树、peek、`herdr.seen` 规则 |
| 命令 | `space.new/close/rename/move/select/next/prev`、`tab.*`、`pane.split/close/zoom/focus/go/swap`、`agent.focus/next/prev`、`terminal.open/keep/park/peek/kill/pin` 的名称与参数 |
| 按键 | `keys.json` 段（global/terminal/layout/mod）语义；macOS 默认键位表；`ctrl-alt-shift-escape` 逃生 |
| 机器 | 列表/状态/重命名/移除/添加；`needs_login` 弹出交互终端；远程 space 的 folder 在远端 |
| 终端 UX | 回看上限、滚轮三行、copy-on-select、Cmd-click 链接与 `t7` 地址 peek、Shift 保留给客户端、右键默认菜单、bracketed paste、拖放、kitty graphics、最小对比度 |

---

## 7. 里程碑

每步都以「能验证」结尾；不能验证的不算完成。

**M0 · 能看见一个真实终端（协议 + 渲染）**
JSON-RPC 明文/帧、hello 门禁、attach 原始字节进 Ghostty、CREDIT、RESIZE/FOCUS、
重连重放。判据：`hc run --bg 'printf …'` 起的终端在 Kraal 窗口里显示正确，
改窗口大小后 `hc get` 的 `cols/rows` 跟着变。

> **落地记录（2026-11-02）**：协议层（#223）、attach/Ghostty/窗口（#224）、
> 事件归约（#225）、机器（#226）、共享布局文档层（#227）已完成。
> `make run-hc` 打开 M0 窗口；实测核心侧 `cols/rows` 从 attach 的
> 80×24 变成窗口的 98×38，窗口截图里能看到核心重放的 `APP-MODE`。
> **cell→ANSI 删除没有随 #224 做**：旧窗口仍在使用那条链，删了 main 会红。
> 删除改由 #234 在旧窗口退场时一次完成——这与「不双栈」不矛盾：两条路径是
> 两个入口（`KRAAL_HC=1` 与否），不是同一条路径上的兼容分支。
>
> #225 的 M0 窗口现在只读事件：快照 + `created/labels/status/turn/foreground/
> finished/removed`，`missed` 换快照，15 s heartbeat 缺失时标题显示「core 失联」。
> 录制的真实事件流在 `Tests/KraalHCTests/Fixtures/events.ndjson`。
>
> #226 的机器也归 core：侧栏按 `machine.list` 分组（core 没有机器事件，2.5 s 轮询），
> `temporary` 机器连同其终端隐藏；add/rename/rm/reconnect 走 RPC，
> `needs_login`/`needs_update` 各开一个真实终端跑 `hc machine login|update`。
> 直连 `ssh host hc connect` 拆到 #242，SSH 专项 fixture 拆到 #243。
>
> #227 的文档层：`HcDocumentSync`（CAS、conflict 重读、最新胜出）、
> `HcLayoutDocument`（原始 JSON 编辑，只动 `children`/`size`，未知字段原样
> 带回）。`doc` 事件只带 name/version，模型收到后重读；M0 窗口已加载并打印
> `hc: layout vN spaces=M tabs=K`，渲染与命令留给 #228。
>
> #228 的模型层：`KraalModel` 是纯 Swift（只依赖 Foundation + `KraalHC` 的值类型），
> 规则按官方 `src/model.rs` / `src/layout.rs` 的可观察行为重写：space 跟随第一个
> 终端目录、tab 用序号、焦点历史 32、关 pane 回退到 before、split 同轴复用父容器、
> close 权重归还前邻居、settled tab 被 next/prev 跳过、recent 去重且上限 20。
> 共享文档里的 id 按机器加前缀、写入时 strip；`view.json` 只存 `active_space` /
> `active_tabs` / `tabs`（focused/before/zoomed/settled）。官方 `herdr-app` fixture
> 加载→split→投影后未知字段仍在。
>
> #229 的终端归属：`terminal.run` 的终端带 `herdr.space`/`herdr.tab` 标签；
> 窗口把带标签的终端收养进对应 space/tab，未标标签的 worker 只留在 `hc ls`
> 里，不进布局/侧栏。关闭 pane 先删模型节点再 `terminal.kill`（级联未标标签
> 的子终端），空间/标签组关闭先弹一次确认；`keep:true` 的终端丢程序后由 core
> 原地换 shell，窗口重新 attach；`park` 清标签把 pane 退回 worker。真实 core
> 的 `LiveHcOwnershipTests` 覆盖这条链路并检查共享文档已写回。
>
> #230 的 agents 侧栏：`HcAgentTracker` 只消费终端记录里的 `status`、`turn`、
> `parent` 与 `herdr.seen`/`herdr.pinned`，不读屏幕文本；`done` 用
> `turn > seen_turn` 判定，子 agent 的 `done`/`error` 先降为 `idle`/`blocked`。
> priority 视图按 `blocked > done > working > idle`（父行取子树最高级），
> 还有按 space 分组；pinned 置顶，子 agent 缩进并点击 peek。`herdr.seen` 只在
> 窗口前台且该终端真正显示（当前 tab 的 pane 或 peek）时写，只升不降、同 turn
> 一次；mark unread 写 `turn-1`。blocked 新出现或 busy→quiet 且没在看时给
> toast/系统通知/声音，子 agent 与不属于任何 space 的终端不告警。旧
> `KraalUI` 的 `SnapshotNotices`/agent 解析仍在旧窗口路径上，随 #234 一起删除。
>
> #231 的动作面：`KraalActions` 不是 UI 的副本，而是唯一表；`kraal commands`
> 由它生成，`HcWorkspaceModel.performAction` 只负责把名字翻译成模型调用。菜单与
> ⌘K 面板共用这个 runner，`implementedActions` 之外的 native action 暂时不展示
> （`pane.go/swap`、`terminal.right_click`、主题/缩放等留给后续阶段）；不支持的
> action 保留原因，帮助浮层按官方名字列出。命令面不引 JS mods，`layout.*`/
> `mod.*`/`overlay.*` 永远不在 Kraal 的可执行集合里。
>
> #231 的键位：`keys.json` 与官方同构（`global`/`terminal`/`layout:<name>`/
> `mod:<name>`），Kraal 只执行 global + terminal 两段；layout/mod 段会校验但
> 没有运行时。文件默认在 `~/.config/kraal/keys.json`，坏文件不会覆盖上一份
> 可用绑定；`ctrl-alt-shift-escape` 只恢复键位，不动共享布局。默认表来自
> herdr-app 的 `defaults/keys.macos.json`，`pane.go`/`pane.swap` 已可用。
>
> #231 的分隔条：拖动只改 JSON 的 `size.weight`，两兄弟权重和不变，每侧最小
> 36pt；命中区比 1pt 线宽，AX 可每次调 5%；文档只在手势结束写一次。tab 条用
> SwiftUI drag/drop，落到哪个 tab 就 `tab.move` 到它的 1-based 位置。
>
> #231 的设置只属于本机，不进共享布局：字体、padding、背景透明度、最小对比度
> 走 `TerminalConfiguration` 推到所有 live surface；density 只改侧栏/tab 的
> 垂直 padding；App appearance 改 `NSApp.appearance`；通知声音开关控制
> `NSUserNotification.soundName`。core socket 与 keys 路径只读展示，避免设置页
> 悄悄换掉正在用的 core。
>
> #231 的收尾：`app.zoom_*` 只改设置里的字号；`layout.toggle:sidebar` 是
> `layout.toggle` 的 Kraal 子集（其他 layout 节点仍 unsupported）；F2/shift-F2
> 打开 rename sheet，不把键值当名字。
>
> #232 的第一刀不重画终端：选择/复制/粘贴交给 Ghostty（`copy_to_clipboard`、
> `paste(text:)`），右键菜单只做 AppKit 的壳并回调模型动作；scrollback 用
> Ghostty 的 `scrollback-limit-lines` / `scrollback-limit` 两个键，10,000 行与
> 10 MB 先到为准。Kraal 不解析 VT，也不维护第二份滚动缓冲。
>
> #233 的控制面照 herdr-app 的「一行 JSON、一条连接一个命令」做，不引入
> 第二套 RPC。窗口是唯一写入者：`do` 走 `performAction`，`ls/status` 只是
> 模型投影；创建型动作回读 adopt 后的 id，而不是相信调用方猜的 id。控制
> socket 只在本机，权限 0600；第二个实例发 `{"raise":true}` 后退出。
>
> #231 的分隔条：拖动只改 JSON 的 `size.weight`，两兄弟权重和不变，每侧最小
> 36pt；命中区比 1pt 线宽，AX 可每次调 5%；文档只在手势结束写一次。tab 条用
> SwiftUI drag/drop，落到哪个 tab 就 `tab.move` 到它的 1-based 位置。
>
> #231 的设置只属于本机，不进共享布局：字体、padding、背景透明度、最小对比度
> 走 `TerminalConfiguration` 推到所有 live surface；density 只改侧栏/tab 的
> 垂直 padding；App appearance 改 `NSApp.appearance`；通知声音开关控制
> `NSUserNotification.soundName`。core socket 与 keys 路径只读展示，避免设置页
> 悄悄换掉正在用的 core。
>
> #231 的收尾：`app.zoom_*` 只改设置里的字号；`layout.toggle:sidebar` 是
> `layout.toggle` 的 Kraal 子集（其他 layout 节点仍 unsupported）；F2/shift-F2
> 打开 rename sheet，不把键值当名字。
>
> #232 的第一刀不重画终端：选择/复制/粘贴交给 Ghostty（`copy_to_clipboard`、
> `paste(text:)`），右键菜单只做 AppKit 的壳并回调模型动作；scrollback 用
> Ghostty 的 `scrollback-limit-lines` / `scrollback-limit` 两个键，10,000 行与
> 10 MB 先到为准。Kraal 不解析 VT，也不维护第二份滚动缓冲。
>
> #233 的控制面照 herdr-app 的「一行 JSON、一条连接一个命令」做，不引入
> 第二套 RPC。窗口是唯一写入者：`do` 走 `performAction`，`ls/status` 只是
> 模型投影；创建型动作回读 adopt 后的 id，而不是相信调用方猜的 id。控制
> socket 只在本机，权限 0600；第二个实例发 `{"raise":true}` 后退出。

**M1 · 布局是自己的（模型 + 文档）**
space/tab/pane 树、创建/关闭/拆分/缩放/移动、共享文档读写与透传、私有视图状态。
判据：在官方 `herdr-app` 里建两个 space 三个 tab，Kraal 启动后原样显示；
Kraal 里 split 一次，官方 app 刷新后看到同一个 split；双方同时改，最新的赢且不丢节点。

**M2 · 用起来像官方客户端（UI + agents + terminal UX）**
原生 chrome、命令面、按键、命令面板、设置；OSC 7501 侧栏、seen/pinned、通知；
Ghostty 侧的选择/链接/鼠标/图形。判据：§6 表格逐项过，gui.sh 有对应用例。

**M3 · 可交付（验证 + 清理 + iOS）**
`kraal` CLI 对齐 `herdr-app` 控制面、gui.sh 用例重写、性能基线重录、
旧代码与旧文档清理、iOS 用 `ssh hc connect` 实测。
判据：`verify.sh` 六道门禁全绿；gui.sh 的断言在注入缺陷时会红；
iOS 模拟器连一台远端 core 能显示并输入。

---

## 8. 验证策略

1. **wire 单测**：用 `hc schema` 生成的 OpenRPC + 手写帧 fixture，钉住
   JSON-RPC、帧头、CREDIT、事件 reducer。协议事实以运行中的 `hc` 为准，
   不以文档为准（文档滞后过）。
2. **隔离集成**：所有实验用 `HC_SESSION=kraal-test` + 临时
   `XDG_STATE_HOME`/`XDG_CONFIG_HOME`，绝不碰机器上真实的 core
   （`herdr-core/AGENTS.md` 的 trap）。
3. **端到端**：`gui.sh` 仍是唯一能证明「点了有反应」的门禁，但断言目标从
   Herdr 1 daemon 换成 `hc get/list/read --json`；VM 后端与 TCC 授权不变。
4. **性能**：`bench.sh` 的 cell/patch 两组用例删除，改为
   「attach 字节吞吐」「N pane 下的主线程占用」「输入→回显延迟」。
   基线重录之后才允许谈回归。

---

## 9. 非目标（v1 明确不做）

- JS mods / 布局文件 / 主题市场（官方那套 `defaults/mods`、`layouts/*.json`）。
- Herdr 1 daemon 兼容、旧 socket、旧配置迁移。
- Windows 客户端（core 支持，但 Kraal 只做 macOS/iOS）。
- 终端内搜索（官方也没有；选择 + 复制是唯一取文本方式）。
- 多窗口共享同一 core 的复杂协调（先按官方「最后活跃的 viewer 决定尺寸」处理）。

---

## 10. 风险与未验证

| 风险 | 说明 | 应对 |
|---|---|---|
| core 仍是 `0.x` preview | generation 1 只保证**只增不减**；0.x 内仍可能加必填参数 | 钉住最低版本；`hello.methods` 门禁；升级前跑兼容测试 |
| 共享文档 schema 会演进 | `Node` 字段多（float/stack/look），官方会加 | 不反序列化成强类型再写回；用 JSON 透传 + 只改自己拥有的子树 |
| Ghostty 绑定比官方薄 | `libghostty-spm` 有 `readViewportText`/`scrollToRow`/selection，但链接识别、kitty 图形细节是否暴露未验证 | M2 先用官方 `herdr-app` 做 A/B；缺 API 时在 issue 里记实测，不硬编 |
| 多客户端抢 active viewer | 谁输入/缩放/focus 谁决定尺寸 | 按协议实现 FOCUS/RESIZE；不自己发明协商 |
| win32-input-mode（DEC 9001） | 首帧末尾会带 `?9001h/l`；core 不编码按键 | macOS 客户端先按 Ghostty 现有编码；接 Windows core 时单独验 |
| 旧文档仍在误导 | `DESIGN.md`/`CLI.md`/`GAP-VS-HERDR.md` 描述的是 Herdr 1 | 已归档到 `docs/archive/`；`RUNNING.md` 等操作文档随 M3 更新 |
