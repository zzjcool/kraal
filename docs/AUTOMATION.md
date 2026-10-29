# 自动化 Agent 开发闭环（重构方案 · 提案）

> 状态：**提案，未实施**。2026-10-22。
> 本文所有"✅ 实测"条目都在 2026-10-22 于 Tart VM `kraal-probe` 上跑过，
> 原始日志在 `/tmp/kraal-vm-probe{,2,3,5,6,7,8}.log`。标"⚠️ 未验证"的不要当结论用。

---

## 0. 一句话

**把 UI 验证从「进程内探针 + 人眼看截图」搬到「外部驱动真实界面」**，
让 agent 能自己在 GUI 上点、打、截、断言。
**执行后端是两个可选实现：宿主（local）或 Tart VM（vm）**，同一套驱动、同一套用例。

不是“引入一个自动点击工具”。是把验证方式从**在产物里埋探针**换成**从外部驱动真实界面**，
顺带得到一个免费的副作用：`KRAAL_PROBE_*` 这类测试脚手架可以从产品代码里删掉。

### 0.1 后端的选择（决策已定）

| 后端 | 谁用 | 前提 | 隔离度 |
|---|---|---|---|
| **local**（默认） | 不在乎共享桌面的开发者 | 宿主已授 Accessibility + Screen Recording | ⚠️ 与你真实会话**共享** daemon |
| **vm**（可选） | 要与本机环境隔离的人 | Tart + base 镜像（SIP off） | ✅ 完全隔离 |

> **VM 不是必须的。** 它是给"不想让自己的 daemon 被测试碰"的人准备的选项，
> 不是架构的前置条件。两者共用 `kraal-gui` 与用例层，只换 transport 与生命周期。

**实测支撑这个设计的关键一条**：`AXPress` **不需要激活 app，也不抢焦点**。
宿主上验证：设备窗口用 `orderBack(nil)` 起在后台，前台一直是 Brave Browser，
不碰它直接 `AXPress` → 目标收到 `PRESSED counter=1`，**前后前台都没变**。

> 这意味着 **local 后端可以在你正常用电脑时后台跑 UI 测试**，不需要独占桌面。
> 从而是 **AX 优先、CGEvent 降级**（CGEvent 确实需要 activate，会抢焦点）。

---

## 1. 先修正事实：三条旧结论被实测推翻

`docs/ENVIRONMENT.md` §4.6 目前把下面三条当成硬约束写死。**它们都是错的**，
而且正是它们让"VM 里做 GUI 自动化"看起来不可能。必须先改掉，否则方案推进不下去。

| 旧结论 | 位置 | 实测结果 | 证据 |
|---|---|---|---|
| 「经 SSH 合成鼠标不可用，因为 VM 里没有 Aqua 会话」 | `docs/ENVIRONMENT.md:328-371` | **对 SSH 成立，对 Tart 不成立。** `tart exec` 落在 **Aqua** 会话：`launchctl managername` → `Aqua`，WindowServer(pid 194) + loginwindow(pid 193) 在跑，`autoLoginUser = admin` | `/tmp/kraal-vm-probe.log` E1 |
| 「CGEvent.post 能移动光标但点击进不了任何 app」 | `docs/ENVIRONMENT.md:319` | **点击能进 app。** 测靶 app 收到 `mouseDown at (200.0, 166.0) hits=1`；对照组（点窗口外）`hits=0` | `/tmp/kraal-vm-probe5.log` E25/E26 |
| 「pane 内容是 Metal 画的，AX 树几乎为空 ⇒ AX 路线不可行」 | `docs/ENVIRONMENT.md:161-162` | **终端内容确实为空，但 Chrome/菜单完全可用。** Kraal 在 VM 里：**193 个 AX 节点，163 个可 press** | `/tmp/kraal-vm-probe8.log` E38 |

> ⚠️ **一处必须自我修正的数字**：本文初稿写的是「105 个带 `AXIdentifier`」。
> 这是计数陷阱——那 105 是**匹配正则的次数**，不是唯一个数。去重后只有 **27 个唯一值**，
> 且几乎全是 **AppKit 自动合成的 selector 名**，不是手写的稳定标识：
> `runCommand:` 出现 **5 次**（New Workspace / New Tab / Rename… 全共用一个），
> `_recentItemRequested:` 出现 **7 次**。
> `rg accessibilityIdentifier Sources/` 实测 **0 处**（全仓只有
> `Theme.swift:128` 一个 `accessibilityLabel`）。

### 1.1 之前为什么判错（写进 DEBUGGING.md 用）

1. **测的对象是 SSH，不是 VM。** SSH 进程确实在 Background domain（`launchctl managername` = `Background`），
   那部分推理对。但 `tart exec` 走 guest agent，落在已自动登录的 Aqua 会话里——两者不是一回事，
   结论被从 SSH 推广到了整个 VM。
2. **失败签名被误读。** "光标动了但点击没生效"有两个独立成因：(a) 前台有个 TCC 授权弹窗
   `universalAccessAuthWarn` 在抢焦点（首张截图里可见），(b) 目标窗口没激活 + 坐标算错。
   当时只归因到 Aqua 会话。
3. **缺 A/B 对照组。** 没有"点窗口外应该 0 次"这一组，所以无法区分"事件没送达"和"事件送达了但没点中"。

> 这正是 `docs/DEBUGGING.md` §1「样本要能区分对错」和第 3 条「探针要测对对象」的又一例。

---

## 2. 实测能力清单（重构的地基）

在 `kraal-probe`（tahoe-base clone，6 vCPU / 12 GB / 1920×1200，`--no-graphics` 无头）上逐项验证：

| 能力 | 结果 | 关键数字 / 证据 |
|---|---|---|
| `tart exec` 会话类型 | ✅ Aqua | `managername=Aqua`，`axTrusted=true` |
| 启动 GUI app（AppKit / SwiftUI） | ✅ | Kraal 窗口正常，`window: number=131 pid=3406` |
| 窗口级截图 | ✅ | `screencapture -x -o -l 131` → 1180×760 PNG |
| 全屏截图 | ✅ | `screencapture -x` → 1920×1200 PNG |
| AX 树读取 | ✅ | 193 节点 / 27 唯一 identifier（均为 AppKit 合成）/ 163 pressable |
| AX 语义化驱动 | ✅ | `AXUIElementPerformAction(kAXPressAction)` → `err=0` |
| CGEvent 鼠标点击 | ✅ | 靶 app 收到 `mouseDown hits=1`；对照 0 hits |
| CGEvent 键盘输入 | ✅ | `NSTextField` 收到 `abcd`（`KB_RESULT value=abcd`） |
| **端到端：GUI 动作 → daemon 状态** | ✅ | press `Split Right` → `herdr pane list` **1→2**；再 press → **2→3**；press `Split Down` → **3→4**，截图确认 4 个 pane |
| SIP 状态（base 镜像） | ✅ **已关闭** | `csrutil status: disabled` ⇒ 可写系统 TCC.db 预授权 |
| TCC 弹窗程序化消除 | ✅ | 写入 `kTCCServiceAccessibility/PostEvent/ScreenCapture` + `killall tccd` → 不再出现 `universalAccessAuthWarn` |
| VM 内 `swift` / `swiftc` / `codesign` / `git` | ✅ | 均存在 |
| VM 内 `Testing.framework` | ✅ 意外可用 | `/Library/Developer/CommandLineTools/.../Frameworks/Testing.framework` |
| VM 内 Xcode / `xcodebuild` | ❌ | `xcode-select -p` = CLT；不会出 `.app` |
| VM 内访问 github / ghcr | ❌ | `curl` 双双 20s 超时 → **构建必须在宿主机做** |
| 宿主 ↔ VM 网络 | ✅ | VM 192.168.64.6 → 宿主 192.168.64.1，0.28 ms；宿主 22 端口 LISTEN |
| VM 冷启动到可用 | ✅ 18 s | 含 guest agent 就绪 |
| 宿主推送产物进 VM | ✅ | `tar -cf - ...` 管道给 `tart exec -i <vm> /bin/bash -lc 'tar -xf - -C /tmp'` |

