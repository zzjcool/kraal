<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# 开发环境基线

> 实测记录：2026-10-20 · 本机 macOS 27.0 / Xcode 27.1
>
> 本文档只记录**已验证的事实**。未验证的推断会明确标注。

---

## 0. 结论

macOS 优先开发的环境依赖**已全部就绪**。iOS 侧同样可用，但真机调试还缺 Xcode 内的 Apple ID 登录。

---

## 1. 本机基线

| 项 | 版本 / 状态 |
| --- | --- | --- |
| macOS | 27.0（26A428） |
| 架构 | arm64（Apple Silicon，14 核 / 48 GB） |
| Xcode | **27.1**（27A9275），`xcode-select -p` 已指向它 |
| Swift | **6.4**（swiftlang-6.4.0.34.1） |
| iOS SDK | 27.1 |
| macOS SDK | 27.0（最低部署目标 12.0） |
| iOS 模拟器 runtime | iOS 18.6（可运行 Xcode 27 产物） |
| herdr（本机） | 0.9.4 |
| herdr（远端） | `nj-rssyes` 0.9.1 / `devcloud` 0.9.4 |
| Python | 3.14.6 + `research/.venv`（pyte 已装） |

Xcode 27 的 Swift 6.4 同时满足 `swift-tools-version: 6.0` 和 `6.2`，因此
`libghostty-spm` 的任意 tag 都能解析（Xcode 16.4 的 Swift 6.1.2 无法解析 6.2）。

---

## 2. 依赖清单

### 2.1 Ghostty 渲染：`libghostty-spm`

```swift
.package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "1.6.20261003")
```

- 预编译 `libghostty.a`（binaryTarget，**不需要 zig**）
- xcframework 包含 `ios-arm64` / `ios-arm64_x86_64-simulator` /
  `macos-arm64_x86_64` / `ios-arm64_x86_64-maccatalyst` / `xros-*`
- macOS 切片 `minos = 13.0`，iOS 切片 `minos = 15.0`
- 传递依赖 `MSDisplayLink`

**版本选择注意**

| 写法 | 是否可用 | 原因 |
| --- | --- | --- | --- |
| `revision: "1.6.20261003"` | ✅ | 最新可用 tag |
| `branch: "main"` | ⚠️ | 用 swift-tools-version 6.2，Xcode 27 可解析但不可复现 |
| `exact: "upstream.1.3.1"` | ❌ | 非语义化版本号，SwiftPM 直接拒绝 |
| `from: "1.5.2"` | ⚠️ | 会解析到 1.6.x，实际等价于取最新 |

**Xcode 16.4 时代的坑（已解除）**：1.2.x–1.5.x 的
`TerminalInputAccessoryView.swift` 使用了 `UIGlassEffect`（iOS 26 SDK 符号），
在 Xcode 16.4（iOS 18.5 SDK）下 iOS 编译必失败。Xcode 27 自带 iOS 27.1 SDK，
该问题不再存在。

### 2.2 SSH 传输：`libssh2-spm`

```swift
.package(url: "https://github.com/Lakr233/libssh2-spm.git", from: "1.0.0")
// product: CSSH2，传递依赖 openssl-spm
```

- Homebrew 的 `libssh2` **只有 macOS 切片**，不能用于 iOS，必须走这个 SPM 包
- 已验证 iOS 设备切片 `arm64-apple-ios18.0` 编译通过

### 2.3 工具链

| 工具 | 状态 | 用途 |
| --- | --- | --- | --- |
| `xcodegen` 2.46.0 | ✅ | 从 `project.yml` 生成 `.xcodeproj`（仓库不提交 `.xcodeproj`） |
| `gh` 2.101.0 | ✅ 已登录 `zzjcool` | PR / issue |
| `git` | ✅ push 权限已验证 | |
| `pod` | 有，但**不用** | 统一走 SPM |

### 2.4 调研脚本

