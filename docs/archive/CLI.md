# 借鉴 Rex 的客户端接口（2026-10-30）

Rex（Superlogical 的终端应用）的 CLI 是「一个 agent 能不能独自驱动整个 app」这件事的
参考实现：session / window / block 三级资源、`--json` 稳定 ID、可发现的动作目录
（`rex actions` + `rex -C CLIENT do ACTION k=v`）、以及一份**自描述**的 agent 指南
（`rex __internal skill`，468 行，随 CLI 版本走）。这份文档记录它的清单、Kraal 现在
有什么、差什么，以及**已经落地的那一部分**。

`docs/` 里其余文档按 `AGENTS.md` §5 分工；这份只管「对外接口」。

---

## 1. Rex 有什么（实测清单）

| 层 | 命令 | 说明 |
|---|---|---|
| 资源 | `new` / `ls` / `session` / `window` / `block` | session → window（= tab）→ block（= pane），全部有 `--json` 和完整 ID |
| 布局 | `split` / `zoom` / `move` / `swap` / `focus` / `resize` | `--split=right\|left\|above\|below`、`--ratio 1..99`、`--focus=false` |
| 命令 | `run` / `split -- COMMAND` | `--label`、`--keep-open`、`--wait`（要退出码时）、`-c DIR`、`--shell=none` |
| 读屏 | `capture --format=text\|html\|vt`、`--trim`、`--unwrap` | 屏幕 + 全部 scrollback；`--format=vt` 带转义序列 |
| 输入 | `send` / `send-key` | `send-key ctrl+c`、`shift+g` |
| 等待 | `wait --for 30s`、`events --json` | 等块/窗口/session 结束；流式事件 |
| 状态 | `block call METHOD`（`process` / `modes` / `size` / `pwd`） | 每块的类型方法：`modes.screen` 判断是否 alternate screen |
| 发现 | `api list` / `api describe METHOD --json` / `api call METHOD '{...}'` | 服务端 API 的通用逃生口，带 JSON Schema 参数 |
| 客户端 | `client ls`、`-C CLIENT actions`、`-C CLIENT do ACTION k=v` | 控制**某台机器上的 app**：切 session、换 tab、字号、侧栏、配置重载 |
| 指南 | `__internal skill`、`keymap`、`whoami --json` | agent 上手材料 + 键位表 + 连接/位置上下文（`REX_SESSION`/`REX_BLOCK`） |

两条设计原则值得抄：**动作名即文档**（`actions` 列出参数 Schema，agent 不必读源码），
**没有动作就报错而不是假装成功**（`do` 找不到目标返回非零）。

## 2. Kraal 现在有什么

| 组件 | 能力 |
|---|---|
| `herdr` CLI | 已经很像 Rex 的服务端：`pane list/get/layout/process-info/neighbor/edges/focus/resize/zoom/read/rename/input/split/swap/move/close/send-text/send-keys/wait-output`、`tab`、`workspace`、`agent`、`notification`、`api snapshot\|schema`（JSON Schema 里有 86 个 `pane.*/tab.*/workspace.*/session.*/agent.*/notification.*` 方法名） |
| `kraal`（KraalCLI） | 只有协议探针：handshake / `screenshot` / `snapshot` / `call --method` / `keys` / `send-text`（Kraal 自己的 bincode endpoint 协议，不是 herdr 那个） |
| `kraal-gui`（KraalGUIDriver） | 外部驱动 app：`probe/ax/press/wait/window/shot/pixels/rowscan/type/launch/quit/click/scroll/drag/diff/key/menu`，纯 AX + CGEvent，不链接任何 Kraal target |
| app 内部 | `AppCommand`（约 60 个，`Sources/KraalUI/AppCommands.swift`）+ 菜单栏，但**没有外部入口**：想触发它只能靠 AX 点菜单 |

## 3. 差距（照 Rex 逐项对）

