<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# AGENTS.md

给在这个仓库里工作的 AI agent / 协作者的操作约定。

`docs/` 下是**知识**（协议怎么工作、环境什么版本），这份是**行为**（该跑什么、
不该做什么、验证到什么程度算完）。两者冲突时以 `docs/` 的实测记录为准。

---

## 0. 三条硬规则

### 0.1 不留探索区

**不要**用真实 herdr 会话做实验：不在这台机器上正在使用的 workspace 里 split /
close / 发键盘输入 / 改布局。开发与自测必须在隔离环境里做
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

`Scripts/verify.sh` 直接调 `swift`，在本机默认工具链下会因为上面的原因失败。
要么先 `export DEVELOPER_DIR`，要么逐条手动跑。

### 命令清单

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

/usr/bin/swift build                     # 全部 target
/usr/bin/swift test                      # 173 个测试，28 个套件
export PATH="$HOME/.pi-lens/bin:$PATH"   # swiftlint 不在默认 PATH
swiftlint --quiet Sources Tests          # 必须零违规
./Scripts/build-app.sh                   # 打包 build/Kraal.app（ad-hoc 签名）
```

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

### debug bundle 默认指向一个不存在的沙箱

`Scripts/build-app.sh` 生成的启动器会强制：

| 变量 | 默认值 | 作用 |
|---|---|---|
| `KRAAL_HERDR_SOCKET` | `/tmp/kraal-mine/herdr-client.sock` | 不存在时连不上，显示连接面板 |
| `KRAAL_DEV_BACKGROUND` | `1` | 不抢焦点、不做常规 App |
| `KRAAL_HERDR_HOME` | `/tmp/kraal-mine/herdr-home` | 给 `herdr` 子进程一份空名册，避免改到真实 machines |

**连真实 daemon**（也就是用户实际在用的那个）时：

```bash
open --env KRAAL_HERDR_SOCKET="$HOME/.config/herdr/herdr-client.sock" \
     --env KRAAL_HERDR_HOME="$HOME" \
     --env KRAAL_DEV_BACKGROUND=0 \
     build/Kraal.app
```

加上 `KRAAL_HERDR_HOME="$HOME"` 才能真正看到 3 台远端机器——否则 Machines
面板是空的。副作用：`KRAAL_DEV_BACKGROUND=0` 会真的抢焦点和键盘。

### 日志

```
~/Library/Logs/Kraal-<session>.log     # 开发会话（session 从 socket 路径派生）
~/Library/Logs/Kraal.log               # 无 KRAAL_DEV_SESSION 时
```

`KRAAL_LOG=0` 关闭；Debug 菜单可运行时切换。

### 脚本化触发一条真实命令

不要靠人点。`KRAAL_PROBE_COMMAND` 走**与鼠标点击完全相同**的
`runCommand → dispatch → perform` 路径，只跳过鼠标：

```bash
KRAAL_PROBE_COMMAND=split_right KRAAL_PROBE_PANE=wS:p5 \
  open --env KRAAL_HERDR_SOCKET=... --env KRAAL_PROBE_COMMAND=split_right ...
```

然后对着日志和 `herdr pane list` 双向确认。

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
| `docs/ROADMAP.md` | 里程碑与完成状态 |
| `docs/DESIGN.md` | 协议与架构设计 |
| `docs/ENVIRONMENT.md` | **实测**的环境事实：版本、隔离方式、多机验证、Tart VM |
| `docs/DEBUGGING.md` | **怎么验证一件事是真的**（排查教训） |
| `AGENTS.md`（本文件） | agent 的操作约定：跑什么命令、验证到什么程度 |

新发现的排查教训进 `DEBUGGING.md`；新发现的环境事实进 `ENVIRONMENT.md`。
两处都写明**实测日期**和**未验证的部分**。