```bash
python3 -m venv research/.venv
research/.venv/bin/pip install pyte
```

Homebrew Python 是 PEP 668 externally-managed，**必须用 venv**，不能直接
`pip install`。`.venv/` 已在 `.gitignore` 中。

---

## 3. 代码签名与真机

| 项 | 状态 |
| --- | --- | --- |
| `Apple Development: email@zzj.cool (YMY6FDTW38)` | ✅ 在 login keychain 中 |
| 证书有效期 | 2026-11-20（**约一个月后到期**） |
| Team ID | `589F7R6Q2H`（Personal Team） |
| Provisioning Profile | ❌ 0 个 |
| Xcode 内 Apple ID | ❌ 未登录 |

**真机调试前的阻塞项**（做 M10/M11 时才需要，不阻塞 macOS 开发）：

`Xcode → Settings → Accounts → + → Apple ID → zzj.cool` → 选 Personal Team

登录后 Xcode 会自动生成 provisioning profile。也可用免费的 `CODE_SIGN_IDENTITY: "-"`
做本地临时签名跑 macOS 版。

---

## 4. 运行时环境注意

### 4.1 root 与用户身份

本环境的 pi 会话通过 `sudo` 提升为 **root（uid=0）**。后果：

- `DerivedData` 默认落在 `/var/root/Library/Developer/Xcode/DerivedData`
- `xcrun simctl` 使用 `/var/root` 下的**另一套模拟器容器**，设备 UUID 与 zzj 的完全不同
- 在 root 下构建的产物，GUI 里的 Xcode 看不到

**约定**：本轮开发全部走 `sudo -u zzj`，与 GUI 共用一套 DerivedData 和模拟器。
构建命令统一加 `-derivedDataPath .build/DerivedData` 落到仓库内（已 gitignore）。

### 4.2 TCC 权限

| 权限 | 状态 |
| --- | --- | --- |
| Screen Recording | ✅ `com.kk2.rootshell` |
| Accessibility | ✅ `com.kk2.rootshell-helper` |
| Full Disk Access | ✅ |
| `kTCCServiceDeveloperTool` | ❌ 系统策略禁止授权（`does not allow prompting; returning denied`） |

`DeveloperTool` 拒绝是 macOS 27 对非标准开发者工具入口的安全限制，会影响
GUI 型自动化，**不影响 `swift build` / `xcodebuild` 命令行**。可忽略。

### 4.3 网络

- GitHub HTTPS / SSH 均通，release 资产下载实测 ~8.7 MB/s
- 无系统代理；`swcdn.apple.com` 可达
- 远端 herdr 通过 `ssh -o BatchMode=yes` 免交互认证

---

## 5. 已知待验证项（承接 DESIGN.md §12）

| # | 项 | 现状 |
| --- | --- | --- | --- |
| 1 | `libssh2` 单 session 多 exec channel 并发 | 未验证 |
| 2 | `terminal session control --cols/--rows` 是否改远端 PTY | 未验证 |
| 3 | 三个 optional codec 开启后的收益 | 未验证 |
| 4 | Ghostty 对 herdr ANSI 的实际渲染一致性 | 未验证（Ghostty 已接好，尚未做逐行比对） |

**注意 `research/04_ansi_vs_surface.py` 当前 18/18 行不一致**：根因是
attach 使用的 `cols/rows` 与 pane 的 `inner_rect`（118×18）不匹配，触发了远端
resize，不是渲染器的问题。这正是待验证项 #2 的入口，做 M4 时需要先修脚本再比对。

---

## 6. 未验证的推断（做对应阶段时必须复核）

- Xcode 27 的 iOS 26+ SDK 是否改变了 `UITerminalView` 的键盘/安全区行为
- macOS 27 上 Ghostty Metal surface 在 `NSHostingView` 中的 resize 时序
- 模拟器 runtime 18.6 与本项目 UI 的手势/键盘适配细节