**顺带发现一个真 bug**（这就是这套东西的价值）：
在 VM 里用 AX press 工具栏 `Refresh` 按钮，Kraal **崩溃**：

```
EXC_BREAKPOINT (SIGTRAP)
  _assertionFailure(_:_:file:line:flags:)
  EnvironmentValues.subscript.getter
  KeyPath._projectReadOnly(from:)
  EnvironmentBox.update(property:phase:)
```

崩溃报告：`~/Library/Logs/DiagnosticReports/KraalMac-bin-2026-10-22-041655.ips`（VM 内）。
建议单独开 issue，本文不处理。

---

## 3. 目标架构：两个后端，一套用例

```
┌──────────────────────────────────────────────────────────────┐
│  编排层  Scripts/gui.sh                                        │
│  build → deploy → run <case> → collect → 判定                   │
│  后端无关：后端只决定“在哪跑”和“怎么连”                          │
└───────────────┬──────────────────────────┬──────────────────┘
                │ KRAAL_GUI_BACKEND=local  │ KRAAL_GUI_BACKEND=vm
┌───────────────▼───────────┐  ┌───────────▼──────────────────────┐
│ local（默认）              │  │ vm（可选，隔离）                   │
│ 宿主 Aqua 会话             │  │ tart exec → VM 内 Aqua 会话       │
│ 直接用你的 daemon？不。     │  │ 独立 daemon（固定名额）           │
│ 用一次性 scratch 会话       │  │                                    │
│ kraal-gui 在同一机器       │  │ kraal-gui 推进 VM                  │
└───────────────┬───────────┘  └───────────┬──────────────────────┘
                └──────────┬───────────────┘
                  ┌────────▼─────────┐
                  │ 断言平面（相同） │
                  │ ① daemon 状态    │
                  │ ② AX 树          │
                  │ ③ 截图           │
                  └──────────────────┘
```

### 3.0 两个后端的差异（就这些）

| 维度 | local | vm |
|---|---|---|
| 执行通道 | 直接在本机跑 `kraal-gui` | `tart exec` 把命令送进 VM |
| 隔离点 | **独立 socket + 独立 `KRAAL_HERDR_HOME`**（永不碰你的真名册） | 整个 OS 隔离 |
| 抢焦点 | ❌ 不抢（AX 路径实测不抢） | ❌ 不抢（无头） |
| 视觉可信度 | ✅ 真 GPU，**可做视觉定稿** | ❌ 虚拟 GPU，材质不一致 |
| 前置 | 宿主已授 AX + Screen Recording（本机实测 ✅） | Tart + base 镜像（SIP off） |
| 启动成本 | 0 | 冷启 18 s（长期存活后也只有重置成本） |
| 适合 | 日常开发、改完就验 | 不想让测试碰自己 daemon 的人 |

> **关键设计**：`local` 后端也用**一次性 daemon 实例**，只是它跑在你的机器上。
> 这靠现成的 `build-app.sh` 就已经支持了（它把 `KRAAL_HERDR_SOCKET` 默认指向
> `/tmp/kraal-mine/herdr-client.sock`，`KRAAL_HERDR_HOME` 指向 scratch 目录）。
> 所以“用宿主”不等于“用你的真会话”。

### 3.1 为什么是「外部驱动」而不是继续加探针

现状（P2 之前）：`KraalMacMain.swift` 里 `KRAAL_PROBE_COMMAND` /
`KRAAL_PROBE_DIVIDER_DRAG` 是**编译进发布产物**的测试脚手架，P2 已删除。问题有三个：

1. 只能覆盖**已经想到要埋探针**的路径。菜单点击、右键菜单、模态框、命中测试全都没有。
2. 探针绕过了真实的 AppKit 事件分发——而 `fa3496e`、`e82c104`、`2156703` 三个 bug
   恰恰都出在分发/时序/坐标系上。探针天然看不见这类缺陷。
3. 每次验证都要临时改产品代码（`DEBUGGING.md` §5「临时改动是完整动作」），成本高且容易忘还原。

外部驱动把这三条一起解决，并且**让 `AGENTS.md` §0.1「不留探索区」从愿望变成可执行**：
所有 GUI 操作都发生在一次性 VM 里，真实的 herdr 会话根本不在射程内。

### 3.2 为什么不用 XCUITest

| | XCUITest | 自定义 AX 驱动（推荐） |
|---|---|---|
| 工程门槛 | 必须有 `.xcodeproj` + UI Testing bundle；本仓是 **纯 SPM**（`Package.swift`，无 xcodeproj） | 无，加一个 executableTarget 即可 |
| 与现有构建 | 要维护两套构建系统（SPM + Xcode project） | 复用 `swift build` + `build-app.sh` |
| 等待/重试/报告 | 内建，成熟 | 自己写（约 300 行，已跑通原型） |
| 终端内容断言 | 同样做不到（Metal 自绘） | 同样做不到 |
| 结论 | **暂不引入**，留作 P3 备选 | **P0 起点** |

本仓 `.gitignore:14-15` 还留着 "xcodegen 生成物（project.yml 是唯一事实源）" 的注释，
但 `project.yml` 并不存在——说明曾经想过走 Xcode 路线又放弃了。别再走回头路。

---

## 4. 驱动 `kraal-gui` 的设计

新增 `Package.swift` executableTarget `KraalGUIDriver`（产物名 `kraal-gui`），
**零依赖**于 Kraal 任何 target（只用 AppKit + ApplicationServices），
因此可以被 `swift build` 顺带构建、被 swiftlint 检查、被单独推进 VM。

### 4.1 选择器（全部可选，AND 组合）

```
--id    <AXIdentifier>     # ⚠️ 见下方：Kraal 自己没有手写 identifier，别依赖这个
--desc  <AXDescription>    # 工具栏按钮/单选按钮走这个（如 "Split View Horizontally"）
--title <AXTitle>          # 菜单项走这个（如 "Split Right"）
--role  <AXRole>
--index <n>                # 第 n 个匹配
```

**实证一：identifier 不可靠，必须用 desc/title。**

`rg accessibilityIdentifier Sources/` = **0 处**。AX 里看到的那些 "identifier" 全是
AppKit 自动合成的 selector 名，**不唯一**：

