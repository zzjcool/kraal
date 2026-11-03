<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# AGENTS.md

给在这个仓库里工作的 AI agent / 协作者的操作约定。

`docs/` 是知识（协议、环境、怎么验证），这份是**行为**（该跑什么、不该做什么、
验证到什么程度算完）。冲突时以 `docs/` 的实测记录为准。

## 0. 三条硬规则

### 0.1 不留探索区

开发与自测必须在隔离环境里做：独立 `HC_SESSION` + 临时
`XDG_STATE_HOME` / `XDG_CONFIG_HOME`，或 Tart VM。**不要**在正在使用的 core
上 split / close / 发键盘 / 改布局；也不要驱动真实桌面窗口。

`KRAAL_DEV_BACKGROUND=1` 的 debug app 不抢焦点、不进 Dock；需要真实窗口时用
VM（见 `docs/AUTOMATION.md`）。

### 0.2 UI 改动必须端到端验证

`swift test` 全绿只说明请求体/纯函数对。用户报「点了没反应」时，测试通过和
修好没有关系。标准是**core 侧状态变了**：

```bash
kraal ls
# 触发 UI 命令
kraal ls           # 集合/内容必须变
```

不是断言「我们发出的字典」，也不是只看日志里的 `call: ok`。

### 0.3 说「修好了」之前，先证明它曾经坏

先 A/B 复现：旧行为能红，改完能绿。不能复现就写「未验证」，不要用
「逻辑上应该对」代替证据。细节见 `docs/DEBUGGING.md`。

## 1. 工具链与验证

**必须用 Xcode 工具链。** `/usr/bin/swift` 默认指向 CLT，`swift test` 会报
`no such module 'XCTest'`。只对当前 shell 生效：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

命令：

```bash
/usr/bin/swift build
/usr/bin/swift test
export PATH="$HOME/.pi-lens/bin:$PATH"
swiftlint --quiet Sources Tests          # 必须 0
for f in Scripts/*.sh; do shellcheck -S warning "$f"; done
./Scripts/build-app.sh                   # build/Kraal.app

./Scripts/verify.sh                      # 全部门禁
./Scripts/verify.sh --fast               # 跳过打包
```

`verify.sh` 当前门禁：`swift build` → `swift test` → `swiftlint` →
`shellcheck` → `build-app.sh`。

`Scripts/gui.sh` 是三层 GUI 门禁（`client` / `core` / `pixels`）：默认 Tart VM
`kraal-agent`，`local` 必须 `KRAAL_GUI_ALLOW_HOST=1`。UI 改动先跑
`./Scripts/gui.sh run`（或 `verify`），门禁没覆盖的部分按 `docs/AUTOMATION.md`
的 VM 手工流程留证据。

### 已知误报

`No such module 'KraalHCTerminal'` 可能来自 pi-lens / SourceKit-LSP 的工具链
布局不一致，不是编译错误。判断：

```bash
swift build 2>&1 | tail -2
swift package describe --type json | grep -A2 KraalMac
```

`Build complete!` 且依赖图正确就是误报，不要花时间「修」。

## 2. 跑起来

```bash
hc server status          # core 必须 running
make run FOCUS=0          # 构建 + 打包 + 前台窗口
make run                  # 后台，不抢键鼠
make stop
make logs
```

`make run` 使用 `/tmp/kraal-mine/control.sock`，可用 `CONTROL_SOCKET=...`
覆盖。debug 包的 `KraalMac` 是 bash 启动器，**真正的可执行文件是
`KraalMac-bin`**；脚本当 `CFBundleExecutable` 会让 `NSRunningApplication`
报 `pid=-1`。

隔离 core：

```bash
HC_SESSION=qa XDG_STATE_HOME=/tmp/kraal-qa/state \
XDG_CONFIG_HOME=/tmp/kraal-qa/config hc server start
```

## 3. 架构边界

- `KraalSocket`：Unix socket / listener，无业务。
- `KraalHC`：JSON-RPC、framed streams、hello、events、doc、machine、control；
  传输层 `HcByteLink`，本机 socket 与 `HcSSHLink` 共用握手。
- `KraalModel`：space/tab/pane 树、命名、focus、zoom；不依赖 UI。
- `KraalActions`：69 条动作目录、参数校验、keys.json。
- `KraalHCTerminal`：Ghostty 接线 + SwiftUI chrome + workspace model。
- `KraalSupport`：`KraalLog`、`DevSession`，Foundation only。
- `KraalCLI`：`kraal ls/status/do/commands/shot`。
- `KraalMac`：app 入口；只依赖 `KraalHC`、`KraalHCTerminal`、`KraalSupport`。

约束：

- 客户端不自己维护 SSH 隧道；远端默认只用 `hc machine.*`。
  `KRAAL_HC_SSH` 是例外：直接 `ssh -T host hc connect`，只把字节管道接进同一个
  `HcConnection`，不要在这条路径里另造协议。
- 共享文档 `doc name="herdr-app"`：只改自己拥有的子树，未知字段原样透传；
  CAS 冲突后最新胜出。
- focus / zoom / settled / recent / active 只进 `view.json`，不进共享文档。
- 终端 UX 尽量交给 Ghostty；不要自己拼 bracketed paste、滚动缓冲或
  cell→ANSI 重编码。
- 控制面一行 JSON、一连接一命令；窗口是唯一写入者；socket 权限 0600。
- 阻塞式握手不能跑在 Swift 协作线程池上；测试用独立 Thread。

## 4. 测试约定

- 测试 socket 路径必须在 `/tmp` 下（`sun_path` 103 字节）。
- live HC 测试默认跳过，设 `KRAAL_LIVE_HC_TESTS=1` 才跑。
- Swift Testing：`#expect` 不能包 mutating 调用，先提取到 `let`。
- 动作表数量断言在 `Tests/KraalActionsTests/KraalActionTests.swift`；增删动作要同步。
- 设置反序列化逐字段 `decodeIfPresent`，保持向前兼容。

## 5. 提交

风格：`type(scope): 中文描述`。

```
fix(control): 无窗口时 kraal ls 返回 exit 2
feat(terminal): 右键菜单复用 performAction
refactor(hc): 删除 Herdr 1 客户端栈
```

提交信息写证据：失败现象 + 根因 + 实测数字 + 验证方式。

交付一律走 PR，不直接推 `main`：

```bash
git checkout main && git fetch origin && git pull --ff-only origin main
git checkout -b fix/<scope>
# 改动、验证
git add -A
git commit -F /tmp/commit-msg
git push -u origin fix/<scope>
gh pr create --base main --fill
```

推之前必须 `git fetch`；合并后要在**合并后的树**上重跑门禁。

## 6. 文档分工

| 文件 | 写什么 |
|---|---|
| `README.md` | 是什么、怎么开始、控制面、目录 |
| `docs/HERDR2.md` | HC 架构、硬性决策、已删除的旧实现 |
| `docs/ROADMAP.md` | 剩余工作与判据 |
| `docs/RUNNING.md` | 上手、make、隔离 core、VM |
| `docs/AUTOMATION.md` | VM 里怎么取 UI 证据 |
| `docs/ENVIRONMENT.md` | 版本、Tart、TCC、路径 |
| `docs/DEBUGGING.md` | 怎么证明一件事是真的 |
| `docs/PERFORMANCE.md` | 测量原则（旧基线作废） |
| `docs/archive/` | Herdr 1 历史，只读 |

新发现的排查教训进 `DEBUGGING.md`；环境事实进 `ENVIRONMENT.md`；操作步骤进
`RUNNING.md`。写实测日期和未验证部分。
