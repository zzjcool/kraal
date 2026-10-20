# Kraal

原生 Swift 的 [Herdr](https://herdr.dev) 客户端，为 iOS / iPadOS / macOS 共用一套代码。

> **命名**：`Kraal` 是南非荷兰语的「畜栏」——给畜群一个围起来的落脚处，正如这个 app 给 Herdr 的 agent 群一个随身的窗口。
>
> **商标**：Herdr 是 Herdr, Inc. 的商标。Kraal 是独立的第三方客户端，
> 与 Herdr, Inc. 无关联，未获其授权或背书。
>
> **状态：设计阶段。** 本仓库当前包含完整的可行性验证、协议逆向研究与技术设计文档。

## 为什么再做一版

现有的 Herdr 移动客户端几乎全部走同一条路线：通过 SSH 调用 `herdr agent list` 之类的 CLI 命令，解析 JSON，然后把 `pane.read` 返回的 ANSI 文本自己重绘成"终端"。这条路有三个天然上限：

1. **终端是重绘的**——光标位置、宽字符、emoji、box drawing、alt-screen TUI 都会出偏差
2. **一条连接一个请求**——每次操作新开一次 SSH
3. **拿不到几何信息**——没有 split 布局、没有鼠标区域、没有 popup

Kraal 走另一条路：直接用 Herdr 桌面客户端（GPUI 版）使用的 **endpoint 协议**，拿到结构化的 cell 网格和分屏几何，然后把 pane 内容交给 **Ghostty** 自己的渲染器。

## 核心发现

调研期间对 herdr 0.9.4（本机）/ 0.9.1（远端）做了实测：

| 指标 | 结果 |
|---|---|
| 握手 → 侧边栏数据（snapshot） | 22 ms |
| 握手 → 首个完整画面（PaneSurface） | 67 ms 本地 / 224 ms 远程 SSH |
| 完整画面大小（120×40） | 73 KB |
| 增量 patch | **66 B** |
| ANSI 帧（单 pane 60×40） | 2.7 KB |
| **ANSI 与权威 cell 网格一致性** | **36/36 行逐字节一致** |

最后一行是整个方案的地基：herdr 输出的 ANSI 是标准 VT 序列，喂给任何正确的终端模拟器都能得到与 herdr 自己渲染完全一致的结果。所以我们不需要自己实现终端，只要接线到 Ghostty。

## 架构

```
┌──────────────────────────────────────────────────────┐
│  1 个 SSH session（libssh2）                          │
│  ├─ Channel A: herdr remote-client-bridge             │
│  │   ├─ shell.snapshot.v1  → 侧边栏 / 标签栏数据       │
│  │   ├─ PaneSurface        → panes[].innerRect 布局    │
│  │   └─ EndpointRequest    → tab/pane/workspace 管理   │
│  ├─ Channel B: terminal attach <pane1> → ANSI          │
│  ├─ Channel C: terminal attach <pane2> → ANSI          │
│  └─ ...                                                │
└──────────────────────────────────────────────────────┘

渲染：
  侧边栏 / 标签栏  →  SwiftUI 原生（数据驱动，兼容 config.toml）
  pane 内容       →  Ghostty InMemoryTerminalSession（Metal）
  分屏布局        →  SwiftUI 按 innerRect 摆
```

## 文档

- **[技术设计文档](docs/DESIGN.md)** —— 完整设计：连接层、协议类型、渲染、侧边栏引擎、交互、实施计划
- **[可行性研究（修订版）](docs/feasibility-revised.md)** —— 路线对比与关键实测
- **[竞品调研](docs/feasibility.md)** —— 现有 Herdr 客户端现状

## 验证脚本

`research/` 下是调研期间使用的协议探测脚本（Python）。它们能：

- 直连 `herdr-client.sock`，完成 `endpoint.hello.v1` 握手
- 解码 `shell.snapshot.v1`（侧边栏数据）与 `PaneSurface`（cell 网格）
- 用标准 VT 模拟器（pyte）解析 ANSI 帧并与 herdr 权威表面逐行比对
- 通过 SSH 直连远端 herdr 的 `remote-client-bridge`

```bash
python3 -m venv .venv && .venv/bin/pip install pyte
.venv/bin/python research/01_handshake.py        # 握手 + welcome
.venv/bin/python research/02_decode_snapshot.py  # 侧边栏数据
.venv/bin/python research/03_decode_surface.py   # cell 网格
.venv/bin/python research/04_ansi_vs_surface.py  # ANSI 一致性校验
.venv/bin/python research/05_remote_ssh.py       # 远程 SSH
```

## 许可证

本仓库以 **Apache License, Version 2.0** 发布，全文见 [LICENSE](LICENSE)。

协议类型的结构定义衍生自 [herdrdev/herdr](https://github.com/herdrdev/herdr)（Apache-2.0）与 [penso/herdr-gpui](https://github.com/penso/herdr-gpui)（Apache-2.0）。归属声明见 [NOTICE](NOTICE)。贡献规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

Apache License 2.0 不授予商标权。本项目与 Herdr 官方无关，未获其背书。