| identifier | 出现次数 | 谁在用 |
|---|---|---|
| `runCommand:` | 5 | New Workspace / New Tab / Rename Workspace… / Rename Tab… / Settings… |
| `_recentItemRequested:` | 7 | Apple 菜单「最近项目」下所有条目 |
| `_aboutThisMacRequested:` 等 | 1 各 | 系统菜单项 |

所以 `--id` 只能当辅助线索。真正能区分元素的是：
- 工具栏按钮 → 只有 `AXDescription`（`desc=Refresh`），**无 title**
- 菜单项 → 只有 `AXTitle`（`title=Split Right`），identifier 是共用的 `runCommand:`
- 侧边栏行 → 两者都无时，只能退到 `--role` + `--index` 或坐标

**实证二：目标不是"AX 全绿"，而是"关键路径可寻址"。**

能稳定驱动的：菜单项 100%、工具栏按钮 100%、侧边栏单选钮/Add/Command 100%。
**不能驱动的**：终端 pane 内部（Metal 自绘，零元素）、
侧边栏 `AXUnknown` 行（`desc=unknown`，只有 `AXShowMenu`）。
后者要断言只能走坐标 + 截图。

### 4.2 命令

实际签名见 §7.1（这节早先写的是设计草稿，与实现有出入，已按实现改写）。
这里是策略层摘要：

| 想做 | 用 | 是否需要前台 |
|---|---|---|
| 按菜单项/按钮 | `press --title` / `--desc` | **不需要**（AXPress 不抢焦点） |
| 按菜单里没展开过的项 | `menu --menu View --item "Split Right"` | 不需要 |
| 点某个坐标 | `click --at X,Y`（窗口相对）或 `click --at-screen X,Y`（屏幕） | 需要，会自动 activate 并确认 |
| 拖分隔条 | `drag --from --to`（窗口相对） | 需要 |
| 键盘快捷键 | `key --char w --mod cmd` | 需要 |

两种坐标不是一个东西，这一点在 issue #72 之前是静默的：`ax --json` 的 `frame` 是**屏幕**
坐标（AX 原生），`click --at` 的参数是**窗口相对**偏移。要点的东西来自 AX，就直接用
`click --at-screen`（原样传，不少一次减法）；只有自己按窗口几何算出的点才用 `--at`。
两种形式都会校验落点在窗口 frame 内，越界退出码 2 并打印窗口 frame 与实际屏幕坐标——
不再 clamp 到窗口边缘（那会让「坐标算错了」表现成「产品 bug」）。

### 4.3 实现坑（P0/P1 实测，2026-10-22）

- **`AXWindows` 在 macOS 27 上不可用**。它返回的元素 `AXRole` 是
  `AXApplication`（app 自身，自引用），`AXPosition`/`AXSize` 一律
  AXError -25205（`.illegalArgument`）。与策略（`.regular`/`.accessory`）、
  重启、干净进程都无关；Finder 从同一属性返回 `AXScrollArea`，所以是系统
  级问题。窗口几何改从 `CGWindowListCopyWindowInfo` 取。
- **`screencapture -l <windowid>` 在本机对每个 app 都失败**
  （`could not create image from window`）——Herdr 也一样，不是 Kraal 的问题。
  降级路径是截全屏再 `sips` 裁剪。
- **没有屏幕录制权限时 `screencapture` exit 0 却产出全黑 PNG**。
  所以驱动会检测均匀像素并 `exit 2` 如实报告，而不是写一张黑图当证据。
- **`activate()` 返回值是 void，而且经常静默失败**。必须轮询
  `NSWorkspace.frontmostApplication` 确认真的到了前台，再发合成事件；
  否则点击会落到当前真正前台的 app 上（实测落到 Herdr，于是"点击成功"但
  app 没反应）。三种失败原因要分开报：锁屏（`loginwindow` 占前台）/
  `.accessory` 策略无法请求前台 / 别的 app 占着焦点。
- **锁屏下 AXPress 照常工作，合成事件完全不可用**。`IOConsoleLocked=true` 时
  前台是 `loginwindow`，任何 app 都无法成为 frontmost。这决定了用例要按
  「AX 可跑 / 需要解锁」分组（`requires() { echo focus; }`）。
- **`AXPress` 的返回码 0 不代表逻辑成功**，只代表动作已投递；必须配合状态断言。

### 4.4 退出码契约（区分"产品 bug"和"环境 bug"）

| 码 | 含义 | agent 该怎么反应 |
|---|---|---|
| 0 | 通过 | 继续 |
| 1 | 断言失败（产品行为不符） | 修代码 |
| 2 | 驱动/环境失败（找不到元素、VM 没起、超时） | **不要改业务代码**，报 blocker |
| 3 | 被测 app 崩溃 | 读崩溃报告，按崩溃处理 |

这条直接对应 `docs/DEBUGGING.md` 的教训：把"测试失败"和"代码错误"分开，
是自动修复闭环不跑偏的前提。

---

## 5. VM 生命周期

### 5.1 一次性初始化（幂等）

```bash
./Scripts/gui.sh bootstrap        # 可用 KRAAL_GUI_VM 换名，默认 kraal-agent
```

步骤：
1. `kraal-agent` **已存在**（2026-10-22 建），正常情况下跳过这步。
   本地克隆源 `tahoe-base` 已删除以回收 31GB；若整台 VM 丢失，改用
   `tart clone ghcr.nju.edu.cn/cirruslabs/macos-tahoe-base:latest kraal-agent`
   （重建后要重做的 guest 设置见 `docs/ENVIRONMENT.md` §4.6）
2. `tart set --cpu 6 --memory 12288 --disk-size 80 --display 1920x1200`
3. `tart run --no-graphics`，等 guest agent（实测 18 s）
4. 推 `herdr` 二进制（`gzip | tart exec -i gunzip`）
5. 推 `kraal-gui` + 测试用的固定名册（`~/.config/herdr/`）
6. **TCC 预授权**：对 `kraal-gui` / Kraal.app 写
   `kTCCServiceAccessibility` `kTCCServicePostEvent` `kTCCServiceScreenCapture`，
   然后 `killall tccd`
7. 起 `herdr server`，验收 `herdr status` 出现 `status: running`

> ⚠️ 第 6 步依赖 base 镜像 **SIP disabled**（已实测）。如果换镜像要重新确认，
> 否则会退回到"人工点授权弹窗"。

### 5.2 每次运行的重置（廉价）

VM 长期存活，每次 case 前做：
- `pkill KraalMac-bin`、`pkill -f "herdr server"` 后重启 daemon
- 删掉 `~/.config/herdr/` 下动态状态，重铺固定名册
- 删 `/tmp/kraal-run-*`

**不要每次 `tart clone`**：克隆是整盘复制（~30 GB），冷启 18 s 反而是最便宜的一环。

### 5.3 网络方向的硬约束

```
宿主：swift build + build-app.sh   ──tar──▶  VM：只运行，不构建
VM：无 Xcode、无外网
```

这不是选择，是实测约束（`xcodebuild` 不存在、github/ghcr 双双超时）。

---

## 6. 断言策略：三档优先级

