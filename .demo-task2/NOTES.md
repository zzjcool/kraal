# Task 2 — Herdr Machines 配置/管理 UI

状态：**完成**。未 commit / 未 push。

---

## 1. 结论先行：machines 走 CLI，不是 daemon

这是本次实现最重要的事实，先说清楚，否则整个设计会看错。

`herdr machine` 管理的是 **Herdr CLI 自己的** SSH profile 配置（`~/.local/state/herdr/client/`
下的 `endpoints.json` + `ssh-metadata/*.json`）。它描述「怎么用 SSH 连到另一台 Herdr server」，
在任何 server 连接建立**之前**就要被读写。

三条独立证据指向同一结论。

**证据 1 — daemon 自带 schema（最权威）。** `herdr api schema --json` 打印随二进制发布的
完整 API schema（`protocol: 22`、`schema_version: 1`）。对它做 namespace method 扫描：

```text
namespace method tokens found: 127
machine-ish hits: ['server.ssh_agent.register']
```

127 个 method 里唯一带 ssh 字样的是 `server.ssh_agent.register`，用途是在 server 上注册
SSH agent，与「保存的机器目录」无关。

**证据 2 — 固定回放 fixture。** `Tests/KraalProtocolTests/Fixtures/welcome.json` 记录了本仓库
握手时实际收到的 40 个 method（`server_version: 0.9.4`）。对
`machine|host|ssh|profile|remote|transport|endpoint` 扫描**零命中**；命名空间只有
`client_shell.` `command.` `integration.` `layout.` `pane.` `product_announcement.`
`release_notes.` `server.` `tab.` `workspace.` `worktree.`，`capabilities` 的 8 项
（`surface_reuse` `surface_delta` `surface_scroll` `surface_interest`
`presentation_effects_fence` `health_check` `agent_view_projection` `agent_completions`）同样无关。

**证据 3 — 仓库内已有实测文档。** `docs/feasibility.md:13-21` 早已记录同一结论，并给出实测反证：
本机 `herdr machine list --json` 有多台，而在远端 `hw-nj` 上执行同一命令返回 `[]`。存储位置也写在文档里：

```text
~/.local/state/herdr/client/endpoints.json          # 目录 id/label/target/session/enabled
~/.local/state/herdr/client/ssh-metadata/<id>.json  # 每台机器的 os / herdr 路径缓存
```

这两个路径我在本次实测中也**独立复现**了：在隔离 HOME 里执行一次 `machine add` 后，新生成的文件
正是这两个。这也解释了为什么隔离 `HOME` 就能完全隔离验证——配置跟着 `$HOME` 走。

进一步核实到的存储细节（本次实测）：

```text
~/.local/state/herdr/client/endpoints.json            # {"version":1,"ssh":[{id,label,target,session,enabled}…]}
~/.local/state/herdr/client/endpoint-selection.json   # {"version":1,"selected_profile":null}
~/.local/state/herdr/client/ssh-metadata/<id>.json    # {version,target,session,metadata:{os,executable}}
```

- `endpoints.json` 权限 `0600`。截至本次收尾，其 mtime 仍是 `2026-10-15 17:26:16`、1169 字节
  —— **本次所有工作从未写过它**。这比「list 出来还是 6 台」更硬：文件时间戳没变。
- 路径遵守 `XDG_STATE_HOME`，其次 `HOME`。两者任一指向空目录时 `machine list` 返回 `[]`，
  往该路径放一份改写 label 的副本即被读回 —— 确认这就是唯一读取源。
- **`machine list` 完全离线**：把 `HERDR_SOCKET_PATH` / `HERDR_CLIENT_SOCKET_PATH` 指向不存在的路径，
  仍返回全部 6 台，且文件 mtime 前后不变。这为「machines 面板不需要 daemon 连接」提供了直接实测证据。

**`selected` 字段的真正来源**（这解释了一个先前容易误读的点）：它来自
`endpoint-selection.json` 的 `selected_profile`，而不是 `endpoints.json`。本机该值为 `null`，
所以 6 台机器的 `selected` 全是 `false`。同时注意 `machine list` 的**文本输出第 4 列是
`session`（值恰好是 `"default"`），不是「默认机器」标记** —— 只看文本输出会把两者混淆，
这也是实现选择 `--json` 而非解析表格的具体原因。面板的 `default` 徽标读的是 `selected`，
语义正确，只是当前环境下恒为假。

