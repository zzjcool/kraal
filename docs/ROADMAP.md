<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# 实施路线：macOS 优先

> 决策：2026-10-20 · 先做 macOS，基础功能跑通后再回到 iOS
> 更新：2026-10-20 · **M0–M8 完成；M7 鼠标、M9 打磨待收敛**

本文档是 [DESIGN.md](DESIGN.md) §10 实施计划的执行版本。
iOS 阶段计划保留在 DESIGN.md，进入时再细化。

---

## 0. 为什么先 macOS

| 维度 | macOS | iOS |
|---|---|---|
| 传输 | 本机 unix socket，**不需要 SSH** | 必须 SSH（iOS 没有 ControlMaster） |
| 调试 | 直接跑、直接看窗 | 模拟器/真机 + 签名 + 部署链路 |
| 阻塞项 | 无 | Xcode 内 Apple ID 登录才可真机 |
| 代码复用 | 协议层、渲染层、状态层 100% 共用 | 仅 UI 布局与传输层增补 |

---

## 1. 里程碑

### M0 · 协议内核 ✅

`Sources/KraalProtocol/`：`Bincode.swift`、`Frame.swift`、`Wire.swift`、
`Decoder.swift`、`Encoder.swift`、`Endpoint.swift`、`Surface.swift`、
`TerminalColor.swift`、`Snapshot.swift`。

**验收达成**：`swift test` 全绿；`Tests/KraalProtocolTests/Fixtures/surface_120x40.bin`
解出 4800 个 cell，文本与 `surface_120x40.txt` **逐行一致**（真实抓包，
不是自造数据）。

### M1 · 本地连接与握手 ✅

`Sources/KraalTransport/UnixSocket.swift`（POSIX + `SO_NOSIGPIPE`）、
`HerdrDiscovery.swift`（含 `XDG_CONFIG_HOME`、命名 session、`HERDR_*_SOCKET_PATH`）、
`SSHTransport.swift`、`Sources/KraalClient/EndpointConnection.swift`。

**验收达成**：`kraal` CLI 打印出 workspace / tab / pane / agent 列表与画面文本；
本机 daemon（0.9.3）与远端 daemon（0.9.4，含 15 个 agent、20 个 pane）都验证过。

### M2 · PaneSurface 解码 ✅

`Surface.swift` 的 patch 校验与文本投影，`SurfaceText` 提供按列切片。

**验收达成**：整屏文本与 fixture 一致；宽字符列对齐有单独测试。

### M3 · Ghostty 渲染 ✅

`Sources/KraalProtocol/SurfaceANSIRenderer.swift`（cell → VT 序列，全帧 + 行级增量）、
`Sources/KraalTerminalView/PaneTerminal.swift`（pane 裁剪、`InMemoryTerminalSession` 接线、焦点）。

**验收达成**：窗口里显示真实 daemon 的 pane，颜色/宽字符/光标正确，
键盘输入经 `TextCommit`/`Key` 语义事件回到 daemon。

> **路线修正**：原计划用第二条 `terminal attach` 通道拿 ANSI。实际改成复用
> endpoint 的权威 cell 网格，再编码成 ANSI 喂给 Ghostty。收益：
> 一条连接、无 takeover 竞争、渲染内容与桌面端同源。

### M4 · ANSI 一致性回归 ✅（形态变更）

调研脚本 `04_ansi_vs_surface.py` 的 `cols/rows` 不匹配问题已不再相关——
既然渲染输入就是权威 cell 网格，一致性由构造保证。改为在 Swift 侧做等价门禁：

- `surface_120x40.bin` → 文本逐行比对（真实抓包）
- cell → ANSI 往返：首帧完整、次帧只含变更行、颜色走 `38;2` / `48;5`

### M5 · 多 pane 布局 ✅

`PaneLayoutView.swift` 按 `innerRect` 比例摆放；分隔条可拖动并调用
`layout.set_split_ratio`。

**实测修正**：布局必须按真实 cell 尺寸摆放，不能用容器宽度拉伸 pane。
容器宽度和「列数 × cell 宽」差几个点时 Ghostty 会按较窄的网格重排，于是每行
都换行。现在 pane 用 `.frame` 精确到 cell 网格尺寸再 `.position` 居中；
网格尺寸与 pane 帧不一致时清屏重绘，避免错误宽度写下的行留在 scrollback 里。

### M6 · 侧边栏 + 标签栏 ✅

