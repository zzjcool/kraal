# Kraal

原生 Swift 的 **herdr-core**（`hc`）客户端，为 macOS / iOS / iPadOS 共用一套代码。
它和官方 `herdr-app` 连接同一个 core、读写同一份布局文档，只是窗口用
SwiftUI/AppKit + Ghostty 实现。

> **命名**：`Kraal` 是南非荷兰语的「畜栏」——给畜群一个围起来的落脚处。
>
> **商标**：Herdr 是 Herdr, Inc. 的商标。Kraal 是独立第三方客户端，
> 与 Herdr, Inc. 无关联，未获其授权或背书。

Herdr 1 的 bincode endpoint、cell→ANSI 渲染、服务端布局和 SSH 桥已经删除。
现在只有一条客户端栈：**JSON-RPC + framed streams → herdr-core**。

---

## 它是什么

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

- **画面是原始字节**：attach 流直接进 Ghostty，不维护第二份 cell 网格。
- **布局归客户端**：space/tab/pane 在本地，与官方 app 共享
  `doc {name:"herdr-app"}`；私有 focus/zoom 只进本地 `view.json`。
- **远端归 core**：只用 `hc machine.*`，客户端不自己维护 SSH。
- **一个入口**：不再有 `KRAAL_HC=1` 开关，也不再有第二个 Herdr 1 窗口。

---

## 快速开始

前提：macOS 14+、Xcode（不是 CLT）、`hc` 在 PATH 上。

```bash
# 1. 启动/确认 core
hc server start
hc server status

# 2. 构建 + 打包 + 启动 HC 窗口
make run FOCUS=0
```

- `make run` 默认 `FOCUS=1`：后台窗口，不抢键鼠，适合截图/验证。
- `make run FOCUS=0`：窗口到前台，正常体验。
- `make run` 会把 debug 的控制 socket 放在 `/tmp/kraal-mine/control.sock`；
  可用 `CONTROL_SOCKET=... make run` 覆盖。

打包后也可以自己启动：

```bash
./Scripts/build-app.sh
build/Kraal.app/Contents/MacOS/KraalMac-bin
```

debug bundle 的 `KraalMac` 是启动器；直接启动 `KraalMac-bin` 才能让
`NSRunningApplication` 拿到真实 pid（见 `docs/AUTOMATION.md`）。

---

## 控制面

窗口运行时，`kraal` 走本机控制 socket：

```bash
kraal commands                 # 69 条动作目录
kraal commands --help
kraal ls                       # spaces / tabs / terminals
kraal status                   # focus / zoom / documents / scrollback
kraal do space.new --name qa
kraal do pane.split --direction right
kraal shot /tmp/window.png
```

退出码：`0` 成功，`1` 动作/业务错误，`2` 无窗口或用法错误。

控制 socket 解析顺序：

1. `KRAAL_CONTROL_SOCKET`
2. `KRAAL_HC_VIEW` 同目录的 `control.sock`
3. `$XDG_CONFIG_HOME/kraal/control.sock`（默认 `~/.config/kraal/control.sock`）

---

## 环境变量

| 变量 | 作用 |
|---|---|
| `HC_SESSION` | core 会话名；默认 `default` |
| `HC_SOCKET` | core API socket；覆盖路径解析 |
| `KRAAL_HC_SOCKET` | 只覆盖 app 读取的 core socket（VM/scratch 用） |
| `KRAAL_HC_VIEW` | 每屏私有状态 `view.json`；同目录默认 control socket |
| `KRAAL_CONTROL_SOCKET` | app/CLI 控制 socket |
| `KRAAL_DEV_SESSION` | 日志与窗口位置的命名空间 |
| `KRAAL_DEV_BACKGROUND` | `1` = 不抢焦点、`.accessory` |
| `KRAAL_LOG` | `0` 关闭日志；默认开启 |
| `KRAAL_KEYS` | keys.json 路径；默认 `~/.config/kraal/keys.json` |

