# iOS / macOS 原生 Herdr 客户端 — 可行性（修订版）

> 2026-10-20 · 本机 herdr 0.9.4 · 已经在 macOS 上**跑通**桌面端私有 endpoint 协议

---

## 0. 先说结论

你的判断是对的，我上一版高估了难度。但**真正的关键不是"那些 App 做得差"，而是有两条完全不同的技术路线，工作量差 5–10 倍**：

| 路线 | 传输 | 能做出来的产品 | 工作量 |
|---|---|---|---|
| **A. CLI/JSON API 拼装**（90% 的现有 App 走这条） | SSH exec 跑 `herdr agent list` / `remote-api-bridge`，解析 JSON | 列表 + 读文本 + 发 prompt，**终端只能靠 ANSI 文本重绘** | 中，但天花板低 |
| **B. 桌面端 endpoint 协议**（只有 herdr-gpui 走这条） | SSH exec 跑 `remote-client-bridge`，**bincode 二进制帧**，直接收整屏 cell 网格 | 和桌面端**逐像素一致**的渲染，split/pane/popup/图片/鼠标全支持 | 前期重、后期省 |

**路线 B 的协议我已经完整摸清并跑通了**（见第 3 节实测），Apache-2.0 有完整 Rust 参考实现可以直译。这才是"原生客户端"该走的路，也是现有 iOS App 全都没做到的地方 —— 这是真正的差异化。

---

## 1. 为什么现有 App 都很差（技术原因，不是能力问题）

它们几乎全部走路线 A，天然有三个天花板：

1. **终端是重绘的，不是原生的**：拿 `pane.read --source visible` 的 ANSI 文本自己渲染 → 光标位置、宽字符、emoji、box drawing、颜色、alternate screen TUI 都会错。
2. **一条连接一个请求**：`herdr.sock` 和 `remote-api-bridge` 都是"请求-响应-关闭"，每次操作要新开一条 SSH（实测 20–60ms，虽可接受但会话状态无法保持）。
3. **拿不到 pane 几何**：`pane.read` 只有文本，没有 split 布局、没有鼠标区域、没有 popup，所以做不出桌面端那种分屏。

路线 B 一次解决这三个问题：**一条长连接、整屏 cell、带几何信息和鼠标区域**。

---

## 2. 路线 B 的协议全貌（已实测跑通）

### 2.1 握手

```
帧格式：[u32 LE 长度] + [bincode payload]
bincode = 行内 varint 编码（<251 单字节，否则 0xFB/0xFC/0xFD 前缀）

Client → Server:  tag 20 (EndpointControl) { kind:"endpoint.hello.v1", data: JSON字符串 }
Server → Client:  tag 20 { kind:"endpoint.welcome.v1", data: JSON }   ← 服务端声明能力
Server → Client:  tag 20 { kind:"endpoint.agent-completions.v1", data: JSON }
Server → Client:  tag 20 { kind:"shell.snapshot.v1", data: JSON }     ← 全部 workspace/tab/pane/agent
Server → Client:  tag 8  (MouseCapture) / tag 17 / tag 6 (WindowTitle)
Server → Client:  tag 13 (PaneSurface)  ← 整屏 cell 网格
Server → Client:  tag 19 (PaneSurfacePatch) ← 增量
```

`ServerMessage` 共 21 个 tag，索引即 wire tag（顺序是兼容契约，不可改）：

```
0 Welcome  1 Terminal  2 Graphics  3 ServerShutdown  4 Notify  5 Clipboard
6 WindowTitle  7 ReloadSoundConfig  8 MouseCapture  9 TerminalBell
10 GraphicsFile  11 GraphicsTransmissionRetired  12 ClientShellSnapshot
13 PaneSurface  14 SemanticNotification  15 ClientShellError
16 DirectTerminalKeyboardProtocol  17 ClientShellKeyboardReportAll
18 ClientShellEndpointResponseChunk  19 PaneSurfacePatch  20 EndpointControl
```

`ClientMessage` 共 21 个 tag，其中 `EndpointControl` 是 **tag 20（不是 11）**，这是最容易踩的坑。

### 2.2 实测数据（本机 macOS，unix socket）

| 步骤 | 结果 |
|---|---|
| `endpoint.hello.v1` → `welcome` | 0.02s，返回 `server_version: 0.9.4` + 完整 methods 列表 |
| `shell.snapshot.v1` | 0.06s，11.8 KB，含全部 workspace/tab/pane/agent |
| `PaneSurface`（首帧整屏） | 0.09s，**43 KB**，100×30 = 3000 个 cell |
| `PaneSurfacePatch`（增量） | 0.14s，**66 字节** |
| 解码验证 | 成功还原出 30 行 × 100 列的文本，`cells` 数量与 width×height 完全对上 |

