<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# 开发环境基线

> 实测记录：2026-10-20 · 本机 macOS 27.0 / Xcode 27.1
>
> 本文档只记录**已验证的事实**。未验证的推断会明确标注。

---

## 0. 结论

macOS 优先开发的环境依赖**已全部就绪**。iOS 侧同样可用，但真机调试还缺 Xcode 内的 Apple ID 登录。

---

## 1. 本机基线

| 项 | 版本 / 状态 |
| --- | --- | --- |
| macOS | 27.0（26A428） |
| 架构 | arm64（Apple Silicon，14 核 / 48 GB） |
| Xcode | **27.1**（27A9275），`xcode-select -p` 已指向它 |
| Swift | **6.4**（swiftlang-6.4.0.34.1） |
| iOS SDK | 27.1 |
| macOS SDK | 27.0（最低部署目标 12.0） |
| iOS 模拟器 runtime | iOS 18.6（可运行 Xcode 27 产物） |
| herdr（本机） | 0.9.4 |
| herdr（远端） | `nj-rssyes` 0.9.1 / `devcloud` 0.9.4 |
| Python | 3.14.6 + `research/.venv`（pyte 已装） |

Xcode 27 的 Swift 6.4 同时满足 `swift-tools-version: 6.0` 和 `6.2`，因此
`libghostty-spm` 的任意 tag 都能解析（Xcode 16.4 的 Swift 6.1.2 无法解析 6.2）。

---

## 2. 依赖清单

### 2.1 Ghostty 渲染：`libghostty-spm`

```swift
.package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "1.6.20261003")
```

- 预编译 `libghostty.a`（binaryTarget，**不需要 zig**）
- xcframework 包含 `ios-arm64` / `ios-arm64_x86_64-simulator` /
  `macos-arm64_x86_64` / `ios-arm64_x86_64-maccatalyst` / `xros-*`
- macOS 切片 `minos = 13.0`，iOS 切片 `minos = 15.0`
- 传递依赖 `MSDisplayLink`

**版本选择注意**

| 写法 | 是否可用 | 原因 |
| --- | --- | --- | --- |
| `revision: "1.6.20261003"` | ✅ | 最新可用 tag |
| `branch: "main"` | ⚠️ | 用 swift-tools-version 6.2，Xcode 27 可解析但不可复现 |
| `exact: "upstream.1.3.1"` | ❌ | 非语义化版本号，SwiftPM 直接拒绝 |
| `from: "1.5.2"` | ⚠️ | 会解析到 1.6.x，实际等价于取最新 |

**Xcode 16.4 时代的坑（已解除）**：1.2.x–1.5.x 的
`TerminalInputAccessoryView.swift` 使用了 `UIGlassEffect`（iOS 26 SDK 符号），
在 Xcode 16.4（iOS 18.5 SDK）下 iOS 编译必失败。Xcode 27 自带 iOS 27.1 SDK，
该问题不再存在。

### 2.2 SSH 传输：`libssh2-spm`

```swift
.package(url: "https://github.com/Lakr233/libssh2-spm.git", from: "1.0.0")
// product: CSSH2，传递依赖 openssl-spm
```

- Homebrew 的 `libssh2` **只有 macOS 切片**，不能用于 iOS，必须走这个 SPM 包
- 已验证 iOS 设备切片 `arm64-apple-ios18.0` 编译通过

### 2.3 工具链

| 工具 | 状态 | 用途 |
| --- | --- | --- | --- |
| `xcodegen` 2.46.0 | ✅ | 从 `project.yml` 生成 `.xcodeproj`（仓库不提交 `.xcodeproj`） |
| `gh` 2.101.0 | ✅ 已登录 `zzjcool` | PR / issue |
| `git` | ✅ push 权限已验证 | |
| `pod` | 有，但**不用** | 统一走 SPM |

### 2.4 调研脚本

```bash
python3 -m venv research/.venv
research/.venv/bin/pip install pyte
```

Homebrew Python 是 PEP 668 externally-managed，**必须用 venv**，不能直接
`pip install`。`.venv/` 已在 `.gitignore` 中。

---

## 3. 代码签名与真机

| 项 | 状态 |
| --- | --- | --- |
| `Apple Development: email@zzj.cool (YMY6FDTW38)` | ✅ 在 login keychain 中 |
| 证书有效期 | 2026-11-20（**约一个月后到期**） |
| Team ID | `589F7R6Q2H`（Personal Team） |
| Provisioning Profile | ❌ 0 个 |
| Xcode 内 Apple ID | ❌ 未登录 |

**真机调试前的阻塞项**（做 M10/M11 时才需要，不阻塞 macOS 开发）：

`Xcode → Settings → Accounts → + → Apple ID → zzj.cool` → 选 Personal Team

登录后 Xcode 会自动生成 provisioning profile。也可用免费的 `CODE_SIGN_IDENTITY: "-"`
做本地临时签名跑 macOS 版。

---

## 4. 运行时环境注意

### 4.1 root 与用户身份

本环境的 pi 会话通过 `sudo` 提升为 **root（uid=0）**。后果：

- `DerivedData` 默认落在 `/var/root/Library/Developer/Xcode/DerivedData`
- `xcrun simctl` 使用 `/var/root` 下的**另一套模拟器容器**，设备 UUID 与 zzj 的完全不同
- 在 root 下构建的产物，GUI 里的 Xcode 看不到

**约定**：本轮开发全部走 `sudo -u zzj`，与 GUI 共用一套 DerivedData 和模拟器。
构建命令统一加 `-derivedDataPath .build/DerivedData` 落到仓库内（已 gitignore）。

### 4.2 TCC 权限

| 权限 | 状态 |
| --- | --- | --- |
| Screen Recording | ✅ `com.kk2.rootshell` |
| Accessibility | ✅ `com.kk2.rootshell-helper` |
| Full Disk Access | ✅ |
| `kTCCServiceDeveloperTool` | ❌ 系统策略禁止授权（`does not allow prompting; returning denied`） |

`DeveloperTool` 拒绝是 macOS 27 对非标准开发者工具入口的安全限制，会影响
GUI 型自动化，**不影响 `swift build` / `xcodebuild` 命令行**。可忽略。

### 4.3 多会话开发（多人 / 多 agent 同机）

实测记录：2026-10-21

第二个 `Kraal.app` 会抢焦点、覆盖窗口、`rotate()` 掉别人的日志。隔离方式与
实测结论：

| 隔离点 | 机制 | 实测 |
|---|---|---|
| 前台焦点 | `KRAAL_DEV_BACKGROUND=1` → 跳过 `NSApp.activate(ignoringOtherApps:)` | ✅ 启动后前台 app 未改变 |
| 窗口层级 | `window.orderBack(nil)` 而非 `makeKeyAndOrderFront` + `orderFrontRegardless` | ✅ 日志打印 `ordered back` |
| Dock / ⌘Tab | `NSApp.setActivationPolicy(.accessory)` | ✅ `lsappinfo` 报 `type="UIElement"` |
| 窗口位置 | `KraalWindowFrame.<session>` | ✅ 两个 session 拿到不同 key |
| 日志 | `~/Library/Logs/Kraal-<session>.log` | ✅ 与 `Kraal.log` 并存 |
| 收尸 | `dev-session.sh stop` 按 pid 文件 | ✅ 只杀自己，用户实例存活 |
| 视觉验证 | `screencapture -l <windowNumber>` | ✅ 2360×1520（非全屏 3456×2234），窗口被压下面也能截 |

**没有采用的做法**：`open -g` 单独用无效，因为 app 自己会 `activate`；
`pkill -f KraalMac` 会误杀用户实例。

**macOS VM 方案的已知局限**：Tart / VirtualBuddy / UTM 都能给 agent 一个完全
独立的桌面，但虚拟 GPU 下 `NSVisualEffectView` 的 `.behindWindow` 材质与真机
不一致。功能回归可以在 VM 里跑，**透明/模糊的视觉定稿必须在真机上做**。

> **更正（2026-10-22，同日复测）**：本节原先写「Accessibility 驱动不可行——
> pane 内容是 Ghostty Metal 画的，AX 树几乎为空」。这句以偏概全了。
> 终端 pane **内部**确实是 AX 盲区（Metal 自绘，无元素），但 Chrome 与菜单
> **不是**：Kraal 在 Tart VM 里实测有 **193 个 AX 节点、105 个带 identifier、
> 163 个可 `AXPress`**，`AXPress` 驱动菜单项 `Split Right` 能让 daemon 侧
> pane 数从 1 变 2。AX 路线对"界面骨架"可用，只有"终端内容断言"不可用。
> 详见 `docs/AUTOMATION.md` §1–2。

### 4.4 多机行为要在双 daemon 上验

单机沙箱验不了跨机器行为，而跨机器**不是**边角情况——它是这套代码最容易错的一条
前提。官方把话说明白了：

> Workspace, tab, pane IDs, and agent names are scoped to one server.
> **Two machines may both contain `w1:p1`**
> —— `docs/next/website/src/content/docs/connecting-machines.mdx:118`

#### 机器列表是全局的，不属于哪个 daemon

这一步很容易踩：机器 profile 存在**一份**文件里，
`~/.local/state/herdr/client/endpoints.json`，账号下所有 Herdr 进程共用。
`herdr machine` 没有 `--socket` 选项，它根本不开连接——所以**把 app 指向沙箱
daemon 并不会隔离这份列表**。

后果是：为了测试加一台临时机器，写的是真实名册；删掉时删的也是真实名册。
别人开着 Herdr 时会看到你的临时机器冒出来，你也可能删掉别人正在用的条目。

`Scripts/build-app.sh` 生成的 debug launcher 因此默认把
`KRAAL_HERDR_HOME=/tmp/kraal-mine/herdr-home` 交给 `herdr` 子进程当 `$HOME`
（只有子进程，app 自己的窗口位置和日志仍用真实 home）。于是开发会话里的机器
列表是空的、跟真实名册完全分开：

```bash
herdr machine list                                     # 你的真实名册，6 台
HOME=/tmp/kraal-mine/herdr-home herdr machine list     # 开发会话看到的，空的
```

`herdr` 读的是 `$HOME/.local/state/...`，实测空目录下会报 "No saved SSH
machines."，真实名册不受影响。

**想在开发会话里验多机**，就把这个隔离关掉、或指到你自己的一份配置：

```bash
KRAAL_HERDR_HOME=/tmp/my-test-home ./Scripts/dev-session.sh start
```

但那样加的机器会进你自己的名册，验完记得删。想彻底不碰真实名册，就复制一份
到临时目录再指过去。

#### `machine add` 有两个隔离面：名册 vs session 目录（2026-10-23 实测）

上面讲的是**名册**。`herdr machine add` 同时还做第二件事：它起一台远端
session 的 daemon。这两件事**看的是两侧不同的变量**，只隔离 `$HOME` 会得到
一个"名册干净、daemon 落在真实账户里"的半隔离状态（issue #75）。

| 隔离面 | 谁写的 | 落在 | 看的变量 |
| --- | --- | --- | --- |
| 名册 | 本地 `herdr machine` | `client/endpoints.json` | 本地 `XDG_STATE_HOME` |
| session | 远端 bridge | `sessions/<name>/` | 远端 `XDG_CONFIG_HOME` |

两者都优先 XDG、否则回落到 `$HOME` 下的固定子目录（名册在
`.local/state/herdr/`，session 在 `.config/herdr/`）。

路径来源（上游，herdr 0.9.5）：名册走 `config::state_dir()`
（`src/client/endpoint/catalog.rs:373-377`），session 目录走
`config::config_dir().join("sessions")`（`src/session.rs:191`、`:331`），
两者的 XDG 优先顺序在 `src/config/io.rs:30-41`。

**为什么本地设 `XDG_CONFIG_HOME` 不管用**：写 `sessions/<name>/` 的那个进程
不在本机。`machine add` 通过 `ssh <target> '/bin/sh -s'` 在远端拉起
`herdr --session <name> remote-client-bridge`，目录是**远端**那个进程用
**远端**的 `config_dir()` 建的。本地 export 再多次也传不过去——ssh 只带
`LANG LC_*`（本机 `/etc/ssh/sshd_config.d/100-macos.conf` 实测）。

三个对照实验（scratch HOME `R=/tmp/m75-roster`，目标是本机
`zheng@127.0.0.1`，远端登录后 `HOME=/Users/<me>`）：

| 实验 | 设置 | 名册 | session 目录 |
| --- | --- | --- | --- |
| A | 只 `HOME=$R` | 隔离 ✅ | 真实 home ❌ |
| B | A + 本地 `XDG_CONFIG_HOME=$R` | 隔离 ✅ | 真实 home ❌ |
| C | A + 本地 `HERDR_SOCKET_PATH=/tmp/x.sock` | 隔离 ✅ | 真实 home ❌ |

A 的名册具体落在 `$R/.local/state/herdr/client/endpoints.json`，session 目录落在
`~/.config/herdr/sessions/<name>/`。C 额外一个事实：`/tmp/x.sock` **根本没被
创建**。

名册侧换 `XDG_STATE_HOME` 也成立（实测名册落到
`$R/state/herdr/client/endpoints.json`）。

**`HERDR_SOCKET_PATH` 管什么、不管什么**：它只改**本地**那台 daemon 的 socket
路径（见 `Scripts/gui.sh` 顶部的注释）。实验 C 证明它与
`machine add --remote-session` 的远端 session 毫无关系——连
`/tmp/x.sock` 都不会被创建，因为 `machine add` 不开本地 daemon。

**怎么真正隔离 session 目录**：只能在**远端侧**让那个进程的环境里带
`XDG_CONFIG_HOME`。实测有效的做法是自己去远端起 daemon：

