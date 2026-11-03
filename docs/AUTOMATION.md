# UI 验证（三层 GUI 门禁）

`Scripts/gui.sh` 是 HC-only 的三层 GUI 门禁
（[#235](https://github.com/zzjcool/kraal/issues/235)）。Herdr 1 的 44 个旧用例
已删除；这里先重建 4 个 HC 用例，断言的是**控制面状态和屏幕像素**，不是我们
发出的请求：

> `swift test` 全绿只说明请求体对；`AXPress` 返回成功只说明事件发出去了。
> 门禁要看 `kraal ls/status` 的模型、`hc get --json` 的 core 记录，以及屏幕
> 上真的变了没有。

原则不变（`docs/DEBUGGING.md` §7、§8）：修完要能说清哪一层变了；门禁要能红。

## 1. 为什么是三层

| 层 | 读什么 | 例子 |
|---|---|---|
| `client` | `kraal ls` / `kraal status`（窗口模型 + `view.json`） | pane 树、`focused`、`documents[0].version`、`active` |
| `core` | `hc get --json` | `state`、`turn`、`cols/rows`、`labels["herdr.seen"]` |
| `pixels` | `KraalGUIDriver shot/diff/ax` | 截图差异、分隔条 AX 几何 |

三层必须分开，因为它们**写在不同地方**：

- **布局是客户端状态。** space/tab/pane 树在窗口模型里，core 只知道终端、不知道
  谁 split 了谁。树形状、焦点、文档版本只有 `client` 能断言。
- **终端事实在 core。** 终端有没有真的起来/结束、PTY 多大、`herdr.seen` 写没写，
  只有 `hc get` 说了算。`kraal do` 返回 `ok` 不代表 core 多了一个 live 终端——
  `close-pane` 的注入（跳过 `killCascade`）就是「树里已经没有这个 pane，core 里
  还 live」。
- **Ghostty 是 Metal。** 终端内容不进 AX 树、也不进视图层次，除了截图没有别的
  读法；拖动有没有落进窗口、分隔条挪没挪，只有 `diff` 能证明。

所以一个层对不算通过。反例对应现有注入：close 跳过 `killCascade` → 树干净但
core 还 live；resize 丢掉 RESIZE 转发 → 版本涨了、像素动了、core 的 cols 没变；
seen 丢掉 `appActive` 守卫 → `status.active` 仍对，后台那次 turn 把 `herdr.seen`
推走了。每个断言都带层标签，`summary.json` 能指出是谁错了。

## 2. 命令

```bash
./Scripts/gui.sh list              # 用例清单，每个断言什么
./Scripts/gui.sh probe             # 这套 rig 能不能驱动窗口（不跑用例）
./Scripts/gui.sh run [case ...]    # 默认跑全部用例
./Scripts/gui.sh verify            # build-app.sh + run 全部
```

Backend（默认 `KRAAL_GUI_BACKEND=vm`，默认 VM `KRAAL_GUI_VM=kraal-agent`）：

```bash
# 默认：Tart VM kraal-agent，tart exec 落在 guest 的 Aqua 会话里
./Scripts/gui.sh run
KRAAL_GUI_VM=<vm> ./Scripts/gui.sh run resize    # 换一台 VM

# local：驱动本机桌面，必须显式放行，否则 exit 2
KRAAL_GUI_BACKEND=local KRAAL_GUI_ALLOW_HOST=1 ./Scripts/gui.sh run
```

`local` 的合成点击/拖动/按键会落到当时最前面的窗口上，所以它是安全边界而不是
偏好：没有 `KRAAL_GUI_ALLOW_HOST=1` 直接拒绝。默认 `vm` 是因为 guest 有独立
Aqua 会话，宿主锁屏不影响它，也不抢人的键鼠（`AGENTS.md` §0.1）。

前置与自检：

- `jq`（门禁唯一的 JSON 读取器；VM 里也要能跑，所以不依赖 python）；
- `hc` 在 `PATH` 上（软链会被解析成真实文件再推进 guest）；
- `build/Kraal.app`（`./Scripts/build-app.sh`）；
- `KraalGUIDriver` / `kraal`（`swift build --product ...`）。

`run` 会拒跑过期产物：`Sources/**/*.swift` 比 `build/Kraal.app` 新就 exit 2，
因为 `build-app.sh` 忘跑时 A/B 会为**错误的原因**变绿（bundle 里还是旧代码）。
`KraalGUIDriver` 的源码比二进制新会自动重建——`build-app.sh` 只打 app，不重建
驱动。

`probe` 逐项打印 jq / `hc` / app / 产物新鲜度 / driver / `kraal` / tart / VM /
Aqua 会话 / driver probe，任何一项红就 exit 2。红 probe 是环境问题，不是产品
证据。

## 3. 用例

四个，名字沿用 issue：

### split-right

`space.new` → `pane.split --direction right`。**client**：`kraal ls` 里该 tab 的
`tree` 是 `row` 且恰好两个 `block` 子节点，两个 terminal id 就是两次动作返回
的；`focused` 与 `status.focused_pane` 都指向新 pane。**core**：两条
`hc get --json` 都是 `state=live`、id 不同，且都带 `herdr.space`/`herdr.tab`
并且等于 `space.new` 报的 space/tab。

### close-pane

建 space、split right（焦点在新 pane），`pane.close`。**client**：树里只剩一个
`block` 叶子（root 可能仍是 `row`），终端列表里没有关掉的那个，剩下那个持有
焦点。**core**：关掉的是
`state=finished` 且 `reason=killed`（是「结束」不是「丢了」），剩下的是
`live`。

### resize

读两侧 `hc get` 的 cols/rows 和 `status.documents[0].version`；`KraalGUIDriver
ax --json` 找到唯一 `desc == "Resize panes"` 的分隔条，用 `window` 换算成窗口
坐标；`shot` → `drag --from … --to (x-60,y) --steps 10` → `shot`。**client**：
文档版本上升（布局确实存了）。**core**：左 cols 变小、右 cols 变大、rows 不变、
两侧 cols 之和 ±2 内。**pixels**：分隔条两侧 pane 带的 `diff` `mismatch > 0`
（AX 里只有一个分隔条本身也是 pixels 断言）。

### seen

三次 OSC 7501 turn 夹着两次激活切换。**client**：`status.active` 前后台翻转
正确，`status.agent` 是跑 turn 的终端。**core**：前台那次 `herdr.seen` 跟进
（1 → 2）；后台那次 turn 记录了但 `herdr.seen` 不动；`hc label herdr.seen=9`
之后只升不降（第三次 turn 后仍是 9）。

## 4. 隔离

每条都是硬约束（`AGENTS.md` §0.1）：

- `HC_SESSION=g<case-index>-<pid>`；`guard_isolation` 直接拒绝空值和 `default`；
- 每 case 一个 `/tmp/kg-<pid>-<rand>/c<n>`：`state/`、`config/`、`ctl.sock`、
  `view.json`、`keys.json` 全在里面；路径落在 `$HOME`、`~/.config`、
  `/tmp/kraal-mine/`（开发者的控制 socket）就拒绝；
- socket 路径必须短于 100 字节（`sun_path` 上限 103）：超了在 bind 时报错，
  看起来像产品 bug（`docs/DEBUGGING.md` 的「本仓库的具体教训」）；
- `Kraal.app` 每个 case 复制一份到自己的 scratch 根；收尾只 kill 自己启动的 pid
  和自己那份 bundle 的路径，从不 `pkill -f KraalMac`；
- 驱动前确认 `KraalGUIDriver clients --json` 里有自己启动的 pid；之后所有
  `window`/`ax`/`shot`/`drag`/`activate` 都带 `--client <pid>`，所以同一台 VM
  上并行跑别的 Kraal 也不会驱动错窗口；
- `HcSettings` 仍存在 app 的 `UserDefaults`（bundle id 域）：`vm` 落在 guest，
  `local` 会读到宿主的字体/主题偏好；门禁不改设置，但 `local` 只应在无人使用时
  打开；
- `vm` backend 不碰真实桌面；`local` 必须有 `KRAAL_GUI_ALLOW_HOST=1`；
- `split-right`/`close-pane` 用 `KRAAL_DEV_BACKGROUND=1`（`.accessory`，不抢
  键鼠），`resize`/`seen` 用 `0`（拖动和激活都需要 frontmost）。

## 5. 产物与退出码

```
artifacts/gui/<run-id>/<case>/summary.json    # 每 case 一份，机器可读
artifacts/gui/<run-id>/<case>/                # ls.json status.json hc-<t>.json
                                              # shot-*.png stdout.log app-runtime.log
artifacts/gui/<run-id>/run.json               # runId backend vm status cases[]
artifacts/gui/<run-id>/cases.jsonl
```

`summary.json`：

```json
{
  "case": "split-right",
  "backend": "vm",
  "status": "passed",              // passed | failed | error
  "exitCode": 0,                   // 0 | 1 | 2
  "failureType": "none",           // none | assertion | harness
  "reason": "",                    // harness/error 必填
  "durationMs": 1234,
  "assertions": [
    {"layer": "client", "status": "pass", "what": "the tab's tree is a row", "detail": "tree.type=row"}
  ]
}
```

`assertions[]` 每条四个字段：`layer`（`client`/`core`/`pixels`）、`status`
（`pass`/`FAIL`）、`what`（被断言的行为）、`detail`（实测值）。`detail` 成功时
也写——门禁说不出自己看了什么，就和永远绿的一样。`status=error` 时，已经
记录过的断言照样保留（供定位），`reason` 记第一个 rig 原因。

退出码：

| code | 含义 |
|---|---|
| `0` | 全部断言通过 |
| `1` | 产品断言失败（`failureType=assertion`），`FAIL` 那行说要改什么 |
| `2` | rig 问题（`failureType=harness`）：没有 VM、app 没起来、TCC/Aqua 不可用、无法激活、jq 缺失、产物过期、用法错 |

一次 `run` 里两种错都有时，run 的退出码取 `1`：看到 1 就该去看产品，那才是可
行动的那件事。

## 6. 注入证据

门禁要能红（`docs/DEBUGGING.md` §8）。做法固定：

1. `git diff` 干净（除本次改动）；
2. 改坏一条下表里的产品行为，然后 `./Scripts/build-app.sh` 重建——不重建等于
   在测旧代码，门禁的产物新鲜度检查就是为了挡这个；
3. `./Scripts/gui.sh run <case>` **必须 exit 1**，且 `summary.json` 里对应断言
   是 `FAIL`（不是 harness 错，不是空 `assertions`）；
4. `git checkout -- <file>` + 重建 + 重跑，同一断言转绿。

| case | 注入点 | 实测：变红断言 + exit |
|---|---|---|
| `split-right` | `splitFocusedPane` 跳过 `movePane`/`split` 的模型变更，只返回成功 | `[client] the tab's focused pane is the new pane`（tab.focused=旧 pane，want=新 pane）与 `kraal status agrees on the focused pane` FAIL；exit 1。adoption 仍把 terminal 放进了树，所以变红的是焦点断言，不是树形状——这正好证明只看「树有两个 block」不够。 |
| `close-pane` | `closeFocusedPane` 跳过 `killCascade` | `[core] the closed terminal finished`（state=live reason=null）FAIL；exit 1 |
| `resize` | `HcTerminalSession` 丢掉 RESIZE 转发 | `[core] the left pane got narrower`（cols 80 -> 80）与 `the right pane got wider` FAIL；document 版本和像素仍变，exit 1 |
| `seen` | `shareSeen` 丢掉 `appActive` 守卫 | `[core] an inactive window writes no herdr.seen`（herdr.seen=2，turn 2 在后台跑）FAIL；exit 1 |

以上均为 2026-11-03 在 `kraal-agent`（guest macOS 26.6.2）实测；每次注入后
`./Scripts/build-app.sh` + `./Scripts/gui.sh run <case>`，还原后再跑。还原后的
全量门禁约 26s（split-right 2s / close-pane 2s / resize 7s / seen 14s），
4/4 通过（最新一次 `artifacts/gui/20261104-005214/`）。

评审后又验证了 `status.active` 缺失的分支：删掉该字段并重建后，`seen` 记
`[client] kraal status exposes active` FAIL 并 exit 1（不是 exit 2 的 harness）；
还原后同用例转绿。这样「字段没实现」和「环境无法激活」不再混为一谈。注入改动只用于取证，不进 PR diff。

## 7. 手工配方（门禁没覆盖的 UI 改动）

`gui.sh` 只覆盖四个用例。其它 UI 改动仍按下面在 VM 里手工留证据，原则相同：
**断言 core/控制面状态，不猜测我们发出的请求**。

### 7.1 为什么在 VM

驱动真实窗口会抢走指针和键盘。VM 是 `kraal-agent`（Tart，headless），
`tart exec` 落在 guest 的 Aqua 会话里，宿主锁屏不影响 VM 内的窗口、AXPress、
合成键盘和 `screencapture`。

```bash
./Scripts/vm-bootstrap.sh          # 创建/检查 VM + Aqua + TCC
./Scripts/vm-bootstrap.sh --fix-tcc
```

### 7.2 宿主准备

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Scripts/build-app.sh
swift build --product KraalGUIDriver
swift build --product kraal
```

VM 里没有 Xcode，所以产物都在宿主构建。

### 7.3 推进 VM

`tart cp` 不存在；用 tar 流。以 `/tmp/kraal-hc-gui` 为例：

```bash
VM=kraal-agent
ROOT=/tmp/kraal-hc-gui
RUN=$ROOT/run
mkdir -p "$RUN/bin" "$RUN/state" "$RUN/config"

# app bundle（保留可执行位）
tar czf - -C build Kraal.app | tart exec -i "$VM" \
  /bin/bash -lc "rm -rf $ROOT/Kraal.app && tar xzf - -C $ROOT"

# driver + CLI
for bin in KraalGUIDriver kraal; do
  tar czf - -C .build/out/Products/Debug "$bin" | tart exec -i "$VM" \
    /bin/bash -lc "mkdir -p $RUN/bin && tar xzf - -C $RUN/bin && chmod +x $RUN/bin/$bin"
done

# core 二进制：路径以 which hc 为准
tar czf - -C "$(dirname "$(command -v hc)")" "$(basename "$(command -v hc)")" \
  | tart exec -i "$VM" /bin/bash -lc "mkdir -p $RUN/bin && tar xzf - -C $RUN/bin && chmod +x $RUN/bin/hc"
```

取回文件用 `tart exec "$VM" cat /path`（不要用不存在的 `tart cp`）。

### 7.4 启动隔离 core

```bash
tart exec "$VM" /bin/bash -lc "
  cd $RUN &&
  HC_SESSION=qa \
  XDG_STATE_HOME=$RUN/state \
  XDG_CONFIG_HOME=$RUN/config \
  $RUN/bin/hc server start
"
```

确认：

```bash
tart exec "$VM" /bin/bash -lc "
  HC_SESSION=qa XDG_STATE_HOME=$RUN/state XDG_CONFIG_HOME=$RUN/config \
  $RUN/bin/hc server status
"
```

socket 是 `$RUN/state/herdr-core/qa/qa.sock`。

### 7.5 启动 app

```bash
tart exec "$VM" /bin/bash -lc "
  KRAAL_HC_SOCKET=$RUN/state/herdr-core/qa/qa.sock \
  KRAAL_HC_VIEW=$RUN/view.json \
  KRAAL_CONTROL_SOCKET=$RUN/control.sock \
  KRAAL_KEYS=$RUN/keys.json \
  KRAAL_DEV_SESSION=qa-ui \
  KRAAL_DEV_BACKGROUND=0 \
  $ROOT/Kraal.app/Contents/MacOS/KraalMac-bin >$RUN/app.log 2>&1 &
"
```

- `KRAAL_DEV_BACKGROUND=0` 是**合成键盘/拖动**的前提；否则 `.accessory` 无法
  成为 frontmost，`CGEvent` 不会落到窗口。
- `KRAAL_HC_VIEW` 同目录会派生 `control.sock`；显式给路径避免和别的窗口撞。
- 日志：`~/Library/Logs/Kraal-qa-ui.log`（guest 内）。
- 启动后看 `hc: control listening at ...` 和 `hc: ready core=...`。

### 7.6 用控制面取证据

```bash
tart exec "$VM" /bin/bash -lc "
  KRAAL_CONTROL_SOCKET=$RUN/control.sock $RUN/bin/kraal ls
"
tart exec "$VM" /bin/bash -lc "
  KRAAL_CONTROL_SOCKET=$RUN/control.sock $RUN/bin/kraal status
"
```

动作：

```bash
tart exec "$VM" /bin/bash -lc "
  KRAAL_CONTROL_SOCKET=$RUN/control.sock \
  $RUN/bin/kraal do pane.split --direction right
"
```

断言要看 `ls` / `status` 的前后差异（pane 数、tab、focus、scrollback、
document version），不是看动作返回的 `ok`。

### 7.7 驱动 UI

`KraalGUIDriver` 的完整命令与参数用它自己的 `skill` / `help` 查（由代码生成，
不会和实现走散）：

```bash
DRV="$RUN/bin/KraalGUIDriver"
tart exec "$VM" "$DRV" skill
```

常用：

```bash
# 截图全窗口
tart exec "$VM" /bin/bash -lc "$DRV shot -o $RUN/shot.png"
tart exec "$VM" cat "$RUN/shot.png" > /tmp/shot.png

# AX 树 / 窗口几何
tart exec "$VM" /bin/bash -lc "$DRV ax --json" > /tmp/ax.json
tart exec "$VM" /bin/bash -lc "$DRV window" > /tmp/window.txt

# 点击、按键、打字、滚轮、拖动
tart exec "$VM" /bin/bash -lc "$DRV click --at 640,400"
tart exec "$VM" /bin/bash -lc "$DRV key --char k --mod cmd"
tart exec "$VM" /bin/bash -lc "$DRV type --text 'rename'"
tart exec "$VM" /bin/bash -lc "$DRV scroll --at 640,400 --lines -3"
tart exec "$VM" /bin/bash -lc "$DRV drag --from 640,400 --to 580,400 --steps 10"
```

坐标两套不要混：`--at` / `drag` / `diff --rect` 是窗口相对坐标，`ax --json` 和
`window` 打的是屏幕点，换算要减窗口原点（`gui.sh` 的 resize 用例就是这么做的）。
`press --title X` 遇到重名（菜单 vs Edit 菜单）时用 `--allow-ambiguous` 或
`--within-*`。

### 7.8 SSH 直连回环

VM 里启用 Remote Login 后，可以用宿主的 `Kraal.app` 直连 guest core：

```bash
# guest: 安装 hc 到 PATH，启动隔离 core
tart exec kraal-agent /bin/bash -lc 'sudo -n cp /tmp/.../hc /usr/local/bin/hc'
tart exec kraal-agent /bin/bash -lc '
  HC_SESSION=sshqa XDG_STATE_HOME=/tmp/kraal-ssh-test/state   XDG_CONFIG_HOME=/tmp/kraal-ssh-test/config hc server start'
```

宿主启动 app：

```bash
KRAAL_HC_SSH=admin@<guest-ip> KRAAL_HC_SSH_COMMAND='HC_SESSION=sshqa XDG_STATE_HOME=... hc connect'   build/Kraal.app/Contents/MacOS/KraalMac-bin
```

断言 `kraal status` 的 `core.socket` 是 `ssh:<host>`、`connected=true`；再
`kraal do space.new`，用远端会话的 `hc ls --json` 和 `hc read t1` 验证终端。

可选的 live 测试（不跑默认门禁）：

```bash
KRAAL_LIVE_SSH=admin@<guest-ip> KRAAL_LIVE_SSH_COMMAND='... hc connect'   swift test --filter LiveHcSSHTests
```

### 7.9 取证清单

一个 UI 修复至少留：

1. 失败现象（截图或日志）；
2. 触发前后 `kraal ls` / `status` 的 JSON diff；
3. 成功状态截图；
4. 日志里对应的 `hc:` 行；
5. 如果改了 wire/字段，附 core 侧 `hc get/list/read --json` 证据。

### 7.10 清理

```bash
tart exec "$VM" /bin/bash -lc "pkill -f KraalMac-bin || true"
tart exec "$VM" /bin/bash -lc "
  HC_SESSION=qa XDG_STATE_HOME=$RUN/state XDG_CONFIG_HOME=$RUN/config \
  $RUN/bin/hc server stop || true
"
```

不要 `pkill -f KraalMac`：会连启动器一起杀，且可能匹配到别的会话。`gui.sh` 自己
的收尾只按 pid 和自己 scratch 路径里的 bundle 匹配，理由相同。