`CellData` 结构（bincode）：
```
symbol: String, fg: u32, bg: u32, modifier: u16, skip: bool, hyperlink: Option<u32>
// fg/bg: 命名色 0..=16 | indexed 0x010000XX | RGB 0x02RRGGBB（注意不是 ARGB）
```

`PaneSurfaceFrame` 除了 `frame`（cell 网格）还带：
- `panes: Vec<PaneSurfacePane>` — 每个 pane 的 `rect`/`inner_rect`/`scrollbar_rect`/`focused`/`mouse_reporting`/`alternate_screen_active`
- `splits: Vec<PaneSurfaceSplit>` — split 方向、位置、hit_rect
- `popup: Option<ClientShellPopupSurface>` — 弹窗独立 frame
- `graphics: SurfaceGraphicsScene` — 图片 aset/placement

**这就是桌面端的完整渲染数据。** 拿到它，iOS/macOS 只要做 cell grid → CoreText/Metal 绘制，不碰任何终端状态机。

### 2.3 三个 optional codec（省流量，可选）

`surface_scroll` / `surface_delta` / `surface_reuse` —— 在 hello 里声明，服务端 welcome 接受后启用。**可以先全部关掉**（首版只收完整 PaneSurface + Patch），后面再逐个加。

---

## 3. 现成的参考实现（Apache-2.0，可以直接用）

### `penso/herdr-gpui` — 1522★，Rust，Apache-2.0

它把协议拆成了三个**互不依赖**的 crate，这是关键：

| crate | 内容 | 对 iOS 的意义 |
|---|---|---|
| `herdr-protocol` | **1520 行**，纯 wire 类型 + bincode 编解码 + surface patch 校验。零依赖（base64/bincode/serde/thiserror） | **直接照抄到 Swift**，1–2 天能翻完 |
| `herdr-client` | 连接管理、握手、队列、重连、SSH bridge 拉起、API request 租约 | 逻辑参考，Rust 依赖 `std::process`/`UnixStream`，不能直接上 iOS |
| `herdr-gpui` | GPUI 渲染层 | 只参考 UX，代码不可用 |

它还提供了两个可以直接抄的"生产级细节"：
- **`NOTICE.md` 记录了从 Herdr 0.9.1 commit `856b64b` 抄的哪些文件** —— 省去你自己去 Herdr 源码里翻
- **`limits.rs` 给出的超时参数**：握手 10s、命令 60s、SSH 静默 5s 发 ping、ping 10s 无应答判定断线、响应上限 8MB、帧上限 2MB（图形 32MB）

**注意**：这两个 crate **没有发布到 crates.io**（`publish = false`），得 vendor 进仓库。但如果你的客户端主体是 Swift，你只需要读它、翻译它，不需要编译它。

### 为什么不直接 Rust + UniFFI 复用？
可行但**不推荐**做第一版：
- iOS 上 `herdr-client` 的 SSH 部分（`std::process::Command` 起 ssh）不能直接用，得换成 libssh2
- 会引入 Rust 工具链 + 两个 target（device/simulator）的交叉编译 + UniFFI 绑定，构建链复杂度陡增
- 协议只有 1520 行，Swift 手写一次比维护绑定更省事；而且 Swift 的 `Codable`+`Data` 做 varint 解码很直接

---

## 4. iOS 上真正要解决的问题（按难度排序）

### 4.1 SSH 传输：**libssh2，没有第二选择**
- `libssh2 ≥ 1.11.0` 才有 `libssh2_channel_direct_streamlocal_ex()`，可以直连 `herdr.sock`
- 但**路线 B 不需要 streamlocal**！`remote-client-bridge` 走的是 **stdout/stdin 二进制流**，只要 SSH exec 通道就行
- 这意味着 `swift-nio-ssh`（无 streamlocal 支持）**也能用** —— 生态反而更宽

> 关键发现：`remote-client-bridge` 只做 stdin/stdout 二进制管道，不碰 socket。所以 iOS 上一个纯 Swift SSH 库 + `channel.executeCommand` 就够了。

### 4.2 渲染：cell grid，不是终端模拟器
这是路线 B 最大的红利：**你不需要终端模拟器**。
- 输入：`FrameData { cells, width, height, cursor }`
- 输出：CoreText/Metal 画格子。box drawing、宽字符、颜色都是数据，不用解 ANSI
- 参考 herdr-gpui 的 README：连"实心/粗线 box-drawing、block elements、四分之一块"都是自己按 cell 网格画的

