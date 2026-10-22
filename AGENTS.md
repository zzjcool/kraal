<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# AGENTS.md

给在这个仓库里工作的 AI agent / 协作者的操作约定。

`docs/` 下是**知识**（协议怎么工作、环境什么版本），这份是**行为**（该跑什么、
不该做什么、验证到什么程度算完）。两者冲突时以 `docs/` 的实测记录为准。

**第一次进这个仓库、或者换了一台机器，先读 `docs/RUNNING.md`**——那是一份从
clone 到能验证 UI 改动的最短路径清单（装什么、跑什么、缺什么会表现成什么样）。

文档分工见文末 §5。

---

## 0. 三条硬规则

### 0.1 不留探索区

**不要**用真实 herdr 会话做实验：不在这台机器上正在使用的 workspace 里 split /
close / 发键盘输入 / 改布局。

**桌面本身也算探索区。** 驱动真实窗口会夺走指针和键盘——为了调一个拖拽，曾经
反复 `activate()` 把窗口拉到前台，把正在干活的人打断了。所以 `gui.sh` 默认后端
是 `vm`；`local` 下要前台的用例会被直接拒绝，除非显式
`KRAAL_GUI_ALLOW_FOCUS=1`。

开发与自测必须在隔离环境里做
（`docs/ENVIRONMENT.md` §4.3、§4.4）。

本项目开发期间发生过：反复在 agent 自己正在运行的 workspace 里 split，
既打断会话又让"测试"污染了真实状态。

### 0.2 UI 改动必须端到端验证

`swift test` 全绿只说明请求体/纯函数对。**用户报的是"点了没反应"时，测试通过
和修好没有关系**——这个仓库最难的三个 bug 全部通过了单元测试，却全部没生效：

| 缺陷 | 单元测试为什么没抓到 |
|---|---|
| `pane.split` 用了 `pane_id`（schema 只有 `target_pane_id`） | 测试断言的是"我们发出的字典"，不是 daemon 接受了什么 |
| `focus()` 是异步的，命令同步读了旧焦点 | 测试不经过 `runCommand` 的时序 |
| daemon 用 `{"error":{...}}` 在 body 里拒绝，不抛异常 | 测试不知道自己属于"带内报错"协议 |

验证一个 UI 命令真的生效，标准是**daemon 侧状态变了**：

```bash
# 动手前
herdr pane list | ...   # 记录 pane 集合
# 触发命令
# 动手后：集合必须变；只看到 "call: ok" 不算证据
herdr pane list | ...
```

### 0.3 说"修好了"之前，先证明它曾经坏

见 `docs/DEBUGGING.md` §2。修完看起来正常 ≠ 修的是那个原因。A/B 回退能复现，
才算定位。

---

## 1. 构建与验证

### 工具链：必须用 Xcode，不能用 CLT

`swift test` 需要 Xcode 平台框架。用 `/usr/bin/swift`（CommandLineTools
工具链）会失败。

> **更正（2026-10-22 实测）**：原文写「需要 `Testing.framework`，它只随 Xcode
> 提供」——现在 CLT 也带了 `Testing.framework`：
> `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework`
> 确实存在。真正缺的是 **`XCTest.framework`**（CLT 目录里没有），
> 而 `Tests/KraalTransportTests/` 有 3 个文件 `import XCTest`。
>
> 实测错误是：
> ```
> HerdrMachineClientTests.swift:13:8 unable to resolve module dependency: 'XCTest'
> ```
> 结论不变（仍然必须 `DEVELOPER_DIR` 指向 Xcode），**但看错误信息时不要再去找
> `Testing`**——它会先把人往错方向引。

```
error: no such module 'Testing'
```

而 `xcodebuild` 会被 Xcode 许可协议拦（`You have not agreed to the Xcode
license agreements`，exit 69）。