| 档 | 手段 | 用途 | 强弱 |
|---|---|---|---|
| ① | **daemon 状态**（`herdr pane list` / `pane layout`） | split / close / rename / focus / 布局比例 | 最强，与 UI 实现无关 |
| ② | **AX 树**（结构 + identifier + 可 press） | 菜单是否存在、面板是否打开、按钮是否可用、文本内容 | 强，但终端 pane 内部为空 |
| ③ | **截图** | 布局错位、遮挡、图标异常、视觉回归 | 弱，仅辅助 |

沿用 `chatgpt` 对话里的判断：**截图/视觉模型不能承担精确断言**，
但也不能完全不用——`docs/ENVIRONMENT.md:164-166` 已经写明虚拟 GPU 下
`NSVisualEffectView.behindWindow` 与真机不一致，所以**视觉定稿必须留在宿主机人工判断**，
VM 里只做"有没有明显错位/遮挡"这一档。

---

## 7. 脚本接口（agent 唯一入口）

**实测可用的接口**（P0/P1 已实现，`local` 后端验证通过）：

```
Scripts/gui.sh probe                 # 宿主机能不能驱动 GUI（AX 授权、窗口、截图）
Scripts/gui.sh list                  # 列出用例
Scripts/gui.sh run [case...]         # 不传用例名则跑全部，写 artifacts/
Scripts/gui.sh verify [case...]      # build-app.sh → 跑用例（merge gate）
```

`vm` 后端尚未实现，接口预留为 `KRAAL_GUI_BACKEND=vm`。

**规划中、尚不存在**（P2/P3）：`start|stop|status|reset|build|deploy|collect`、
`shot`、`ax`、`logs`。文档早先写了这些名字，但代码里从来没有——写在这里是为了
不再有人照着跑。

## 7.1 `kraal-gui` 驱动命令

```
kraal-gui probe                              # AX 授权、目标 app 是否在跑
kraal-gui ax [--out FILE]                    # 打印/保存 AX 树
kraal-gui window [--timeout 10] [--title T]  # 窗口 frame + windowNumber
kraal-gui press --title T | --desc D | --id I [--index N] [--within-title M]
kraal-gui menu --menu View --item "Split Right"
kraal-gui click --at X,Y [--right] [--no-activate]    # 窗口相对坐标
kraal-gui click --at-screen X,Y [--right] [--no-activate]  # 屏幕坐标（AX frame 空间）
kraal-gui drag --from X,Y --to X,Y [--steps N]        # 窗口相对坐标
kraal-gui key --char w [--mod cmd,shift]
kraal-gui wait --title T [--timeout 10]
kraal-gui shot --out FILE
kraal-gui type --text S
kraal-gui launch --path build/Kraal.app
kraal-gui quit
```

退出码：`0` 通过 / `1` 断言失败（产品问题）/ `2` 驱动或环境问题（不改业务代码）/
`3` 被测 app 崩溃。

三条实现事实值得记住：

- **`press` 在匹配到多个元素时拒绝执行**。`Split Right` 在 View 菜单和右键菜单
  各有一个，`Copy` 在 Edit 菜单和右键菜单各有一个。
- **AX 图不是树**。`AXMenuBar` 可从 `AXApplication` 和 app 的 children 两条路径
  到达，菜单子树在自身之下重复出现。DFS 必须带 visited 集合，否则
  `Split Right` 会匹配到 13 个元素。
- **窗口几何来自 `CGWindowListCopyWindowInfo`，不是 `AXWindows`**。macOS 27 上
  `AXWindows` 返回的元素 `AXRole` 是 `AXApplication`（app 自身），
  `AXPosition`/`AXSize` 均 AXError -25205；Finder 也一样。

产物布局：

```
artifacts/<run-id>/
├── summary.json          # {case, status, exitCode, assertions[], failureType}
├── cases/<case>/
│   ├── ax-before.json
│   ├── ax-after.json
│   ├── shot-before.png
│   ├── shot-after.png
│   ├── daemon-before.json
│   ├── daemon-after.json
│   └── kraal.log
└── crash/                # 有崩溃才出现（.*.ips）
```

`summary.json` 里必须有 `failureType: product | harness | crash`——
这是 agent 决定"改代码"还是"报 blocker"的唯一依据。

---

## 8. 用例写法（fixture 用 herdr CLI，断言用 herdr + AX）

```bash
# cases/split-right.sh
fixture() {
  herdr workspace new --name t          # 或用固定名册
  herdr pane list | jq -e '.result.panes | length == 1'
}

action() {
  kraal-gui menu "Split Right"
}

assert() {
  # ① 强断言：daemon 状态
  herdr pane list | jq -e '.result.panes | length == 2' || return 1
  # ② 强断言：新 pane 与源 pane 同 tab 且不同 id
  herdr pane list | jq -e '[.result.panes[].pane_id] | unique | length == 2' || return 1
}
```

**这个写法有一个很好的性质：`herdr` CLI 同时是 fixture 构造器和断言 oracle**，
两边都不依赖 Kraal 的 UI 实现。UI 换了写法，测试照样有效——这正是回归测试想要的。

### 8.1 多机（machines / SSH）用例怎么造环境

不需要第二个 VM，也不需要容器。**一个 guest 里就能造出多台机器**，做法是把
`herdr --session <name>` 当成一台独立机器 —— 它有自己的 socket、自己的 `boot_id`、
自己的 pane 集合，正是 `machine add` 要的那种目标。

实测（2026-10-23，guest `kraal-agent`，herdr 0.9.5）从零到「App 里三台机器全在线」**34 秒**。

```bash
# 1. 回环 SSH：guest 的 sshd 本来就开着，只缺 key 和 known_hosts
ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519
cp ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
ssh-keyscan -t ed25519 127.0.0.1 >> ~/.ssh/known_hosts && sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts

# 2. 每台「机器」= 一个 named session；add 会顺手把它的 daemon 起起来
HOME=$ROSTER herdr machine add admin@127.0.0.1 --remote-session mach-a --label alpha-a
HOME=$ROSTER herdr machine add admin@127.0.0.1 --remote-session mach-b --label alpha-b

# 3. App 用同一份名册
KRAAL_HERDR_HOME=$ROSTER KRAAL_HERDR_SOCKET=... KraalMac-bin
```

落地的用例：`./Scripts/gui.sh run machines-roster` 与 `machines-switch`
（`Scripts/gui.sh` 的 machines 段）。

#### 五条实测出来的路，不写下来一定会重踩

