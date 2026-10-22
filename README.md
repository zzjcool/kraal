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

**和官方 herdr 的差距**（copy mode、滚动条、popup 浮层、通知、OSC 8 链接等）逐条列在
[docs/GAP-VS-HERDR.md](docs/GAP-VS-HERDR.md)，每条都带上游与我方的代码位置；
同一份文档的 §7 还记了 9 个已定位的错误，其中 4 个已修，各条目的状态一目了然。

---

## 快速开始

```bash
# 构建、测试、lint、GUI 门禁一次跑完
./Scripts/verify.sh

# 打包成真正的 .app（ad-hoc 签名）并启动
./Scripts/build-app.sh
open build/Kraal.app
```

### 换一台机器 / 新 clone 之后（agent 和人都看这里）

两条命令起步，其余自动：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # CLT 缺 XCTest
./Scripts/build-app.sh            # 打包（VM 里没有 Xcode，必须在宿主做）
./Scripts/gui.sh probe            # 起 VM → 部署 → 自检
```

`gui.sh` 默认后端是 **`vm`**，它跑在一个叫 `kraal-agent` 的 Tart 虚拟机上。第一次
在新机器上跑，先执行一次（幂等，已有就只做检查）：

```bash
./Scripts/vm-bootstrap.sh
```

它会：检查 `tart` → 没有就 clone（走国内镜像源）→ headless 启动 → **确认
`launchctl managername` 是 `Aqua`** → 检查三条约 TCC 授权。

如果是全新机器，有两件事 `bootstrap` 只能报告、不能替你决定：

| 缺什么 | 症状 | 怎么补 |
| --- | --- | --- |
| guest 内 SIP 未关 | 写不了 `TCC.db`，三条约授权缺失 | 关 SIP（`docs/ENVIRONMENT.md` §4.6） |
| tart-guest-agent 未被授权 | `AXPress` 能用但点击/拖拽/截图全部失效，看起来像产品 bug | `./Scripts/vm-bootstrap.sh --fix-tcc` |

**为什么不能用 `local` 后端：** 它会驱动你正在用的那张桌面，夺走指针和键盘。
`local` 只用于需要真 GPU 的视觉判断，且会拒绝任何要前台的用例，除非显式
`KRAAL_GUI_ALLOW_FOCUS=1`。

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

开发和自测**必须**在一次性环境里做，不要连任何正在使用的 daemon。GUI 调试会
分屏、打字、关 pane、改布局，这些落在真实会话里就是破坏。

**macOS 上首选 Tart 虚拟机**（脚本已封装）：

```bash
./Scripts/agent-vm.sh start    # 起 VM + 拉起 herdr daemon（~27 s）
./Scripts/agent-vm.sh probe    # Kraal 走 SSH 连进去，看 daemon / pane / surface
./Scripts/agent-vm.sh sh       # 进 VM
./Scripts/agent-vm.sh stop     # 停（不删，下次 start 还是热的）
```

为什么不用容器：Kraal 是 macOS/iOS 客户端，macOS 上容器里跑不了 macOS，而
要验的恰恰是 macOS 语义。VM 里没挂共享目录，改坏了 `destroy` 重新 clone 即可，
代价几分钟。配置与限制见 [ENVIRONMENT.md §4.6](docs/ENVIRONMENT.md)。

容器路线（远端 Linux，适合验跨机/无 macOS 语义的部分）：

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

跨机器行为（切换机器、两台机器的同名 pane）单机验不出来，要在沙箱里再起一个
独立 session 组成双 daemon，做法见
[ENVIRONMENT.md §4.4](docs/ENVIRONMENT.md)。

### 桌面侧隔离（多人 / 多 agent 同机）

daemon 隔离了，桌面还没隔离：第二个 `Kraal.app` 启动时会
`activate(ignoringOtherApps:)` 抢焦点、把窗口盖到你的窗口上、`rotate()` 掉你的
日志。同机并行开发一律走 `Scripts/dev-session.sh`，不要自己 `open build/Kraal.app`：

```bash
./Scripts/dev-session.sh start        # 后台会话启动，不抢焦点
./Scripts/dev-session.sh status       # pid / 日志路径 / 窗口号
./Scripts/dev-session.sh shot a.png   # 只截自己那个窗口
./Scripts/dev-session.sh log 60       # 看自己的日志
./Scripts/dev-session.sh stop         # 只杀自己启动的 pid
```

它靠四个环境变量划清边界，都由 `Scripts/build-app.sh` 生成的 debug launcher
预置（release 包一个都不带，行为不变）：

| 变量 | 作用 | debug 默认 |
|---|---|---|
| `KRAAL_HERDR_SOCKET` | 连哪个 daemon | `/tmp/kraal-mine/herdr-client.sock` |
| `KRAAL_DEV_BACKGROUND` | `1` = 不 activate、不 `orderFrontRegardless`、`.accessory`（不进 Dock/⌘Tab） | `1` |
| `KRAAL_DEV_SESSION` | 隔离窗口位置与日志文件名 | 由 socket 路径派生（`dev-<base36>`） |
| `KRAAL_DEV_BACKGROUND=0` | 想手动看界面时显式恢复前台行为 | — |

窗口位置存 `KraalWindowFrame.<session>`、日志写 `~/Library/Logs/Kraal-<session>.log`，
所以两个会话不会互相踩。**注意 `pkill -f KraalMac` 会把你自己的实例一起杀掉**
——这是 `dev-session.sh stop` 按 pid 文件收尸的原因。

在后台会话里做视觉验证不要截全屏，用日志里那行 `window: number=<id>`：

```bash
screencapture -x -o -l "$WINDOW_NUMBER" out.png   # 只截该窗口，压在你窗口下面也行
```

这样 agent 可以自证渲染结果，不需要把窗口提到前面，也不需要 Accessibility
（Ghostty 由 Metal 绘制，AX 树几乎是空的）。

要**点**某个控件时，别拿截图目测换坐标——先把它提到前台，再按布局数值算：

```bash
osascript -e 'tell application "System Events" to tell process "KraalMac-bin" to set frontmost to true'
```

不激活就点，事件会落到别的窗口上，表现是"点了没反应"，很容易误判成命中区域
有问题。反过来，如果在**已激活**的窗口上仍点不中，那多半真的是布局错了，去查
`.frame` / `.padding` / `contentShape` 的实际数值，而不是继续微调坐标。

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
swift test      # 全绿
```