绕开方式——**只对 `swift build` / `swift test` 生效**，不改系统状态：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/usr/bin/swift build
/usr/bin/swift test
```

`Scripts/verify.sh` 现在会自己导出 `DEVELOPER_DIR` 并显式用 `/usr/bin/swift`，
所以直接跑也行（2026-10-22 起）。手动逐条跑仍需要自己 export。

### 命令清单

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

/usr/bin/swift build                     # 全部 target
/usr/bin/swift test                      # 全绿（330 个 test id，参数化用例会被并成一个）
export PATH="$HOME/.pi-lens/bin:$PATH"   # swiftlint 不在默认 PATH
swiftlint --quiet Sources Tests          # 必须零违规
for f in Scripts/*.sh; do shellcheck -S warning "$f"; done   # 必须零警告
./Scripts/build-app.sh                   # 打包 build/Kraal.app（ad-hoc 签名）

./Scripts/verify.sh                      # 六道门禁全跑（推荐）
./Scripts/test-baseline.sh               # 已知红名单（现在是空的）+ 全量跑；verify.sh 用它
./Scripts/test-baseline.sh --compare     # 名单里是否有「其实已经绿了」的陈旧条目
./Scripts/gui.sh run split-right         # 单个 UI 用例（需已 build-app.sh）
./Scripts/gui.sh list                    # 现有用例

./Scripts/vm-bootstrap.sh                # 幂等：建/查 VM、验 Aqua、验三条 TCC 授权
./Scripts/vm-bootstrap.sh --fix-tcc      # 授权丢了才用（升级 guest 内 Homebrew 包后会丢）
./Scripts/vm-bootstrap.sh export FILE    # 自己换机器：22GB / 32s
./Scripts/vm-bootstrap.sh import FILE    # 换机器另一端：17s
```

`verify.sh` 六道门禁：`swift build` → `swift test` → `swiftlint` → `shellcheck`
→ `build-app.sh` → `gui.sh run`。`--fast` 跳过最后两道，`KRAAL_SKIP_GUI=1` 只跳 GUI。

**移植的兼容性测试现在全绿。** 从上游三个参考项目移植的那批测试，当初有 22 条
是红的（它们钉的是本客户端还没实现的行为）。这些差异已全部修完
（issue #1、#3–#10、#18、#19），逐条记录在 `docs/PORTED-TESTS.md`。

门禁仍是 `Scripts/test-baseline.sh`：它跑全量、只跳过 `REDS` 名单里的条目。
**名单为空就是目标状态**，此时它退化成一条普通的 `swift test`。

两条纪律：

- 名单一旦重新长出条目，说明有真实回归（或者又移植了一条故意红的测试）。
- 修掉一条就从 `REDS` 删掉它。`--compare` 会列出「名单里但其实已经绿了」的
  条目，输出为空才说明名单是准的。**名单变陈过两次**（issue #2、#9），每次都是
  白丢了护栏。

**给别人的时候不要传 .tvm**：公开的基础镜像已自带 Aqua 会话、SIP 关闭、四条 TCC
授权，他跑一次 `vm-bootstrap.sh` 就行（拉 26.4GB，实测 25 分钟）。传 .tvm 会让
他的镜像永久冻结在你的 macOS 补丁级别上。细节见 `docs/RUNNING.md` §7。

**`shellcheck` 缺失时门禁判 FAILED**，和 `swiftlint` 同样的策略（`KRAAL_SKIP_LINT=1`
可跳过）。脚本本身就是门禁的一部分——`gui.sh` 坏了等于 GUI 门禁坏了。

### GUI 门禁：`gui.sh` 能证明界面动作真的改了 daemon

跑在 VM 里（`KRAAL_GUI_BACKEND=vm` 是默认值），所以可以无人值守地跑：
它不会碰你的指针、键盘，也不会截你的屏。

`swift test` 覆盖不到「点了有没有反应」——§0.2 那三个 bug 全部通过了单元测试。
补这一层的是 `Scripts/gui.sh`：起一个**隔离的 scratch daemon**，用
`kraal-gui` 通过 Accessibility 驱动真实窗口，然后断言 **daemon 状态**。

```bash
./Scripts/gui.sh run split-right
#   ✓ pane count grows by one (1 -> 2)
#   ✓ split geometry is two equal halves (ratio=0.5 widths=[56, 56] focused=w1:p2)
#   ✓ split stays inside one tab, ids distinct (tabs=1 panes=[['w1:p1', 'w1:p2']])
```

三条纪律：

1. **几何断言必须用 `herdr pane layout`，不能用 `pane list`**。后者没有尺寸
   字段，只能数数量——「split 了但比例是 0.85」这种 bug 数数量是抓不到的
   （实测：注入 ratio=0.85，数量断言 ✓、几何断言 ✗）。
2. **`AXPress` 不需要前台，合成事件需要**。锁屏时（`IOConsoleLocked`）前台是
   `loginwindow`，任何 app 都无法成为 frontmost，CGEvent 会落到不存在的窗口。
   这类用例声明 `requires() { echo focus; }`，`gui.sh` 会跳过并 exit 2（环境
   问题），不当成产品失败。
