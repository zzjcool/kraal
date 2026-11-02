# Kraal

原生 Swift 的 [Herdr](https://herdr.dev) 客户端，为 macOS / iOS / iPadOS 共用一套代码。

> **命名**：`Kraal` 是南非荷兰语的「畜栏」——给畜群一个围起来的落脚处，
> 正如这个 app 给 Herdr 的 agent 群一个随身的窗口。
>
> **商标**：Herdr 是 Herdr, Inc. 的商标。Kraal 是独立第三方客户端，
> 与 Herdr, Inc. 无关联，未获其授权或背书。
>
> **状态：正在从 Herdr 1 迁移到 herdr-core（Herdr 2）。** 目标、硬性决策与
> 对齐口径已冻结在 [docs/HERDR2.md](docs/HERDR2.md)，执行拆单见
> [docs/ROADMAP.md](docs/ROADMAP.md)。当前源码里仍有 Herdr 1 的实现，
> 按 M0–M3 逐层删除；在迁移完成前，下表与命令仅代表旧版本。

---

## 它是什么

Kraal 是 **herdr-core**（`hc`）的 Swift 原生客户端，与官方 `herdr-app` 并列：
同一个终端运行时，同一份布局文档，不同的窗口实现。

```
┌──────────────────────────────────────────────────────────────┐
│  Kraal（Swift / SwiftUI / AppKit）                           │
│  ├─ spaces / tabs / panes   → 客户端自己的模型                │
│  ├─ 侧边栏 / 命令面板 / 设置 → 原生 SwiftUI                   │
│  └─ pane 内容               → Ghostty（libghostty-spm）       │
└───────────────────────────┬──────────────────────────────────┘
                            │ JSON-RPC + framed streams（unix socket）
                    ┌───────▼────────┐
                    │  herdr-core hc │  PTY / OSC 7501 / doc / machines
                    └───────┬────────┘
                            │ ssh <target> hc connect（core 自己做）
                    远程机器上的 core（终端以 `machine/t7` 出现）
```

**关键点：**

- **画面是原始字节。** attach 流直接是程序的 PTY 输出，写进 Ghostty 即可；
  不再有 cell 网格、差分、ANSI 重编码、kitty 图形编码。
- **布局归客户端。** core 没有 workspace/tab/split；Kraal 与官方 app 通过
  core 的 `doc {name:"herdr-app"}` 共享同一份 space/tab/pane 结构。
- **远端归 core。** `hc machine add` 之后，远端终端出现在同一条事件流里；
  Kraal 不再维护 SSH 桥。

---

## 迁移状态

| 里程碑 | 状态 | 内容 |
|---|---|---|
| M0 协议与渲染 | ⏳ | JSON-RPC 明文/帧、hello 门禁、attach 原始字节进 Ghostty、CREDIT、RESIZE/FOCUS |
| M1 布局与文档 | ⏳ | 客户端 space/tab/pane 树、共享 `herdr-app` 文档、私有 view 状态 |
| M2 客户端对齐 | ⏳ | 原生 chrome、命令面/按键、OSC 7501 侧栏、Ghostty 终端 UX |
| M3 交付与清理 | ⏳ | 控制 CLI、gui.sh 重写、性能基线、旧代码清理、iOS |

旧的 Herdr 1 实现（bincode endpoint、cell→ANSI 渲染、服务端布局、SSH 桥）
仍在仓库里，会在 M0–M3 中逐层删除；旧文档已归档到 `docs/archive/`。

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

目标结构（M0–M3 逐步落地；旧目录在清理前仍然存在）：

```
Sources/
├── KraalCore/          hc 协议：JSON-RPC、framed streams、hello、events、doc、machine
├── KraalModel/         space / tab / pane 树、命名、focus 历史、zoom、settle
├── KraalTerminal/      Ghostty 接线：attach 字节 → InMemoryTerminalSession
├── KraalUI/            侧边栏、标签栏、命令面板、设置、连接面板
├── KraalCLI/           `kraal` 控制面（ls / status / do / commands / shot）
└── KraalMac/           macOS app 入口 + .app 打包
Tests/
└── ...                  wire fixture、模型、文档透传、Ghostty 接线
```

`KraalCore` 不依赖 Ghostty，可以在任何平台 `swift test`；只有 `KraalTerminal`
拉 xcframework。旧的 `KraalProtocol` / `KraalSidebar` / `KraalClient`
会在 M0–M3 中删除或改名。

---

## 验证

```bash
./Scripts/verify.sh    # build → test → lint → shellcheck → build-app → gui.sh
```

迁移期的目标判据（详见 [docs/ROADMAP.md](docs/ROADMAP.md)）：

- **wire**：用 `hc schema` 与手写帧 fixture 钉住 JSON-RPC、帧头、CREDIT、事件 reducer。
- **端到端**：`gui.sh` 用 AX 驱动真实窗口，断言 `hc get/list/read --json` 的状态，
  不是断言我们自己发的请求体。
- **性能**：`bench.sh` 测 attach 字节吞吐、N pane 主线程占用、输入→回显延迟；
  基线重录后才谈回归。

旧协议的 bincode / surface / 移植测试随实现删除；`test-baseline.sh` 的
空名单机制保留。

---

## 文档

- **[目标：对齐 herdr-core](docs/HERDR2.md)** —— 架构差异、硬性决策、保留/删除清单、对齐口径
- **[实施路线](docs/ROADMAP.md)** —— M0–M3 里程碑与判据
- **[开发环境](docs/ENVIRONMENT.md)** —— 本机基线、依赖版本、签名与已知坑
- **[排查方法](docs/DEBUGGING.md)** —— 怎么验证一件事是真的：样本、A/B 回退、探针纪律
- **[性能测量](docs/PERFORMANCE.md)** —— 怎么量出一件事有多贵：防优化器、真实数据、帧预算
- **[iOS 移植](docs/IOS-PORT.md)** —— 编译矩阵与阻塞项（协议部分将随 M3 更新）

`docs/archive/` 是 Herdr 1 时代的文档，只作历史参考。

---

## 许可证

以 **Apache License, Version 2.0** 发布，全文见 [LICENSE](LICENSE)。

协议与行为的权威依据是 [herdrdev/herdr-core](https://github.com/herdrdev/herdr-core)
（Apache-2.0，`hc`）与 [herdrdev/herdr-app](https://github.com/herdrdev/herdr-app)
（Apache-2.0，官方 GPUI 客户端）。本文档对照的是 core `0.1.16` / app `0.1.11`
（2026-11-02 实测）。归属声明见 [NOTICE](NOTICE)；贡献规范见
[CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 致谢

Kraal 的协议理解来自 `herdr-core` 的 `schema/hc.openrpc.json` 与 `hc --skill`；
客户端行为对齐参考 `herdr-app` 的 `docs/commands.md`、`docs/labels.md` 与
`src/model.rs`。两者都是 Apache-2.0，这里记录的是思路与协议理解上的参考；
Kraal 的代码为独立实现（Swift），未复制其源码。

Herdr 1 时代的参考项目（herdr / herdr-gpui / rootshell / Rex）已不再作为依据，
相关笔记归档在 `docs/archive/`。

Apache License 2.0 不授予商标权。