真正重要的是这几条：

- **`surface_120x40.bin`（真实抓包）能解出 4800 个 cell，文本与参考逐行一致**
  —— 手写解码器与 Rust 编码器逐字节对得上。
- **cell 网格 → ANSI 的重编码**：首帧完整、次帧只发变更行、颜色走非 ARGB 编码。
- **surface patch 原子性**：revision 缺口 / boot_id 不符 / 行列越界一律拒绝，
  且拒绝后帧内容不变。
- **输入解码**：控制字符、CSI/SS3 方向键、xterm 修饰符、跨包拆分的 UTF-8 与
  转义序列、单个 Esc、坏字节不卡死。
- **上游兼容性**：21 个 client tag 逐条对齐、字段序用**手写字节表**（不是我们
  自己的编码器）钉住、三份 herdr-gpui 冻结 fixture 能解码。

### 从上游移植的兼容性测试

参考的三个项目（herdr / herdr-gpui / rootshell）各自有一套成熟测试。适合我们的
部分已移植，**现在全部是绿的** —— 它们当初是红的，每一条指向一个具体差异
（命名字色 SGR 偏一档、半角假名声宽、OSC 8 缺失、`u8` 写成 varint、握手用
error 判新旧、快照 revision 回退、patch 行重叠、重连倒计时错位……）。

这些差异已按缺陷全部修完（issue #1、#3–#10、#18、#19），逐条出处与当时的
差异见 **[docs/PORTED-TESTS.md](docs/PORTED-TESTS.md)**。