| # | 事实 | 证据 / 后果 |
| --- | --- | --- |
| 1 | **`machine add` 只认它自己起的 daemon** | 手起一个 `HERDR_SOCKET_PATH=…/sessions/x/herdr.sock herdr server`，再用 add 指向它 → `error: remote server is not ready for saved machines`。补 `HERDR_MACOS_SERVER_CONTEXT=user` + `HERDR_SESSION` 也拒。**规则：要重置就 `herdr --session X server stop` + 删目录，让 add 去起** |
| 2 | **`known_hosts` 必须先种** | saved machine 走严格 host-key 检查（Kraal 自己 SSH 时才用 `accept-new`）。不种 → `Host key verification failed` + `machine was not saved` |
| 3 | **`HOME` 只隔离名册，不隔离 session 目录** | `HOME=$R herdr machine add …` 把 `endpoints.json` 写进 `$R`，但 daemon 落在**真实** `~/.config/herdr/sessions/<name>`。`XDG_CONFIG_HOME` 和 `HERDR_SOCKET_PATH` 都搬不动它（issue #75） |
| 4 | **`herdr pane list` 要 API socket，不是 client socket** | 指向 `herdr-client.sock` → `EmptyResponse`；指向同目录的 `herdr.sock` → 正常 JSON。一个 `<session>/` 目录里两个 socket，各走各的协议 |
| 5 | **同一 session 反复 add 会留下重复名册项** | 三次 `add` 同一 `--remote-session` 得三条 profile（id 不同、session 相同）。fixture 必须先 teardown 再 add |

#### 断言怎么下

机器行是 SwiftUI `Text`，在 AX 里**只有 `AXValue`**（无 title/desc/identifier，见 issue #71），
而 `onTapGesture` 不响应 `AXPress`。所以「点击某台机器」必须合成点击，而定位要**从 AX 读
坐标**，不能写死：

```bash
# 读 value=alpha-b 那一行的 AX frame（**屏幕**坐标），原样交给 --at-screen
point=$(sidebar_row_point alpha-b)   # Scripts/gui.sh，输出 X,Y
$D click --at-screen "$point"
```

这里曾经要在调用方减一次窗口原点再走 `click --at`（issue #72）。减法没了：AX frame 本来就
是屏幕坐标，`--at-screen` 原样使用；而「越界不报错、悄悄 clamp 到窗口边缘」也一起没了。
`sidebar_row_point` 返回的就是屏幕点，不再需要 `driver window` 配合。

写死 y 的版本失败过：Local 多一个 workspace，机器行整体下移，点击落到 workspace 行上，
用例报「split 落到了 alpha-a」，而产品是对的。

**断言必须落在 daemon 上**：点 alpha-b 后按 Split Right，必须是 **alpha-b** 的 pane 数 +1、
alpha-a 不变。只断言「App 认为切换了」无法区分「切了」和「切了但命令还发往旧连接」。

#### 这个用例抓住过什么

故意把 `selectEndpoint` 里的 `target = endpoint.settings` 删掉（模拟「切了但不改命令目标」），
`machines-switch` 立刻红：`alpha-a 1->1, alpha-b 1->1`，退出码 1。恢复后绿。
这是 §0.3 要求的 A/B。

#### 不能用两个容器：guest 没有嵌套虚拟化

```text
guest: kern.hv_support = 0
guest: docker/podman/colima/lima/tart 全部 missing
```

宿主是 M1 Pro（`hv_support=1`），理论上能 `tart run --nested` 重建镜像再在 guest 里跑
Linux 容器，但那是重造整个验证环境（80 GB 磁盘、guest 内再装一套运行时），换来的只是
「多台机器」——而 named session 已经给了这个，代价是零。

---

## 9. 分阶段计划

### P0 跑通一次真实 GUI 断言（0.5–1 天）

- `Scripts/gui.sh` 的 `bootstrap / build / deploy / run / collect`
- `kraal-gui` 的 `launch / ax / press / menu / shot / wait`
- 一个 case：`split-right`（daemon 1→2）
- 文档修正：`docs/ENVIRONMENT.md` §4.6 三条错误结论 + `KraalMacMain.swift:153-155` 注释

**验收**：`./Scripts/gui.sh verify` 退出 0；
把 `split` 的 daemon 请求故意改坏 → 退出 1 且 `summary.json` 指向 `pane 数没变`。

### P1 断言层成型（1–2 天）

- 选择器 + wait/retry + `ax --json`
- 覆盖：右键菜单 split/close、分隔条拖动（坐标路径）、pane 聚焦、菜单快捷键
- artifacts 全套 + 失败自动截图 + AX 快照

**验收**：任一 case 失败时，只看 `artifacts/` 就能说出"哪个元素没出现 / 哪个数没变"。

### P2 Agent 闭环（1–2 天）

- 改写 `AGENTS.md`：删「禁止真实鼠标」的旧约束 → 改为「UI 验证只走 VM」
- 3 轮修复上限、失败分类、`verify` 作为 merge gate
- ~~逐步删除 `KRAAL_PROBE_*`~~ **已完成**：先补上 `drag-divider` 用例
  （`KRAAL_PROBE_DIVIDER_DRAG` 曾是 `e82c104` 唯一的端到端证据），再删掉 4 个
  探针变量、2 个私有方法、`MacMenuBar.runProbe`，以及同类的
  `KRAAL_MACHINES_DEMO`。合计 -146 行产品代码。

**验收**：故意引入一个 UI bug → agent 从红到绿，全程无人参与。

### P3 无人值守（按需，前置条件见 §10）

- 合盖常驻 + 远程接入
- 任务队列：agent 领任务 → VM 跑 → 出报告

---

## 10. 合盖 / 远程：现状与未验证项

### 10.1 已确认

| 项 | 状态 |
|---|---|
| VM 无头运行（不占屏幕、不抢焦点） | ✅ `tart run --no-graphics` 实测 |
| VM 占资源 | 6 vCPU / 12 GB；宿主 14 核 / 48 GB，余量够 |
| 宿主 sshd | ✅ `launchctl print-disabled system` → `com.openssh.sshd => enabled`，22 LISTEN |
| VM → 宿主连通 | ✅ 0.28 ms |

### 10.2 ⚠️ 未验证 —— 不要当结论

| 项 | 为什么没验 | 怎么验 |
|---|---|---|
| **合盖不休眠** | 需要 sudo 密码，`sudo -n pmset` 被拒 | `sudo pmset -a disablesleep 1` → 合盖 → 从另一台机器 ssh 进来肉眼确认；用完 `pmset -a disablesleep 0` **必须还原** |
| VM 在宿主睡眠期间的表现 | 同上 | 宿主睡 → 醒后 `tart list` 看 State、`herdr status` 是否还活着 |
| 跨网络远程接入 | 本机未装 Tailscale | 装 Tailscale 或用 frp/反向隧道 |
| 长时间无人值守的稳定性 | 未跑过小时级 | 连跑 N 小时看 VM 是否泄漏、herdr daemon 是否僵死 |

**风险提示（我的判断，非实测）**：MacBook 合盖 + `disablesleep=1` 会持续发热，
电池长期这么干有损耗。如果这是长期形态，**一台常开的 Mac mini 比笔记本合盖更合适**。
这条不影响 P0–P2——那三段都不需要合盖，甚至可以人在电脑前跑。

### 10.3 远程架构（验证过连通性，未实现）

```
你的笔记本 ──ssh/tailscale──▶ 宿主 Mac
                                 └─ tart run --no-graphics kraal-agent（常驻）
                                      └─ agent 在 VM 里/宿主侧循环领任务
```

注意：**不要用 SSH 进 VM 驱动 GUI**（那是 Background 会话，见 §1.1）。
SSH 只用于**宿主**；进 VM 一律 `tart exec`。

---

## 11. 明确不做