3. **断言要打印出来**。`summary.json` 带 `assertions[]`，一次通过的运行也应该
   能回答"到底验证了什么"。

改 `gui.sh` 或驱动后，**用注入验证它还抓得住**（§0.3）：故意改坏一个被断言的
行为，确认对应断言变红且退出码是 1。

### `scripts/build-app.sh` 的 `nested herdr is disabled` 是噪音

输出里会出现：

```
error: nested herdr is disabled by default.
see configuration if you want to enable it.
```

它来自生成的 debug 启动器里的 `$(herdr)` 命令替换被求值，**不是构建失败**，
产物正常。判断成功的标志是末尾的 `==> Done: .../Kraal.app`。

---

## 2. 跑起来

### 看真实效果：`make run`

```bash
make run              # 构建 + 打包 + 启动，连你自己的 daemon
make run FOCUS=0      # 同上，但让窗口到前台（会抢焦点）
make socket-status    # 连的是哪个 socket
make logs             # 跟日志
make stop
```

### debug bundle 默认指向一个不存在的沙箱

`Scripts/build-app.sh` 生成的启动器默认强制：

| 变量 | 默认值 | 作用 |
|---|---|---|
| `KRAAL_HERDR_SOCKET` | `/tmp/kraal-mine/herdr-client.sock` | 通常是失效的旧 socket，连不上就显示连接面板 |
| `KRAAL_DEV_BACKGROUND` | `1` | 不抢焦点、不做常规 App |
| `KRAAL_HERDR_HOME` | `/tmp/kraal-mine/herdr-home` | 给 `herdr` 子进程一份空名册，避免改到真实 machines |

`make run` 就是替你把三个都覆盖掉。手动等价形式：

```bash
KRAAL_HERDR_SOCKET="$HOME/.config/herdr/herdr-client.sock" \
KRAAL_HERDR_HOME="$HOME" KRAAL_DEV_BACKGROUND=1 \
  build/Kraal.app/Contents/MacOS/KraalMac-bin
```

两个容易搞错的地方：

- **两套 socket 不能混**：`herdr-client.sock` 是 Kraal 的 bincode 协议；
  `herdr.sock` 是 CLI 的 JSON API（`$HERDR_SOCKET_PATH` 指向那个）。用错协议
  会得到 `EmptyResponse`。
- **启动 `KraalMac-bin`，不是 `KraalMac`**：后者是 bash 启动器，脚本当
  `CFBundleExecutable` 会让 `NSRunningApplication` 报 **`pid=-1`**。实测
  Finder/Safari 正常，只有它报 -1，`kraal-gui window` 因此找不到窗口。
  代价是启动器提供的沙箱默认值要由调用方自己传。

连真实 daemon 时 `KRAAL_HERDR_HOME="$HOME"` 是必须的，否则 Machines 面板是空的
（看不到 6 台远端机器）。

### 日志

```
~/Library/Logs/Kraal-<session>.log     # 开发会话（session 从 socket 路径派生）
~/Library/Logs/Kraal.log               # 无 KRAAL_DEV_SESSION 时
```

`KRAAL_LOG=0` 关闭；Debug 菜单可运行时切换。

### 脚本化触发一条真实命令

不要靠人点，也不要往产品代码里埋探针（`KRAAL_PROBE_*` 已于 P2 删除，见
`docs/AUTOMATION.md` §13 决策 2）。用外部驱动走真实界面：

```bash
./Scripts/gui.sh run split-right     # 起隔离 daemon → AXPress 真实窗口 → 断言 daemon
./Scripts/gui.sh run                 # 全部用例
```

**默认后端是 `vm`**（Tart `kraal-agent`），不是宿主。原因是硬性的：驱动真实
窗口会夺走指针和键盘，而那是你正在用来干活的桌面。`KRAAL_GUI_BACKEND=local`
只用于需要真 GPU 的视觉判断，且会拒绝任何「要前台」的用例，除非显式
`KRAAL_GUI_ALLOW_FOCUS=1`。

然后对着日志和 `herdr pane list` 双向确认——这条原则不变，只是手段换了。

---

## 3. 排查原则

细节见 `docs/DEBUGGING.md`（7 条，每条对应一次真实白跑）。摘要：