| Rex 概念 | Kraal 现状 | 结论 |
|---|---|---|
| session/window/block 资源 | herdr 的 workspace/tab/pane ✓ | 用 herdr，不重写 |
| `--json` + 稳定 ID | herdr 有 | 同上 |
| `capture --format=text\|vt` | `herdr pane read --source visible\|recent\|recent-unwrapped\|detection --format text\|ansi` ✓ | 用 herdr |
| `capture --format=html` | 无 | **已补**：`kraal capture --format text\|ansi\|html`（§4c） |
| `run --wait` 退出码 | `herdr pane wait-output` + `herdr agent wait` 部分覆盖 | 差一个「等命令结束并给退出码」的动词 |
| `events --json` | herdr 定义了 `events.subscribe` + `subscription_event`，CLI 无 `events` 动词 | **已补**：`kraal events`（§4e） |
| `api call METHOD` | herdr 只有 `api snapshot/schema`，无通用 call | 中优先（要做就是 herdr 的活） |
| **客户端动作目录** | **无**（ax 只能盲点） | **本轮已补**：`kraal-gui actions` |
| **按名调用客户端动作** | **无** | **本轮已补**：`kraal-gui do` |
| `whoami --json` / 位置上下文 | herdr 在 pane 里注入了 `HERDR_*` 环境变量；Kraal 无自己的 | 低（herdr 已覆盖大半） |
| `client ls` | 无 | **已补**：`kraal-gui clients --json` + `--client PID` |
| `__internal skill` | 无 | **已补**：`kraal-gui skill`（从命令表生成） |
| block 类型 / Lua / init.lua / 浮动层 / Tailscale | 无 | 不抄：herdr 没有类型化 block，Kraal 是纯客户端 |

## 4. 本轮落地：客户端动作（`actions` / `do`）

Rex 的 `rex -C CLIENT actions` / `do` 对应到这里是：

```bash
kraal-gui actions --json        # {"app":"Kraal","count":71,"actions":[{"path":"View > Split Right",…}]}
kraal-gui do --item "Split Right"          # → pressed "View > Split Right"
kraal-gui do --path "View > Split Right"   # 同上，菜单名写错就拒绝
```

**目录来源是 app 自己的菜单栏**（AX 遍历，必要时逐个点开读）。这不是偷懒：driver 与 app
刻意不共享代码（见 `main.swift` 顶部注释），在 driver 里硬编码一份命令表就等于第二份真相，
菜单改名的那天它会悄悄过期。读菜单栏意味着 `actions` 只能报「人按得到的」，`do` 只能做
「人做得到的」——做不到的事靠**缺席**暴露，而不是靠一句谎话。

实测（VM，2026-10-30，`./Scripts/gui.sh run client-actions`）：

```
✓ do splits the pane (daemon state, not the driver's word) (1 -> 2)
✓ actions lists Split Right as enabled (71 actions, Split Right at View > Split Right)
✓ a path under the wrong menu is refused (kraal-gui: no such action; menus are: Apple, Edit, File, Help, Kraal, View, Window)
✓ an unknown action is refused
✓ do reports the path a human would have pressed (pressed "View > Split Right")
```

断言按 §0.2 只认 daemon 状态（pane 1 → 2）。注入验证：把 `pressMenuItem` 那一行去掉重建，
同一条断言变红 `(1 -> 1)`、`FAILED: client-actions failed at assert`。

### 已知边界

- **没有参数**。Rex 的 `do` 可以带 `k=v`（`pane.split direction=right`）；Kraal 的动作参数
  目前只能来自「聚焦的 pane」这类上下文。要支持参数，得先给 app 一个非 AX 的入口
  （URL scheme / 本地 socket），那是一个协议决定，不在本轮。
- **要输入的动作**（`Rename Pane…` 会开 sheet）按下后会停在弹窗上；后面得自己
  `type` + `key --name return` 收尾。`actions` 不区分这类动作（区分就要读 app 内部语义，
  与「不共享代码」冲突）。
- **键位没导出**。Rex 有 `keymap`；Kraal 的 `AXMenuItemCmdChar/CmdModifiers` 语义没实测过，
  宁可不给也不要写错（`docs/DEBUGGING.md` 的「探针要测对对象」）。

## 4b. 第二个切片：`help` / `skill` / `clients`

```bash
kraal-gui help --json          # 19 条命令 + 退出码表，机器可读
kraal-gui help --command do    # 单条用法
kraal-gui skill                # agent 指南：目标划分、动作发现、命令表、六条诚实守则
kraal-gui clients --json       # 正在跑的实例（pid / 窗口数），配合 actions|do --client PID
```