迁移期用过 `Scripts/test-baseline.sh` 跳过已知红；名单现在是空的，它退化成
一条普通的 `swift test`。名单一旦重新长出条目就说明有东西坏了 —— `--compare`
会报告「名单里但其实已经绿了」的条目，防止名单变陈。

---

## 文档

- **[实施路线](docs/ROADMAP.md)** —— 里程碑与工程约定（含已完成/待办对照）
- **[移植的上游测试](docs/PORTED-TESTS.md)** —— 抄自哪里、为什么、当时的差异怎么修的
- **[开发环境](docs/ENVIRONMENT.md)** —— 本机基线、依赖版本、签名与已知坑
- **[排查方法](docs/DEBUGGING.md)** —— 怎么验证一件事是真的：样本、A/B 回退、探针纪律
- **[性能测量](docs/PERFORMANCE.md)** —— 怎么量出一件事有多贵：防优化器、真实数据、帧预算
- **[技术设计文档](docs/DESIGN.md)** —— 完整设计：连接层、协议类型、渲染、侧边栏引擎
- **[可行性研究（修订版）](docs/feasibility-revised.md)** —— 路线对比与关键实测

`research/` 下保留调研期用的 Python 协议探测脚本（已完成使命，作为交叉参考）。

---

## 许可证

以 **Apache License, Version 2.0** 发布，全文见 [LICENSE](LICENSE)。

协议类型与行为的权威依据是 [herdrdev/herdr](https://github.com/herdrdev/herdr)
（Apache-2.0），部分结构定义另参考 [penso/herdr-gpui](https://github.com/penso/herdr-gpui)。
归属声明见 [NOTICE](NOTICE)；贡献规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 致谢与参考来源

Kraal 不是照着文档写的——官方没有客户端协议文档。以下项目按重要性排列，
它们的源码是这份实现的事实依据。

### [herdrdev/herdr](https://github.com/herdrdev/herdr)（Apache-2.0）—— 一手依据

**官方实现，本项目的权威依据。** 协议语义、wire 字段、连接生命周期、侧边栏
渲染规则，全部以它为准，不以我们的猜测为准。

本文档写作时对照的是 `v0.9.5`（commit `143bf5f`），约 29 万行 Rust、399 个源文件。
几个反复回来查的地方：

| 官方位置 | 我们从中确认的事实 |
|---|---|
| `src/client/endpoint/supervisor.rs` | 每个 enabled endpoint 启动即连（`next_attempt: Some(now)`），握手一律 `surface_active: false`；退避 500ms→120s，稳定 60s 才重置 |
| `src/client/endpoint/activation.rs` | 切换机器 = 翻转 surface 租约（`surface.set(false)` → `set(true)`），**全程不 disconnect transport** |
| `src/client/endpoint/registry.rs` | `set_surface_active` 只改一个 bool |
| `src/server/headless/render.rs` | 所有 shell client 都持续收 snapshot；只有非 active 的跳过 pane surface |
| `src/client/shell/sidebar.rs`、`endpoint_sidebar.rs` | 侧栏行规则、`├─`/`└─` 嵌套、`↑ahead`/`↓behind` 双色 |
| `src/client/shell/render.rs` | `endpoints.len() > 1` 是「多机」的唯一判据 |
| `src/client/shell/settings.rs` | 设置是一个带页签的浮层，`prefix+s` 打开 |
| `src/client/endpoint/catalog.rs`、`src/cli/machine.rs` | 机器增删只走 CLI，写入 `endpoints.json`，客户端 1s 轮询感知 |

一条工作方法也来自它：**先读官方源码，再动手**。之前有次判断「终端版没有
机器分组」，因为只 grep 了 `sidebar.rs` 而漏了 `endpoint_sidebar.rs`，结论正好
相反——那次之后，凡是「官方有没有 X」的问题都必须给出 文件:行号 作为证据。

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