### 4.3 输入：语义事件，不是字节流
`ClientPaneInputEvent` 枚举：`Key{code, modifiers, kind}` / `TextCommit(String)` / `Mouse{...}` / `Paste(String)`。
这对 iOS 反而友好 —— 软键盘直接发 `TextCommit`，不需要字节级键盘映射。

### 4.4 后台与推送（**唯一的硬约束**）
- iOS 后台只有 25–30s，长连接必死
- 要"agent blocked 时通知我" → 必须自建 APNs relay（主机侧插件加密 → relay 只转发密文）
- 但**可以第一版不做**：App 前台时全功能，退到后台就断；推送作为 v2

### 4.5 macOS 版几乎白送
同一个 Swift 包，macOS 上用 `Network.framework` 的 `nw_unix_socket`（或直接 POSIX socket）连 `~/.config/herdr/herdr.sock`，**连 SSH 都不需要**。协议、渲染、输入全部复用。

---

## 5. 工作量重估

| 阶段 | 内容 | 时间 |
|---|---|---|
| **M0 协议内核** | Swift 移植 `herdr-protocol`（varint + 21 个 ServerMessage + 21 个 ClientMessage + Surface/Patch 校验） | 3–5 天 |
| **M1 macOS 直连** | POSIX socket 连本机 `herdr-client.sock`，跑通 hello→snapshot→surface→解码成文本 | 2–3 天（**我已经用 Python 跑通，可以直接对照**） |
| **M2 macOS UI** | SwiftUI 侧栏 + cell grid 渲染（CoreText 起步，后续换 Metal） | 1–2 周 |
| **M3 输入** | 鼠标点击 → `PaneSurfacePane.rect` 命中 → `ClientShellPaneInput`；键盘 → `TextCommit` | 3–5 天 |
| **M4 iOS SSH** | libssh2 或 swift-nio-ssh + exec `remote-client-bridge`，二进制管道 | 1 周 |
| **M5 iOS UI 适配** | 手机窄屏布局、软键盘、滚动 | 1 周 |
| **M6 推送**（可选） | 主机侧插件 + APNs relay | 2–3 周 |

**M0–M3 大约 3–4 周，就能做出一个和桌面端渲染一致、能看能点的 macOS 原生客户端。** 这是最快的"能证明自己"的里程碑。

---

## 6. 建议的执行顺序

**不要先做 iOS。先做 macOS。**

理由：
1. macOS 版**不需要 SSH**（直连 unix socket），把协议 + 渲染两个最难的问题先解掉
2. 我自己已经在 macOS 上用 Python 跑通了从握手到解码整屏的完整链路，你能直接对照
3. macOS 版做出来就是一个能用的产品（比 GPUI 版更好看的原生 SwiftUI）
4. 之后 iOS 只是加一层 SSH 传输 + UI 适配，协议层完全复用

---

## 7. 可以直接抄的资产清单

| 资产 | 路径 | 用途 |
|---|---|---|
| 协议 wire 类型（697 行） | `herdr-gpui/crates/herdr-protocol/src/wire.rs` | 全部 struct/enum 定义，含字段顺序注释 |
| 编解码（79 行） | `.../codec.rs` | u32 LE 长度帧 + bincode varint |
| 握手类型（64 行） | `.../endpoint.rs` | hello/welcome 字段 |
| Surface patch 校验（90 行） | `.../frame.rs` | revision 单调性、cell 边界、原子提交 |
| 三个 optional codec | `.../surface_{delta,scroll,reuse}.rs` | 省流量，可后置 |
| SSH bridge 拉起脚本 | `herdr-client/src/ssh.rs` | shell 脚本模板（含 `herdr-remote-output-ready:1` 握手） |
| 生产超时参数 | `herdr-client/src/limits.rs` | 直接照抄 |
| 上游溯源 | `herdr-gpui/crates/herdr-protocol/NOTICE.md` | 对应 Herdr 0.9.1 commit `856b64b` |
| 官方 JSON schema | `herdr api schema --json` | 路线 A 的 128 个方法定义 |
| 我的验证脚本 | `/tmp/local_hs2.py`, `/tmp/welcome.py`, `/tmp/decode2.py` | 逐字节对照用 |

---

## 8. 唯一需要你决策的点

**M0–M3 就是 3–4 周的投入。** 如果接受，下一步我可以：
1. 把这套 Python 验证脚本整理成一份**带注释的协议说明**（每个字节什么意思）
2. 起 Swift Package 骨架，先把 M0 的编解码写完并用真实数据做单测

要哪个？
