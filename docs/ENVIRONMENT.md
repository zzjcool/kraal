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
tart exec kraal-agent /bin/bash -lc 'launchctl managername'   # 必须是 Aqua
./Scripts/gui.sh probe                                        # axTrusted=true
./Scripts/gui.sh run split-right                              # panes 1 -> 2
```

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

#### 限制（实测）

| 项 | 实际情况 | 影响 |
| --- | --- | --- |
| Xcode | **没有**。`xcode-select -p` = `/Library/Developer/CommandLineTools`，`xcodebuild` 报 “requires Xcode” | 能跑 `swift build` / `swift test`，**不能** `xcodebuild`、不能出 `.app` 包 |
| Swift | 有。`/usr/bin/swift`，Swift 6.4，target `arm64-apple-macosx26.0` | 纯 SwiftPM 验证可行 |
| 共享目录 | **没有**。`/Volumes` 只有 `Macintosh HD`，无 VirtioFS | 宿主机↔guest 传文件只能靠 `tart exec` 的 stdio 管道或走网络 |
| Automation Mode | **关着**。有 `TCC.db`，`AXIsProcessTrusted` 返回 true（`sshd-keygen-wrapper` 有授权条目） | 见下方「why synthetic input fails」——不是权限问题 |
| 合成鼠标/键盘事件 | **经 SSH 不可用**（Background 会话）。**经 `tart exec` 可用**——见下方更正 | SSH 里用进程内探针；VM 里用 `tart exec` + AX/CGEvent |
| 常用命令 | 缺 `mount`、部分 `system_profiler`、`timeout` | 排查挂载用 `df`；guest 的 `sh` 的 `echo` **不支持 `-n`**，用 `printf`；等超时自己写循环 |
| 网络 | 出网正常但慢；拉 OCI 镜像直连 GHCR 只有 ~116 KB/s | 拉镜像走 `ghcr.nju.edu.cn` 镜像源（实测 ~19 MB/s） |

**不要拉 `macos-tahoe-xcode` 大镜像**，除非明确需要 Xcode 且用户同意——它几十 GB，
而这里的绝大多数验证（SwiftPM 构建、纯逻辑、协议）用不上 Xcode。

因此分工是：**逻辑与测试放 VM**，**app 打包留在宿主机**（VM 无 Xcode、无外网），
**GUI 验证也放 VM**（`tart exec` 落在 Aqua 会话，见下）。

#### 会话类型：SSH 是 Background，`tart exec` 是 Aqua

实测记录：2026-10-22（两次，第二次推翻了第一次的结论）

踩过的坑：一开始判断成「Accessibility 没授权，事件被丢弃」。**错了两处**：

1. `AXIsProcessTrusted` 在这个 VM 里返回 **true**（`TCC.db` 里有
   `sshd-keygen-wrapper|2`）。权限是有的。
2. 光标**确实会动**（`CGEvent.post` 把指针从 (600,364) 挪到 (400,400)）。
   事件没被丢弃，只是没进 GUI app。

真正的原因在会话类型：

```bash
launchctl managername        # → Background，不是 Aqua
```

SSH 进来的进程在 **Background domain**，与窗口服务器（WindowServer）不在一
个会话里。CGEvent 的生命周期全在 Aqua 会话内部：`CGEvent.post` 把事件交给
WindowServer，由它路由给前台 app。Background 会话没有这条路由通道，所以：

- 光标位置能设（那是 WindowServer 的直接属性）
- 但「投递给前台 app 的鼠标事件」不成立——连 Dock 图标都点不动
- 自己 post 的事件在自己的 `CGEventTap` 里也看不到，因为 tap 的注册本身
  就需要窗口服务器连接

`sudo launchctl asuser <uid>` 也绕不过去（实测返回
`Could not switch to audit session: Operation not permitted`），因为拿不到
Aqua 会话的 audit session。

上游说法一致（[mac-type-string](https://github.com/bgolinvaux/mac-type-string)）：

> SSH sessions: Even if you SSH into a Mac, the shell has no connection to the
> window server. … There is no workaround: CGEvent posting is fundamentally a
> GUI-session operation.

**结论（经 SSH）**：SSH 这条通道在 VM 里验不了「点一下/拖一下」——
它落在 Background 会话，缺的是 WindowServer 的路由通道，与 Accessibility 权限无关。

---

**更正：同一台 VM，`tart exec` 的行为完全不同。**

| 通道 | `launchctl managername` | 能否注入鼠标/键盘 |
|---|---|---|
| `ssh admin@<vm-ip>` | `Background` | ❌ 光标会动，点击不进 app |
| `tart exec <vm> …` | **`Aqua`** | ✅ 实测可用 |

> ⚠️ 上文「要在 VM 里验点按，就得有一个真的 Aqua 会话里的人（VNC、Tart 窗口）」
> 这句只说对了一半。`tart exec` 走的 guest agent 就落在 Aqua 会话里——
> base 镜像配了自动登录（`autoLoginUser = admin`），WindowServer 与
> loginwindow 都在跑，不需要 VNC 也不需要图形窗口（`--no-graphics` 即可）。

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

#### 进程内探针还要不要

可以退役，但不是现在就删。探针（`KRAAL_PROBE_*`）验的是
「命令会不会被正确发出、参数对不对、daemon 状态变了没」；
它绕过了真实 AppKit 事件分发，而历史 bug（`fa3496e`/`e82c104`/`2156703`）
恰恰都出在分发/时序/坐标上。

VM 里的 AX/CGEvent 驱动覆盖的是探针的**超集**，所以计划是
「先并行跑 → 确认无回归 → 再删探针」，而不是一次性拔掉。
重构方案见 `docs/AUTOMATION.md`。

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