**结论：没有任何 `machine.*` / `host.*` / `ssh.*` / `profile.*` 方法。** 所以：

- 不存在「kraal 已有 daemon 路径可复用」这回事；
- 这也解释了一个设计上的必然：kraal 现有的请求封装 `AppStore.call(_:_:)` 是
  **fire-and-forget**（`_ = try await connection.request(...)`，返回值被丢弃，错误只写进
  `lastError` 字符串）。它适合「发个 focus 就走」的动作，但机器管理需要读回结果，
  所以这条路径即使存在也无法复用；
- 唯一诚实的实现是驱动用户在终端里会打的那套 CLI；
- 也正因如此，machines 面板**不需要 daemon 连接**——断网、没连 herdr 时它照样能用。

反过来，我也确认了它确实作用在真实数据上（不是 mock）：`machine add` 会真的做 SSH
round trip，连不上就**不保存**并返回 stderr：

```text
$ herdr machine add --label x "ssh://nobody@127.0.0.1:1"
ssh: connect to host 127.0.0.1 port 1: Connection refused
error: remote platform detection failed: ...; machine was not saved
$ echo $?
1
```

---

## 2. 入口

三条，最终都汇聚到 `WindowActions.showMachines()`：

| 入口 | 位置 |
|---|---|
| 菜单栏 · **File ▸ Machines…** | `MacMenuBar.swift` `fileMenu(_:)`（放在 rename 组之后、Close 组之前） |
| 命令面板 | `AppCommand.machines`（id `machines`），可经 `perform(...)` 触发 |
| 环境变量（仅自动化用） | `KRAAL_SHOW_MACHINES=1`，驱动同一个 `WindowActions` 计数器 |

菜单项和其它命令一样走 `runCommand(_:)` → `KraalUI.perform(...)` → `CommandEnvironment.showMachines`
→ `WindowActions.showMachines()` → `RootView` 的 `.onChange(of:)` → `.sheet`。**没有第二条代码路径。**

> 说明：`KRAAL_SHOW_MACHINES` 存在的原因是无 nib 的 `NSApplication` 在 AX 层不暴露菜单层级，
> 自动化脚本点不到 File 菜单。它只驱动菜单项驱动的那同一个计数器，不是旁路。

---

## 3. 面板能力（对齐 `herdr machine` CLI）

| CLI | UI |
|---|---|
| `machine list --json` | 列表：label / target / session / enabled / default 徽标 |
| `machine add <target> [--label] [--remote-session]` | **Add Machine** 表单（三个字段，可空的两个明确标 optional） |
| `machine rename <id> --label <l>` | 每行 **Rename** + 右键 Rename… |
| `machine enable <id>` / `disable <id>` | 每行开关 + 右键 Enable/Disable，disable 需确认 |
| `machine remove <id>` | 每行 **Remove**（红色）+ 右键，**二次确认** |
| `machine status [--json]` | 后端已封装（`status(_:)`），**UI 暂未接**（见已知缺口） |

交互上的三个决定，都是被 CLI 的真实行为逼出来的：

1. **所有写操作都放到 `Task.detached` 里跑。** `machine add` 会真的 SSH，几秒起步；在主 actor 上跑会把窗口冻住。
2. **add 失败时表单不关闭。** 因为 add 同时是唯一一次连通性校验——连不上就不保存，乐观插入一行会是假数据。
3. **每次写操作成功后强制 `reload()`。** CLI 会重写自己的配置，default 标记、session 名这些 UI 没显式设置的字段只能重新问才准；不复读就会显示与磁盘不一致的状态。

---

## 4. 实现文件

新增：

```text
Sources/KraalTransport/HerdrMachineClient.swift   herdr 可执行文件发现 + list/add/rename/remove/enable/disable
                                                  + HerdrMachine 模型 + 错误类型
Sources/KraalUI/MachinesPanel.swift               MachinesStore（@Observable）+ 列表 / 添加 sheet /
                                                  重命名 sheet / 删除与禁用确认 alert
Tests/KraalTransportTests/HerdrMachineClientTests.swift   16 个用例，全部走 stub 子进程
Tests/KraalTransportTests/LiveMachineSmokeTests.swift     真机端到端，默认 skip，只在隔离 HOME 下跑
```