```bash
# 远端侧（这里用 ssh 到本机模拟）。daemon 需要伪终端，否则报
# "cannot attach without a usable terminal". 注意 macOS 的 script 没有 -c。
ssh <target> 'XDG_CONFIG_HOME=/tmp/m75-rx nohup script -q /dev/null \
  /bin/bash -c "stty rows 40 cols 120; exec herdr --session iso1" \
  >/tmp/rx.log 2>&1 &'
sleep 12
ssh <target> 'XDG_CONFIG_HOME=/tmp/m75-rx herdr session list'
```

```text
name    status   directory
iso1    running  /tmp/m75-rx/herdr/sessions/iso1
```

真实 home 里没有这个 session 目录。

⚠️ **但 `machine add` 不会接管既有 daemon**。实测：远端已经有一台
`XDG_CONFIG_HOME=/tmp/m75-rx` 下的 daemon 时，`machine add --remote-session`
仍然报 "Remote server is ready" 却在**真实 home** 另起一台同名 session，两台
并存（手工起的 daemon 也一样，不是 XDG 特有的）。所以想让它写进 XDG，可控的
只有让**远端进程环境本身**带 `XDG_CONFIG_HOME`（远端 shell 启动文件里 export，
或 sshd `AcceptEnv` + `SendEnv`）。

**清理**：`machine add` 留下的是真实账户里的东西，`rm -rf $R` 清不掉。

```bash
herdr machine remove <profile-id>              # 名册条目
herdr session stop <name> && herdr session delete <name>
# 或按 socket 停：
HERDR_SOCKET_PATH=~/.config/herdr/sessions/<name>/herdr.sock herdr server stop
```

`session delete` 会把目录一起删掉（实测）。`Scripts/gui.sh` 的 machines
fixture 的 `machines_teardown` 已经对 `fx-alpha`/`fx-beta` 做了这件事：先按
socket 停 daemon，再 `rm -rf "$HOME/.config/herdr/sessions/$s"`。

**未验证的部分**：

- **非本机 ssh（真正跨网络）**是否同样行为。理论上一样（远端跑的是同一份
  上游代码），但**没测过**；上面的实验全是 loopback。
- 远端 `~/.zshenv` 里 export `XDG_CONFIG_HOME` 能否让 `machine add` 起的
  bridge 继承。只验证了「非交互 ssh 会 source `~/.zshenv`」（远端 PATH 里确实
  带 `.zshenv` 设的 `$HOME/.local/bin`，是个能区分对错的样本），**没有**为
  此改真实 dotfile 做端到端。
- `SendEnv` 路线：本机 sshd 只收 `LANG LC_*`，`SendEnv=MARKER` 实测被丢弃，
  因此改用 `AcceptEnv` 的方案未端到端验证。

也就是说 pane id 只在单台 daemon 内唯一。凡是按 `paneId` 建索引的地方——终端池、
SwiftUI 的 `ForEach` 身份、复用判断——都可能把两台机器当成同一台。而两台机器的
**几何完全相同**（第一个 workspace 的第一个 pane 都是 `w1:p1`、同样的分屏比例、
同样的 innerRect），所以任何"数字没变就别重画"的判断在这条路径上必然失效。

同一台机器内切 workspace 验不出这些：paneId 前缀不同，集合比较能兜住。必须有两个
真正的 daemon。做法是在沙箱里再起一个独立 session：

```bash
# 1. 容器里起第二个 daemon（需要伪终端，stty 显式给尺寸）
ssh devcloud 'docker exec kraal-zzj-sandbox bash -lc "
  nohup script -qec \"stty rows 40 cols 120; herdr --session kraal-b\" /dev/null \
    > /root/b.log 2>&1 &"'
sleep 12
ssh devcloud 'docker exec kraal-zzj-sandbox herdr session list'   # 应看到 kraal-b running
```

它的 socket 在容器内 `/root/.config/herdr/sessions/kraal-b/herdr-client.sock`，宿主机
看不见。两条路把它接到本机：

- **只想用 CLI 查**：容器里没 socat/nc/包管理器，可用 `python3` 写个 TCP→unix socket
  转发，再 `ssh -L` 接到那个端口；
- **想让 Kraal 自己连（GUI 验证）**：app 的 SSH transport 执行的是
  `herdr --session <name> remote-client-bridge`，所以 daemon 必须在**宿主机**上可达。
  `docker cp` 出一个同版本二进制到宿主机再起 session 即可。

然后在 Kraal 侧注册成一台"机器"：

```bash
herdr machine add devcloud --label AAA-sandbox-b --remote-session kraal-b
herdr machine list                                    # 确认 remote session 是 kraal-b
```

验完**必须清理**，否则会污染你自己和别人的机器列表：

```bash
herdr machine remove <profile-id>
ssh devcloud 'herdr session stop kraal-b && rm -f /tmp/herdr-095'
```

判断两台是不是真的不同，看 `bootId`——daemon 启动时打上，两台永不撞：

```bash
kraal --socket /tmp/kraal-mine/herdr-client.sock | grep ^boot
kraal --socket /tmp/kraal-b/herdr-client.sock    | grep ^boot
```

想确认没串台，给两边同名 pane 写**不同内容**再来回切：

```bash
kraal --socket <A> send-text --pane w1:p1 --text "clear; echo MACHINE_A"
kraal --socket <B> send-text --pane w1:p1 --text "clear; echo MACHINE_B"
```

切换后若屏上是另一台的字，就是串台；若是自己的字，状态隔离正确。

### 4.5 网络

- GitHub HTTPS / SSH 均通，release 资产下载实测 ~8.7 MB/s
- 无系统代理；`swcdn.apple.com` 可达
- 远端 herdr 通过 `ssh -o BatchMode=yes` 免交互认证
- 本机 `nj-rssyes` 是 **Debian Linux**（非 macOS），不能跑 macOS GUI 隔离

### 4.6 Tart VM（`kraal-agent`）作为验证环境

宿主机上有一个常驻的 Tart VM，验证优先级高于直接动宿主机：真正 macOS 语义
（TCC、签名、Spotlight、`darwin` 行为）在宿主机上改东西代价大，在 VM 里毁掉重来
很便宜。

```bash
./Scripts/agent-vm.sh status   # 起停 / IP / SSH / herdr / pi 一屏看完
./Scripts/agent-vm.sh start    # 无窗口启动，拉起 herdr daemon，等 SSH 就绪
./Scripts/agent-vm.sh probe    # 用 Kraal 走 SSH 连进 VM 的 herdr daemon
./Scripts/agent-vm.sh sh       # 进 VM
./Scripts/agent-vm.sh exec …   # 在 VM 里跑一条命令
./Scripts/agent-vm.sh stop     # 停（不删）
```

裸 `tart` 命令仍可用：

```bash
tart list                      # 确认 kraal-agent 是 running
tart ip kraal-agent            # 例如 192.168.64.2
tart exec kraal-agent uname -a # 不要写 `--`，会 exit 125
```

#### `kraal-agent` 是唯一副本（2026-10-22 起）

克隆源 `tahoe-base` 已删除以回收 31GB，所以**没有本地模板可再克隆**。它是
`gui.sh` 的默认后端（`KRAAL_GUI_VM` 默认值），坏掉就没有 GUI 门禁了。

丢了的重建路径，按代价从低到高：

1. **VM 还在，只是状态脏**：`tart stop --force kraal-agent` 后重启即可；guest 内
   的 `/tmp/kraal-gui/` 是部署产物，`gui.sh` 每次运行都会重新推一份，不用清理。
2. **VM 镜像坏了**：`tart pull ghcr.io/cirruslabs/macos-tahoe-base:latest`
   （走 `ghcr.nju.edu.cn` 镜像源，直连 GHCR 实测 ~116 KB/s）。
3. **重建后要重做的 guest 侧设置**：autologin 用户 `admin`、SIP 关闭
   （TCC 预授权需要，见 §4.3）、网络出网。

健康自检（三条都应通过）：

```bash
./Scripts/vm-bootstrap.sh                                     # 一次检查全部前置条件
tart exec kraal-agent /bin/bash -lc 'launchctl managername'   # 必须是 Aqua
./Scripts/gui.sh probe                                        # axTrusted=true
./Scripts/gui.sh run split-right                              # panes 1 -> 2
```

#### guest 内的 TCC 授权（迁移时最容易漏的一步）

`tart exec` 走 guest agent，所以**需要授权的进程是 `tart-guest-agent`，不是
sshd、也不是 Kraal**。三条缺一不可（2026-10-22 实测的条目格式）：

```
kTCCServiceAccessibility   auth_value=2   AXPress 与元素树
kTCCServicePostEvent       auth_value=2   CGEvent 点击/拖拽/键盘
kTCCServiceScreenCapture   auth_value=2   screencapture
```

`client_type=1` 表示按绝对路径匹配（`/opt/homebrew/Cellar/tart-guest-agent/<ver>/bin/tart-guest-agent`），
`auth_value=2` 表示允许。

**失败表现很误导**：只缺 `PostEvent` 时，`AXPress` 照常工作，于是
`split-right` 这类用例全绿，但 `drag-divider` 会报"拖拽没生效"，
看起来像拖拽功能坏了。缺 `ScreenCapture` 时 `screencapture` 返回 0 却写出
全黑 PNG（§8.4）。

写入需要两个条件，缺一不可：

1. guest 内 **SIP 关闭**（base 镜像默认就是关的）
2. **`sudo`** —— `TCC.db` 是 `root:wheel 0644`，普通用户 `sqlite3` 写入直接报
   `attempt to write a readonly database`。根卷虽然 sealed 只读，但 `sudo` 下
   sqlite3 能写（2026-10-22 实测 `rc=0`）。guest 的 `admin` 有免密 sudo。

自动修复：

```bash
./Scripts/vm-bootstrap.sh --fix-tcc
```

手动等价（guest 内，需 `sqlite3`）：

```sql
insert or replace into access
  (service, client, client_type, auth_value, auth_reason, auth_version,
   csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier,
   indirect_object_code_identity, flags, last_modified)
values ('kTCCServicePostEvent', '<agent 绝对路径>', 1, 2, 0, 1,
        NULL, NULL, 0, 'UNUSED', NULL, 0, strftime('%s','now'));
```

之后 `killall tccd` 并重启 guest agent 才会生效。

#### ⚠️ 升级 guest 里的 Homebrew 包会让授权全部失效

`client` 存的是**解析符号链接后的绝对路径**，而 Homebrew 的 Cellar 路径含版本号：

```
TCC 里：  /opt/homebrew/Cellar/tart-guest-agent/0.15.0/bin/tart-guest-agent
符号链接：/opt/homebrew/bin/tart-guest-agent -> ../Cellar/tart-guest-agent/0.15.0/bin/...
```

`brew upgrade tart-guest-agent` 之后，`/opt/homebrew/bin/...` 指向 `0.16.0/`，
而 TCC 里那条 0.15.0 的路径再也没有进程去匹配它。**授权条目仍然"存在"**，
所以任何只看"条目在不在"的检查都会误报健康。

症状和缺授权完全一样：`AXPress` 正常，但点击/拖拽/截图全部失效。

所以：**guest 里升级 Homebrew 包之后，必须重跑 `./Scripts/vm-bootstrap.sh --fix-tcc`。**
`--fix-tcc` 用当前的实际路径重新插入条目（`insert or replace`），旧条目会留着但无害。

第一条最关键：`tart exec` 落在 **Aqua** 会话是合成事件能进 app 的唯一原因
（§4.5）。如果这里返回 `Background`，`drag-divider` 这类用例会全部失败，
而且看起来像产品 bug。

VM 没起来时无头启动（不抢焦点，和在跑的桌面并存）：

```bash
tart run --no-graphics kraal-agent
```

#### 配置（2026-10 实测，Tart 2.32.1 / macOS 26.6.2 build 25G83）

| 项 | 值 |
| --- | --- |
| CPU / 内存 / 磁盘 / 显示 | 6 vCPU / 12 GB / 80 GB / 1920×1200 |
| 用户 | `admin`（密码 `admin`），免密 sudo |
| herdr | 0.9.5，`~/.local/bin/herdr`；daemon 由 `start` 拉起，**不是** login item |
| pi | 1.3.0，`/opt/homebrew/bin/pi`，带完整配置与 SOP 库 |
| node | v24.22.0（镜像自带 `node@24`） |

#### ⚠️ `tart set --display` 不会改 guest 已保存的分辨率（2026-10-22 实测）

这是换机器后最容易踩的一步，表现和产品 bug 一模一样。

`tart get kraal-agent` 报 `Display 1920x1200`，VM 配置
`~/.tart/vms/kraal-agent/config.json` 里也是 `1920x1200`，
但 guest **实际**运行在 `1024×768`：

```bash
tart exec kraal-agent /bin/bash -lc 'plutil -p /Library/Preferences/com.apple.windowserver.displays.plist' \
  | grep -E 'Wide|High|Scale'
#   "Wide" => 1024 / "High" => 768 / "Scale" => 2      ← 实际生效的模式
```

原因：`tart set --display` 只改**虚拟显示器支持的尺寸**，而 macOS 把自己的
显示模式存在 `windowserver.displays.plist` 里；那份偏好优先。停 VM、
`tart set --display 1920x1200`、重启，**仍然是 1024×768**（实测）。

**这条为什么危险**：Kraal 默认窗口 1180×760，屏幕只有 1024×768 时窗口被压成
1004×660。而 `drag-divider` 当时把终端容器宽度写死成 959pt（1180pt 窗口下
sidebar 221pt 的值），窗口一窄，算出的分隔条坐标就落进右侧 pane，拖拽打在终端
上而不是分隔条上。用例报的却是「stuck: the drag never reached the daemon」——
读起来像产品回归，实际是环境。其余 4 个用例照旧全绿，更容易误判。

**修法**：在 guest 里用 CoreGraphics 切到目标模式并永久保存。

