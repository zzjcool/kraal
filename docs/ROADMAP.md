<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# 实施路线：从 Herdr 1 客户端切到 herdr-core

> 决策：2026-11-02 · 目标与架构见 [HERDR2.md](HERDR2.md)
>
> 旧路线（Herdr 1 daemon / bincode endpoint / 服务端布局）的里程碑与完成记录
> 已作废：代码保留到 M3 清理，文档在 `docs/archive/`。

---

## 0. 一句话

服务端只认 `hc`；布局归客户端；终端字节直接进 Ghostty；行为对齐官方
`herdr-app`。我们保留 Swift + Ghostty + 不做 JS mods。

---

## 1. 里程碑

| 里程碑 | 交付 | 判据（必须能跑） |
|---|---|---|
| **M0 协议与渲染** | JSON-RPC 明文/帧、hello 门禁、attach 原始字节、CREDIT、RESIZE/FOCUS、重连 | 真实终端在 Kraal 里显示；改窗口大小后 `hc get` 的 cols/rows 跟着变 |
| **M1 布局与文档** | space/tab/pane 树、共享 `herdr-app` 文档读写、私有 view 状态 | 官方 app 建的布局 Kraal 原样显示；Kraal 的 split 官方 app 能看到；未知节点不丢 |
| **M2 客户端对齐** | 原生 chrome、命令面/按键/面板/设置、OSC 7501 侧栏、Ghostty 终端 UX | HERDR2.md §6 的表格逐项过，gui.sh 有对应用例 |
| **M3 交付与清理** | `kraal` 控制 CLI、gui.sh 重写、性能基线、旧代码/文档清理、iOS | `verify.sh` 全绿；注入缺陷时 gui.sh 会红；iOS 连远端 core 可显示输入 |

---

## 2. 工程约定（迁移期）

- **不双栈。** 不写 Herdr 1 兼容分支；旧实现要么还在用（UI 外壳），要么删除。
- **协议事实以运行中的 `hc` 为准。** 文档滞后过：`hc schema` / `hc --version` /
  实际 JSON 回复高于任何 md。
- **实验必须隔离。** `HC_SESSION` + 临时 `XDG_STATE_HOME`/`XDG_CONFIG_HOME`；
  绝不碰本机真实 core（它可能正跑着别人的 agent）。
- **UI 改动仍要端到端证据。** 断言对象从 Herdr 1 daemon 换成
  `hc get/list/read --json`；`swift test` 绿不算修好。
- **删除也是交付。** 每删一层旧实现，先在 issue 里写清「删了什么、为什么不再需要」，
  再动 `git rm`；`git diff --stat` 要能对上预期。

---

## 3. 当前状态

目标已冻结（[HERDR2.md](HERDR2.md)），issue 按 M0–M3 重建；旧 issue（#1–#219）
全部关闭，理由写在各条评论里。

- **#223 已完成**：`KraalHC`（JSON-RPC、帧、路径、hello 门禁、重连）。
  46 个测试 + 真实 `hc` 冒烟。
- **#224 已完成**：`HcAttachStream` / `HcTerminalSession`，原始字节进 Ghostty；
  M0 窗口 `make run-hc`（终端列表 + 一个 pane）。实测窗口的网格
  98×38 已写回核心，截图可见重放内容；真实 core 的 headless 测试同时验证
  输入回显与 RESIZE。
- **#225 已完成**：`HcStateStore` + `HcEventSubscription`（事件通道按行解码）；
  M0 窗口改为事件驱动（快照 + 归约，`missed` 换快照，heartbeat 缺失显示失联）。
  真实事件流录制在 `Tests/KraalHCTests/Fixtures/events.ndjson`。
- **#226 已完成**：`machine.list` 轮询（core 无机器事件）、侧栏按机器分组、
  `temporary` 隐藏、add/rename/rm/reconnect，`needs_login`/`needs_update` 开
  真实终端跑 `hc machine login|update`。直连 ssh → #242，SSH 专项 fixture → #243。
- **#227 文档层已完成**：`doc.get/set` 的 CAS、conflict 后重读并最新胜出、
  `herdr-app` 原始 JSON 编辑（split 只改 `children`/`size`，未知节点/外观字段
  原样保留）、1 MiB 本地检查、`doc` 事件触发重读。M0 窗口启动时读一次并打日志。
- **#228 模型层已完成**：`KraalModel`（纯 Swift，无 AppKit/Ghostty）/ `KraalOperations`
  / `KraalView`：space/tab/pane 值与规则、命名（worktree 优先、跳 mod）、焦点历史
  上限 32、关 pane 回退、split 同轴复用/跨轴包容器、close 权重归还、
  swap/move、zoom/settle（next/prev 跳过 settled）、recent 上限 20、机器前缀
  限定与 `view.json`。29 个模型测试 + 8 个树操作测试；官方布局 fixture
  加载→编辑→投影不丢未知字段。文档读写仍由 #227 的 `HcDocumentSync` 负责。
- **#229 终端归属已完成**：`terminal.run/get/kill/label/keep/rm` 客户端 API；
  `KraalModel.adopt` 按 `herdr.space`/`herdr.tab` 安放终端；未标标签的 worker
  不进布局/侧栏。新 tab/split/close 由窗口发起：`terminal.run` 写标签，
  客户端落文档，关闭走 `terminal.kill`（级联未标标签的子终端；组关闭先确认）。
  `keep:true` 的终端丢程序后由 core 换新 shell，窗口自动重新 attach；`park`
  清标签把 pane 退回 worker。真实 core 的端到端测试 `LiveHcOwnershipTests`
  覆盖建 tab、split、关闭、外部收养、keep 重启与文档持久化。
- **下一步**：#230（agents 侧栏 / OSC 7501 状态与通知），再做 #231 的命令面与 chrome。
- `KRAAL_HC=1` 与旧入口是两个独立窗口；旧 cell 链路在 #234 随旧窗口一起删除。