`SidebarView.swift`、`TabBarView.swift`、`StatusBarView.swift`。
agent 列表为空时回退为 pane 列表（纯 shell 环境下不显示空白侧栏）。

### M7 · 输入 ✅（键盘、鼠标）/ ⏳（滚轮精度）

- 键盘：`TerminalInputDecoder` 把 Ghostty 的字节翻译成语义事件，覆盖控制字符、
  方向键、F1–F20、xterm 修饰符、跨包拆分的 UTF-8 与转义序列、单个 Esc。
- 焦点：由 `TerminalViewState.requestFocus()` 接管，不拦截点击
  （拦截会让 Ghostty 拿不到第一响应者，键盘就永远进不去）。
- 鼠标：`MouseForwarder` 用 `NSEvent.addLocalMonitorForEvents` 观察（不消费）
  事件，按 pane 命中矩形换算成 cell 坐标，再按 daemon 的 `mouseReporting` /
  `sgrPixelMouse` 决定是否转发。实测 `cat -v` 能收到列号递增的 SGR 序列。
- 滚轮沿用同一路径（`scrollUp`/`scrollDown`），尚未针对大 scrollback 压测。

### M8 · 侧边栏配置引擎 ✅

`KraalSidebar`：TOML 解析器（真实 70 KB `config.toml` 5 ms 解析完）、
`ui.sidebar.{spaces,agents}.rows`、`rows_by_agent`、`row_gap`、
token 样式与 `rules`（`equals`/`contains`/`starts_with`/`gt`/`lt`，含 ASCII
`ignore_case`）。上限与 daemon 一致（16 行 × 16 token × 16 规则）。

### M9 · 打磨 ⏳

已做：健康检查、指数退避重连、窗口几何协商、窗口越界复位、
`~/Library/Logs/Kraal.log`、`⌘1..⌘9` 切 tab、`⌘K` 命令面板、`⌘B` 侧栏。

**兼容性修正**：0.9.1 这类 daemon 不会因为别的连接切 tab 而推新 snapshot。
切 tab / 切 workspace 后主动用 `client_shell.surface.set`（`false` → `true`）
要求重投影；没有 `surface_interest` 的 daemon 则重连。

待做：主题（`theme.custom.*`）、滚动性能、大 surface 压测。

---

## 2. iOS 阶段（延后）

进入条件：M7 的鼠标部分完成、M9 主要项收敛。届时：

- `libssh2-spm` 或 `swift-nio-ssh` 接 SSH exec `remote-client-bridge`
  （路线 B 不需要 streamlocal，所以两者都行）
- iPhone 单 pane + 切换器布局；iPad 真实分屏
- 软键盘 + 输入辅助栏；触摸手势映射
- 真机调试前置：Xcode 内登录 Apple ID（见 [ENVIRONMENT.md](ENVIRONMENT.md) §3）

协议层、侧边栏引擎、`AppStore` 已与平台无关，可整体复用。

> **工作量与阻塞项实测见 [IOS-PORT.md](IOS-PORT.md)（2026-10-27）。**
> 一句话结论：`KraalProtocol` 到 `KraalSidebar` 四个 target 加 3 处条件编译即可
> 编过 iOS；真正的缺口是 SSH 传输（`Process` 不可用）和约 4300 行 AppKit UI。
> 上面这份清单**没有算** SSH 凭据界面与 Machines 面板的替代方案，那两项是
> 产品级工作。

---

## 3. 工程约定

### 3.1 仓库结构

```text
Kraal/
├── Package.swift                 # SwiftPM 主 manifest
├── Scripts/
│   ├── build-app.sh              # 从 SwiftPM 产物组装 Kraal.app
│   └── verify.sh                 # build + test + lint 一次跑完
├── Sources/
│   ├── KraalProtocol/            # 零依赖，可 Linux CI
│   ├── KraalTransport/           # socket / SSH
│   ├── KraalClient/              # 连接状态机、帧循环、API 请求
│   ├── KraalSidebar/             # 侧边栏模型与 TOML
│   ├── KraalUI/                  # SwiftUI + AppStore
│   ├── KraalTerminalView/        # Ghostty 接线
│   ├── KraalCLI/                 # `kraal` 协议探针
│   └── KraalMac/                 # macOS app 入口
├── Tests/
├── Fixtures → Tests/KraalProtocolTests/Fixtures/   # 真实抓包
└── research/                     # Python 逆向脚本（保留参考）
```