```bash
cat > /tmp/setmode.swift <<'EOF'
import CoreGraphics
import Foundation
let d = CGMainDisplayID()
guard let modes = CGDisplayCopyAllDisplayModes(d, nil) as? [CGDisplayMode],
      let m = modes.first(where: { $0.width == 1920 && $0.height == 1200 })
else { print("no such mode"); exit(1) }
var cfg: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { exit(1) }
CGConfigureDisplayWithDisplayMode(c, d, m, nil)
print(CGCompleteDisplayConfiguration(c, CGConfigureOption.permanently).rawValue)
EOF
tar -czf - -C /tmp setmode.swift | tart exec -i kraal-agent /bin/bash -lc \
  'mkdir -p /tmp/dd && cd /tmp/dd && tar -xzf - && /usr/bin/swift setmode.swift'
```

`permanently` 是必需的，否则重启回 1024×768（`permanently` 已实测跨重启保持）。
guest 里没有 Xcode 但**有** `swift`，所以这段能直接跑；`swift -e` 也行。

可用的模式共 16 个，含 `1280x800` / `1600x1200` / `1920x1200` / `2560x1600`。
检查当前值最快的方式是读 `windowserver.displays.plist` 里的 `Wide`/`High`，
不要信 `tart get`。

#### 限制（实测）

| 项 | 实际情况 | 影响 |
| --- | --- | --- |
| Xcode | **没有**。`xcode-select -p` = `/Library/Developer/CommandLineTools`，`xcodebuild` 报 “requires Xcode” | 能跑 `swift build` / `swift test`，**不能** `xcodebuild`、不能出 `.app` 包 |
| Swift | 有。`/usr/bin/swift`，Swift 6.4，target `arm64-apple-macosx26.0` | 纯 SwiftPM 验证可行 |
| 共享目录 | **没有**。`/Volumes` 只有 `Macintosh HD`，无 VirtioFS | 宿主机↔guest 传文件只能靠 `tart exec` 的 stdio 管道或走网络 |
| Automation Mode | **关着**。有 `TCC.db`，`AXIsProcessTrusted` 返回 true（`sshd-keygen-wrapper` 有授权条目） | 不是权限问题，见下方 |
| 合成鼠标/键盘事件 | **看通道**：经 SSH ❌（Background 会话）；经 **`tart exec` ✅**（Aqua 会话，2026-10-22 实测） | 见下方「两条通道的行为完全不同」 |
| 常用命令 | 缺 `mount`、部分 `system_profiler`、`timeout` | 排查挂载用 `df`；guest 的 `sh` 的 `echo` **不支持 `-n`**，用 `printf`；等超时自己写循环 |
| 网络 | 出网正常但慢；拉 OCI 镜像直连 GHCR 只有 ~116 KB/s | 拉镜像走 `ghcr.nju.edu.cn` 镜像源（实测 ~19 MB/s） |

**不要拉 `macos-tahoe-xcode` 大镜像**，除非明确需要 Xcode 且用户同意——它几十 GB，
而这里的绝大多数验证（SwiftPM 构建、纯逻辑、协议）用不上 Xcode。

因此分工是：**逻辑与测试放 VM**，**app 打包留在宿主机**（VM 无 Xcode、无外网），
**GUI 验证也放 VM**（`tart exec` 落在 Aqua 会话，见下）。

#### 两条通道：SSH 是 Background，`tart exec` 是 Aqua

先给结论，再看证据：**这台 VM 里能不能注入鼠标/键盘，取决于用哪条通道进去**，
而 `Scripts/gui.sh` 用的是能用的那条。

实测记录：2026-10-22（两次，第二次推翻了第一次的结论）

踩过的坑，按顺序：

1. 先判断成「Accessibility 没授权，事件被丢弃」。**错**：
   `AXIsProcessTrusted` 返回 **true**（`TCC.db` 有 `sshd-keygen-wrapper|2`）。
2. 再判断成「VM 里没有 Aqua 会话」。**也错**：

   ```bash
   launchctl print user/501    # subdomains = { gui/501 }
   launchctl print gui/501     # session = Aqua
   ```

   VM 登录后一直有一个 Aqua 会话，与 `tart run --no-graphics` 无关——那个
   开关只影响宿主机要不要建窗口，不影响 guest 内部的 loginwindow。
3. 真正的问题：**从 SSH 启动的进程不在那个会话里**。

   ```bash
   launchctl managername        # → Background
   ```

`CGEvent` 只在 Aqua 会话内被 WindowServer 路由给前台 app。Background 会话
里，光标位置能设（那是 WindowServer 的直接属性，实测指针确实从 (600,364)
挪到了 (400,400)），但「投递给 app 的鼠标事件」不成立——连 Dock 图标都点
不动，自己 post 的事件在自己的 `CGEventTap` 里也看不到。