1. **样本要能区分对错**——空 shell 的"正确"和"空白"长得一样。
2. **A/B 回退能复现**才算定位。
3. **探针要测对对象**——先问"这个值是谁写的、应该多少"。
4. **删探针不用跨行正则**，用精确文本匹配；清理后看 `git diff --stat`。
5. **临时改动是完整动作**：加 → 验 → 还原 → 干净重启 → 再确认。
6. **自动化点击先激活窗口**，再谈坐标。
7. **没证据就说"没验证"**，不要用"逻辑上应该对"代替。

### 两条本仓库具体的经验

**带内报错。** endpoint 协议把拒绝写在响应体里
（`{"error":{"code":"endpoint_busy",...}}`），帧是完整的、JSON 合法、socket
不报错。任何"只 catch 异常"的代码都会把拒绝当成功。`call()` 现在
`throwIfErrorEnvelope` 并记录 `ok / FAILED / BUSY / skipped` 全路径——改动
请求层时不要把这些日志删掉，它们是唯一能看出"ok 但没发生"的东西。

**一条连接一个命令。** 同一 tick 发两个请求，后一个会被 `endpoint_busy`
拒绝。所以 focus 和它要影响的动作**不能并发**（`MacMenuBar.dispatch` 把
focus 放在 `perform` 之后）。新增命令时注意这一点。

**`No such module 'KraalTerminalView'` 是 IDE 误报，不是编译错误。** pi-lens 的
SourceKit-LSP 会报这个，但 `swift build` 零错误、`swift test` 全绿。

根因是两套工具链的 `.swiftmodule` 布局不同：

| 工具链 | 产物 | 形态 |
| --- | --- | --- |
| CLT | `.build/arm64-apple-macosx/debug/Modules/X.swiftmodule` | **单个文件** |
| Xcode | `.build/out/Products/Debug/X.swiftmodule/` | **目录**（内含 `arm64-apple-macos.swiftmodule`） |

`.build/debug` 是一个符号链接，指向哪一套取决于最后一次构建用的是哪个工具链。
SourceKit-LSP 跟随这个链接，遇到跨工具链的布局就会解析不到跨 target 的模块——
`KraalTerminalView` 恰好是最深的一环（它还依赖二进制 target `GhosttyTerminal`）。

**判断它是否真错误**，看这三点就够：

```bash
swift build 2>&1 | tail -2                              # Build complete!
swift package describe --type json | grep -A2 KraalMac   # 依赖图包含它
ls .build/out/Products/Debug/KraalTerminalView.swiftmodule  # 产物存在
```

三条都对就是误报，**不要花时间“修”它**。判断完直接在回复里说明即可。

---

## 4. 提交

风格：`type(scope): 中文描述`，与 `git log` 现有条目一致。

```
fix(context-menu): 右键弹菜单时一并消费配对的 mouseUp
feat(macos): 菜单/右键菜单对等、Machines 面板、液态玻璃 chrome
docs(env): 记录 Tart VM 作为验证环境及其限制
```

提交信息要写**证据**，不只是结论。好的例子是 `fa3496e`：三个根因各自附了
实测数字（`pane_id: wS:p1` 建到 `wT:t1`，`target_pane_id` 建到 `wS:t1`）。

提交前：

```bash
git diff --stat        # 行数变化是否符合预期（见 DEBUGGING.md §4）
git status --short     # 别把无关的未跟踪文件带进来
swift test             # 全绿
swiftlint --quiet Sources Tests
```

---

## 5. 文档分工

| 文件 | 写什么 |
|---|---|
| `README.md` | 是什么、怎么开始、致谢 |
| `docs/RUNNING.md` | **怎么跑起来**：上手顺序、命令、迁移到新机器 |
| `docs/ROADMAP.md` | 里程碑与完成状态 |
| `docs/DESIGN.md` | 协议与架构设计 |
| `docs/ENVIRONMENT.md` | **实测的环境事实**：版本、隔离方式、多机验证、Tart VM、TCC |
| `docs/AUTOMATION.md` | GUI 验证闭环：方案、实测数据、未验证项 |
| `docs/DEBUGGING.md` | **怎么验证一件事是真的**（排查教训） |
| `AGENTS.md`（本文件） | agent 的行为约定：跑什么、验证到什么程度算完 |

新发现的排查教训进 `DEBUGGING.md`；新发现的环境事实进 `ENVIRONMENT.md`；
新的操作步骤（装什么、跑什么、怎么迁移）进 `RUNNING.md`。
都写明**实测日期**和**未验证的部分**。