| 不做 | 原因 |
|---|---|
| 引入 `.xcodeproj` / XCUITest | 纯 SPM；两套构建系统成本 > 收益。留 P3 备选 |
| 在 VM 里编译 | 无 Xcode、无外网（实测超时） |
| 把视觉定稿搬进 VM | 虚拟 GPU 的 `behindWindow` 材质与真机不一致 |
| 用 SSH 驱动 VM 里的 GUI | Background 会话，事件投递不到 app |
| 通用坐标录制回放 | 对窗口尺寸/cell 尺寸极脆弱；坐标只在"AX 表达不了的 pane 内部"用 |
| 每次 case 都 `tart clone` | 整盘复制 ~30 GB，比冷启 18 s 贵得多 |

---

## 12. 需要立刻修的文档/代码漂移

重构的同时一并处理（都是实测发现）：

| # | 位置 | 问题 |
|---|---|---|
| 1 | `docs/ENVIRONMENT.md:328-371` | 「合成鼠标一定失败」结论错误（§1） |
| 2 | `docs/ENVIRONMENT.md:319` | 「点击进不了任何 app」错误 |
| 3 | `docs/ENVIRONMENT.md:161-162` | 「AX 树几乎为空」以偏概全（终端为空，Chrome 完整） |
| 4 | `docs/ENVIRONMENT.md:301,416` | tart 版本写 2.32.1，实测 **2.41.1** |
| 5 | `docs/ENVIRONMENT.md:421-423` | 「可直接 clone 本地缓存镜像」——OCI 缓存符号链接已断 |
| 6 | `Sources/KraalMac/KraalMacMain.swift:153-155` | 注释仍是旧结论（Accessibility 导致失败） |
| 7 | ~~`README.md:91`~~ | 已过时：`kraal-agent` 现在**存在**并且是 `gui.sh` 的默认后端；`tahoe-base` 已删除 |
| 8 | `AGENTS.md:85` | 「173 个测试，28 个套件」→ 实际 228 `@Test` / 38 `@Suite` / 26 XCTest |
| 9 | `Scripts/agent-vm.sh:64` | `die` 在 `case` 之前，VM 不存在时连 `destroy` 都执行不了 |
| 10 | `Scripts/agent-vm.sh:187` | `"$*"` 拼接丢失引号语义 |
| 11 | `Scripts/verify.sh:11` | **门禁漏洞**：未导出 `DEVELOPER_DIR`——新机器/CLT 环境下 `import Testing` 会 `no such module`，而 `swift test` 是该脚本的核心门禁 |
| 12 | `Scripts/verify.sh:64-66` | **门禁漏洞**：`swiftlint` 缺失时只打印 `swiftlint not installed; skipping`，**不算失败**。CI/新环境下会静默少一道门禁，本地却一直是绿的 |
| 13 | `Scripts/build-app.sh:96` | launcher heredoc 里未转义的反引号在生成时被求值，产物注释里 `` `herdr` `` 变成空串（`build/Kraal.app/Contents/MacOS/KraalMac:20` 实测为 `#  honours $HOME…`）。**仅影响注释，功能无损**，但下次有人读产物会被弄糊涂 |
| 14 | `AGENTS.md:91-96` | 「`nested herdr is disabled` 是噪音」——但当前源码与产物里**已无 `$(herdr)` 命令替换**，该条目已失效，会误导人去找不存在的输出 |
| 15 | — | 新 bug：AX press 工具栏 Refresh → `EXC_BREAKPOINT`（§2） |

### 12.1 为什么第 11/12 条要和本次重构一起修

这两条不是文档漂移，是**验收链路本身的缺陷**。新的 `gui.sh verify` 会复用
“全部门禁通过才算绿”这个语义：

- 缺 `DEVELOPER_DIR` → 在 CI 上 `swift test` 直接挂，但本地永远绿 →
  “本地跑通”不再是一个可信信号。
- 缺 `swiftlint` 只跳过 → 与新加的 GUI 门禁叠加后，**两道门都可能静默消失**，
  而 `verify` 依旧退出 0。

这正是 `AGENTS.md` §0.2 反复警告的模式（“测试通过和修好没有关系”），
只不过程度更轻：**门禁绿和代码合格没有关系**。

修法（两条都是一行）：

```bash
# verify.sh 顶部
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# verify.sh 的 lint 分支：缺失即失败，除非显式 KRAAL_SKIP_LINT=1
else
    if [ "${KRAAL_SKIP_LINT:-0}" = "1" ]; then
        printf 'swiftlint not installed; skipped by KRAAL_SKIP_LINT=1\n'
    else
        printf 'FAILED: swiftlint not installed (set KRAAL_SKIP_LINT=1 to override)\n'
        FAILED=$((FAILED + 1))
    fi
fi
```

**但先别急着手改**：这两条会改变 `verify.sh` 的退出码语义，
应该在 P0 建 `gui.sh` 时一并处理，避免“先改门禁、再加门禁”两次改同一处。

---

## 13. 已定决策（2026-10-22）

| # | 决策 | 结论 | 影响 |
|---|---|---|---|
| 1 | **后端策略** | **两个后端：`local` 默认 + `vm` 可选；长期存活，不每次重建** | 架构从“一个平面”改成“两后端一套用例”（§3.0）；`gui.sh` 要接受 `KRAAL_GUI_BACKEND` |
| 2 | **`KRAAL_PROBE_*` 何时删** | **P2 已删除** | 先用 `drag-divider` 用例替代其覆盖，再删；`KRAAL_MACHINES_DEMO` 同类一并删除 |
| 3 | **P3 合盖** | **P0–P2 做完再谈** | §10 的未验证项不阻塞任何实现 |

### 13.1 决策 1 的含义（重要）

“VM 不是必须的”不是把 VM 降级成备注，而是把**执行后端抽象出来**。
具体后果：

1. **`gui.sh` 必须后端无关**：`build/deploy/run/collect` 四个动作对两个后端都有意义，
   只有 `deploy` 在 local 下退化为 `cp`（本地无需推送）。
2. **`kraal-gui` 自身不能知道后端**：它只会“连一个 socket + 找窗口”，
   不关心自己跑在宿主还是 VM。这样两个后端共用同一份驱动和用例。
3. **断言层必须相同**：都是 `herdr pane list` 这类 daemon 查询，
   不能出现“local 用 A 方法、vm 用 B 方法”——那就不再是同一份测试。
4. **视觉定稿只在 local**：§3.0 表格里 `vm` 的视觉可信度是 ❌，
   所以“看起来对不对”永远只能 `KRAAL_GUI_BACKEND=local` 跑。
5. **CI 未来可以只跑 local- headless 部分**（纯协议/单元），GUI 层仍要人机。

### 13.2 决策 1 带来的一个新风险（必须处理）

`local` 后端跑在你的真机器上，而 `build-app.sh` 默认 socket 是
`/tmp/kraal-mine/herdr-client.sock`——**这是沙箱，但仍是宿主的进程**。

风险：如果 `local` 后端的 reset 逻辑出错（或环境变量没传对），
`kraal-gui` 可能驱动到**你正在用的 herdr 实例**上——那正是 `AGENTS.md` §0.1
「不留探索区」禁止的事。

**硬约束（要写进 `gui.sh`）**：