改动：

```text
Package.swift                        新增 KraalTransportTests target
Sources/KraalUI/AppCommands.swift    + AppCommand.machines、CommandEnvironment.showMachines
Sources/KraalUI/WindowActions.swift  + machinesCount / showMachines()
Sources/KraalUI/RootView.swift       + showMachines state 与 sheet
Sources/KraalMac/MacMenuBar.swift    + MenuActions.showMachines，File 菜单新增 Machines…
Sources/KraalMac/KraalMacMain.swift   接线 + KRAAL_SHOW_MACHINES 自动化钩子
```

### 一个被 `--help` 骗到的坑（已修）

```text
$ herdr machine rename --help
Usage: herdr machine rename --label <LABEL> <PROFILE_ID>     # ← 文档写的是这个顺序
```

**这个 help 是错的。** 实测必须 profile id 在前：

```text
$ herdr machine rename --label newname <id>
usage: herdr machine rename <profile-id> --label <label>       # 报 usage
$ herdr machine rename <id> --label newname
Renamed SSH machine d45ae…
```

我第一版照 help 写了，真机跑挂了才发现。代码里留了注释，测试
`testRenamePutsIDBeforeFlag` 把这个顺序钉死。

---

## 5. Verify

```text
$ ./Scripts/verify.sh
ok: swift build
ok: swift test
ok: swiftlint (0 violations)
ok: Kraal.app
verify: all green
```

测试总数 **95**（47 + 32 + 16 新增）。注意 `verify.sh` 用 `grep ✔ Test run | tail -8`
截断输出，XCTest 的 16 个用例在尾部被截掉、不显示，但退出码为 0 且各自单独跑过：

```text
$ swift test --filter HerdrMachineClientTests
Executed 16 tests, with 0 failures
```

---

## 6. 真实链路证据（`machines-cli.log` 摘录）

日志里 `machines:` 前缀的行，来自 `MachinesStore` 的真实 CLI 调用：

#### A. 面板在开发者本机 HOME 上打开（只读）

```text
[23:49:12.223] machines: list via /Users/zzj/.local/bin/herdr
[23:49:12.601] machines: loaded 6 -> nj-mac[191645f4], devcloud[0b5ecacd], nj-hw[7bfb921a],
                nj-host[413b9711], GPU机器[8048d128], host-workspace[6f165f05]
```

6 台、label 与 id 与用户 `herdr machine list` 完全一致 → 面板吃的是真实数据。

#### B. 面板自己的按钮跑 rename → disable → enable（隔离 HOME，一台临时机）

```text
[23:49:40.905] machines: list via /Users/zzj/.local/bin/herdr
[23:49:41.226] machines: loaded 1 -> kraal-task2-temp[4fb15a78]
[23:49:42.062] machines: mutation via /Users/zzj/.local/bin/herdr
[23:49:42.100] machines: loaded 1 -> kraal-task2-temp-renamed[4fb15a78]
[23:49:45.258] machines: mutation via /Users/zzj/.local/bin/herdr
[23:49:48.444] machines: mutation via /Users/zzj/.local/bin/herdr
```

改名后重新读回，label 真的变了；`machines-demo` 行还记下
`after disable enabled=false` / `after enable enabled=true`，与 CLI 最终状态一致。

完整文件见 `machines-cli.log`。

---

## 7. 安全边界：用户真机零改动

这是本次最需要说清楚的一条，因为中途出过风险。

- **开发过程中所有 live 测试都在隔离 HOME 下跑**（`HOME=/tmp/kraal-home-*`），
  herdr 的 profile 存在 `$HOME/.local/state/herdr/client/`，所以隔离 HOME = 隔离配置。
- 用户机器最终状态与开工前**逐字段一致**（6 台，全部 enabled，target 不变）：

