# Kraal

原生 Swift 的 [Herdr](https://herdr.dev) 客户端，为 macOS / iOS / iPadOS 共用一套代码。

> **命名**：`Kraal` 是南非荷兰语的「畜栏」——给畜群一个围起来的落脚处，
> 正如这个 app 给 Herdr 的 agent 群一个随身的窗口。
>
> **商标**：Herdr 是 Herdr, Inc. 的商标。Kraal 是独立第三方客户端，
> 与 Herdr, Inc. 无关联，未获其授权或背书。
>
> **状态：macOS 版可用。** 连接、快照、分屏渲染、键盘输入、侧边栏布局引擎
> 都已跑通并接入真实 daemon。详见下方「已完成」与 [docs/ROADMAP.md](docs/ROADMAP.md)。

---

## 它是什么

现有 Herdr 客户端几乎都走 SSH + CLI + ANSI 重绘。Kraal 走另一条路：
直接用 Herdr 桌面端（GPUI 版）使用的 **endpoint 协议**，拿到结构化的 cell
网格和分屏几何，然后把 pane 内容交给 **Ghostty** 渲染。

```
┌──────────────────────────────────────────────────────────────┐
│  一条连接（本机 unix socket，或 SSH exec remote-client-bridge）│
│  ├─ endpoint.hello.v1  → welcome（能力协商）                  │
│  ├─ shell.snapshot.v1  → 侧边栏 / 标签栏数据                   │
│  ├─ PaneSurface        → panes[].innerRect 布局 + 整屏 cell    │
│  ├─ PaneSurfacePatch   → 增量（实测 66 B）                     │
│  └─ ClientShellPaneInput ← 键盘 / 鼠标语义事件                  │
└──────────────────────────────────────────────────────────────┘
        │
        ├─ 侧边栏 / 标签栏  →  SwiftUI 原生（config.toml 驱动）
        └─ pane 内容       →  Ghostty InMemoryTerminalSession（Metal）
```

**关键点：一条连接。** 不开 `terminal attach` 通道，因此不需要每 pane 一次
握手，也不会和桌面端抢 `takeover`。pane 内容来自 endpoint 的权威 cell 网格，
由 Kraal 重新编码成 VT 序列喂给 Ghostty —— 调研阶段实测「herdr ANSI 与权威
surface 逐行一致 36/36」，所以渲染结果与桌面端一致。

---

## 已完成

| 能力 | 状态 | 说明 |
|---|---|---|
| endpoint 协议内核 | ✅ | bincode varint、u32 帧、21+21 消息、surface/patch 校验 |
| 本机连接 | ✅ | `~/.config/herdr/herdr-client.sock`，含 `XDG_CONFIG_HOME` / 命名 session |
| SSH 连接 | ✅ | exec `remote-client-bridge`，含 `herdr-remote-output-ready:1` 握手 |
| 握手与兼容性 | ✅ | generation / codec / capability 逐项校验，拒绝时给人类可读原因 |
| 快照解码 | ✅ | workspace / tab / pane / agent / 自定义命令 |
| 分屏渲染 | ✅ | 按 `innerRect` 摆 Ghostty 视图，N 个 pane |
| 键盘输入 | ✅ | 字节 → 语义事件（`TextCommit` / `Key` / CSI 序列） |
| 侧边栏布局引擎 | ✅ | 解析 `config.toml` 的 `ui.sidebar.*`，含 token / 样式 / 条件规则 |
| 命令面板 | ✅ | `snapshot.commands` + 内置动作，`command.invoke` 执行 |
| 健康检查与重连 | ✅ | 5 s 静默 ping、10 s 无 pong 判死、指数退避（上限 30 s） |
| 窗口几何协商 | ✅ | 按窗口实际像素换算 cell 网格并重新握手 |
| 鼠标合成 | ⏳ | 协议编码已就绪（`ClientPaneInputEvent.mouse`），UI 手势待接 |
| 分屏拖拽 | ⏳ | 拖动条已实现并调用 `layout.set_split_ratio`，需要在真实分屏上验证 |
| iOS 版本 | ⏳ | 协议层与侧边栏引擎已复用就绪，见 ROADMAP |

---

## 快速开始

```bash
# 构建、测试、lint 一次跑完
./Scripts/verify.sh

# 打包成真正的 .app（ad-hoc 签名）并启动
./Scripts/build-app.sh
open build/Kraal.app
```

Kraal 启动时会自动连本机。没连上（Herdr 没跑）会显示连接面板，
也可以直接连远端：

```bash
# 命令行探针：不启动 UI 也能验证一条链路
swift build --product kraal
./.build/out/Products/Debug/kraal                       # 本机，打印快照 + 前 12 行画面
./.build/out/Products/Debug/kraal --ssh my-host screenshot
./.build/out/Products/Debug/kraal --ssh my-host call --method tab.create --param label=logs
```

### 在别的 Herdr 实例上开发

开发和自测不要动正在用的那个 Herdr。用独立容器起一个：

```bash
ssh devcloud 'docker run -d --name kraal-herdr \
  -v /tmp/kraal-herdr:/root/.config/herdr pi-herdr-sandbox:latest bash -lc "herdr server"'

# 把它的 unix socket 映射到本机，然后
./.build/out/Products/Debug/kraal --socket /tmp/kraal-dev/herdr-client.sock
```

---

## 仓库结构

```
Sources/
├── KraalProtocol/      bincode、帧、wire 类型、surface 校验、cell→ANSI、输入解码
├── KraalTransport/     POSIX unix socket、SSH 子进程、socket 路径发现
├── KraalClient/        握手、帧循环、健康检查、API 请求、协议流抽象
├── KraalSidebar/       config.toml 解析、布局规格、token 解析、样式规则
├── KraalUI/            AppStore、侧边栏、标签栏、分屏布局、命令面板、连接面板
├── KraalTerminalView/  Ghostty 接线（pane 裁剪、焦点、几何协商）
├── KraalCLI/           `kraal` 命令行探针
└── KraalMac/           macOS app 入口 + .app 打包
Tests/
├── KraalProtocolTests/ 真实抓包 fixture 驱动的协议回归
└── KraalClientTests/   TOML / 侧边栏规格
Fixtures 在 Tests/KraalProtocolTests/Fixtures/
```

`KraalProtocol` 零第三方依赖，可以在任何平台 `swift test`。只有
`KraalTerminalView` 依赖 Ghostty xcframework。

---

## 验证

```bash
swift test      # 60 个测试
```

真正重要的是这几条：

- **`surface_120x40.bin`（真实抓包）能解出 4800 个 cell，文本与参考逐行一致**
  —— 手写解码器与 Rust 编码器逐字节对得上。
- **cell 网格 → ANSI 的重编码**：首帧完整、次帧只发变更行、颜色走非 ARGB 编码。
- **surface patch 原子性**：revision 缺口 / boot_id 不符 / 行列越界一律拒绝，
  且拒绝后帧内容不变。
- **输入解码**：控制字符、CSI/SS3 方向键、xterm 修饰符、跨包拆分的 UTF-8 与
  转义序列、单个 Esc、坏字节不卡死。

---

## 文档

- **[实施路线](docs/ROADMAP.md)** —— 里程碑与工程约定（含已完成/待办对照）
- **[开发环境](docs/ENVIRONMENT.md)** —— 本机基线、依赖版本、签名与已知坑
- **[技术设计文档](docs/DESIGN.md)** —— 完整设计：连接层、协议类型、渲染、侧边栏引擎
- **[可行性研究（修订版）](docs/feasibility-revised.md)** —— 路线对比与关键实测

`research/` 下保留调研期用的 Python 协议探测脚本（已完成使命，作为交叉参考）。

---

## 许可证

以 **Apache License, Version 2.0** 发布，全文见 [LICENSE](LICENSE)。

协议类型的结构定义衍生自 [herdrdev/herdr](https://github.com/herdrdev/herdr)
与 [penso/herdr-gpui](https://github.com/penso/herdr-gpui)（均为 Apache-2.0）。
归属声明见 [NOTICE](NOTICE)；贡献规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

Apache License 2.0 不授予商标权。
