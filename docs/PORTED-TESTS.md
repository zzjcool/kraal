# 上游测试移植清单

本文件记录从三个参考项目移植过来的测试：哪一条、抄自哪里、为什么值得抄、
以及移植后 **当前是红的** 说明我们哪里不对。

参考项目（与 `NOTICE` 一致）：

| 仓库 | 许可 | 我们用它做什么 |
|---|---|---|---|
| [herdrdev/herdr](https://github.com/herdrdev/herdr) | Apache-2.0 | daemon 本体：ANSI 重编码、surface 编码、连接健康 |
| [penso/herdr-gpui](https://github.com/penso/herdr-gpui) | Apache-2.0 | 最接近的先行客户端：协议字节序、surface 校验、会话状态机 |
| [kitknox/rootshell](https://github.com/kitknox/rootshell) | MIT | 同为 libghostty 的 Apple 客户端：几何、拖拽、分屏、快照校验 |

本轮**只移植测试**，不修实现。按约定，红是预期的：每条红的测试都指向一个
具体的、可以用一句话说清的差异。

> **这些差异已经全部修完了。** 移植当时是 29 绿 / 25 红；随后 issue #1、#3–#10、
> #18、#19 逐条修掉，`Scripts/test-baseline.sh` 的已知红名单**现在是空的**，
> `swift test` 直接跑就是全绿。下面第三节保留的是每条测试当时指向的差异、以及
> 修法要点 —— 它是这些测试存在的原因，改那段代码前值得先读。

---

## 一、新增文件

原有 119 条测试全部保留且全绿；本轮新增 **54 条**，移植当时是 **29 绿 / 25 红**，
main 合入 issue #2 后是 **32 绿 / 22 红**。

| 文件 | 新增 | 其中红 | 来源 |
|---|---|---|---|
| `Tests/KraalProtocolTests/WireOrderTests.swift` | 9 | 3 | herdr-gpui `herdr-protocol/tests/{compatibility,host_theme,clipboard}.rs` |
| `Tests/KraalProtocolTests/ANSIConformanceTests.swift` | 14 | 10 | herdr `src/protocol/render_ansi.rs`（51 个测试里挑出与渲染结果有关的） |
| `Tests/KraalProtocolTests/FramingConformanceTests.swift` | 8 | 2 | herdr-gpui `compatibility.rs` + herdr `render_ansi.rs:1882` + `herdr-client/tests/framing.rs` |
| `Tests/KraalProtocolTests/UpstreamFixtureTests.swift` | 4 | 1 | herdr-gpui 的三份冻结 fixture（已复制进 `Fixtures/upstream-*.json`） |
| `Tests/KraalClientTests/HandshakeFencingTests.swift` | 10 | 7 | herdr-gpui `version_mismatch.rs`、`session_state.rs`、`framing.rs`、`supervisor.rs`；rootshell 快照校验 |
| `Tests/KraalClientTests/GeometryFencingTests.swift` | 10 | 1 | rootshell `TmuxDividerResizeTests`、`HerdrProtocolTests`；herdr-gpui `surface_prefix.rs` |

`root shell` 与 `herdr-gpui` 里另有大量测试是**没有移植**的，理由写在第四节。

---

## 二、当前是绿的（回归护栏）

这些是「我们本来就对，但没人钉住」的部分。它们的价值是防止以后改坏。

- **21 个 client tag 逐条对齐**（`WireOrderTests`）：bincode 是位置编码，
  重排一个变体会让之后所有消息的含义变化，且两边都不报错。
- **手写字节表 vs 编码器**：`ClientShellPaneInput` 的 Key 事件（含
  Windows 键记录、所有 optional）、`ClientShellResize`、
  `ClientShellEndpointRequest`、`ClientSurface` 字段顺序、剪贴板图片信封、
  三个 clipboard target tag。
- **上游冻结 fixture 解码**：welcome / snapshot 用**别的客户端写下的** JSON，
  证明我们和第二个实现对得上，而不是和自己对得上。
- **帧分片、敌意长度前缀、数组/字符串长度越界**：在分配前拒绝。
- **patch 原子性**：失败不改 receiver、同一 patch 不能重放、拒绝时有效行也不落盘。
- **surface 投影栅栏**：别的 projection 的帧不采纳、同一 projection 内 revision
  回退丢弃、换 boot id 后才允许 revision 变小。
- **非方形分屏拖拽换算**、退化区域、越界 clamp、嵌套 origin 只减一次。
- **重连退避 1→2→4→8→16→30→30**：从 `phase` 的 `retryAt` 读出来，
  不是读内部计数器。
- **时序常量**：5 s 静默 ping / 10 s pong 超时 / 10 s 握手 / 60 s 命令 /
  8 MiB 响应 / 2 MiB 帧 / 32 MiB 图形帧。

---

## 三、移植时是红的（25 条，每条一个具体差异）—— 现已全部修好

下面每条都附了当时的差异和修法；能否复核的最直接方式是看对应 issue。

### 3.1 渲染（6 条）

> `every frame is wrapped in synchronized output`、`a size change repaints
> without clearing the screen`、`a missing cursor hides the host cursor` 三条
> 已随 issue #2 / #3 的合入转绿，不再列在这里。

| 测试 | 上游出处 | 差异 | Issue |
|---|---|---|---|
| `named foreground colors use SGR 30-37 / 90-97` | `render_ansi.rs:1110` | `StyleCode` 对 16 个命名色一律发 `38;5;<n>`，且索引直接用了 wire 值。**named(1) = 黑，被画成 256 色第 1 号 = 红**。整组命名色全部偏一档。 | #1 |
| `named background colors use SGR 40-47 / 100-107` | `render_ansi.rs:1128` | 同上，背景侧。 | #1 |
| `curly underline keeps its style parameter` | `render_ansi.rs:1194` | modifier 高 4 位是下划线样式（1 单线 / 2 双线 / 3 波浪…），daemon 发 `4:<style>`；我们只发 `4`，波浪线画成直线。 | #3 |
| `every frame is wrapped in synchronized output` | `render_ansi.rs:1284` | 同步输出对（`?2026h`…`?2026l`）只在**首帧**成对发出；diff 帧完全不包，所以每次 patch 重绘都是半画状态可见 —— 正是这对序列要防的撕裂。 | #2 |
| `a size change repaints without clearing the screen` | `render_ansi.rs:1772` | 尺寸变化走 `full` 并发 `2J`。daemon 只在 pane 的**第一帧**清屏；我们是每次窗口 resize 都清一次，把用户正在读的 scrollback 摸掉了。 | #2 |
| `halfwidth katakana plus voiced mark is two columns` | `render_ansi.rs:2360` | 半角假名 + 浊点（`U+FF66…FF9D` + `U+FF9E/FF9F`）是一个字素占 **2 列**。`SurfaceText.isWide` 只看首个 scalar，这些码位不在任何区间里，于是整行左移一列。 | #3 |
| `a linked cell emits OSC 8` | `render_ansi.rs:1618` | `hyperlinks` 已解码并一路透传到 `PaneTerminal`，渲染器从不发 OSC 8 —— 链接在 pane 里是纯文本。 | #3 |
| `cursor shape is emitted with DECSCUSR` | `render_ansi.rs:1508` | `CursorState.shape` 解码了但渲染丢弃，从不发 `ESC[<n> q`；逻辑光标形状永远是默认方块。 | #3 |

### 3.2 线格式（3 条）

| 测试 | 上游出处 | 差异 | Issue |
|---|---|---|---|
| `each update variant matches the handmade layout` | `herdr-protocol/tests/host_theme.rs:14` | bincode 把 `u8` 写成**一个裸字节**（只有宽于 8 位的整数才用 varint）。`encodeHostTheme` 对调色板索引和三个颜色分量都用了 `writeVarint`：≤250 时字节恰好相同，>250 就错（索引 255 发成 `251 255 0`）。 | #4 |
| `colour bytes above 250 stay single bytes` | 同上 | 上条的最小复现：颜色 `(255,254,251)` 应发 3 字节，实发 7 字节。 | #4 |
| `a full palette fits one frame with a varint length` | `host_theme.rs:64` | 256 色调色板：数组**长度**该用 varint，**元素**该是 4 个裸字节。我们现在 5 + 256×7 ≠ 5 + 256×4。 | #4 |

### 3.3 握手与快照（5 条）

| 测试 | 上游出处 | 差异 | Issue |
|---|---|---|---|
| `generation, not the error code, says which side is older` | `version_mismatch.rs:40` | 上游用 generation 判定谁旧，**即使 welcome 同时带了 error**。我们先把 `welcome.error` 短路掉，于是「客户端太旧」被报成通用拒绝，用户被指引去更新错误的一端。 | #5 |
| `an older daemon is reported as too old` | 同上 | `Compatibility.serverTooOld` 这个 case 存在但**永远不会被产生**：generation 更低时走的是 `clientTooOld`。 | #5 |
| `a version below the client minimum is refused` | rootshell `testVersionsBelowMinimumAreRefused` | 完全不解析 `server_version`。`0.4.0`、`0.8.9`、`not-a-version` 一律接受，然后在半工作状态里慢慢出问题。也缺 fork/build 后缀（`1.0.0+build.7`）的解析。 | #5 |
| `a snapshot revision regression is not published` | `session_state.rs:104` | `handleSnapshot` 无条件赋值。每条 surface 都以 `projectionRevision == snapshot.revision` 为栅栏，一旦采纳回退的 revision，**所有在飞的帧同时变成「陈旧」**。 | #6 |
| `duplicate pane ids are rejected at decode time` | rootshell `testSessionSnapshotRejectsDuplicateTopologyIDs` | 快照里重复的 `pane_id` 会让命中测试和 pane 切片永远取第一个。解码期就该拒。 | #6 |

### 3.4 边界与防御（7 条）

| 测试 | 上游出处 | 差异 | Issue |
|---|---|---|---|
| `bytes after a complete message are rejected` | `compatibility.rs:430` | `ServerMessageDecoder` 解完就返回，不检查 `reader.isAtEnd()`。`BincodeError.trailingBytes` 是**死代码**（定义了、从不抛出）。解码错位的流会继续把垃圾当作下一条消息的开头。 | #7 |
| `overlapping rows are rejected` | `render_ansi.rs:1882`、`surface_scroll.rs` | `validatePatch` 查每行边界，不查行间重叠。重叠时后一行静默覆盖前一行，屏幕上出现 daemon 从未合成过的内容。 | #7 |
| `an unrenderable grid is refused by the store` | `herdr-client/tests/framing.rs:24` | `resizeSurface` 只挡 0。daemon 的上限是每轴 4096、总计 1 000 000 格；`4097×24` 和 `1001×1000` 现在都被接受并直接发给 daemon。 | #8 |
| `a non-finite drag cannot produce a ratio` | rootshell `TmuxDividerResizeTests:66` | `splitRatio` 挡了除数为 0，没挡分子。`translatedY` 为 `NaN`/`∞` 时直接传出去（`min`/`max` 不消毒 NaN）。daemon 侧 `layout.set_split_ratio` 会拒（`src/app/api/layouts.rs:235`），但那条错误用户看不到，分隔条**一动不动**。 | #8 |
| `a ratio request names its tab and never a pane` | rootshell `HerdrProtocolTests:29` | `setSplitRatio` 只发 `path` + `ratio`，不发 `tab_id`。daemon 侧 `tab_id` 可选，缺省时走 "当前 workspace 的当前 tab"（`src/app/api/layouts.rs` 的 `resolve_layout_export_target` 的 `(None, None)` 分支）—— 只有在本客户端恰好显示着它时才是同一个 tab。拖拽落在焦点切换之后，就会**静默地改掉用户没在看的那个 tab**。为了可测，只把参数构造成提成了纯函数 `AppStore.splitRatioParams`，行为未改。 | #8 |
| `a hidden cursor is parked, not abandoned` | `render_ansi.rs:2218` | 光标隐藏时要把它停在**上次可见的位置**再 `?25l`，否则 IME 候选框出现在角落。我们现在只发 `?25l`。 | #3 |
| `the frozen hello keeps every negotiated field` | `endpoint.rs:361` | `EndpointClientHello` 没有自定义 `init(from:)`，每个字段都必填。上游 fixture 省掉了 `surface_active`（serde 默认 `true`）等四个字段。**目前不影响 app**（我们只发不收），但类型描述的不是它所声称的线协议，将来任何读 hello 的代码（测试替身、诊断工具）都会在合法载荷上失败。 | #10 |

---

### 3.5 重连（1 条）

| 测试 | 上游出处 | 差异 | Issue |
|---|---|---|---|
| `reconnect backoff doubles and is capped` | `supervisor.rs:1132` | 延迟算了两遍、基于同一个计数器的两次读法：`scheduleReconnect` 用自增前的值设 `phase.retryAt`，`scheduleEndpointRetry` 自增后才是真正的 sleep。实测报 1/1/2/4/8/16，实际睡 1/2/4/8/16/30 —— 从第 2 次起重连横幅一直少报一档。 | #9 |

## 三·附、Issue 与分支对照

25 条红按缺陷（而不是按测试文件）拆成了 9 个 issue，每个对应一个待修分支。
下表「条数」是**移植时**的计数；issue #2 已合入并清空（#3 也因此少了 1 条）。
tracking issue 是 #11。

| Issue | 主题 | 建议分支 | 条数 |
|---|---|---|---|
| [#2](https://github.com/zzjcool/kraal/issues/2) | ~~diff 帧没包同步输出 + resize 清 scrollback~~ **已修，已 CLOSED** | `fix/render-sync-and-clear`（已合并） | 0 |
| [#1](https://github.com/zzjcool/kraal/issues/1) | 命名色 SGR 偏一档 | `fix/named-color-sgr` | 2 |
| [#3](https://github.com/zzjcool/kraal/issues/3) | OSC 8 / URI 清洗 / 半角假名 / 光标 | `fix/render-links-and-cursor` | 5 |
| [#9](https://github.com/zzjcool/kraal/issues/9) | 重连倒计时与真实 sleep 差一档 | `fix/reconnect-backoff-report` | 1 |
| [#5](https://github.com/zzjcool/kraal/issues/5) | 握手用 error 而非 generation + 版本下限 | `fix/handshake-version-order` | 3 |
| [#8](https://github.com/zzjcool/kraal/issues/8) | setSplitRatio 缺 tab_id / NaN / 网格上界 | `fix/split-request-params` | 3 |
| [#6](https://github.com/zzjcool/kraal/issues/6) | 快照 revision 回退 / 重复 pane_id | `fix/snapshot-fences` | 2 |
| [#7](https://github.com/zzjcool/kraal/issues/7) | 尾随字节 / patch 行重叠 | `fix/payload-hygiene` | 2 |
| [#4](https://github.com/zzjcool/kraal/issues/4) | host theme 的 u8 写成 varint | `fix/host-theme-u8` | 3 |
| [#10](https://github.com/zzjcool/kraal/issues/10) | Hello 缺 serde 默认值 | `fix/hello-serde-defaults` | 1 |

名单现在已经清空。**如果它重新长出条目**，先看 `--compare`：报告「名单里但其实
已经绿了」说明名单陈旧（白丢护栏），一声不响地红着说明有真回归。

## 四、看过但**没有**移植的（附理由）

这些不是漏了，是明确不适合我们的架构，或者抄过来也测不到东西。

| 区域 | 上游测试量 | 不移植的理由 |
|---|---|---|---|
| surface `scroll` / `delta` / `reuse` 编码 | herdr-gpui `surface_encodings.rs` 10 条、herdr `surface_scroll.rs` 6 条、`surface_delta.rs` 18 条 | 我们根本不协商这三个可选编码（`EndpointClientHello.optionalCodecs` 默认 `false`，`EndpointConnection` 也不传）。移植需要先写 base64、三个解码器、9 个新错误 case，属于**立项**而不是移植。 |
| `surface_prefix`（提前放行键盘输入） | herdr-gpui `surface_prefix.rs` 4 条 | 我们是单连接、单一投影，没有「排队输入等投影到位」这条通道。 |
| control stream / 所有权 / 接管 / parser fence | rootshell `HerdrProtocolTests` 约 30 条、herdr `activation_tests.rs` 大部分 | 我们直接连 daemon 的 endpoint，没有多客户端共享 attach、没有 authority 切换、没有 DECRQM 探测。移植 = 先实现整套功能。 |
| tmux / mosh / zellij 会话目标、路径补全、软键盘几何 | rootshell 约 50 条 | 对应功能我们没有（软键盘见 ROADMAP M6）。其中 `TerminalKeyboardGeometry*` 是纯 CoreGraphics 判定函数，做 iOS 时可以整段照抄。 |
| 写队列 / 背压 / 部分写 / flush deadline | herdr `endpoint/writer.rs` 9 条、`supervisor.rs` 14 条 | 我们没有写队列（同步写、actor 串行）。其中「对端不读时 teardown 不阻塞」指向一个**真实风险**：`UnixSocket.write` 在对端不消费时会在 actor 上自旋。这条值得单独立项，不是纯测试移植。 |
| `surface_delta/decode.rs` 的「分配前拒绝」边界 | herdr 9 条 | 思路已有一条等价覆盖（`readArray` 的 `minimumElementBytes`），整套要等 delta 解码器存在。 |

---

## 五、怎么跑

```bash
swift test                                    # 全绿
swift test --filter "Handshake compatibility"  # 按 suite
./Scripts/test-baseline.sh                    # 全量 + 跳过 REDS 名单（现为空）
./Scripts/test-baseline.sh --list             # 打印名单（现为空）
./Scripts/test-baseline.sh --compare          # 名单里有没有「其实已经绿了」的
```

`swift test` 曾经是红的（25 → 22 → … → 0），那段时间靠 `test-baseline.sh`
跳过已知红，才让「有没有真回归」仍有信号。名单清空后它退化成一条普通的
`swift test`；`Scripts/verify.sh` 一直用它，所以命令不用变。
- 修好一条后跑 `--compare`，它会告诉你哪条该从名单里删掉 —— 避免名单变陈。

只看新增部分的红：

```bash
swift test 2>&1 | grep -E '^✘ Test "' | grep -v 'failed after'
```

参考项目在 `/tmp/kraal-refs/{herdr,herdr-gpui,rootshell}`（`--depth 1` 克隆）；
文件不在的话重新 clone 即可，坐标（文件:行号）取自本轮的快照。