**为什么绕不过去**：`sudo` 只改 UID/GID，不跨 Mach bootstrap namespace
（[aahlenst: Accessing the macOS GUI](https://aahlenst.dev/blog/accessing-the-macos-gui-in-automation-contexts/)
说得很直接：「You cannot switch to a different namespace using `sudo` because
`sudo` is operating on UID/GID and not on the Mach layer」）。

**试过、都失败的四种方式**（同一天实测，探针自己报 `SessionGetInfo` 的
`sessionHasGraphicAccess`）：

| 方式 | `sessionHasGraphicAccess` | `AXIsProcessTrusted` |
| --- | --- | --- |
| SSH 直接运行 | false | true（sshd 的授权） |
| 打成 `.app` 后 `open` | false | false |
| `launchctl bootstrap gui/501` + `LimitLoadToSessionType=Aqua` | false | false |
| `sudo launchctl asuser <uid>` | 直接报 `Could not switch to audit session` | — |

作为对照，`open ~/Kraal.app` 启动的 app **确实在** Apple 的 GUI 域里：

```bash
sudo launchctl procinfo <kraal pid>
#   domain = gui/501 [100003]
#   spawn type = app (1)
```

所以「能启动一个 GUI app」与「能从脚本注入输入」是两件事。后者需要一个已经在
Aqua 会话里的进程去发事件，而这个进程从 SSH 创建不出来。

**tart 侧还有什么可试**（未验证完，写下来避免重复踩）：

- `tart run --vnc-experimental <vm>`：实测**能起**，在
  `127.0.0.1:<随机端口>` 开 VNC，并自动 `open vnc://…`。宿主机上 Screen Sharing
  进程确实出现了（`CGWindowListCopyWindowInfo` 能看到），但本次连接只停在一个
  43×56 的工具栏小窗，没展开成 VM 画面——未确认是等待时间不够还是连接失败。
  **这条路最有希望**：VNC 客户端在宿主机是普通 Aqua app，往它发输入等于往
  guest 发真 HID 事件，完全绕开 namespace 问题。
- `tart run <vm>`（带窗口）从 SSH shell 启动**不加窗口**：`tart` 进程在
  `Background` domain，创建不了窗口。`open -a tart --args run …` 也不行，
  因为 `/Applications/tart.app` 的 `CFBundleExecutable` 就是 CLI 本体，不是
  GUI 前端。要在宿主机开窗，得从一个已经在前台的终端里跑。
- `open` 打 `.app` 时若报 `-10825`，是 `kLSIncompatibleSystemVersionErr`：
  编译没指定 deployment target，继承了宿主 SDK（实测 `minos` 比 guest 新）。
  加 `-target arm64-apple-macosx14.0` 重编即可。

上游说法一致（[mac-type-string](https://github.com/bgolinvaux/mac-type-string)）：

> SSH sessions: Even if you SSH into a Mac, the shell has no connection to the
> window server. … There is no workaround: CGEvent posting is fundamentally a
> GUI-session operation.

**结论（仅限 SSH）**：SSH 这条通道在 VM 里验不了「点一下/拖一下」——它落在
Background 会话，缺的是 WindowServer 的路由通道，与 Accessibility 权限无关。

**但这不等于 VM 里不能注入**。`tart exec` 走 guest agent，落在 **Aqua** 会话，
图表见下。所以本项目的 GUI 验证一条也不用 SSH。

---

**同一台 VM，`tart exec` 和 SSH 的行为完全不同。**

| 通道 | `launchctl managername` | 能否注入鼠标/键盘 |
| --- | --- | --- |
| `ssh admin@<vm-ip>` | `Background` | ❌ 光标会动，点击不进 app |
| `tart exec <vm> …` | **`Aqua`** | ✅ 实测可用 |

> ⚠️ 早先「要在 VM 里验点按，就得有一个真的 Aqua 会话里的人（VNC、Tart 窗口）」
> 这句只说对了一半。`tart exec` 就走在那个人所在的会话里——base 镜像配了自动
> 登录（`autoLoginUser = admin`），WindowServer 与 loginwindow 都在跑，
> 不需要 VNC，也不需要图形窗口（`--no-graphics` 即可）。

2026-10-22 用 A/B 实测（完整日志 `/tmp/kraal-vm-probe5.log` E25/E26、
`/tmp/kraal-vm-probe6.log` E27）：

| 项 | 结果 |
|---|---|
| `launchctl managername`（cwd = tart exec） | `Aqua` |
| 靶 app 的 `mouseDown` 回调 | ✅ 收到 `mouseDown at (200.0, 166.0) hits=1` |
| **对照组**：点在同一 app 窗口之外 | ✅ `hits=0`（证明不是"无条件记一次"） |
| `NSTextField` 收键盘 | ✅ `KB_RESULT value=abcd` |
| `screencapture -x -o -l <windowNumber>` | ✅ 1180×760 PNG |
| **端到端**：`AXPress` 菜单 `Split Right` → daemon | ✅ `herdr pane list` **1→2**，再按 → **2→3**，`Split Down` → **3→4** |

**之前为什么判错（两次）**：

1. 测的是 **SSH**，但结论被推广成了整个 VM。
2. 首次 `tart exec` 注入失败时，真实原因有两个，都不是 Aqua：
   - 前台有个 TCC 授权弹窗 `universalAccessAuthWarn` 抢焦点（截图里可见）；
   - 目标窗口**没激活**，且点击坐标是硬编码的，落在别的窗口上。
   修法：先 `activate()` → 用 AX 读 `kAXPosition`/`kAXSize` 现算坐标 → 再 post。

这是 `docs/DEBUGGING.md` 第 1 条（样本要能区分对错）和第 3 条（探针要测对对象）
的又一个实例：**没有对照组时，"没生效"无法区分是事件没送达还是没点中**。

#### 这条通道撑起了整个 GUI 门禁（2026-10-22 再次确认）

`Scripts/gui.sh` 的 `vm` 后端就是走 `tart exec`，五个用例全部真跑：

| 用例 | 需要什么 | 结果 |
|---|---|---|
| split-right / menu-split / split-down / close-pane | 只需 `AXPress` | ✅ |
| **drag-divider** | **真实鼠标拖拽**（CGEvent 按下/拖动/抬起） | ✅ 并测出 2 倍位移 bug（见 §8.8） |

`drag-divider` 是最强的反证：如果 `tart exec` 进不了 Aqua，`CGEvent` 的拖拽
不可能被 `DragGesture` 接住，更不可能让分隔条移动并算出 ratio。

**所以不需要 VNC 也不需要人操作。**（`KRAAL_AGENT_VM_GRAPHICS=vnc` 仍然保留，
它的用途是给人**看**画面，不是给脚本**注入**输入。）

#### 探针已删除（原「进程内探针还要不要」一节）

2026-10-22：探针（`KRAAL_PROBE_*` 与同类的 `KRAAL_MACHINES_DEMO`）已从产品代码
移除，共 -146 行。删除前先补了 `drag-divider` 用例替代其覆盖，理由见
`docs/AUTOMATION.md` §13 决策 2。

探针当年要验的三件事——命令发出去了吗、参数对不对、daemon 状态变了吗——现在由
`herdr pane layout` 的几何断言承担，而且比探针更强：它经过真实 AppKit 事件分发，
那正是 `fa3496e`/`e82c104`/`2156703` 三个 bug 所在的地方。

传文件用 `tart exec -i` 的 stdio 管道，比 scp 稳妥（guest 的 sshd 要单独开，
而 guest agent 一直可用）：

```bash
tar -czf - ~/.pi/agent/skills | tart exec -i kraal-agent /bin/bash -c 'tar -xzf - -C ~/.pi/agent'
```

---

## 5. 已知待验证项（承接 DESIGN.md §12）

| # | 项 | 现状 |
| --- | --- | --- | --- |
| 1 | `libssh2` 单 session 多 exec channel 并发 | 未验证 |
| 2 | `terminal session control --cols/--rows` 是否改远端 PTY | 未验证 |
| 3 | 三个 optional codec 开启后的收益 | 未验证 |
| 4 | Ghostty 对 herdr ANSI 的实际渲染一致性 | 未验证（Ghostty 已接好，尚未做逐行比对） |

**注意 `research/04_ansi_vs_surface.py` 当前 18/18 行不一致**：根因是
attach 使用的 `cols/rows` 与 pane 的 `inner_rect`（118×18）不匹配，触发了远端
resize，不是渲染器的问题。这正是待验证项 #2 的入口，做 M4 时需要先修脚本再比对。

---

## 6. 未验证的推断（做对应阶段时必须复核）

- Xcode 27 的 iOS 26+ SDK 是否改变了 `UITerminalView` 的键盘/安全区行为
- macOS 27 上 Ghostty Metal surface 在 `NSHostingView` 中的 resize 时序
- 模拟器 runtime 18.6 与本项目 UI 的手势/键盘适配细节

---

## 7. 重建 `kraal-agent` 虚拟机

`./Scripts/agent-vm.sh destroy` 之后按这里重建。整个过程约 10 分钟，绝大多数时间
花在拉基础镜像上。

### 7.1 拉基础镜像

```bash
brew install --cask zheng/local/tart          # 若尚未安装（当前 2.32.1）

tart clone ghcr.nju.edu.cn/cirruslabs/macos-tahoe-base:latest kraal-agent
```

**走 `ghcr.nju.edu.cn` 镜像源**。直连 GHCR 实测只有 ~116 KB/s，80 GB 的镜像要拉
一个多小时；换镜像源后 ~19 MB/s。`tart list` 里能看到本地已缓存的那份 OCI 镜像，
可以直接 `tart clone` 它而不重新下载。

### 7.2 配置资源

```bash
tart set kraal-agent --cpu 6 --memory 12288 --disk-size 80
tart set kraal-agent --display 1920x1200
```

### 7.3 起 VM 并初始化

```bash
./Scripts/agent-vm.sh start     # 无窗口启动，等 guest agent 与 SSH 就绪
./Scripts/agent-vm.sh sh        # 进 VM（用户 admin，密码 admin，免密 sudo）
```

guest 里要装的：

```bash
# Homebrew（镜像自带，确认在 PATH）
eval "$(/opt/homebrew/bin/brew shellenv)"

# herdr
curl -fsSL https://herdr.dev/install.sh | sh     # 装到 ~/.local/bin/herdr

# node（镜像自带 node@24：/opt/homebrew/opt/node@24/bin）
# pi
npm install -g @earendil-works/pi-coding-agent
```

**daemon 不是 login item**，镜像里没有对应配置，由 `agent-vm.sh start` 显式拉起。
不要指望重启后自动恢复。

### 7.4 同步 pi 配置

guest 没挂共享目录（见 §4.6 限制表），传文件用 `tart exec -i` 的 stdio 管道：

```bash
tar -czf - ~/.pi/agent/skills | tart exec -i kraal-agent /bin/bash -c 'mkdir -p ~/.pi/agent && tar -xzf - -C ~/.pi/agent'
```

跨机器同步的完整注意事项（绝对路径、原生二进制、平台差异）见
`sop:sync-pi-config-to-remote-machine`。

### 7.5 验收

```bash
./Scripts/agent-vm.sh status    # vm/ip/ssh/herdr/daemon/pi/node 全绿
./Scripts/agent-vm.sh probe     # Kraal 走 SSH 连进 VM 的 daemon，打印快照
```

`probe` 能打印出 workspace / pane / surface，就说明整条链路（SSH 传输、
`remote-client-bridge`、endpoint 握手）在 VM 里也成立。

### 7.6 guest 里能做什么、不能做什么

| 能 | 不能 |
| --- | --- |
| `swift build` / `swift test`（Swift 6.4 自带） | `xcodebuild`、出 `.app` 包（没有 Xcode） |
| 跑 herdr daemon 并作为多机验证的一端 | UI 自动化：经 SSH 无 Aqua 会话，合成事件进不了 app（见 §4.6） |
| 改坏后 `destroy` 重来 | 透明/模糊材质的视觉定稿（虚拟 GPU 与真机不一致，见 §4.3） |

所以分工是：**逻辑与测试放 VM**，**app 打包与 GUI/点击类验证留在宿主机**。


---

## 8. 宿主 GUI 自动化能力实测（2026-10-22）

用 `Sources/KraalGUIDriver` 在 M4 Pro / macOS 27.0 上直接测出来的事实。
这些不是推断，每一条都有可复现的命令。

### 8.1 `AXPress` 不需要焦点

目标 app 用 `orderBack` 送到所有窗口后面、前台是 Brave Browser 时，
`AXPress` 仍然投递成功（靶 app 收到 press），**前台全程没有变化**。

这是 `local` 后端能在用户正常使用电脑时跑的前提。

### 8.2 `AXWindows` 在 macOS 27 上不可用

树本身是好的（Kraal 的 AX 树 1362 个可寻址元素，菜单项齐全），
但 `kAXWindowsAttribute` 返回的元素：

| 查询 | 结果 |
| --- | --- |
| `AXRole` | `AXApplication`（app 自身，自引用） |
| `AXPosition` / `AXSize` | AXError **-25205**（`.illegalArgument`） |
| `AXMainWindow` / `AXFocusedWindow` | 同样返回 app 自身 |

与激活策略无关（`.regular` 与 `.accessory` 都一样），与是否重启无关。
**Finder 从同一属性返回 `AXScrollArea`**，所以这是系统级问题，不是 Kraal 的。

结论：窗口几何一律走 `CGWindowListCopyWindowInfo`（那里 `kCGWindowBounds`
和 `kCGWindowNumber` 都是准的）。`screencapture -l` 本来也需要
`kCGWindowNumber`，所以这不是额外成本。

### 8.3 AX 图不是树，DFS 必须带 visited

`AXMenuBar` 同时可以从 `AXApplication` 和 app 的 children 两条路径到达，
菜单子树还会在自身之下重复出现。没有 visited 集合时：

```bash
$ kraal-gui press --title "Split Right"
kraal-gui: title=Split Right matches 13 elements
```

**13 个**，而实际上只有一个。这让「这个 title 是否唯一确定一个元素」这个
driver 赖以拒绝歧义按压的判据失效。加 `Set<CFHashCode>` 后恢复为 1。

### 8.4 截图权限：exit 0 + 全黑

没有「屏幕录制」授权时，`screencapture` **返回 0 并写出一个合法的、
全黑的 PNG**。把它当成功会让截图断言永远通过而什么都没证明。

实测还有一条更窄的坑：`screencapture -l <windowid>` 在本机对**每个** app 都
失败（`could not create image from window`），Herdr 的窗口同样失败，
而全屏 `screencapture -x` 成功。所以驱动先试 `-l`，失败则截全屏 + `sips` 裁剪，
并且无论如何都检测结果是否均匀纯色，是则 `exit 2` 并说明缺哪个权限。

### 8.5 锁屏会禁用合成事件，但不禁用 AXPress

```bash
$ ioreg -n Root -d1 | grep -A1 IOConsoleLocked
  <key>IOConsoleLocked</key>
  <true/>
```

锁屏时前台是 `loginwindow`（pid 610），`NSWorkspace.frontmostApplication`
就是它。此时：

| 手段 | 锁屏下 | 说明 |
| --- | --- | --- |
| `AXPress` | ✅ 正常 | 实测 split 1→2 成功 |
| `CGEvent` 点击/拖拽/键盘 | ❌ 全部无效 | 事件投给 loginwindow |

`activate()` 是 void 且经常静默失败，必须轮询确认真的到了前台再发事件。
否则点击会落到当前真正前台的 app 上——实测落到 Herdr，表现为「点击成功、
app 毫无反应」，很容易误判成产品 bug。

### 8.6 `herdr pane list` 没有几何，`pane layout` 才有

| 命令 | 有 | 没有 |
| --- | --- | --- |
| `herdr pane list` | `pane_id` / `tab_id` / `focused` / `terminal_title` / `cwd` / `revision` | **尺寸、宽高、rect** |
| `herdr pane layout` | `panes[].rect{x,y,width,height}` / `splits[].ratio` / `splits[].direction` / `focused_pane_id` / `zoomed` / `area` | — |

单位是终端 **cell**，不是点。split 后 `ratio` 默认 0.5。

所以「split 了但比例错了」这类 bug 只能用 `pane layout` 断言。实测注入
`ratio: 0.85`：pane 数量断言 ✓（1→2），几何断言 ✗（`widths=[17, 95]`）。

**`pane list` 的顺序不稳定**，既不是字典序也不是创建序（实测
`w1:p5` 排在 `w1:p2` 之前），看起来是内部 map 顺序。断言必须按 `pane_id`
建集合比较，不能用下标。

### 8.7 未验证

- `NSMenu.popUpContextMenu` 阻塞期间，**外部进程**的 `AXPress` 是否会投递到
  正在 tracking 的菜单项。
- 右键菜单弹出后，其 `AXMenuItem` 挂在 `AXApplication` 子树还是独立 `AXMenu` 下。
- `KRAAL_DEV_BACKGROUND=1`（窗口 `orderBack`）下 CGEvent 右键的投递行为。
- `pane list` 顺序是否跨 daemon 重启也稳定（只采样了 3 次，未跨重启）。
- VM 内 `screencapture -l` 是否也失败（宿主失败，VM 早期实验里曾成功过）。

### 8.8 分隔条拖拽：位移是 2 倍（2026-10-22 实测并修复）

在 `kraal-agent` VM（headless，`tart exec` → Aqua）里用单次 `leftMouseDragged`
40pt 拖分隔条，终端容器 959pt，起始 ratio 0.5：

| `dragged` 与 `mouseUp` 的间隔 | ratio 变化 | 幅度 |
| --- | --- | --- |
| 0 ms（同一 tick） | +0.0462 | **1.11x** |
| 100 ms | +0.0882 | **2.12x** |
| 300 ms | +0.0882 | 2.12x |
| 800 ms | +0.0882 | 2.12x |
| 只发 `dragged`，不发 `mouseUp` | +0.0462 | 1.11x |

**所以是产品 bug，不是驱动精度问题**：`onChanged` 和 `onEnded` 各自把同一个
累计 `translation` 发了一遍，daemon 应用了两次。真实拖拽两次事件间隔必然
>100ms，因此每次都受影响。

两个细节值得记：

- **同一 tick 时正确**。两次调用被 `dragSplitRatio` 的合并逻辑并成一个请求，
  于是只应用一次。这解释了为什么纯换算的单元测试看不见它。
- **倍数不是常数**。20pt 时 2.42x、40pt 时 2.12x、80pt 时 1.52x——距离越大倍数
  越小，因为 0.9 的 clamp 压缩了尾部。一个会随距离变化的"倍数"很容易被误读成
  单位换算问题，但它其实是「同一段位移被加了两次」加上 clamp。

**修复**：把计算锚定在手势**开始时**的 `split.position`，而不是当前从 daemon
回来的位置。当前 position 已经包含上一次发出去的 translation，再加同一个累计
translation 就是重复计算；用起始 position 使计算幂等，同一 translation 发几次
结果都一样。修复后四种间隔全部是 1.11x，A/B 回退可复现 2.12x。

剩余 ~5pt 的固定偏差来自 `DragGesture` 的起始阈值，随距离从 20pt 到 160pt
保持恒定（1.21x → 1.03x），不是倍数，可以接受。

### 8.9 拖拽用例的断言容差

`drag-divider` 的容差是 **±0.02**。依据是上面的数据：修好后每个距离的残差
≤0.005（约 5pt 常数），而 2x bug 在同样条件下是 +0.046。容差宽到能吸收 2x
就等于给这个 bug 盖章——这也是为什么这个用例第一次跑出偏差时没有调容差，
而是去查换算公式。

### 8.10 坐标换算不能写死窗口尺寸（2026-10-22 实测并修复）

`drag-divider` 一开始把终端容器宽度写成常量 `959`，依据是「1180pt 窗口 -
221pt sidebar」，并且正确跑通过很多次。但那个值只在默认窗口尺寸下成立；
**它是一个被记住的测量值，不是一个不变量**。

实测：VM 屏幕变成 1024×768 后，Kraal 窗口被压到 1004×660，容器宽 783pt
（= 1004 − 221），而算式仍然是 `origin_x + 221 + ratio*959`：

```text
正确：221 + 0.500 × 783 = 612
写死：221 + 0.500 × 959 = 700     ← 偏 +88pt
```

窗口相对坐标 700 落在容器内部，换算成比例是 `(700−221)/783 = 0.612`，也就是
按在了分隔条右侧 88pt 的终端区域上。拖拽打在终端上，daemon 的 ratio 一动不动。
表现是用例报 `stuck: ratio 0.500 -> 0.500, the drag never reached the daemon`。

**修法**：容器尺寸改为从 app 自己的日志读（`layout: container=WxH`），
sidebar 宽度取 `window_w - container_w`，期望 ratio 用 `80/container_w`
而不是 `80/959`。`gui.sh` 里的 `container_size()` 就是做这件事。

**注入验证**（§0.3，1024×768 屏幕下）：

| 注入点 | 结果 |
| --- | --- |
| `float('$coords') * $container_w` → `* 959`，且 expected 仍用 `/959` | `exit 1`，`stuck: ratio 0.500 -> 0.500` |
| 恢复为 `$container_w` | `exit 0`，`0.500 -> 0.608`（expected 0.602，误差 +0.006） |
| 恢复后在 1920×1200 下重跑 | `exit 0`，`0.500 -> 0.588`（误差 +0.005） |

所以这条用例现在两种屏幕尺寸下都过，而写死的旧版本只在小屏下挂—— 这正是
「门禁自己也包含了一个被记住的测量值」该有的表现。

一个失败模式变体值得记：第一次尝试注入时改的是 `sidebar_w = 221`（常量），
用例仍然全绿——因为 sidebar **确实**是 221。真正的常量是容器宽 959，不是
sidebar。注入必须改在被断言的量上，否则“验证过了”是一句空话。

同一个改动还修了一个静默失败：失败分支的 `driver shot -o "$dir/shot-failure.png"`
把 **guest** 路径交给了宿主 shell 的重定向（`>>"$dir/app.out"`），于是每次失败
都多打印一行 `app.out: No such file or directory`，截图本身的报错反而丢了。
现在重定向到 `$host_dir/failure-shot.log`。

### 8.11 OSC 52 剪贴板：payload 是 base64（2026-10-22 实测）

`ServerMessage::Clipboard` 的 `data` 字段是 **base64**，不是原始文本
（上游 `wire.rs:1421-1424` 写明 "Base64-encoded clipboard data"，客户端
`client/clipboard_forwarding.rs:9-15` 先解码再写剪贴板）。

第一次实现直接把字符串写进 `NSPasteboard`：类型检查通过、单元测试全绿，
但剪贴板里躺的是 `S1JBQUxfT1NDNTJfT0s=`——粘贴能成功，内容是垃圾。
**单元测试没有抓到，因为它断言的是我自己构造的值，而不是 daemon 的编码。**
这正是 `AGENTS.md` §0.2 那类缺陷。抓到这个 bug 的是 `Scripts/osc52-probe.sh`。

#### 端到端探针的三个坑（都会伪装成「产品没修好」）

| 坑 | 表现 | 原因 |
| --- | --- | --- |
| VM 里的 `Kraal.app` 是旧的 | 剪贴板收到 base64 原文 | 探针没有部署，测的是 14:15 的旧二进制。`gui.sh` 每次 run 都部署，探针也必须 |
| `herdr pane run --pane <id> <cmd>` | 命令根本没执行，剪贴板不变 | pane id 是**位置参数**：`pane run <PANE_ID> <CMD>`。写成 `--pane` 会被当成命令，返回 `pane_not_found: pane --pane not found`，又被 `2>/dev/null` 吞掉 |
| `herdr server … &` 后 `tart exec` 挂死 | 探针 10 分钟无输出 | 后台进程仍持有 pipe。`gui.sh` 在同一个 `bash -lc` 末尾加了 `sleep 2`，这就是它能返回的原因 |

guest 里没有 `timeout`（§4.6），所以探针里的每个 guest 调用都用宿主侧
watchdog 包住，否则裸 `recv` 会永久挂起。

#### 注入验证

| 改动 | 结果 |
| --- | --- |
| 去掉 base64 解码（`next.clipboard = data`） | `FAIL: ... (S1JBQUxfT1NDNTJfT0s=)`，6 passed / 1 failed |
| 恢复解码 | `7 passed, 0 failed`，剪贴板内容 `KRAAL_OSC52_OK` |

探针断言的是 **daemon 之外的真实剪贴板**（`osascript -e "the clipboard as text"`），
并且先把剪贴板设成哨兵值 `NOT_THE_PANE_VALUE`，所以「本来就是那个值」不可能误判为通过。

### 8.11 分隔条：颜色不跟主题 + 拖拽闪屏（2026-10-26 实测并修复）

用户报告两条：「两个 panel 中间的白条很碍眼，颜色和主题不对」「多动白条会闪屏」。
两个独立的根因，都不是「画错了像素」。

#### 根因 1：用了系统语义色，而不是主题色

`splitHandle` 画的是 `Color.secondary.opacity(0.25)`。`Color.secondary` 是
**系统外观**的语义色，而 pane 里的终端按**用户主题**着色，两者无关。用户的
系统是浅色外观、主题是深色，于是 2 cell 宽的分隔带被画成：

```text
255×0.75 + 128×0.25 = 223.25  →  实测 (223,223,223)
```

而两侧 pane 的内容背景是 `(17,20,25)`。整条亮灰白带因此「很碍眼」。

**修法**：`Palette` 新增 `paneGapColor`（`surface_dim` → `panel_background` →
`.clear`）与 `paneGapLineColor`（`surface0` → `.clear`），`PaneLayoutView` 注入
`@Environment(\.palette)`。fallback 是 `.clear` 而不是平台色：`nil` 在这个类型里
的含义就是「主题没意见」，回退到系统色等于把同一个 bug 再藏一次。

`gruvbox` 的 `surface_dim` 是 `0x282828` = (40,40,40)，实测分隔带 582/584 像素
命中该色。

#### 根因 2：擦屏与重绘是**两次** flush，且擦屏在同步输出块之外

`apply(surface:)` 里重置路径的形状是：

```swift
session.receive(Data(clearScreenSequence.utf8))   // 第一次 flush：2J 3J H
let painted = renderer.render(frame)              // 自身用 ?2026h … ?2026l 包住
session.receive(painted)                          // 第二次 flush
```

Ghostty 收到一次 flush 就合成一次。于是中间存在一个**已擦除、尚未重绘**的状态，
屏幕上就是一帧空白。拖分隔条时每跨一个 cell 网格就触发一次 reset，所以闪屏在
整段拖拽中反复出现——这就是「多动白条会闪屏」。`render()` 的注释写着「每个 frame
都包同步输出」，但擦屏根本不在那个 frame 里。

`grid mismatch` 分支更糟：它 `resetSurfaces()` 后 `return`，**擦了屏却不画**。

**修法**（`Sources/KraalProtocol/SurfaceANSIRenderer.swift` 与
`Sources/KraalTerminalView/PaneTerminal.swift`）：

- `render(_:clearingFirst:)`：擦屏序列进入同一个 `?2026h` 块，并强制全量重绘。
- 所有擦屏路径改成「暂存帧并返回」语义：不擦屏，等网格可信时一次画完。
- `resetSurfaces()` 移到 encode **之前**（`needsCleanRepaint` 分支原来在 encode 之后，
  会让图片被擦掉却没有重新上传）。

#### 断言与注入验证

`gui.sh run drag-divider` 新增两条断言，都做过 A/B：

| 断言 | 修复后 | 注入缺陷后 |
| --- | --- | --- |
| 分隔带像素命中主题 `surface_dim` | 582/584 | **37/584**，`exit 1` |
| 每笔写出的擦屏都带着 cells | 12 writes，12 擦屏且全部同笔重绘 | **5/16 擦屏写没有 cells**，`exit 1` |

三条坑，每条都是「检查通过其实没检查」：

1. **亮度阈值抓不住这个 bug**。第一版用「分隔带不能是亮色」，注入
   `Color.secondary` 后**依然通过**——深色系统外观下 `Color.secondary` 也是深色。
   必须匹配精确主题色（`0x282828 ± 4`）才有区分力。
2. **guest 路径写成了 host 路径**。VM 后端下 `driver` 在 guest 里跑，
   `--in "$host_dir/shot-after.png"` 指向一个 guest 不存在的文件；截图失败、
   像素数解析为空、按 0 处理，于是「0 个亮像素」读成了通过。现在截图失败与
   计数不可解析都直接判失败。
3. **擦屏那一笔没走日志**。第一版断言 `atomic/count`，但注入的缺陷把擦屏交给了
   裸 `session.receive`，日志看不到它，断言照样绿。现在分类从**实际写出的字节**
   推导（`;1H` 判定 cells，`ED2` 判定 erase），并让所有写出经过同一个 `deliver`。

`.clear` 主题下分隔条不画任何东西，所以 `.contentShape(Rectangle())` 是必需的：
一个不绘制内容的 shape 不保证命中测试，分隔条会「看着对、拖不动」。

未验证：Retina（scale=2）下 `pixelSnapped(.up)` 是否让 2 cell 带多出 1pt；
`hitRect` 厚度是否恒为 2 cell（只有 0.9.5 的 `120x2` / `2x20` 两个样本）。

#### 横向分隔带也要断言（用户报的就是这个几何）

用户的截图是**上下一分**（`direction: down`，daemon 叫 `.vertical`），那条白带横跨全宽。
`drag-divider` 的像素断言只覆盖竖向分隔线，所以补了 `split-down` 的对应断言。

两处都踩过「选错带子」：

| 做法 | 结果 |
| --- | --- |
| 从 `pos` + cell 高度推算分隔行 | 偏 ~26pt（`containerOrigin` 是窗口内坐标，截图是窗口图，状态栏+标题栏把它们分开） |
| 从 `y=8` 起扫描第一行主题色 | 命中 `y=38`（顶部区域也是主题色），报「rows 38 and 39」，而真正的带子在 `y=385` |
| 从容器下半部起扫描 | 命中 `y=385`，实测 900/900 |

注入 `Color.secondary` 后：竖向断言 `37/584 → exit 1`，横向断言
`no full-width row ... → exit 1`。两条都能红，才算覆盖了用户报的那个方向。

扫描而不是推算，是因为坐标换算在这里有三层（屏幕点 / 窗口点 / 窗口图像素），
每错一层都是 ~25pt 级别的静默偏差。颜色断言只需要回答「有没有一条全宽的、
主题色的横带」，这是扫描能直接回答的问题。

### 8.12 pane 四周的空白带：daemon 保留了边框 cell，没人画（2026-10-26 实测并修复）

用户第二次报的是「上下拖动分隔条后，上面 pane 的下方会多出一条空白行，上下都
可能出现」。它不是 §8.11 那个白条，是另一个缺陷，而且**在本轮改动之前就存在**：
容器底色原来是系统的 `textBackgroundColor`，和 pane 边框区域同色，所以看不见；
§8.11 给容器铺了主题色之后，没人画的那一圈就变成了实心色块。

#### 实测几何（`split-down`，VM 后端）

```text
layout: container=959x664 grid=119x36 cell=8.0x18.0 containerOrigin=221,71
panes=[w1:p1=116x16@1,1 rect=119x18@0,0->928x288pt
       w1:p2=116x16@1,19 rect=119x18@0,18->928x288pt]
splits=[vertical@18 hit=119x2@0,17]
```

- `pane.rect` **包含** daemon 预留的 1 cell 边框，`pane.innerRect` 是内容
- 只有 `innerRect` 有 view；`rect - innerRect` 那一圈没有任何 view
- grid 是**居中**的（`max((size - gridSize) / 2, 0)`），容器 664pt 装 36×18=648pt
  的 grid，上下各余 8pt —— 这两条也归不到任何 pane
- 于是 row 0、row 35 以及它们的左右两侧露出容器底色

截图（gruvbox，1180×760）里就是 `rows 72..78` 和 `rows 727..733` 两条
`(40,40,40)`，各 7px ≈ 1 cell 减掉的内容偏移。用户看到的就是这两条。

#### 修法：给每个 pane 补一层背景，**不能**改 pane 的 frame

```swift
paneBorderColor?(paneId) ?? palette.paneSurfaceColor
    .frame(w: rect(pane.rect), h: ...)     // 背景可以用外框
    .position(...)
```

颜色取**终端自己的** `state.backgroundColor`（`PaneTerminalModel.state` 上就有），
因为边框在语义上属于 pane、与里面的终端连续，不属于旁边的缝隙。它只存在于
Ghostty surface 上，所以由 app 层注入（`RootView.paneBorderColor` →
`PaneLayoutView` → `PaneBorderCells`）。

`CGRect.extendedToContainerEdge(cellRect:grid:container:cellSize:)`
（`Sources/KraalUI/PaneCoverageRect.swift`）把贴边的 pane 背景向外拉满，吸收居中
余量；中间的 pane 原样返回。

**必须是 background，绝不能去撑 pane 的 frame**：Ghostty 用 view 的像素尺寸
floor 除 cell 尺寸来定 grid，宽一格就会重排、每行都折行（同 §8.8 那次的根因）。

#### 三条「检查通过但其实没查」

| 做法 | 结果 |
| --- | --- |
| 用 `DIVIDER_MATCH`（`surfaceDim`）判「边框画上了」 | gruvbox 的 `panel_background` 与 `surfaceDim` 同为 `0x282828`，两者无法区分 |
| 断言 `state.backgroundColor` 的日志 | 日志打了 16 次 `bg=247,247,247`，但那是**另一次**求值；要用像素才知道最终画了什么 |
| 把 ring 临时改成 `Color.red` | 这个才是决定性的：红色只出现在 `rows 79..96` 和 `709..726`，证明 ring 覆盖的是**内层边框**，容器上下那 7px 余量还没人管 |

最终断言扫描容器内每一行，只允许**一段**（可被 1pt hairline 切开）gap 色带 ——
即分隔带自己。注入「删掉 ring」后变成三段：

```text
3 gap-coloured band(s) [(73, 96), (385, 420), (709, 732)]
```

`(73,96)` 与 `(709,732)` 各 24px = 1 cell + 8pt 居中余量，正是用户报的那两条。
`split-down` 因此从 `passed` 变 `FAILED ... exit 1`。

#### 未验证

- 只测了 `split-down`（用户报的那个方向）。`split-right` / 四宫格没做像素级
  border 断言；几何上走的是同一段代码。
- 只在 gruvbox 上验证。`terminal` 主题（`surfaceDim = 0x444444`）下边框和缝隙
  颜色不同，视觉上是否可接受没有截图确认。

### 8.13 pane 之间那条空白带：终端背景从没被主题化（2026-10-27 实测并修复）

用户第二次报“上下拖动分隔条还会有空白行，改窗口大小也能复现”，并补充
**深色外观下这条带子的颜色也会变**。这两句话把范围锁死了：颜色会跟系统外观变，
说明它不是任何主题色，而是终端库自己的默认值。

#### 实测：颜色就是 libghostty 的默认主题

`TerminalTheme.default` = `light: .alabaster` / `dark: .afterglow`
（`Configuration/TerminalTheme+Defaults.swift:8-11`），而

```text
alabaster  builder.withBackground("F7F7F7")   -> (247,247,247)
afterglow  builder.withBackground("212121")   -> (33,33,33)
```

用户截图里那条带子量出来是 `(247,247,247)`，**逐像素等于 `#F7F7F7`**。深色外观
下变成 `#212121`，与用户的描述一致。

根因：`PaneTerminalModel` 只给 Ghostty 设了 padding（`PaneTerminal.swift:34-39`），
**从没设过任何颜色**。而 Kraal 的主题不在协议里（`docs`/`Decoder.swift` 对
theme/color 零命中），所以 Ghostty 永远不知道自己是 gruvbox。

#### 修法 A：把主题的终端背景告诉 Ghostty

`Palette.terminalBackgroundHex`（`terminalBackground` → `surface_dim` → `nil`），
由 app 层传给 `PaneTerminalPool.background`，再进 `PaneTerminalModel`。

**必须放 `theme`，不能放 `terminalConfiguration`。**
`GhosttyConfigRenderer.render` 先渲染 `configuration`、后渲染 `theme`
（`Configuration/GhosttyConfigRenderer.swift:23-29`），同一个 key 上后者覆盖前者，
而 `TerminalTheme.default` 两个 arm 都设了 `background`。放错的症状是：日志里
`terminal background: 282828` 打得好好的，屏幕上仍然铺 `#F7F7F7`。

#### 修法 B：grid 落后于 view 时，画能画的那部分

`apply(surface:)` 在 grid mismatch 时原本只 park 帧然后 `return`，一帧都不画。
pane 的 view 已经变成新的行数，Ghostty 还是旧 grid，差额那条就露出终端背景 ——
这正是那 1 个 cell（37px）。改成 `paintOverlap(...)`：把帧裁到当前 grid 先画出来。

裁掉的单元格本来就显示不了（grid 没长到那儿），所以这一步不损失任何原本可见的
内容，只是把空白带消掉。完整帧仍然 park，grid 追上后照常重画。

#### 三条“检查通过但其实没查”（本轮又踩到的）

| 做法 | 结果 |
|---|---|
| 断言「没有 gap 色的行」 | 终端主题化之后 pane 内容和缝隙可同色（都 `#282828`），这条判据直接失去分辨力 |
| 只测 `cropped()` / `bridgeFrame()` 纯函数 | 把 mismatch 分支整个删成裸 `return`，**733 个测试全绿** —— 没有一个测试碰 `apply` 的那个分支 |
| 扫描整个容器高度 | 容器是点、截图是像素，扫进了窗口底部状态条，其背景也是 `#F7F7F7`，静默多算 959 px/行 |

第三条的修法是 `kraal-gui rowscan`：逐行输出主色与占比，判据变成“这一行 90%
以上是 libghostty 的默认色”，文字抗锯齿的零星像素不再干扰。

#### 注入验证

| 断言 | 注入 | 结果 |
|---|---|---|
| `the terminals use the theme's background` | `background: nil` | `479256 px are still libghostty's default (#F7F7F7); theme is #282828` → exit 1 |
| `a mismatched grid still reaches the terminal` | 删掉 `paintOverlap` 调用 | `paintCount > before` 失败 → exit 1 |
| `cropped()` 的尺寸 | 裁到 frame 而非 grid | 4 条单测红 |
| `terminalBackgroundHex` | 去掉 `surface_dim` 回落 | 2 条单测红 |

#### 未验证

- `paintOverlap` 的**像素级**效果没有 GUI 断言：VM 里的 `split-down` 在截图时
  grid 已经稳定，注入“不画”仍然通过。行为由单测钉住（`paintCount` 增加），
  但“真的少了那条带子”只有用户在真机上确认。
- 只测了 gruvbox。`terminal` 主题（`surface_dim = 0x444444`）的观感未截图确认。

### 8.14 拖动/缩放时那条带子：三种机制被同时观察到（2026-10-27 实测，**未修复**；后续见 §8.17、§8.18）

用户报的现象（三种几何，同一个症状）：

| 几何 | 现象 |
| --- | --- |
| 上下两格 | 往上拖，下面 pane 出现空行；往下拖，上面出现空行 |
| 三窗格（上 1 下 2） | 分隔带读成 2 cell，hairline 在**第二格**中心 |
| **单 pane** | 最下面一行渲染两次，或出现空行；TUI 与非 TUI 都能复现 |

单 pane 也能复现这一条是决定性的：**与分隔条无关**。此前两轮（§8.11 的颜色、
§8.12 的边框 cell）都只覆盖了 split 的几何，都不是这个缺陷。

#### 实测：`grid mismatch` 双向且不对称（30 条样本）

```text
ghostty > frame : 22
frame > ghostty :  8
```

单向 1 行差的连续序列（单 pane `w5:p3`，拖动窗口）：

```text
g17 f34      ← 起始差异大
g34 f33      ← 之后每一步 Ghostty 落后 1 行
g33 f32
g32 f31
...
g21 f22      ← 反向
g22 f23
g23 f24
```

每一对只出现 2 次，随后收敛。**收敛那一刻的 paint 是 `erase=1` 全量重画**，
所以「收敛后的稳态」在日志上是正确的 —— 但用户看到带子留着，说明**收敛前那一帧
的残留没有被后续帧覆盖掉**。

#### 三种候选机制（都已定位到代码，但**都未用 A/B 证明是用户看到的那一条**）

1. **`bridgeFrame` 只降不升**（`PaneFrameCrop.swift:9-12`）
   `height = min(gridRows, frame.height)`。`ghostty > frame` 时返回整个 frame，
   Ghostty 多出的行无人绘制，保留终端自己的背景。占 22/30 的多数方向。

2. **居中余量**（`PaneLayoutView.swift:646-647`）
   `originY = max((container − grid×cell) / 2, 0)`。实测单 pane
   `container=993x459` vs `grid 116x24 → 986x444`，上下各留 7.5pt。
   两份余量不属于任何 pane，由容器底色承担。**这条路径在 gruvbox 下不可见**：
   `paneGapColor = surfaceDim = #282828` = 终端背景 = `panelBackground`，三者同色。

3. **周期性 erase**（独立缺陷，实测）
   ```text
   15:58:43.037  erase=1 bytes=3003 resets=36
   15:58:52.482  erase=1 bytes=3003 resets=37
   ```
   每 ~10 秒擦屏并全量重画**完全相同**的 3003 字节 —— 无谓重绘，也是「偶尔闪一下」的来源。

#### 已撤销的错误修复（记下来避免再做一次）

`paintOverlap` 里加 `frameGrid = bridge` + `needsCleanRepaint = true` 是**冗余**：
`grid mismatch` 分支在调用它之前已经设了 `frameGrid = nil` 与
`needsCleanRepaint = true`（`PaneTerminal.swift:409-411`）。

A/B 实测：删掉这两行，`swift test` **741 tests 仍全绿**。按 §0.3，删掉修复仍绿
等于该修复没有作用。已 `git checkout` 撤销。

同轮还发现 `Palette.paneSurfaceColor`（`Palette.swift:265`）**零引用** —— 它是
§8.12 attempt 1 回滚后留下的孤儿 token。

#### 侦察得到的 daemon 侧事实（二进制逆向，herdr 0.9.5）

`/private/tmp/herdr-gpui` 是空壳（0 文件 / 643 目录），源码不可读。改从
`/Users/zzj/.local/bin/herdr`（daemon+CLI）与 `/Applications/Herdr.app`（GPUI）
的符号表反推：

- 布局几何算在**服务端**（`herdr::layout::collect_panes`），GPUI 只画 rect：
  `extent = fcvtau(ratio × parent_extent)` —— **truncate，不是 round**；`fcvtas`/
  `fcvtns` 计数为 0。余量 `parent − extent`，负值钳 0。这解释了两个方向都会差 1 行。
- 矩形是 `u16 × 4`，wire 上打包成 `u64`；所有加法 `csel …, 65535` 钳位。
- `apply_pane_chrome` 用 `ratatui Block::inner()` 从 `rect` 抠出 `inner_rect`。
- `pane_geometry_matches` 逐字段比 7×u16 + 2×u32，**任一不等就全量重传**。
- 用户配置实测：`~/.config/herdr/config.toml` 里 `pane_gaps = false`、
  `pane_outer_borders = false`、`pane_borders` 未写（默认 `"auto"`）。
  `pane_gaps = false` = **相邻 pane 共享一条 divider 边框**，这正是「VM 里
  `hit=119x2`、用户机器上 `hit=135x1`」的差异来源 —— `hitRect` 的厚度不固定。

#### 两套基线（结构性隐患，未修）

- `renderer` 内部自己的 `previous`（`SurfaceANSIRenderer.swift:201`）
- `PaneTerminalModel.frameGrid`

两者独立维护，`paintOverlap` 只经手后者。任何「一方更新、另一方没更新」的路径
都会让 diff 与屏幕实际内容脱节。

#### 未验证

- **没有一个动作能在 VM 里复现用户的带子。** `split-down` / `drag-divider` /
  `repro-band` 三例在 VM 中截图都干净（`hit=119x2`、hairline 居中、无留白）。
  用户机器是 `hit=135x1`。这是当前最大的阻塞：没有可复现环境，就无法做 §0.3 的
  A/B。
- 三种候选机制里哪一条（或哪几条叠加）是用户实际看到的，**未确定**。
- `frameGrid` 与 `renderer.previous` 不一致会产生什么具体画面，**未验证**。
- 只在 gruvbox 下观察。`terminal`（`surface_dim = 0x444444`）未测。

#### 8.14.1 根因：`apply` 跑在 SwiftUI 应用布局之前，而 mismatch 分支「画交集」

2026-10-27 定位，**已修**。一条带完整时序的日志（`repro-fastdrag`，VM）：

```
09:54:17.447  grid mismatch: pane=w1:p1 ghostty=118x36 frame=121x39
09:54:19.467  grid mismatch: pane=w1:p1 ghostty=118x36 frame=116x16   ← 分屏那一刻
09:54:19.484  paint: ... bytes=2018                                   ← 17ms 后全量重画
```

`apply(surface:)` 由 daemon 的帧驱动，而 grid 来自 Ghostty 读自己的 NSView
`bounds`。SwiftUI 应用新布局比那个帧**晚一个布局周期**——实测 10ms
（`surface` 到 `.651`，`apply` 在 `.658` 跑，NSView 到 `.668` 才拿到新尺寸）。

于是分屏瞬间每个 pane 都被按**上一个尺寸**测量。旧代码在这种情况下画
`bridgeFrame`（frame 与 grid 的交集）：16 行的 frame 对 36 行的 grid，前 16 行
写成新内容，**剩下 20 行保留上一个布局的画面**。那就是用户报的「快速拖完一大片
空行」；它自己不会消失，因为后续没有重画。

修法两条，缺一不可：

1. **mismatch 时不画任何东西**（删掉 `paintOverlap` / `bridgeFrame` 那条路径）。
   画交集必错：对上的行迟早要在真 grid 上重画，没对上的行无论如何画不出。
2. **grid 追上来时重新 `apply`**（`reapplyAfterGridViewMoved`）。只做第 1 条会让
   pane 一直空白——`apply` 拒画之后，如果程序不再输出，没有任何东西会再画一次。

`bridgeFrame`/`cropped` 本身仍留在 `PaneFrameCrop.swift` 里给 `paintOverlap`
以外的用途（`PaneTerminalModel.bridgeFrame` 有单测钉住裁剪规则）。

**A/B（§0.3）**：把 `bridgeFrame` 的绘制加回 mismatch 分支 →
`✘ a mismatched grid paints nothing and parks the frame` 立刻变红；恢复后绿。
这条测试原本叫 `a mismatched grid still reaches the terminal`，断言的正是
「必须画」——方向反了，已连同理由一起改写。

#### 8.14.2 `>=` 是错的：一帧写进更高的 grid，底部那行就是带子

上面那条「parked frame 在 grid 不比 frame 小时就画」的放宽（`>=`）**本身就是
缺陷**，2026-10-27 在用户真机上抓到现场（`~/Library/Logs/Kraal-live.log`）：

```
[18:00:09.786] grid mismatch: pane=wB:p16 ghostty=126x14 frame=126x13 2142x518px fits=14
[18:00:23.700] paint: pane=wB:p16 ... paints=340      ← 最后一次
        …… 18:00:20 之后 191 条 p16 日志里，paint 为 0，全是 layout
```

pane 的视图是 **13 行（240.5pt）**，Ghostty 仍报 **14 行**。`14 >= 13` 通过，
于是 13 行的 frame 被写进 14 行的屏幕：**前 13 行是内容，第 14 行保留上一个布局
留下的画面**。随后 `frameGrid = frame`，没有任何东西再画它 —— 那就是「带子不会
自己消失」。

同一时刻 p14 是干净的对照组：mismatch 0 条、paint 177 条，因为它 grid 相等。

所以规则只能是**严格相等**。等待只花延迟且可恢复；画在错误高度上两者都不是。
`parkedFrameFits` 已改回 `==`，测试 `a parked frame paints only at the exact grid
it was composed for` 直接钉住这条实测数据（`126x13` vs `126x14`）。

**这一条同时说明了 `reapplyAfterGridViewMoved` 为什么必需**：严格相等之后
mismatch 必拒画，如果没人在 grid 追上时重投一帧，pane 会一直空白。

**教训（§0.3 的正确用法）**：上一轮的 A/B 只证明了「改回 `==` 会让某条测试变红」，
没有证明「`>=` 在真实场景下是对的」。注入缺陷能证明代码被覆盖，不能证明方向正确
——方向要靠真实日志。


### 8.15 退出时必崩：`isReleasedWhenClosed` 与那个被 ARC 骗过的 `NSWindow?`

2026-10-27 实测。**与 §8.14 无关的独立缺陷**，但它让每一次「关掉最后一个窗口」
都变成一次 SIGSEGV。

现象：`~/Library/Logs/DiagnosticReports/` 里同一晚六份崩溃报告，栈逐帧一致：

```
EXC_BAD_ACCESS (SIGSEGV, KERN_INVALID_ADDRESS at 0x…)
  libobjc.A.dylib  objc_retain
  KraalMac-bin     KraalAppDelegate.saveFrame()
  KraalMac-bin     KraalAppDelegate.applicationWillTerminate(_:)
  AppKit           -[NSApplication terminate:]
  AppKit           _scheduleCheckForTerminateAfterLastWindowClosed   ← 关最后一个窗口
```

根因：`KraalAppDelegate` 用 `private var window: NSWindow?` 持有窗口，而 `NSWindow`
的 `isReleasedWhenClosed` **默认是 `true`**。窗口关闭时 AppKit 会发一次
`release`，ARC 并不知道这件事 —— 于是那个强引用变成了悬垂指针。
`applicationWillTerminate` 里 `saveFrame()` 读它，`objc_retain` 就崩。

**15 行复现**（`/tmp/w2.swift` 去掉那行 flag 即崩）：

```swift
final class D: NSObject, NSApplicationDelegate {
    var w: NSWindow?
    func applicationDidFinishLaunching(_ n: Notification) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false        // ← 去掉这一行就 SIGSEGV
        w = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            win.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        }
    }
    func applicationWillTerminate(_ n: Notification) {
        guard let w else { return }
        print("frame=\(w.frame)")             // 有 flag 时正常打印；没有时崩在这一行
    }
}
```

修法就是那行 flag。**不能用「在 `close()` 时置 nil」代替**：`NSWindowDelegate` 的
`windowWillClose` 能拿到通知，但那要求每个窗口都设 delegate，而这里的窗口由
`makeWindow` 造、delegate 挂在 app delegate 上；一个 flag 是更小的改动面。

**未验证**：Kraal 产品本身的构建在无人值守环境里拿不到窗口（`AX` 报告
`window_count=0`），所以无法在 CI/VM 里走完整关窗路径复现。证据是用户机器上六份
一致的崩溃栈 + 上面的独立复现程序。GUI 门禁不覆盖退出路径，这一条目前只能靠
崩溃报告回归。


### 8.16 拖动不丝滑：每次高度变化都在擦屏（2026-10-27 实测，已修）

用户描述是「拖动很不丝滑，herdr-gpui 可丝滑了，都不会有窗口抖动」。量出来的
东西和「渲染慢」无关，是**每秒几十次 `2J 3J H` 加整屏重写**。

一次纵向拖动（`~/Library/Logs/Kraal-live.log`）的实测：

```
拖动 20 秒：883 次 set_split_ratio → 609 个新 surface → 1152 次 paint
其中 1139 次带 erase=1，每次约 6 KB ANSI，最高一秒 97 次
同一秒客户端还要跑 31 次 layout + 28 次同步写日志

77.322 MISS  ghostty=29 frame=30
77.358 PAINT erase=1 bytes=8862
77.360 MISS  ghostty=30 frame=33
77.379 PAINT erase=1 bytes=9472
77.381 MISS  ghostty=33 frame=35
77.395 PAINT erase=1 bytes=10111
… resets 计数 0.7 秒内从 653 涨到 704（51 次）
```

**整段拖动宽度始终是 126**，只有高度在变。而 `needsScreenReset` 把「grid 变了」
一律当成重置——纵向拖动每移动一个鼠标事件就跨一行，于是每一行都擦一次屏。
`3J` 还会清掉滚动历史，所以每次不只是重画，是把历史也扔了。

三处改动：

1. `needsScreenReset` 只看**宽度**。宽度变化每行都重排，没有一个 cell 保持原坐标；
   高度变化行还在原列，旧高度以上根本没动。
2. `SurfaceANSIRenderer` 在「同宽、变矮」时，于**行循环之后**从新高度的下一行做一次
   `0J`（清到屏末），把失去的那几行擦掉。顺序是要害：`0J` 清到屏末，先清就等于把
   内容写在空白上又被擦掉。
3. `flushPendingFrame` 的 `clearingFirst` 从硬编码 `true` 改成同样的宽度判断——
   那是拖动路径的第二个调用点，两处都改才覆盖住。

顺带：`pane view:` 日志改成只在视图与 daemon 的 grid 不一致时写。原来每次尺寸
变化一行，一次拖动 562 行，每行一次同步 `open/seek/write`——诊断本身成了负载。

**A/B**：

| 注入 | 结果 |
|---|---|
| 去掉渲染器的 `0J` 清行 | `✘ a height-only change does not reset, but clears the rows it lost`（`36;1H` 与 `0J` 断言双双失败） |
| 把 height 加回 `needsScreenReset` | 同一条测试的 `!needsScreenReset` 断言变红 |
| `flushPendingFrame` 的 `wipe` 改回 `true` | 无单测覆盖（该路径依赖 `state.surfaceSize`，测试无注入点） |

**GUI 用例 `drag-divider-vertical` 是护栏，不是证据。** 诚实记录：把它撤销后的
版本跑同一条用例仍然通过（`0 screen resets`），因为合成的 20 步拖动被系统合并成
8 次 layout / 12 次 paint，缺陷所在的「逐行」路径根本没进去。它挡住的是**未来**
有人把这行为改成无条件擦屏。

**未验证**：真实拖动的丝滑程度只能在用户的机器上看。VM 无法给出「流畅」的判断，
只能给出计数。
### 8.17 拖动后 pane 底部的空白：写入先于引擎采用新网格（2026-10-28 实测，已修）

§8.14 到 §8.16 之间修了二十多处，每一处都是「读代码推出一个原因，改，用户说还有」。
原因是**没有一个能复现的环境**：`swift test` 里所有测试用 `gridOverride` 替换了
Ghostty，屏幕错了也能全绿；VM 的最终几何总是对的。这一节换了方法——**在进程内跑
真引擎**（`Tests/KraalClientTests/LiveGhosttyDragTests.swift`：真 SwiftUI、真
`GhosttyPaneView`、真 `PaneSurfaceHostView`、真 libghostty），读引擎自己的屏幕。

#### 复现

字母轮转的内容（`alphabet[(row + generation) % 26]`），使过期、错位、被钳的屏幕
不会碰巧正确。**对照组（不拖动）必须绿**——这个 rig 第一版什么都没画（嵌套 run loop
让主队列的 `surfaceSize` 发布块跑不起来），所有拖动「失败」，失败毫无意义。

修复前，同一批用例：

```text
grow 20 -> 24   want BCDEFGHIJKLMNOPQRSTUVWXY  got BCDEFGHIJKLMNOPQRSTY....
grow 20 -> 27   want BCDEFGHIJKLMNOPQRSTUVWXYZAB  got BCDEFGHIJKLMNOPQRSTB.......
grow 20 -> 33   want …                           got BCDEFGHIJKLMNOPQRSTH.............
control（不拖动）  want ABCDEFGHIJKLMNOPQRST  got ACEGIKMOPQRST.......
```

**签名**：前 K 行对，第 K+1 行是帧**最后一行**的字母，其后全空。这与用户的症状一致：
放大的那个 pane 底部空白；慢拖空行少（2–3），快拖空行多（实测到 7）。

#### 机制（有时间线）

`TerminalDebugLog` 的时间线，一次失败的拖动（最终 38 行）：

```text
引擎 receive resize rows=33   @7979.7 ms
引擎 receive resize rows=34   @8013.4
引擎 receive resize rows=38   @8066.4
38 行整帧 (bytes≈4500) 写入  @8055.1 / 8056.6 / 8058.5    ← 比引擎采用 38 行早约 8 ms
```

Ghostty 的 IO 线程把 resize 合并在 25 ms 定时器之后才真正作用于屏幕
（`termio/Thread.zig`，`Coalesce.min_ms = 25`），而 `ghostty_surface_size`、`surfaceSize`、
由 `bounds` 推出的网格**都在更早**就变了。写入立刻作用于旧屏幕：

1. 超出旧屏高度的行被 CUP 钳到最后一行（后写覆盖先写）；
2. 引擎随后采用更大的网格，底部露出空行；放大时若有 scrollback，旧行还会被拉回顶部，
   已画内容整体下移；
3. 渲染器的基线认为这些行已在屏上，之后相同的帧一行也不再写。

`ghostty_surface_size`/`readViewportText` 的行数始终正确（直挂 12/12 随机游走行数全对）——
**错的是屏上内容的位置，不是行数**。此前所有「行数从哪来」的改动（`resolvedGrid`、
`viewRows`、`surfaceSize`）都在追一个并不错的数。

#### 修法

引擎有一个**在屏幕真正 resize 之后**才发的信号：DEC 模式 2048（in-band size report）。
`Termio.resize` 在同一把锁里先 `terminal.resize` 再 `sizeReportLocked`，所以收到报告时
屏幕已经是新尺寸。`InMemoryTerminalSession` 的 `resize:` 回调**不是**这个信号——它在
`terminal.resize` 之前触发（`HostManaged.resize` → `notifyResize`），此前把它接上的
尝试因此没有任何效果。

- 每个 surface 首次画之前发 `CSI ? 2048 h`（`requestEngineScreenIfNeeded`）
- 引擎写回的 `ESC[48;rows;cols;hPx;wPx t` 在 write 回调里被识别并**截下**，不转发给
  daemon（否则会被当作键盘输入敲进 shell）。整块都是报告才算报告，粘贴内容里碰巧
  含这串字节的不动
- 报告经 `EngineReportRelay` 回到主线程，**成批、不合并**（34→38→34 这种往返也要
  看到）；网格变了就把整帧重写一遍（`engineScreenMoved` → `needsRepaint` 的
  `viewSizeChanged` + 渲染器 `invalidateBaseline`）

实测：`engineAnnouncesItsRealScreen` 对 5 组 (行,列) 全部与引擎真实屏幕一致，且 daemon
一侧没有收到 `[48;`。

#### A/B（用 rig 裁判）

| 版本 | control | grow | fast ×6 | slow ×4 | quick-daemon ×6 |
| --- | --- | --- | --- | --- | --- |
| 修复前 | ✘ | ✘ | ✘ | ✘ | ✘ |
| 只请求报告、不触发重写 | ✘ | ✘ | ✘ | ✘ | ✘ |
| **完整** | ✔ | ✔ | ✔ | ✔ | ✔ |

完整版本连跑多轮全绿（9 条，约 65 s）。11 条单元测试（`EngineScreenReportTests`）另外
对解析、变化检测、重写决策各注入了缺陷，六处都变红。

#### 走过、证明无效的路（别再走）

- **按「引擎已采用的网格」排版**（`paintGrid`）：做了，A/B 不红，回退。公告本身与写入
  竞争，预测它的改动无法消除竞争。留下的只有「公告到了就整帧重写」。
- **`enforceLayerFrame`**：真引擎下对 540 个采样（快速 resize）逐个比较各层 frame 与
  视图 bounds，**零处不一致**；禁用后依然零。不是这个。`PaneSurfaceHostView` 里的那份已删，
  `enforceEngineLayerFrame`（`viewDidSettle` 里）保留作为「用户机器是否和测试 rig 不同」的探测——
  真实日志里 `layer frame:` 从未出现（扫了 `~/Library/Logs` 下当时全部 61 份，都是本次修复之前的构建写的），可以删。
- **`surface replaced`**：同样那 61 份日志里零次。`ObjectIdentifier` 改成对象身份比较，
  但这只是防御，没有证据它曾发生。

#### 代价

快拖每次约多 ~20% 的写入（3 次拖动：259 → 310 次 paint；平均 68.5 KB → 86.1 KB）。每次
引擎网格变化多一次整帧，是这个方案的固有成本，没有优化过。

#### 未验证 / 局限

- **没有在用户的真实窗口里验证**。rig 是进程内的，窗口是不可见的，daemon 用固定字母帧
  代替。证据强度：真引擎 + 真 SwiftUI + 真视图链路的 A/B 红→绿，不是真实使用。
- **日志污染**：跑 `swift test` 不带 `KRAAL_LOG=0`，测试里的模型会经 `kraalLog` 往 `~/Library/Logs/Kraal.log` 追加（本节写作时就被自己污染过一次：里面出现了 `engine screen:` 行，但那是测试写的）。App 每次启动会删掉该文件重来，所以让用户贴日志前先**重启 App 再复现**。
- 用户的症状里「页面空的不止一行」「往下拖和往上拖各一个 pane」与机制吻合，但没有
  新的用户日志可以对照。需要用户贴 `grep "engine screen:" ~/Library/Logs/Kraal*.log`。
- VM 里 `split-right` / `drag-divider` / `drag-divider-vertical` / `scroll` 通过，日志里能看到
  `engine screen:` 行；这几条**本来就不会因这个缺陷变红**（见 §8.14 对 `drag-divider-vertical`
  空洞通过的记录），只说明没有回归。
- 模式 2048 只被 Ghostty 一家实现。换引擎需要换这个信号。
- `LiveGhosttyDragTests` 要窗口服务器：SSH 或裸 CI 里 `CGSessionCopyCurrentDictionary()`
  为 nil，自动跳过；`KRAAL_SKIP_LIVE=1` 手动跳过。

### 8.18 拖动过程中闪现的空白带：引擎落后的那 ~25 ms（2026-10-29 实测，**rig 内已修，真实窗口未验证**）

§8.17 之后用户确认**永久**空白带不再出现；但**拖动过程中**仍会闪现，松手后消失，拖动显得不稳。
这一节只讲那段瞬态。方法与 §8.17 相同：进程内真引擎，**读引擎 `IOSurfaceLayer` 自己画出来的像素**，
不信 `readViewportText`（见下）。

#### 量什么

- **统一底色夹具**（一屏同一种背景，即全屏 TUI 的样子）：任何一个视图行颜色 ≠ 该底色，这个采样就算「有带」。
  不依赖字母，也不依赖调色板。
- **marker 夹具**：每行第 0 列是该行的字母色、其余是同一个填充色；用来判定 `ok` / `band` / `torn`
  （`torn` = 画面不是 daemon 在任何时刻发过的帧）。
- 每 2 ms 采样一次。fast / slow / human 是三种随机游走；**late** = 视图先动、daemon 晚 5–30 ms 到；
  **daemon 领先** = daemon 的帧先变、视图晚 0–10 / 5–40 ms 才变（更接近真实日志：ratio→daemon 中位 14 ms，
  surface→view 中位 40 ms）。
- **字母夹具不能评估主色擦除**：擦除用的是帧的主背景色，在每行不同底色的夹具里它是「某个字母的颜色」，
  被分类器当成错行。评估擦除只用上面两种夹具。
- **调色板必须用真 rig 校准**：填充色 `0x112233` 在屏上是 `152232`，不能由原始值推算。校准代码曾遗留一行
  `palette[fill] = "_"` 使「已校准」恒真、真正的校准被跳过，造成一批 late / daemon 领先的 18–30% 假带；已删。
- `readViewportText` 的**瞬态读数不可信**（按 `ghostty_surface_size().rows` 逐行读，写前/写后出现尾部重复同一字母），
  只在静止后用。

#### 机制：四个，叠加

读 pinned Ghostty（`0538f75`）源码定位：

1. **padding 是主题底色，不是最后一行的颜色。** 网格是 `floor(view / cell)`，引擎在视图之后约 25 ms 才采用新尺寸
   （`termio/Thread.zig`，`Coalesce.min_ms = 25`，只有 trailing）。这段时间里变大的 pane 比它的网格高，
   网格下面那条是 *padding*，画主题背景。`generic.zig` 整帧重建时按 `padding_color` 复位扩展位，
   默认 `background` 全不扩。
2. **越界 CUP 被钳到最后一行，然后 `0J` 把它擦了。** `Terminal.eraseDisplay(.below)` 先
   `eraseLine(.right)`，再清下面的行。屏幕只有 h 行时 `CUP h+1;1` 被钳到第 h 行，`0J` 把真正的最后一行
   从光标列起擦成默认底色。实测：20 行屏上发 `CUP 21;1` + `0J`，`ABCDEFGHIJKLMNOPQRST` → `ABCDEFGHIJKLMNOPQRS.`。
   旧代码把这个擦除写在**所有行之后**，所以它有最后一句话；残留的单行带多在**缩小**之后。
3. **自上而下写，屏幕比帧矮时留下的是帧的最后一行。** 每个越界行都被钳到最后一行、后写覆盖先写，
   所以那一行最终是帧的**最后一行**，画面成了 daemon 从没发过的东西（`torn`）。
4. **擦出来的行是终端默认底色，不是程序的底色。** `0J` 遵循当前 SGR 背景（BCE）；渲染器输出以 `ESC[0m` 结尾，
   所以擦除用默认色。daemon 领先视图时，帧下面那些行恰好是没人写过的行。

#### 改动（三处，都在 `Sources/`）

| 改动 | 位置 | 对应机制 |
| --- | --- | --- |
| `window-padding-color = extend-always` | `PaneTerminal.swift`（配置） | 1 |
| 擦除**先于**写行；自下而上写行 | `SurfaceANSIRenderer.render` | 2、3 |
| 擦除用帧的**主背景色**（BCE），写完立即 `ESC[0m` | `appendClearBelow` / `dominantBackground` / `StyleCode.backgroundParameter` | 4 |

细节取舍（都有对应的测试和 A/B）：

- **`extend-always`，不是 `extend`**：`extend` 在边缘行任何一个 cell 是默认底色时放弃，而页脚/命令行几乎总有。
  末行含默认底色 cell 时：`extend` 38.2%，`extend-always` 8.5%（带占比，fast；这一对是在**旧渲染器**上单独换 padding 量的）。
- **主背景色，不是底行首格**：状态栏（htop、tmux、mc）在最后一行，用首格会把状态栏色拉下来铺满空隙。
  按连续 run 计数；reversed 单元（显示的是前景）和 `skip` 单元（宽字符后半）不计入；平局→默认→较小值，
  与字典顺序无关。主要是默认色的帧（shell）不设 SGR，仍是裸 `0J`。
- **不整帧重写**：曾经在 `clearsBelow` 时把所有行都重写一遍（v4）。画面采样分不出差别
  （band 0.5–1.3%、torn 0.0%，两种做法一样），代价却是视图持续高于帧时（#188 的布局）**每次 paint 24.8 KB，
  一个 cell 的改动本来 3.7 KB**。已回退。

#### 结果（rig 内，旧库 `0538f75`，单次运行，每格约 650–2970 个采样，**无重复，±1 个百分点以内不要读**）

统一底色夹具，带占比 %（fast / slow / human / late）：

| 版本 | fast | slow | human | late |
| --- | --- | --- | --- | --- |
| PR #188 现状 `2d1982d` | 40.1 | 24.7 | 28.6 | 50.7 |
| **三处全开** | 1.3 | 0.9 | 0.7 | 1.2 |

daemon 领先（带占比，fast / slow / human）：

| 版本 | 视图晚 5–40 ms | 视图晚 0–10 ms |
| --- | --- | --- |
| `2d1982d` | 58.4 / 39.6 / 39.2 | 42.0 / 30.5 / 32.5 |
| **三处全开** | 1.3 / 0.4 / 0.7 | 1.1 / 0.4 / 0.7 |

`torn`（画面不是任何一帧，marker 夹具）：`2d1982d` 的 fast / slow / human = 32.5 / 21.1 / 26.8% → **0.0 / 0.0 / 0.0%**。

**减一项**（leave-one-out：在三处全开的基础上只去掉一项，同一批夹具）：

| 去掉的一项 | 统一底色 fast | 统一底色 late | daemon 领先 5–40 fast | torn (marker, fast) |
| --- | --- | --- | --- | --- |
| padding 回到默认 | 37.5 | 35.1 | 32.9 | 0.0 |
| 不做主色擦除 | 8.9 | 18.8 | 33.3 | 0.0 |
| 自上而下写 | 0.8 | 1.0 | 1.1 | **33.0** |
| 擦除放回最后 | 1.4 | 1.0 | 1.4 | 0.0 |

「擦除放回最后」在这些画面采样里**看不出来**（0.0% torn、1.4% 带）。原因是被擦的那一行擦成了帧自己的
颜色（BCE）：统一底色夹具里它和「行还在」一样是干净的，marker 夹具的分类器把尾部的填充色算 `ok`
（读分类器代码得出，没有单独做实验）。但它确实坏了：用确定性的字节喂一块恰好 20 行的屏，渲染器照旧时
最后一行被擦、没有任何东西重写，要等引擎公告新尺寸（~25 ms 后）§8.17 的整帧重写才补上。
这一条由 `lastRowSurvivesItsErase` 钉住（确定性，见下），**不靠采样**。

#### 测试

确定性的，不靠 2 ms 采样的百分比：

| 测试 | 钉住什么 | 注入缺陷后 |
| --- | --- | --- |
| `ClearBelowFrameTests`（9 条，字节级） | 自下而上；擦除在行之前；diff 仍是 diff；主色；状态栏不当家；reversed/skip 不计；平局确定；SGR 参数 | 10 种注入，每种至少 1 条变红 |
| `paddingContinuesTheLastRow`（真引擎，2 个夹具） | `extend-always`；第二个夹具带默认底色页脚，把 `extend` 也拦下 | `extend` / `background` / 缺省 全红 |
| `rowsUnderTheFrameKeepItsColour` | 引擎真的按当前 SGR 背景擦，渲染器真的设了它 | 不做 BCE / 不擦 → 红 |
| `lastRowSurvivesItsErase` | 擦除先于行：喂给引擎一块恰好 20 行的屏 | 擦除放回最后 → 红（`want …UVZ got …UV.`） |
| `shortScreenShowsAPrefix` | 帧比引擎的屏高时留下正确前缀，不是 torn 画面 | 自上而下 → 红（`…WXY` vs `…WXE`） |

HEAD 的 Sources 配这批新测试：4 条 live 全红；字节级 7 条红、1 条绿（`a frame on the terminal's own
background…` 是守卫：HEAD 也过，注释里写明了）。`ClearBelowFrameTests` 里的 `backgroundParameters`
测的是新符号，HEAD 上编译不过，这次对照里先把它拿掉了。

全量 `swift test`（`KRAAL_LOG=0`）三个测试包：Transport 36 tests / 4 suites，Protocol 198 / 32
（改动前同一批是 189 / 31，新增的 9 条 `ClearBelowFrameTests` 是它的 +9 / +1），Client 792 / 103
（4 条新 live 测试进了已有的 `Live Ghostty drag` 套件，套件数不变；参数化的
`paddingContinuesTheLastRow` 在计数里算 1 条，不按参数个数算）。全绿；swiftlint 0。

#### 成本

| | 字节/步 fast / slow / human | 单次 paint CPU（release，126×50） |
| --- | --- | --- |
| `2d1982d` | 6822 / 4924 / 6847 | 74–81 µs |
| **现在** | 6815 / 4990 / 6861 | 77–94 µs（只在**视图高于帧、每次 paint 都要擦除时**多 +6（单色）到 +15 µs（多背景），来自主色统计） |

字节数与 `2d1982d` 持平（差 <1.5%）。主色统计在每次需要擦除的 paint 上跑，最多 ~90 次/秒，
≤1.4 ms/s。debug 构建下约 +200–270 µs/paint，**不是**发布构建的数字。

#### 没有被证明的东西（别当结论）

- **没有在用户的真实窗口里验证。** 所有数字来自 rig：窗口不可见、daemon 是固定字母帧、没有真 daemon 往返、
  没有 `PaneLayoutView`、没有 TUI 的 alt-screen。rig 里带占比降到 ~1% 不等于用户肉眼看到的。
- **`extend-always` 在 sub-cell 条（视图高度不是 cell 整数倍，最多近 1 个 cell）上会延伸最后一行的底色。**
  对有状态栏的 TUI，这条会是状态栏色。设计如此，但真实窗口里长什么样没看过。
- **主色擦除补的是背景，不是内容。** 多背景的 TUI 在 ~25–40 ms 的瞬态里，帧下方会是主色。
- **引擎的 25 ms 合并写死在 `Thread.zig`**：这套改动只降低曝光，不消除。
- 「擦除先于行」在引擎屏**不矮于帧**时不改变任何东西；它防的是引擎还没采用新高度的那 ~25 ms。
  这之后引擎公告会触发整帧重写（§8.17），所以残余风险限于 ~25 ms 内连续几次 paint 之间。
- 此前一轮 scout 提到的另外两个杠杆**没有评估**：`TerminalSurfaceOptions.resizeThrottleMilliseconds`
  （默认 0，库注释称针对拖动中的塌缩）、host-theme 消息 `clientShellHostTheme`。

#### 附：`slowDaemonEndsCorrect` 的偶发红是 rig 的毛病，不是产品的（2026-10-29 实测，已修）

全量 `swift test` 里这条红过（`want …IJKL got …IJK.`，视图 38 行、最后一行是空的），当时以为是库升级的副作用，
其实旧库、旧渲染器上也红。逐步排查：

- 40 次随机游走（`slowDaemon` 参数）里：HEAD（`2d1982d`）红 1 与 4 次，改动后红 3 与 2 次——两边都红，
  同一批 seed（12、15、32）在两边都红；**每次失败的帧都比视图矮 1–6 行，一秒后仍然如此，
  `engineScreenMoved` 已是 false**，也就是说没有谁在补写。
- 同一个 seed 12 重复 6 次，结果 FAILED/FAILED/OK/OK/OK/FAILED，输入完全一样。记下每个回复被应用的顺序：
  **失败的那几次，最后一步的回复不是最后一个被应用的**（`[(25, 25), (24, 24)]`：第 25 步的 25 行先到，
  第 24 步的 24 行后到）；通过的那几次，最后一步的回复就是最后一个。6 次里 4 次吻合，2 次不吻合都是失败——
  两个方向都成立。
- 原因：`drag` 里用「按时间排序的截止时间」模拟 daemon 回复保序，但两个相差 1 ms 的回复是两个 `Task.sleep`，
  谁先醒由调度器决定。最终 daemon 的帧是 24 行、视图 25 行，第 25 行本来就该是空的，而测试要求那里有字母。
- 修法：每个回复先 `await` 上一个回复被应用，再睡自己的时间（真实 daemon 的回复就是保序的）。
  修后同一批（40 次随机游走）连跑 3 轮，**0/40、0/40、0/40**。

所以这条 live 测试此前有一个与产品无关的、约几个百分点的偶发红。**修的是 rig**；产品代码没动。
这也说明 §8.17 里「整组连跑多轮全绿」的措辞偏乐观——当时的 N 次不足以抓到这种概率。

#### 附：升级 libghostty-spm 对这一段无影响（2026-10-29 实测）

假设：这段带子来自旧引擎里 `Termio.resize` / 模式 2048 报告的时序，升级能消除。**不成立。**
把封装库从 `1.6.20261003`（Ghostty `0538f75`，`gh compare` 核实比 v1.4.0 落后 464 个提交）升到
`2.2.2026102101`（Ghostty `1e9e14af`，领先 161 个提交，仍落后 v1.4.0 303 个）：

| marker 夹具，band% / torn%，旧库 → 新库 | `2d1982d` 渲染器 |
| --- | --- |
| fast | 6.6/32.5 → 7.1/32.4 |
| slow | 2.8/21.1 → 2.6/20.8 |
| human | 0.1/26.8 → 0.1/26.6 |
| late | 41.4/5.7 → 41.9/6.1 |
| daemon 领先 5–40 ms (fast) | 38.1/17.2 → 36.7/17.1 |

2048 公告延迟（视图变尺寸 → 引擎公告，空闲 rig，24 次）：中位 24.7 → 25.0 ms，p90 26.2 → 26.4 ms。
读源码（未运行）：两个 Ghostty 提交之间 `Thread.zig`（`Coalesce.min_ms = 25`）字节相同，
`Termio.resize`、`sizeReportLocked`、`Terminal.resize` / `eraseLine` / `setCursorPos` 函数级相同。
封装库的 Patches 0001–0017 字节相同（含 `0002-host-managed-io`、`0010-fix-scroll-remainder-zeroing`）。
已确认被测二进制：测试包里的版本串是 `1.3.2-HEAD+1e9e14af5`。

**没测的**：v1.4.0 本身（封装库没有它的二进制，本机没有 zig 0.16）。它的 `Thread.zig` 合并常量同为 25，
`Termio.resize` 只是把 `backend.resize` 挪进了渲染器锁内——这是唯一与版本相关、尚未排除的候选。
升级的副作用（`AppTerminalView` 现在默认接受拖放；新库的 `onTextSelectionRequest` 等公开 API 变化）没处理，
所以**没有合并这个升级**，只留在本地分支 `chore/ghostty-2.2-20261021` 作记录。
同一轮里 `slowDaemonEndsCorrect` 在新库上红过一次；后来查明那是 rig 的毛病，旧库也有（见上一个「附」）。

另外：`docs/ENVIRONMENT.md` 表格里 `revision: "1.6.20261003"` 那行的「最新可用 tag」已经过期
（`2.2.2026102101` 存在）。这里没改它，因为没有换版本。
