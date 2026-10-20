<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# 实施路线：macOS 优先

> 决策：2026-10-20 · 先做 macOS，基础功能跑通后再回到 iOS
>
> 本文档是 [DESIGN.md](DESIGN.md) §10 实施计划的**执行版本**，只覆盖 macOS 阶段。
> iOS 阶段的计划保留在 DESIGN.md，进入时再细化。

---

## 0. 为什么先 macOS

| 维度 | macOS | iOS |
|---|---|---|
| 传输 | 本机 unix socket，**不需要 SSH** | 必须 SSH（iOS 没有 ControlMaster，每次完整认证） |
| 调试 | 直接跑、直接看窗、热重载成本低 | 模拟器/真机 + 签名 + 部署链路 |
| 阻塞项 | 无 | Xcode 内 Apple ID 登录才可真机 |
| 代码复用 | 协议层、渲染层、状态层 100% 共用 | 仅 UI 布局与传输层增补 |

上一轮环境验证已确认 macOS 与 iOS 两侧的 SwiftPM 依赖都能编译，因此
**这不是"只能在 macOS 上做"的妥协，而是把最难的两件事（协议 + 渲染）
在不付 iOS 调试成本的前提下先解掉**。

---

## 1. 里程碑

### M0 · 协议内核（当前起点）

纯 Swift，零 UI 依赖。

| 文件 | 内容 |
| --- | --- |
| `Sources/KraalProtocol/Bincode.swift` | bincode 2 "standard" varint 读写 |
| `Sources/KraalProtocol/Frame.swift` | u32 LE 长度帧编解码 |
| `Sources/KraalProtocol/Wire.swift` | 21 个 `ClientMessage` + 21 个 `ServerMessage` 及嵌套类型 |
| `Sources/KraalProtocol/Endpoint.swift` | `endpoint.hello.v1` / `welcome` |
| `Sources/KraalProtocol/Surface.swift` | `PaneSurfaceFrame` / `PaneSurfacePatch` 校验 |

**验收**：`swift test` 全绿；`Fixtures/surface_120x40.bin` 解码出 4800 个 cell，
文本与 `Fixtures/surface_120x40.txt` 逐字符一致。

### M1 · 本地连接与握手

`Sources/KraalTransport/UnixSocket.swift`（POSIX）+ `BridgeChannel.swift`（帧循环）。

macOS 直连 `~/.config/herdr/herdr-client.sock`，不经 SSH。

**验收**：命令行跑出 snapshot 的 workspace / tab / pane 列表。

### M2 · PaneSurface 解码

`Sources/KraalProtocol/Surface.swift` 补全 patch 校验 + 文本投影。

**验收**：打印整屏文本，与 `Fixtures/surface_120x40.txt` 一致。

### M3 · Ghostty 渲染单 pane

接 `libghostty-spm` 的 `TerminalViewState` + `InMemoryTerminalSession`，
用 `terminal session control` 收 ANSI 喂进去。

**验收**：macOS 窗口里显示一个真实 herdr pane，能打字、能滚动。

### M4 · ANSI 一致性回归

修掉 `research/04_ansi_vs_surface.py` 的 `cols/rows` 不匹配问题（DESIGN.md §12 #2），
把「herdr ANSI → Ghostty 渲染结果 == herdr 权威 surface」做成自动化测试。

**验收**：逐行比对通过，作为渲染正确性的长期门禁。

### M5 · 多 pane 布局

按 `PaneSurfacePane.innerRect` 摆 N 个 Ghostty view。

**验收**：完整复现 herdr 一屏的分屏布局。

### M6 · 侧边栏 + 标签栏

`shell.snapshot.v1` 数据驱动 SwiftUI。

**验收**：侧边栏可点、可切换 workspace / tab。

### M7 · 输入

鼠标合成（点击/右键/拖拽/滚轮）、键盘 `TextCommit`、命令面板。

**验收**：能在 pane 内的 vim 里正常操作。

### M8 · 侧边栏配置引擎

`config.toml` 解析 + token 解析 + rules 条件样式。

**验收**：导入自定义 `config.toml`，侧边栏布局随之变化。

### M9 · 打磨

重连、错误恢复、主题、性能（大 surface / 滚动）。

---

## 2. iOS 阶段（延后）

进入条件：**M0–M6 在 macOS 上验收通过**。届时再做：

- `libssh2-spm` 接 SSH exec `remote-client-bridge`
- iPhone 单 pane + 切换器布局
- 软键盘与触摸手势
- DESIGN.md §12 #1（libssh2 单 session 多 channel）必须先验证

真机调试前置：Xcode 内登录 Apple ID（见 [ENVIRONMENT.md](ENVIRONMENT.md) §3）。

---

## 3. 工程约定

### 3.1 仓库结构

```
Kraal/
├── Package.swift                 # SwiftPM 主 manifest
├── project.yml                   # xcodegen 配置（.xcodeproj 不入库）
├── Sources/
│   ├── KraalProtocol/            # 零依赖，可 Linux CI
│   ├── KraalTransport/           # socket / SSH
│   ├── KraalClient/              # 连接状态机、快照存储
│   ├── KraalSidebar/             # 侧边栏模型与 TOML
│   ├── KraalUI/                  # SwiftUI
│   └── KraalMac/                 # macOS app 入口
├── Tests/
├── Fixtures/                     # 真实抓包，协议回归基准
└── research/                     # Python 逆向脚本（已完成使命，保留参考）
```

### 3.2 构建命令

统一以普通用户身份构建（见 [ENVIRONMENT.md](ENVIRONMENT.md) §4.1）：

```bash
sudo -u zzj swift build          # 或 swift test
sudo -u zzj xcodegen generate
```

`KraalProtocol` 与 `KraalTransport` 不依赖 GhosttyKit，因此 `swift test`
不需要下载 51 MB 的 xcframework，CI 友好。

### 3.3 依赖

| 依赖 | 用途 | 引入阶段 |
| --- | --- | --- |
| `libghostty-spm` `1.6.20261003` | 终端渲染 | M3 |
| `libssh2-spm` | SSH 传输 | iOS 阶段 |

`KraalProtocol` 在 M0/M1 阶段保持**零第三方依赖**。

### 3.4 许可证

Apache-2.0，新文件需带 SPDX 头（见 [CONTRIBUTING.md](../CONTRIBUTING.md)）。
协议类型衍生自 herdr / herdr-gpui（Apache-2.0），归属见 [NOTICE](../NOTICE)。

---

## 4. 与 DESIGN.md 的对应关系

| DESIGN.md | 本路线 |
| --- | --- |
| M0 协议内核 | M0 |
| M1 连接与握手 | M1 |
| M2 Ghostty 渲染 | M3（拆出 M2 专门做 surface 解码） |
| M3 布局与侧边栏 | M5 + M6 |
| M4 侧边栏配置引擎 | M8 |
| M5 交互 | M7 |
| M6 iOS 适配 | 移至 iOS 阶段 |
| M7 打磨 | M9 |

新增的 **M4（ANSI 一致性回归）** 不属于原计划，是把 DESIGN.md §12 #4
（「Ghostty 对 herdr ANSI 的实际渲染」是核心假设）提前固化为自动化门禁。
