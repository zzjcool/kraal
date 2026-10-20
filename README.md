# Kraal

原生 Swift 的 [Herdr](https://herdr.dev) 客户端，为 macOS / iOS / iPadOS 共用一套代码。

> **命名**：`Kraal` 是南非荷兰语的「畜栏」——给畜群一个围起来的落脚处，
> 正如这个 app 给 Herdr 的 agent 群一个随身的窗口。
>
> **商标**：Herdr 是 Herdr, Inc. 的商标。Kraal 是独立第三方客户端，
> 与 Herdr, Inc. 无关联，未获其授权或背书。
>
> **状态：macOS 版可用。** 连接、快照、分屏渲染、键盘输入、侧边栏布局引擎
> 都已跑通并接入真实 daemon。详见下方「已完成」与 [docs/ROADMAP.md](docs/ROADMAP.md)。

---

## 它是什么

现有 Herdr 客户端几乎都走 SSH + CLI + ANSI 重绘。Kraal 走另一条路：
直接用 Herdr 桌面端（GPUI 版）使用的 **endpoint 协议**，拿到结构化的 cell
网格和分屏几何，然后把 pane 内容交给 **Ghostty** 渲染。

```
┌──────────────────────────────────────────────────────────────┐
│  一条连接（本机 unix socket，或 SSH exec remote-client-bridge）│
│  ├─ endpoint.hello.v1  → welcome（能力协商）                  │
│  ├─ shell.snapshot.v1  → 侧边栏 / 标签栏数据                   │
│  ├─ PaneSurface        → panes[].innerRect 布局 + 整屏 cell    │
│  ├─ PaneSurfacePatch   → 增量（实测 66 B）                     │
│  └─ ClientShellPaneInput ← 键盘 / 鼠标语义事件                  │
└──────────────────────────────────────────────────────────────┘
        │
        ├─ 侧边栏 / 标签栏  →  SwiftUI 原生（config.toml 驱动）
        └─ pane 内容       →  Ghostty InMemoryTerminalSession（Metal）
```

**关键点：一条连接。** 不开 `terminal attach` 通道，因此不需要每 pane 一次
握手，也不会和桌面端抢 `takeover`。pane 内容来自 endpoint 的权威 cell 网格，
由 Kraal 重新编码成 VT 序列喂给 Ghostty —— 调研阶段实测「herdr ANSI 与权威
surface 逐行一致 36/36」，所以渲染结果与桌面端一致。

---

## 已完成

| 能力 | 状态 | 说明 |
|---|---|---|
| endpoint 协议内核 | ✅ | bincode varint、u32 帧、21+21 消息、surface/patch 校验 |
| 本机连接 | ✅ | `~/.config/herdr/herdr-client.sock`，含 `XDG_CONFIG_HOME` / 命名 session |
| SSH 连接 | ✅ | exec `remote-client-bridge`，含 `herdr-remote-output-ready:1` 握手 |
| 握手与兼容性 | ✅ | generation / codec / capability 逐项校验，拒绝时给人类可读原因 |
| 快照解码 | ✅ | workspace / tab / pane / agent / 自定义命令 |
| 分屏渲染 | ✅ | 按 `innerRect` 摆 Ghostty 视图，N 个 pane |
| 键盘输入 | ✅ | 字节 → 语义事件（`TextCommit` / `Key` / CSI 序列） |
| 侧边栏布局引擎 | ✅ | 解析 `config.toml` 的 `ui.sidebar.*`，含 token / 样式 / 条件规则 |
| 命令面板 | ✅ | `snapshot.commands` + 内置动作，`command.invoke` 执行 |
| 健康检查与重连 | ✅ | 5 s 静默 ping、10 s 无 pong 判死、指数退避（上限 30 s） |
| 窗口几何协商 | ✅ | 按窗口实际像素换算 cell 网格并重新握手 |
| 鼠标合成 | ⏳ | 协议编码已就绪（`ClientPaneInputEvent.mouse`），UI 手势待接 |
| 分屏拖拽 | ⏳ | 拖动条已实现并调用 `layout.set_split_ratio`，需要在真实分屏上验证 |
| iOS 版本 | ⏳ | 协议层与侧边栏引擎已复用就绪，见 ROADMAP |

---

## 快速开始

```bash
# 构建、测试、lint 一次跑完
./Scripts/verify.sh

# 打包成真正的 .app（ad-hoc 签名）并启动
./Scripts/build-app.sh
open build/Kraal.app
```

Kraal 启动时会自动连本机。没连上（Herdr 没跑）会显示连接面板，
也可以直接连远端：

```bash
# 命令行探针：不启动 UI 也能验证一条链路
swift build --product kraal
./.build/out/Products/Debug/kraal                       # 本机，打印快照 + 前 12 行画面
./.build/out/Products/Debug/kraal --ssh my-host screenshot
./.build/out/Products/Debug/kraal --ssh my-host call --method tab.create --param label=logs
```

### 在隔离的 Herdr 实例上开发

开发和自测**必须**在一次性容器里做，不要连任何正在使用的 daemon。GUI 调试会
分屏、打字、关 pane、改布局，这些落在真实会话里就是破坏。

```bash
# 1. 起一个专属容器，配置目录用一次性路径
ssh devcloud 'mkdir -p /tmp/kraal-zzj-iso && chmod 777 /tmp/kraal-zzj-iso \
  && docker run -d --name kraal-zzj-sandbox \
     -v /tmp/kraal-zzj-iso:/root/.config/herdr \
     pi-herdr-sandbox:latest bash -lc "herdr server"'

# 2. 升到最新版（镜像自带的是旧版）
ssh devcloud 'docker exec kraal-zzj-sandbox sh -c "herdr update </dev/null"'
ssh devcloud 'docker restart kraal-zzj-sandbox'

# 3. 把它的 unix socket 映射到本机那个专属路径
sudo -u zzj ssh -N -L \
  /tmp/kraal-mine/herdr-client.sock:/tmp/kraal-zzj-iso/herdr-client.sock devcloud
```

自查：第一步之后 `docker inspect` 里的 `Mounts` 必须只指向 `/tmp/kraal-zzj-iso`。
`kraal-herdr` 这类**看起来像沙箱**的现成容器要当作别人的环境处理——它可能挂着
真实会话，重启或写入都会落到使用者身上。

`KRAAL_HERDR_SOCKET` 指定连哪个 daemon，app 和 CLI 都认：

```bash
KRAAL_HERDR_SOCKET=/tmp/kraal-mine/herdr-client.sock \
  ./.build/out/Products/Debug/kraal probe
```

debug 包里的 `Kraal.app` 由 `Scripts/build-app.sh` 自动带上这个变量并默认指向
`/tmp/kraal-mine/herdr-client.sock`；release 包不带，连本机。

这个默认值必须是**只为此目的存在**的路径。写错或写旧的路径比不写更危险：
它会静默解析到该路径上碰巧在监听的 daemon，而不是报错。

---

## 仓库结构

```
Sources/
├── KraalProtocol/      bincode、帧、wire 类型、surface 校验、cell→ANSI、输入解码
├── KraalTransport/     POSIX unix socket、SSH 子进程、socket 路径发现
├── KraalClient/        握手、帧循环、健康检查、API 请求、协议流抽象
├── KraalSidebar/       config.toml 解析、布局规格、token 解析、样式规则
├── KraalUI/            AppStore、侧边栏、标签栏、分屏布局、命令面板、连接面板
├── KraalTerminalView/  Ghostty 接线（pane 裁剪、焦点、几何协商）
├── KraalCLI/           `kraal` 命令行探针
└── KraalMac/           macOS app 入口 + .app 打包
Tests/
├── KraalProtocolTests/ 真实抓包 fixture 驱动的协议回归
└── KraalClientTests/   TOML / 侧边栏规格
Fixtures 在 Tests/KraalProtocolTests/Fixtures/
```

`KraalProtocol` 零第三方依赖，可以在任何平台 `swift test`。只有
`KraalTerminalView` 依赖 Ghostty xcframework。

---

## 验证

```bash
swift test      # 60 个测试
```

真正重要的是这几条：

- **`surface_120x40.bin`（真实抓包）能解出 4800 个 cell，文本与参考逐行一致**
  —— 手写解码器与 Rust 编码器逐字节对得上。
- **cell 网格 → ANSI 的重编码**：首帧完整、次帧只发变更行、颜色走非 ARGB 编码。
- **surface patch 原子性**：revision 缺口 / boot_id 不符 / 行列越界一律拒绝，
  且拒绝后帧内容不变。
- **输入解码**：控制字符、CSI/SS3 方向键、xterm 修饰符、跨包拆分的 UTF-8 与
  转义序列、单个 Esc、坏字节不卡死。

---

## 文档

- **[实施路线](docs/ROADMAP.md)** —— 里程碑与工程约定（含已完成/待办对照）
- **[开发环境](docs/ENVIRONMENT.md)** —— 本机基线、依赖版本、签名与已知坑
- **[技术设计文档](docs/DESIGN.md)** —— 完整设计：连接层、协议类型、渲染、侧边栏引擎
- **[可行性研究（修订版）](docs/feasibility-revised.md)** —— 路线对比与关键实测

`research/` 下保留调研期用的 Python 协议探测脚本（已完成使命，作为交叉参考）。

---

## 许可证

以 **Apache License, Version 2.0** 发布，全文见 [LICENSE](LICENSE)。

协议类型的结构定义衍生自 [herdrdev/herdr](https://github.com/herdrdev/herdr)
与 [penso/herdr-gpui](https://github.com/penso/herdr-gpui)（均为 Apache-2.0）。
归属声明见 [NOTICE](NOTICE)；贡献规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 致谢

Kraal 的实现参考了以下开源项目。它们的作者在同样没有官方客户端文档的情况下，
把这些协议与渲染问题想清楚并写了下来，读它们的代码省下了大量试错。

### [penso/herdr-gpui](https://github.com/penso/herdr-gpui)（Apache-2.0）

一个 Rust + GPUI 的 herdr 桌面客户端，是我们最接近的先行者。

切 tab / 切 workspace 的画面处理方式直接受它启发。它把「客户端认为的当前状态」
（`LiveState.surface`）与「屏幕上正画的那一帧」（`Presentation`）分成两层：
切换焦点时前者立刻置空，后者保留旧帧直到新投影到达。`presentation.rs` 的模块注释
写得比多数文档都清楚：

> *Painting nothing in those gaps flashes the empty background between two pictures;
> a multiplexer redrawing a cell grid never blanks between them.*

同一份注释里还有一条约束我们照做了：*「Retained cells are presentation only.
Hit testing, input routing, and IME placement keep reading `LiveState::surface`」*
——保留的帧只用于显示，命中测试与输入路由必须继续读真实状态，否则点击会打到
已经离开的 pane。Kraal 的 `paneViewFrames` 由 pane 视图自报、与渲染同步，
结构上避免了这种错位，但这条原则是照它确立的。

断连时保留画面并置灰（`Presentation::hold`）、`boot_id` 变化时才丢弃帧、
以及「`projection_revision` 必须与 snapshot `revision` 精确相等才算当前投影」
这几条判定，也都对齐了它的做法。

### [kitknox/rootshell](https://github.com/kitknox/rootshell)（MIT）

一个同样基于 libghostty 的 Apple 平台终端（iOS / iPadOS / visionOS / Mac Catalyst）。
和我们用同一套引擎，所以它的坑就是我们的坑。

它处理切 tab 的方式比「保留旧帧」更进一步：可见性跟着一个**滞后**的
`displayedTabID` 走，而不是跟着当前选中的 tab；并且要等新 tab 的渲染层真的
画出第一帧（`IOSurfaceLayer.contents != nil`，靠 `CADisplayLink` 轮询）才切换，
超时 600 ms 失败开放。那条注释说得很直白：

> *Visibility keys off the lagging displayedTabID (not the selection) so a freshly
> opened tab stays hidden, and the previous tab stays on screen, until its renderer
> has presented a first frame.*

命中测试仍然是跟着选中的 tab 而不是显示中的 tab，和 herdr-gpui 那条
「保留的帧只用于显示」是同一个原则。

它还把自己踩过的坑写进了更新日志（1.0.9-116 *"Fixed Frozen, Blank Tabs When
Switching"*），并记录了根因：surface 卡在 `flags.visible == false` 会让渲染线程
硬停，表现为永久冻结。Kraal 没有这道开关，但「可见性状态必须与实际显示一致」
这条教训我们记下了。

Kraal 目前等的是「新投影到达」而不是「渲染层画出第一帧」——`InMemoryTerminalSession`
没有暴露首帧已呈现的信号，所以这是能达到的上界。副作用是极端情况下仍可能
有一帧空白，靠我们自己的超时兜底。

两个项目的许可分别是 Apache-2.0 与 MIT。这里记录的是思路与协议理解上的参考；
Kraal 的代码为独立实现，未复制上述项目的源码。

Apache License 2.0 不授予商标权。