三件事都是同一动机：**清单只能有一份**。用法表从 `main.swift` 里的一段字符串搬到
`CommandSpec` 表，`help`、`skill`、`--help` 全部由它渲染——Rex 的 `__internal skill`
值得借鉴的不是那份 468 行文档本身，而是「文档由工具生成」这条不变量。`skill` 里唯一
与 app 状态有关的一段（动作目录）是**现场读的**，没装 app 时会明说没读到，而不是印一段
固定文本冒充。

`clients` 补的是「同时有几个 Kraal 在跑」这个洞：`find` 会静默挑窗口最多的那个，而调用方
有时指的是某个具体的实例（dev build / VM build / `make run` 三个并存）。

`./Scripts/gui.sh run client-actions` 现在 9 条断言（含 `help --json` 覆盖全部命令、
`clients` 的 pid 与窗口 owner 一致、`skill` 读到活目录且带守则）。注入验证：把
`liveActionReport` 改成返回固定字符串 → `✗ skill reads the live action catalog`。

## 4c. 第三个切片：`kraal capture`

```bash
kraal capture --pane w1:p1 --format text      # 纯文本，没有转义序列
kraal capture --pane w1:p1 --format ansi      # 保留 SGR
kraal capture --pane w1:p1 --format html > screen.html
```

不重写 `herdr pane read`：它已经在做「打印一个 pane 的屏幕 + scrollback」，这里只是格式层。
**html 是它给不出的那个格式**，也是真正有用的那个——纯文本恰好丢掉了 bug 报告需要的东西：
哪一行被高亮、哪个词是红的。

实现要点（`Sources/KraalProtocol/ANSIToHTML.swift`）：herdr 已经把主题解成 truecolor
（`ESC[38;2;126;136;142m`），所以这是一次纯文本变换；16 色 / 256 色仍按 xterm 调色板兜底
（实测 `ls -G` 输出的就是基本色 `#000080` 蓝 / `#800080` 紫）。**故意不做终端模拟器**：
`pane read` 是一行一行打印、带 `\r\n`，光标移动/擦除不会出现；SGR 之外的一律丢弃而不是
假装能解释，因为一个默默解释错的半模拟器比忽略更危险。

两个当场踩到的坑，都写进了代码注释：

1. **Swift 把 `\r\n` 折成一个 `Character`**，所以 `character == "\r"` 永远不成立——第一版
   把 `^M` 直接写进了 HTML。改成按 `UnicodeScalar` 遍历（`docs/DEBUGGING.md` §17）。
2. **引号在到达 pane 之前会被吃掉两次**：`herdr pane run` 会 shell-split 它的参数，
   而 `gui.sh` 的 `herdr` 包装在 vm 后端还要把参数拼进 `tart exec bash -lc "…"` 再解析一次。
   实测 `printf '\033[31mX\033[0m'` 变成 `zsh: bad pattern: 033[31mX033[0m`。
   所以用例改用 `ls -G /`（一个字符都不用引的命令），断言红蓝配色。

`./Scripts/gui.sh run capture-formats`：6 条断言（文本无转义、ansi 有转义、html 有颜色 span
且无转义、html 是完整文档、非法格式与非存在 pane 都以 exit 1 被拒）。注入验证：把
`Style.css` 改成返回空串 → `✗ html turns the colour into a span`。

## 4d. 第四个切片：`kraal run --wait`（拿退出码）

```bash
kraal run --wait -- npm test                       # 退出码 = npm test 的退出码
kraal run --split down --label Logs -- tail -f app.log
kraal run --wait --output json -- sh -c 'exit 7'   # {"exit_code":7,"pane_id":"w1:p3"}
```

这是 herdr CLI **结构上给不出**的那一件事：它能起命令、能读 pane，但没有「命令的退出码」，
脚本因此无法按成败分支。

做法不是让 daemon 长出这个功能，而是把命令打进 shell 时**追加一个哨兵**：

```
<命令>; printf '\n[kraal-exit:%s]\n' "$?"
```

然后用 `herdr pane wait-output --regex '\[kraal-exit:([0-9]+)\]'` 等它出现，再从
`pane read` 里读回数字（**取最后一个**，这样同一条命令重跑不会读到上一次的状态）。
管道里每一段都是已有的、已有的测试覆盖过的动词。

三个实现细节，都是踩出来的：