```text
USER MACHINES: 6
  nj-mac        | enabled=True | ssh://zheng@nj-mac.example.com:31415
  devcloud      | enabled=True | ssh://root@devcloud.example.com:2222
  nj-hw         | enabled=True | ssh://zzjcool@nj-hw.example.com:31416
  nj-host       | enabled=True | ssh://chieh@nj-host.example.com:31417
  GPU机器        | enabled=True | ssh://root@gpu-node.example.com:36000
  host-workspace| enabled=True | nj-host-alias
```

- **早期版本的 live 测试曾写过「先 list 然后全量 remove」**。那行代码是错的：
  即使当时因隔离 HOME 而没造成后果，逻辑本身不该存在。已改为**只记录初始 id 集合、
  只增删自己创建的那一台**，并用两次 `XCTAssertTrue(preexisting.isSubset(of:))` 断言
  别人的机器没少。
- 该保护做过反向验证：先在隔离 HOME 里种一台 `PRE-EXISTING-KEEP`，再跑 live 测试，
  结束后 `remaining: ['PRE-EXISTING-KEEP']` —— 预存机存活。

---

## 8. 界面示意（文字，代替截图）

截图为全黑：这台机器当前处于锁屏状态，`screencapture` 抓到的是纯黑
（校验：整屏采样 `distinctLuma=1`，即只有一种亮度）。这是屏幕状态导致，
不是应用渲染问题——面板窗口本身在 `CGWindowListCopyWindowInfo` 中存在，
`onscreen=1`、`alpha=1`、bounds `640×460`（正是 `MachinesPanel` 的 frame）。
因此本文件不附截图，改用文字示意 + 上面的日志证据。

```text
┌─ Machines ─────────────────────────────────────────────── 640×460 ─┐
│  ▣ Machines                     ⟳      ⊕ Add Machine              │
├────────────────────────────────────────────────────────────────────┤
│  🖥  nj-mac                          [●]   Rename   Remove          │
│      ssh://zheng@nj-mac.example.com:31415                               │
│  🖥  devcloud                        [●]   Rename   Remove          │
│      ssh://root@devcloud.example.com:2222                             │
│  🖥  nj-hw                           [●]   Rename   Remove          │
│      ssh://zzjcool@nj-hw.example.com:31416                             │
│  🖥  nj-host                         [●]   Rename   Remove          │
│      ssh://chieh@nj-host.example.com:31417                               │
│  🖥  GPU机器                         [●]   Rename   Remove          │
│      ssh://root@gpu-node.example.com:36000            │
│  🖥  host-workspace                  [●]   Rename   Remove          │
│      nj-host-alias                                                     │
├────────────────────────────────────────────────────────────────────┤
│  6 saved · managed by the herdr CLI                  [   Done   ]  │
└────────────────────────────────────────────────────────────────────┘

Add Machine（sheet，480 宽）
┌──────────────────────────────────────────────┐
│ Add Machine                                  │
│ Herdr prepares the remote server over SSH    │
│ before saving, so this can take a few secs.  │
│  SSH target      [ssh://user@host:port     ] │
│  Label           [optional — sidebar name  ] │
│  Remote session  [optional — default       ] │
│                            [ Cancel ][ Add ] │
└──────────────────────────────────────────────┘

行右键：Rename… / Enable·Disable / ─── / Remove
禁用中的行：图标变橙色、文字 65% 不透明度、旁边标 "disabled"
```

---

## 9. 已知缺口

1. **`status` / `reconnect` 没接到 UI。** 后端已有 `HerdrMachineClient.status(_:)`，
   但面板没有「检查连通性」按钮。`reconnect` 是交互式 SSH 认证（会占用终端），
   放进 GUI 会阻塞，需要先设计进度/取消模型。
2. **截图缺失**（锁屏所致，见上）。
3. **`default` 标记只读。** CLI 没有 `machine default <id>` 子命令；`selected` 字段由
   Herdr 自己维护，UI 只显示不可改。
4. **无拖拽排序**：`herdr machine` 无排序子命令。
5. **菜单栏 AX 不可达**：无 nib 的 `NSApplication` 在 System Events 里看不到 `menu bar 1`，
   所以菜单项本身无法被脚本点击验证；面板内容与写操作已验证，菜单点击需人工确认
   （或后续改用 SwiftUI `MenuBarExtra` 场景）。