`HC_SESSION` / `XDG_STATE_HOME` / `XDG_CONFIG_HOME` 的解析规则与 `hc` 一致。
测试 socket 必须落在 `/tmp` 下（macOS `sun_path` 上限 103 字节）。

---

## 构建与验证

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

./Scripts/verify.sh          # build + test + lint + shellcheck + build-app
./Scripts/verify.sh --fast   # 跳过 build-app
./Scripts/build-app.sh       # 只打包 build/Kraal.app
```

`swift test` 覆盖 wire、事件归约、文档 CAS、布局树、动作目录、按键、
设置兼容和 HC 终端 live 用例（live 用例需要 `KRAAL_LIVE_HC_TESTS=1`）。

旧的 `Scripts/gui.sh` 和旧 Herdr 1 用例已随旧客户端删除；GUI 自动化重写
仍在 [#235](https://github.com/zzjcool/kraal/issues/235)。UI 改动目前按
`docs/AUTOMATION.md` 的 VM 手工流程取证据。

---

## 隔离验证（Tart VM）

```bash
./Scripts/vm-bootstrap.sh          # 创建/检查 kraal-agent，验证 Aqua + TCC
./Scripts/vm-bootstrap.sh --fix-tcc
```

VM 里跑 HC 的配方见 `docs/AUTOMATION.md`：隔离 `HC_SESSION` + 临时
`XDG_STATE_HOME` / `XDG_CONFIG_HOME`，推入 `hc`、`Kraal.app` 和
`KraalGUIDriver`，用 `tart exec` 驱动。

宿主锁屏只挡 `local` 桌面自动化，不挡 VM：`tart exec` 落在 Aqua 会话里，
仍可启动 HC 窗口、AXPress、合成键盘和窗口截图。

---

## 仓库结构

```
Sources/
├── KraalSocket/        Unix socket + listener
├── KraalHC/            hc 协议：JSON-RPC、framed streams、hello、events、doc、machine、control
├── KraalModel/         space / tab / pane 树、命名、focus、zoom、settle
├── KraalActions/       动作目录、参数校验、keys.json
├── KraalHCTerminal/    Ghostty 接线 + 原生 chrome
├── KraalSupport/       日志、DevSession（Foundation only）
├── KraalCLI/           kraal ls/status/do/commands/shot
├── KraalGUIDriver/     AX/CGEvent 外部驱动（零仓库依赖）
└── KraalMac/           macOS app 入口 + .app 打包
Tests/
├── KraalHCTests/       wire / RPC / 文档 / 事件
├── KraalHCTerminalTests/ 模型、设置、布局、live HC
├── KraalModelTests/    树与文档模型
├── KraalActionsTests/  动作与按键
├── KraalCLITests/      控制面解析
└── KraalSupportTests/  日志与 DevSession
```

---

## 文档

- **[目标与决策](docs/HERDR2.md)** —— HC 架构、已删除的旧实现、保留/放弃边界
- **[实施路线](docs/ROADMAP.md)** —— M0–M3 与剩余工作
- **[怎么跑起来](docs/RUNNING.md)** —— 新机器、依赖、make、VM
- **[验证方法](docs/AUTOMATION.md)** —— VM HC 窗口 + control/daemon 断言
- **[开发环境](docs/ENVIRONMENT.md)** —— 版本、Tart、TCC、已知坑
- **[排查原则](docs/DEBUGGING.md)** —— 怎么证明一件事是真的
- **[性能方法](docs/PERFORMANCE.md)** —— 测量原则（旧渲染基线已作废）
- `docs/archive/` 只作历史参考，不再对应当前代码。

---

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。归属声明见 [NOTICE](NOTICE)。
协议以 `herdr-core` 的 `schema/hc.openrpc.json` / `hc --skill` 与官方
`herdr-app` 的行为为准；Kraal 的 Swift 代码为独立实现。