### 3.2 构建

```bash
./Scripts/verify.sh              # 全量门禁
./Scripts/verify.sh --fast       # 跳过 .app 打包
./Scripts/build-app.sh release   # release 版 .app
```

本环境 pi 会话是 root，但 `swift build` 的产物需要 GUI 里的用户能读，
必要时用 `sudo -u zzj`。`.build/` 与 `build/` 均已 gitignore。

### 3.3 依赖

| 依赖 | 用途 | 阶段 |
| --- | --- | --- |
| `libghostty-spm` `1.6.20261003` | 终端渲染 | M3 起 |
| `libssh2-spm` | iOS SSH 传输 | iOS 阶段 |

`KraalProtocol` / `KraalTransport` / `KraalClient` / `KraalSidebar` 均零第三方依赖，
所以 `swift test` 不必下载 51 MB 的 Ghostty xcframework。

### 3.4 代码风格

SwiftLint 配置在 `.swiftlint.yml`。协议类型刻意沿用上游字段形状
（bincode 按位置编码，字段名不参与 wire），但为了通过默认命名规则，
短名已改为描述性名称并在 `Wire.swift` 顶部注明与 `wire.rs` 的对应关系。

### 3.5 许可证

Apache-2.0，新文件需带 SPDX 头（见 [CONTRIBUTING.md](../CONTRIBUTING.md)）。
协议类型衍生自 herdr / herdr-gpui（Apache-2.0），归属见 [NOTICE](../NOTICE)。

---

## 4. 与 DESIGN.md 的对应关系

| DESIGN.md | 本路线 | 状态 |
| --- | --- | --- |
| M0 协议内核 | M0 | ✅ |
| M1 连接与握手 | M1 | ✅ |
| M2 Ghostty 渲染 | M3 | ✅（输入改为复用 cell 网格） |
| M3 布局与侧边栏 | M5 + M6 | ✅ |
| M4 侧边栏配置引擎 | M8 | ✅ |
| M5 交互 | M7 | 键盘 ✅ / 鼠标 ⏳ |
| M6 iOS 适配 | iOS 阶段 | ⏳ |
| M7 打磨 | M9 | 部分 |

新增的 **M4（一致性回归）** 不再是「验证核心假设」——假设已经变成构造性质，
门禁改为守护解码正确性与增量渲染。

---

## 5. 已知待验证 / 待办

| # | 项 | 现状 |
|---|---|---|
| 1 | 分屏拖拽在真实多 split 上的手感 | 拖动条已实现，单 split 未实测 |
| 2 | 鼠标合成（点击/右键/滚轮/`sgr_pixel_mouse`） | 编码已实现，UI 未接 |
| 3 | 三个可选 codec（reuse/delta/scroll）的收益 | 仍为关闭；开启可再省带宽 |
| 4 | 超大 surface（>500 列）性能 | 未压测 |
| 5 | 系统输入法（IME）合成按键 | 拼音候选阶段会把合成键当文本；需要在 `TextCommit` 路径上加 marked-text 判断 |

### 已归档的实验分支（2026-10-29）

`exp/hold-until-adopted`（14 个提交）试过「帧挂起到引擎采纳、不裁剪」这条路，为了让
拖动时几何不追内容。结论：**它能消掉 mismatch / surface 重建，但消不掉抖动**——把
引擎 drawable 冻住之后用户手动拖仍然抖，这条负结果直接指向了真正的机制（合成器把
上一帧按新矩形拉一遍，见 `docs/DESIGN.md` §4.4.1），也就是现在「拖动期间自绘」的
方案（`CellPainterPolicy`）。

分支已删除，提交留在**本地 tag** `archive/exp-hold-until-adopted`（未推送，需要时
`git log archive/exp-hold-until-adopted`）。里面还有两样没有进 main 的东西，留个索引：

- `069fbfb` 的擦屏修复（`lastPaintedWidth` + `widthMoved(fromWidth:to:)`，
  用例 `aParkThatEndsDoesNotErase`）：独立缺陷，只在「挂起模型」成立时才会触发；
  现在的渲染路径下没有复现过，所以没有摘出来单独合。
- 21 个 demo 模式 + `Scripts/demo-jitter.sh`：抖动测量仪，用离屏 demo 窗口量静态带
  闪烁。抖动现在有真门禁了（`gui.sh run drag-jitter`，见 `docs/AUTOMATION.md` §15），
  这套 demo 仪器不再需要。