```bash
# local 后端启动前必须验证：目标 socket 不是用户的真 socket
case "$SOCKET" in
  "$HOME/.config/herdr/herdr-client.sock")
    die "refusing to drive the user's real daemon; use a scratch socket" ;;
esac
# 且 KRAAL_HERDR_HOME 必须指向 scratch（/tmp/...），不能是 $HOME
[ "$KRAAL_HERDR_HOME" = "$HOME" ] && die "KRAAL_HERDR_HOME must be a scratch dir"
```

这条比 VM 的隔离更依赖纪律：VM 里搞错只影响 VM，local 里搞错会**真的分你的屏**。

---

## §14 测试方法的可靠性排序（2026-10-26）

项目缺口不是「测试数量不够」，而是**只有两类证据**：`swift test`（判决逻辑）和
`gui.sh`（daemon 状态）。中间那层——「我们的解码器/渲染器与另一个实现是否一致」——
几乎没有。这一节按**判别力**排序，从最可靠往下。

### 1. 上游 fixture（最强，成本最低）

拿另一个实现写出的字节，喂给我们的解码器。

```swift
// Tests/KraalProtocolTests/UpstreamFixtureTests.swift
@Suite("Upstream surface frames")
struct UpstreamSurfaceFrameTests {
    // 4 个 surface-*-v1.bin，原样拷自 herdr-gpui/crates/herdr-protocol/tests/fixtures/
}
```

**为什么强**：手写一遍 encoder/decoder 再互相对照，只能证明**自己和自己一致**——
两边对字段顺序的同一个误解会同时出现在两边，测试照样绿。上游字节由不同实现写出，
不一致才可见。

**成本**：拷文件 + 一个解析 helper。四个渲染帧覆盖 full / delta / reuse / 两个滚动方向。

**怎么找**：`<ref>/crates/*/tests/fixtures/`。当前上游还有我们用不到的：
`endpoint-agent-view-v1.json`（agent view 投影，我们未实现，见 #102）。

**坑**：上游 fixture 常是**长度前缀的消息流**（`u32` LE + payload，
`codec.rs:69-79`），不是单条裸消息。第一次直接喂给 `ServerMessageDecoder` 得到
`unknown server message tag 61`——61 是长度前缀的第一个字节，不是 tag。

### 2. 上游自己的测试序列（强，需要翻译）

把上游断言**逐条复刻**成我们的测试，而不是只读它的算法再自己写一个。

```swift
// AgentPanelSortTests.upstreamSequenceReplays
// 复刻 endpoints.rs:1915-1975 的三帧：idle→Local 先变→remote 变 working→remote 回 idle
```

**为什么强**：它钉的是**语义**，不是实现。第三帧「变回 idle 本身也是一次变化」是
最容易写错的地方，只看代码很容易漏掉 `is_none_or` 的首次为真语义。

**成本**：找到上游 `#[test]`，读懂它的断言，用我们的 fixture 重放。

**坑**：写的时候把 `previous` 传成了新快照（自己跟自己比，`seq` 相等 → 判定没变化），
测试先红了一次。要看**真实调用点**传的是什么，不是我以为的。

### 3. 故意改坏（A/B，必须有）

任何新断言都要证明「它曾经红过」。

```bash
# 改坏 → 跑 → 数红条 → 恢复
python3 -c "..." ; swift test --filter X 2>&1 | grep -c '✘ Test "'
```

**为什么必须**：本轮写了一个「buffer 大小 == w*h」的断言，把 `width`/`height`
交换后**照样绿**——乘积不变。加了「终端表面宽大于高」才抓住。没有 A/B 就交付了一个
永远抓不到转置的断言。

**纪律**：A/B 之后先 `swift build` 再信结果；SourceKit 的过期诊断会造成假恐慌。

### 4. daemon 状态（已有，`gui.sh`）

`gui.sh` 断言 daemon 侧状态（pane 集合、layout 几何、agent 列表），不是「点了没崩」。

### 5. 像素（最弱，慎用）

本项目已证伪过一次：#135 折叠态透明探针方向反了（有 chrome `dark=27`、
无 chrome `dark=2295`），对「有没有背景」零判别力，断言被删除。

**能用的情况**：被测对象在已知坐标、且颜色差异来自被测行为本身。

### 假 agent：`working` 现在造得出来了（2026-10-26 更新）

之前记为「两次尝试都失败、原因未查清」。**查清了**：

`claude.toml` 的三条 `working` 规则走**不同 region**：

| 规则 | region |
| --- | --- |
| `osc_title_working` | `osc_title`（终端标题） |
| `live_turn_working` | `bottom_non_empty_lines(12)`（屏幕正文） |
| `background_mcp_task_working` | 同上 |

前两次尝试都在**正文**里造格式，而那两条屏幕规则匹配的形状里含 prompt box ——
stub 没有，「屏幕内容明明对、daemon 仍报 idle」就是这个原因：我一直在查自己造的
文本，而规则看的是另一个 region。

正解是标题，一条转义序列就够：

```bash
printf '\033]0;⠋ working\007'
```

**每个状态都要重置标题**：第一版无条件设置，`plant_agent idle` 也报 `working`
（上次的标题还在）。

代码：`Scripts/gui.sh` 的 `plant_agent` stub；用例 `status-change-resorts`。

仍然造不出的：`done`（manifest 里它是从 working 迁移推出来的，不是独立规则）。

### 发送路径现在可测了：`DaemonConnection` + 记录型替身（2026-10-26）

在此之前，所有 `KraalUI` 的「我们发了什么」测试都停在 `connection == nil`：
`AppStore.connection` 是具体的 `EndpointConnection`（actor，构造要真 socket）。

UI 实际只用到 **9 个成员**：

```
connection.request / sendPaneInput / sendPopupInput / sendResize
connection.start / stop / abort / currentBootId
```

帧、握手、读线程、pending-request 记账一概看不到。所以 `DaemonConnection` 协议
只收这 9 个，`AppStore.connection` 改成 `(any DaemonConnection)?`，
测试用 `Tests/KraalClientTests/DaemonConnectionRecorder.swift` 记录每一帧。

**协议必须全 `async`。** 两种错法都试过：

- 标 `@MainActor` → `actor 'EndpointConnection' cannot conform to
  global-actor-isolated protocol`
- 不标但保留同步 `throws` → `conformance crosses into actor-isolated code`

替身的两个刻意的简化：

- `request` 回一个空 JSON `{}`，不解析真实回包。被测路径都丢弃 body，
  假回包只会往测试里塞一个解码器。
- `sendResize` **不**像真 actor 那样去重。真实现尺寸没变就 early return，
  替身若也去重，「只发一次」的断言会对着替身绿、对着生产因为别的原因红。

这套东西解锁的断言（每条都做过 A/B）：resize 的最终网格、粘贴走 `.paste` 而不是
按键、busy 拒绝的重试上限、控制类拒绝不重试、`sendMouse` 的闸门与坐标映射、
copy-mode 的列 clamp 与 `content_revision`、关闭流程的组确认、`cyclePane` 的负步长包裹、
效果路由的通知例外。

### 覆盖率判据：逐函数名，不要看文件名（2026-10-26）

