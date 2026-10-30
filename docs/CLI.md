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
| `capture --format=html` | 无 | **Kraal 独有价值**：自绘 cell painter 已知道每个格子的颜色/样式，能渲染成 HTML（未做） |
| `run --wait` 退出码 | `herdr pane wait-output` + `herdr agent wait` 部分覆盖 | 差一个「等命令结束并给退出码」的动词 |
| `events --json` | herdr 有事件 schema（`subscription_event`），CLI 无 `events` 动词 | 中优先 |
| `api call METHOD` | herdr 只有 `api snapshot/schema`，无通用 call | 中优先（要做就是 herdr 的活） |
| **客户端动作目录** | **无**（ax 只能盲点） | **本轮已补**：`kraal-gui actions` |
| **按名调用客户端动作** | **无** | **本轮已补**：`kraal-gui do` |
| `whoami --json` / 位置上下文 | herdr 在 pane 里注入了 `HERDR_*` 环境变量；Kraal 无自己的 | 低（herdr 已覆盖大半） |
| `__internal skill` | 无 | 中：`docs/` 是给人看的，agent 要的是「命令 + 何时用」 |
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

## 5. 下一步（按价值排序）

1. **`kraal-gui actions` 的兄弟：`kraal __internal skill`**。给 agent 一份「怎么用 herdr +
   kraal 干活」的自描述指南，内容从真实的 `actions` / `--help` 生成，避免手写文档过期。
2. **`capture --format=html`**。Kraal 已经有每格的样式（`PaneCellCanvas` / `SurfaceANSIRenderer`），
   把它渲染成 HTML 是 Rex 没有、而 Kraal 结构上能做到的事。
3. **`run --wait` 拿退出码**：`herdr pane run` 有进程信息，缺「等结束 + 返回码」的动词。
4. **`events --json`**：herdr 的 `subscription_event` 已经定义好了。
5. **多客户端**（`-C CLIENT`）：Kraal 有 Machines 面板；`client ls` / `-C <mac> do` 需要
   app 侧一个控制通道（URL scheme 最省事，但要考虑「不留探索区」：绝不能让外部命令
   在用户正在用的窗口里 split）。

## 6. 未验证 / 不做

- 未验证：`actions` 在**没有 AX 授权**的机器上的表现（应当 exit 2，`probe` 已覆盖授权检查）；
  菜单项里带省略号的动作按下去之后的弹窗状态机。
- 不做：Lua/`init.lua`、block 类型、浮动层、Tailscale——那是 Rex 服务端的能力，herdr 没有，
  Kraal 作为客户端不该伪造。