1. **命令只穿过一层 shell**（pane 里那个），所以转义全部由 `shellQuote`（POSIX 单引号 +
   `'\''`）负责。这和 test harness 不同：那里还要再穿一层 `tart exec bash -lc`，引号会被
   吃掉两次（§4c、`DEBUGGING.md` §17）。
2. **新 tab 先有 pane 后有 shell**，这个空档里打字会丢（`gui.sh` 早就有同样的注释）。所以
   发文本前用 `pane process-info` 轮询「前台进程已存在」，而不是 sleep。
3. **herdr 的返回是嵌套的**：`{"id":"cli:tab:create","result":{…}}`，而且 split 给
   `pane_id`、new tab 给 `pane_ids` 列表。`firstPaneId` 递归找，不猜形状。

`./Scripts/gui.sh run run-wait`：6 条断言（成功退出 0、失败命令的 7 变成 CLI 的退出码、
命令输出确实进了它自己的 pane、不带 `--wait` 时命令照样跑起来、缺命令/坏方向的拒绝信息）。
注入验证：`exit(status)` 改成 `exit(0)` → `✗ a failing command's status comes back as the CLI's status`。
纯函数单测 6 条（`Tests/KraalCLITests/KraalRunTests.swift`：引号、哨兵解析、herdr 形状）。

## 4e. 第五个切片：`kraal events --type …`

```bash
kraal events --list                                   # 正在跑的 herdr 认识哪些事件（27 种）
kraal events --type pane.created --count 1          # 等到第一条就退出（脚本友好）
kraal events --type pane.exited --type layout.updated
```

herdr 的 socket 协议就是**按行分隔的 JSON**，订阅方法也早就在 schema 里，只是 CLI 只暴露了
`api snapshot` / `api schema`。这份改动自己说协议：一行请求，然后原样打印每一行。

```
→ {"id":"kraal-events","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.created"}]}}
← {"id":"kraal-events","result":{"type":"subscription_started"}}
← {"data":{"pane":{… "pane_id":"w7:p9" …},"type":"pane_created"},"event":"pane_created"}
```

要点：

- `--list` **问运行中的 herdr 要清单**（`api schema` 里的 `Subscription.oneOf`），不在二进制里
  硬编码——herdr 每个版本都会加事件种类，写死的清单会开始骗人。
- socket 路径先看 `HERDR_SOCKET_PATH`，再问 `herdr status --json`（`server.socket`）。
- `--count` 让「等到 N 条就退出」可测，比抢时间窗稳；`--timeout` 是兜底（0 = 一直流）。
- 订阅被拒（`invalid_request`）时把 daemon 的原话打出来，而不是静默空转。

`./Scripts/gui.sh run events-json`：7 条断言，顺序本身是断言的一部分——**先等到 ack，再制造
事件**（先触发再订阅在慢机器上会以错误的理由通过）。注入验证：把 subscriptions 改成空数组 →
`✗ creating a pane produces a pane_created frame`。

**踩到的坑**：`--timeout` 是全局 flag，第一版只写进了 `Options.timeout`，`EventOptions.timeout`
还是 0 → 「2 秒后退出」变成了「永远流」，用例挂死 30 分钟。现在 `--timeout` 一次写三处
（probe / `run --wait` / `events`），并在注释里说明为什么共用一个 flag。

## 5. 下一步（按价值排序）

1. ~~`skill` 自描述指南~~（§4b 已做）
2. ~~`capture --format=html`~~（§4c 已做）
3. ~~`run --wait` 拿退出码~~（§4d 已做）
4. ~~`events --json`~~（§4e 已做）
5. **多客户端**（`-C CLIENT`）：**部分完成**——`kraal-gui clients --json` + `--client PID`
   已经能区分同机的多个实例（§4b）。剩下的「控制另一台 Mac 上的 Kraal」需要一个 app 侧
   控制通道（URL scheme 最省事），而且必须保证外部命令绝不在用户正在用的窗口里 split，
   那是协议决定，未开始。

## 6. 未验证 / 不做

- 未验证：`actions` 在**没有 AX 授权**的机器上的表现（应当 exit 2，`probe` 已覆盖授权检查）；
  菜单项里带省略号的动作按下去之后的弹窗状态机。
- 不做：Lua/`init.lua`、block 类型、浮动层、Tailscale——那是 Rex 服务端的能力，herdr 没有，
  Kraal 作为客户端不该伪造。