「测试文件里是否出现源文件名」这个判据在本仓库**错了三次**（#153、#160、#162）。
用它得出的结论每次都偏悲观：`isValidWorkspaceBlock`、`workspaceBlockParams`、
`splitHostPort` 系列都有测试，只是因为测试文件名不同、或者经由公开入口间接调用。

可用的判据是逐函数名：

```bash
for f in Sources/KraalUI/AppStore*.swift; do
  for fn in $(grep -oE "func [a-zA-Z_]+" "$f" | sed 's/func //' | sort -u); do
    grep -rq "\b$fn\b" Tests/ || echo "  $(basename $f): $fn"
  done
done
```

它仍会漏掉「经公开入口间接覆盖」的情况（`closeAfterChecking` 由 `close(workspaceId:)`
覆盖），所以输出要人工过一遍：单行 `call` 包装基本不值得单独测。

### 目前明确无法自动化的（不要假装能做）

| 项 | 原因 |
| --- | --- |
| 系统通知真的弹出 | ad-hoc 签名无 Developer ID，`UNUserNotificationCenter` 授权被拒（`UNErrorDomain 1`）。可断言「走到系统 API 并如实降级」 |
| 卡片/行宽度 | AX 树没有行容器元素（背景由 SwiftUI 绘制），只有文字节点。靠结构保证 + 代码注释 |
| 假 agent 的 `done` 状态 | 见上节：`working` 已能造出，`done` 是 manifest 从 working 迁移**推出来**的，不是独立规则 |
| 改主题后实时重绘 | 需要自动化系统外观切换 |

### 还能做但没做的

1. **UI 层 32 个源文件零测试引用**（`AppStore+*` 共 2679 行）。它们不是 View，
   是可测的状态机；`AppStore+Effects`（本轮新增）有 `EffectRoutingTests` 覆盖，
   其余没有。
2. **`Palette+Builtin` 可做逐值对照**：本轮手工核对过 342 个值全一致
   （脚本一次性比对），但没有固化成测试。转录错误不会有任何单测失败。
3. **`Bench.sh` 只有性能数字，没有回归门禁**：`docs/PERFORMANCE.md` 有实测值，
   但没有「超过 N% 就红」的阈值断言。

---

## §15 抖动现在是门禁：`drag-jitter`（2026-10-29）

抖动是「画面怎么产生」的问题，不是「分隔条最后停在哪」的问题，所以判定标准只能是
**像素**：拖动过程中连拍，比较同一块本该不动的区域。

用例（`Scripts/gui.sh run drag-jitter`）：

1. 上下分屏，往上面板敲 `seq 1 400`，让它填满静态文本；
2. `kraal-gui drag --frames 10 --frame-interval 40` —— 按钮**不松开**的同时连拍 10 张
   （新增能力，见 `SyntheticInput.drag(onHold:)`）；
3. `kraal-gui diff --a frame-0 --b frame-N --rect …` 比较上面板里的一块 919×272pt 区域；
4. 判定：`mismatch` 必须为 **0**——两张帧是同一幅图，任何差异都是渲染器画了 daemon
   没送的东西。

同一用例、同一台 VM、只切一个变量：

| 渲染 | 最差 mismatch |
| --- | --- |
| 默认（拖动期间自绘） | **0 px**（9 次比较） |
| `KRAAL_CELL_PAINTER=off`（只走引擎） | **144 px**（`frame-2.png`） |

这就是注入验证：把遮罩关掉，用例立刻变红。**没有这一栏，门禁只是"跑过了"**。

### 顺带修掉的一个假门禁

`drag-divider-vertical` 原来把分隔条位置算成 `origin_y + container_h / 2`，但容器
是从窗口里 `containerOrigin=(221,71)` 开始的（标题栏/tab 栏占了 71pt）。于是它的
按下点比真正的分隔条高 71pt——落在面板内部，拖动变成了**终端里的文本选择**。

它能一直"通过"，是因为它只断言「20 步拖动没有逐行重建屏幕」，而它根本没在拖分隔条。

现在两个横向拖动用例都按日志里的 `containerOrigin` 取真实位置，并且都断言
**ratio 真的变了**（0.5 → 0.531）。教训与 §0.3 同源：一个用例可以一直绿，
同时什么都没测。

`shellcheck` 在本机缺失（`command -v shellcheck` 为空），所以这一轮脚本改动没有过
shellcheck 门禁，只有 `bash -n` 语法检查——写在这里以免下次误以为跑过了。

---

## §16 一次「八条用例同时红」的根因是一个缺失的文件（2026-10-29）

`verify.sh` 的 GUI 门禁红成一片：`machines-roster`、`machines-switch`、
`machines-controls`、`machines-reachability`、`context-menu-remote`、
`session-name-budget`、`sidebar-priority-across-machines`、`notification-posted`、
`status-change-resorts` —— 看起来像八个 bug，其实是**一个**：

```
error: matching remote herdr 0.9.5 is not installed at "$HOME/.local/bin/herdr";
run from an interactive terminal to approve installation; machine was not saved
```

`herdr machine add` 会把一个同版本 herdr 装到远端账号的 `~/.local/bin/herdr`，但**只在
交互终端里**做。无人值守的 fixture 没有 TTY，于是第一条 machines 用例死在自己的
fixture 里，后面所有「需要名册」的用例跟着一起死。

修法两处，都是幂等的：

- `Scripts/gui.sh` 的 `machines_prereqs` 现在在 `machine add` 之前把**自己用的那个**
  herdr 复制到 `~/.local/bin/herdr` 并校验 `--version` 一致（`machines_remote_herdr`）。
  不同版本的失败信息会写明「remote herdr is X, want Y」，不再伪装成八条用例失败。
- `Scripts/vm-bootstrap.sh` 增加同一项检查与修复（换机器/重建 VM 时一次到位）。

同一次排查里还挖出两条**用例自身的 bug**：

1. `session-name-budget` 在**宿主**上算预算（`os.path.expanduser("~")` = `/Users/zzj`），
   而被测 app 跑在 guest（`/Users/admin`）——两个字符的 home 长度差就是不同的预算。
   它预测 51、app 回答 49，于是红。现在用 `machine_home`（两个后端都对）取 app 的 home。
2. `sidebar-divider-drag` 偶发 `could not bring 'Kraal' to the front`：上一条用例的窗口
   还在拆，第一次 `activate` 被吞。`activateAndConfirm` 现在重试一次（300 ms），
   专治这种「单跑绿、整套红」。

### 整套 36 条用例现在的结果（分两段跑）

| 段 | 用例 | 结果 |
| --- | --- | --- |
| 前 17 条 | `click-coordinates` … `machines-switch` | 17 passed / 0 failed |
| 后 19 条 | `machines-controls` … `status-change-resorts` | 19 passed / 0 failed |

**为什么分两段**：整套一次跑完时 guest 在中途以
`VZErrorDomain Code=1 "The virtual machine stopped unexpectedly."` 停掉（两次，不同位置）。
这不是用例失败，宿主内存/磁盘都正常，是 Virtualization.framework 的 guest 崩溃；分两段
跑各自全绿。这条写在这里，免得下次又把「VM 死了」当成「用例红了」。
