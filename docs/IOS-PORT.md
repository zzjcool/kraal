<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# 移植到 iOS：现状与要做的事

> 实测记录：2026-10-27 · Xcode 27.1 / iOS SDK 27.1 / Swift 6.4
>
> 这份文档回答一个问题：**Kraal 现在离 iOS 上能跑差多远。**
> 所有"✅ 实测"条目都在 2026-10-27 跑过；标"未验证"的不要当结论用。
>
> **本文档不改代码，只记录调研结果。** 验证用的改动全部做在 `/tmp` 的仓库副本里，
> 跑完就删了，原仓库未被修改。

---

## 0. 结论

**有条件可行。** 三句话：

1. **协议内核本来就是跨平台的。** `KraalProtocol`（13 文件 / 5258 行）在 iOS 设备切片上
   **零改动编译通过**。加上 `KraalTransport` / `KraalClient` / `KraalSidebar` 这四个
   target，改 3 个文件就能过。
2. **终端渲染不用自己写。** `libghostty-spm` 的 xcframework 里就有 `ios-arm64` 和
   `ios-arm64_x86_64-simulator` 两个切片；`UITerminalView` 已经处理了触摸、软键盘、
   输入辅助栏、剪贴板、捏合缩放。
3. **真正的缺口是两个**：SSH 传输（现在靠 `Process` 起 `/usr/bin/ssh`，iOS 没有子进程），
   以及约 4300 行 AppKit 专属 UI 需要 iOS 对应实现。其余是贴边修补。

`Package.swift:16` 早就写了 `.iOS(.v17)`，但那只是声明 —— 声明和能编译之间隔着
本文档列的全部工作。第 1 节是这条声明**第一次被真的验证**。

---

## 1. 实测：现在到底能不能编

### 1.1 方法

SPM 交叉编译到 iOS，绕开 Xcode 工程（本仓库没有 `.xcodeproj`，见 §4.4）：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 模拟器切片
/usr/bin/swift build --triple arm64-apple-ios17.0-simulator \
    --build-path /tmp/kios-build --target <TARGET>
# 真机切片（它会连带验证 arm64 的 codegen，比模拟器慢 3 倍左右，值）
/usr/bin/swift build --triple arm64-apple-ios17.0 \
    --build-path /tmp/kios-build-dev --target <TARGET>
```

一定要用 `--build-path` 指到别处：默认的 `.build` 会同时被 macOS 构建使用，
两套 toolchain 的 `.swiftmodule` 布局不同（单文件 vs 目录），互相踩会让
SourceKit-LSP 开始误报 `No such module`（`AGENTS.md` §3 末尾那一段）。

### 1.2 结果（未改动代码）

| Target | 模拟器 | 结论 |
| --- | --- | --- |
| `KraalProtocol` | ✅ Build complete | 零改动 |
| `KraalSidebar` | ✅ Build complete | 零改动 |
| `KraalTransport` | ❌ | `SSHTransport.swift:87`、`HerdrMachineClient.swift:477`：`cannot find type 'Process' in scope` |
| `KraalClient` | ❌ | 被上一级拖累（`ProtocolStream.swift:188` 消费 `SSHProcessTransport`） |
| `KraalUI` | ❌ | 10 个文件 `import AppKit` |
| `KraalTerminalView` | ❌ | 连锁到 `MouseForwarder.swift:15` |

`grep -l '^import AppKit' Sources/*/*.swift` 的分布，就是这份清单的形状：

```text
KraalProtocol      AppKit files=0  total=13
KraalTransport     AppKit files=0  total=5      ← 编译器错误来自 Process，不是 import
KraalClient        AppKit files=0  total=2
KraalSidebar       AppKit files=0  total=5
KraalUI            AppKit files=10 total=70
KraalTerminalView  AppKit files=1  total=4
KraalMac           AppKit files=4  total=4
```

### 1.3 结果（用 §3 的最小改动配方）

| 目标 | 结果 |
| --- | --- |
| `KraalTerminalView` @ 模拟器 `arm64-apple-ios17.0-simulator` | ✅ Build complete |
| `KraalTerminalView` @ 真机 `arm64-apple-ios17.0` | ✅ Build complete |
| 全包 @ macOS（回归检查） | ✅ Build complete，无新错误 |

改动量：**`Sources/` 下 23 个文件，+88 / −12 行**，全部是条件编译，没有重写任何逻辑。

> 这个结果是"能编过"，不是"能跑"。真机/模拟器里起进程、连 daemon、渲染、摸到
> 键盘，全都**未验证**。见 §6。

---

## 2. 阻塞项

### P0 · SSH 传输：唯一的架构缺口

**现状**（`Sources/KraalTransport/SSHTransport.swift`）：

- `:154` `let process = Process()` 起 `/usr/bin/ssh`，靠 `Pipe` 拿到 stdin/stdout。
- `:159-161` 认证完全甩给系统 ssh：`BatchMode=yes`、`NumberOfPasswordPrompts=0`、
  `StrictHostKeyChecking=accept-new`。
- `:110` 的 `bridgeScript` 生成远端那半段 shell 脚本。

`ProtocolStream.swift:188` 的 `StreamFactory.open` 把它包成 `SSHStream` 交给上层。
`UnixSocket.swift:121` 的 `Darwin.connect` 在 iOS 上还能编译，但只能连本机 UDS，
连不到远端 —— iOS 也没有别的机器可连。

**为什么这个缺口不难补**：协议当初就是为 iOS 选的路线。`docs/DESIGN.md:99` 记着
"两者都是 stdin/stdout 二进制管道，不涉及 stream-local forwarding，因此不需要
`AllowStreamLocalForwarding`。**这是选择这条路线的关键原因之一**"。

也就是说，要替换的只有"怎么拿到这个双向字节管道"这一段，**ready 握手、帧循环、
重连、`endpoint_busy` 的处理全部原样复用**。

**建议方案**：`libssh2-spm`（product `CSSH2`）。

- ✅ 实测 iOS **真机切片**编译通过（`arm64-apple-ios17.0` → Build complete）。
  最小验证工程：`.package(url: "https://github.com/Lakr233/libssh2-spm.git", from: "1.0.0")`
  + `import CSSH2`。
- `docs/ENVIRONMENT.md:75` 已经把它列为 iOS 阶段依赖，`docs/ROADMAP.md:124` 也写了，
  只是还没接进来。
- ⚠️ Homebrew 的 `libssh2` **只有 macOS 切片**，不能拿来用（`docs/ENVIRONMENT.md:75`）。

**工作量**：新写 `SSHChannelTransport`（实现现成的 `ProtocolStream` 协议）约 350 行，
外加 `StreamFactory.open` 的 `case .sshShell` 换实现。

`bridgeScript` 本身能直接复用 —— 它只是一段要在远端执行的 shell 文本，
和本地怎么连上去无关。

### P1 · 凭据与主机密钥界面（现在完全不存在）

macOS 版把认证整个交给系统 `ssh`：用户自己的 `~/.ssh/config`、`ssh-agent`、
`known_hosts` 全都能用。iOS 上没有这一层，**必须自己实现**：

| 项 | 谁来做 | 备注 |
| --- | --- | --- |
| 私钥导入与保管 | `Security` framework / `SecItemAdd` | 要不要放 Secure Enclave？未调研 |
| passphrase 输入 | UI + Keychain | |
| 首次连接的主机指纹确认 | 自己实现 `known_hosts` 等价物 | 这是安全问题，不能默认接受 |

这不是编译适配，是产品级工作。`docs/DESIGN.md:115-118` 有初步推演
（`-C` 压缩开关、`libssh2_keepalive_config` 对应 `ServerAliveInterval`），但
**凭据部分文档里也没写**。

### P1 · 子进程类功能整体失效（需要产品决策）

`HerdrMachineClient` 是 Machines 面板的**全部**后端：列表、add、rename、
enable/disable、remove，以及 `machine status` 的连通性探测。落点：
`HerdrMachineClient.swift:477` 的 `invoke()` 里 `Process()`。

同样失效的还有 `$PATH` 扫描（`HerdrMachineClient.swift:257` 的 `discover()` 找
`herdr` 可执行文件）—— iOS 上没有 CLI 可找。

**能编过的修法只要一行**（在 `invoke()` 里对非 macOS 直接抛
`HerdrMachineError.launchFailed`），但**功能上等于这台面板在 iOS 上不存在**。

需要决策（两条路都合理）：

- **A** iOS 版自建本地机器名册（自己存 host/port/user，不走 `herdr machine`）。
  代价：和桌面端的名册**不再同步**，用户要在两处各维护一份。
- **B** 第一版砍掉 Machines 面板，只支持"用户手填一条连接"。
  `ConnectionViews.swift:58` 已经有手填 host/user/port 的界面，够用。

`docs/feasibility.md:20` 早就指出过这件事："所以 iOS App **不能『从服务器读到同一份
machines 列表』**。要么让用户在 App 里自己填（等于重建一份目录）"。

### P2 · 约 4300 行 AppKit 专属 UI

这些文件的 AppKit 用法**不是加一行 `#if` 能包住的**，需要 iOS 版对应实现：

| 文件 | 行数 | 为什么必须重写 | 真 AppKit 用量 |
| --- | --- | --- | --- |
| `SidebarView.swift` | 841 | 宽度拖拽规则、拖拽光标 | 2 处 `NSCursor` |
| `PaneLayoutView.swift` | 855 | `PaneFrameReporter: NSViewRepresentable`（`:771`）+ 内部 `NSView` 子类（`:792`）做命中测试 | 6 处（1 个 representable + 2 处 `NSCursor`） |
| `MachinesPanel.swift` | 870 | 整块是 subprocess 驱动器（见 P1） | 2 处 `NSPasteboard` |
| `MouseForwarder.swift` | 413 | `NSEvent.addLocalMonitorForEvents`（`:103`）靠**窗口级事件监视器** | 15 处 |
| `RootView.swift` | 258 | `.frame(minWidth: 720, minHeight: 420)`（`:116`）+ 固定双栏，iPhone 上必须换单列 | 0（只是布局） |
| `AppStore+CopyMode.swift` | 229 | 复制模式的剪贴板 | 1 处 |
| `PaneContextMenuBar.swift` | 214 | `NSMenu` 26 处（含注释） | 18 处 |
| `SettingsView.swift` | 281 | `NSWorkspace.activateFileViewerSelecting`（`:253`） | 1 处 |
| `DebugInfoView.swift` | 195 | `NSApp.keyWindow`（`:80`） | 2 处 |
| `TerminalEffectsApplier.swift` | 123 | `NSPasteboard` + `NSSound` + `NSWindow` | 5 处 |

**注意右列和左列的对比**。`SidebarView` 的 841 行里只有 2 处真 AppKit 调用，
`PaneLayoutView` 的 855 行里只有 1 个 representable —— 这两处**不是重写，
是抽一个 iOS 版 shim**（触摸命中测试、触摸光标），布局数学（`PaneFrameMath`、
`SurfaceGeometry`）本来是平台中立的。

真正需要从零写的是两件：

- `RootView` 的 iPhone 单列布局（`docs/GAP-VS-HERDR.md:399` 已经记着这项：
  "移动端单列布局（≤64 列）… macOS 不需要；iOS 阶段必须补"）。
- `MachinesPanel` 的替代品（取决于 P1 的决策）。

### P3 · 小修补（已在副本里验证可行）

按 §3 的配方，这些点各 2–8 行：

| 位置 | 现状 | iOS 侧 |
| --- | --- | --- |
| `SurfaceGeometry.swift:235,262` | `NSScreen.main?.backingScaleFactor ?? 2` | SwiftUI 的 `displayScale` 环境值（`PaneLayoutView.swift:30` 已经在用了），兜底 3 |
| `ThemeResolver.swift:91-92` | `NSApp.effectiveAppearance` / `NSAppearance.currentDrawing()` | SwiftUI `colorScheme` |
| `ThemeEnvironment.swift:82` | `NSApplication` 的 KVO 观察器 | 观察 `colorScheme` |
| `Palette.swift:199,205` | `Color(nsColor: .selectedContentBackgroundColor / .separatorColor)` | `Color.accentColor` / `Color(uiColor: .separator)` |
| `RootView.swift:56`、`PopupChrome.swift:57` | `Color(nsColor: .textBackgroundColor)` | `Color(.systemBackground)` |
| `ThemeConfig.swift:111` | `FileManager.homeDirectoryForCurrentUser` | **iOS 上这个 API 不可用**（编译错误，不是运行期 nil）；配置改由用户导入 |
| `MouseCoordinateMapper.swift:65` | `NSEvent.ModifierFlags` 的位换算 | iOS 侧没有修饰键位来源，改写 `UIKeyModifierFlags` |
| `AppCommands.swift:481` | 粘贴走 `NSPasteboard` | iOS 走 `UIPasteboard`，或直接用 `store.sendPaste` |

`SystemNotifier` 只 `import AppKit` 而**一行都没用到**（`UNUserNotificationCenter`
本来就是跨平台的），删掉那行 import 即可。`ShortcutsView` 同理。

`Glass.swift` **本来就有 iOS 分支**（`:129-134` 走 `.ultraThinMaterial`、
`:143-147` 走 `Color(.systemBackground)`），不用动。它是这个仓库里条件编译做得最到位的文件。

---

## 3. 最小改动配方（实测可行）

> 这是 §1.3 那个"能编过"结果的具体内容，留给真要动手时当起点。
> **注意它只处理编译，不处理功能** —— P0/P1/P2 该做的还是要做。

### 3.1 传输层

```swift
// SSHTransport.swift —— 整文件
#if os(macOS)
import Foundation
…
#endif

// HerdrMachineClient.swift —— 只包 invoke() 的函数体
private func invoke(_ arguments: [String]) throws -> Invocation {
    #if !os(macOS)
    throw HerdrMachineError.launchFailed("subprocesses are unavailable on iOS")
    #else
    let process = Process()
    …
    #endif
}

// ProtocolStream.swift —— SSHStream 类整体上守卫，StreamFactory 里换个实现
#if os(macOS)
public final class SSHStream: ProtocolStream, @unchecked Sendable { … }
#endif

case .sshShell:
    throw BridgeError.transport("SSH is not implemented on this platform yet")
```

**`invoke()` 只用函数体级的守卫**，不要整文件包：`HerdrMachine`、`MachineStatus`、
`MachineStatusIndex` 这些类型是跨平台的，`MachineRoster` 和 `EndpointCatalog` 在
iOS 上还要用它们。我第一次整文件包，结果 `MachineRoster.swift:29` 立刻
`cannot find type 'HerdrMachine' in scope`。

### 3.2 `KraalUI`：两类文件，两种处理

**(a) 只需要 import 守卫 + 个别表达式分叉的（13 个）**：加
`#if os(macOS) import AppKit #endif`，再把 `NS…` 那几行按 §2 P3 的表分叉。

**(b) AppKit 用法和主体逻辑不可分的（10 个）**：整文件 `#if os(macOS)` 包住。

**关键陷阱**：整文件包的时候，**平台中立的 `protocol` 声明必须留在守卫外面**，
否则 macOS 侧会炸。实测踩到两次：

- `PaneContextMenuBar.swift:153` 的 `PaneContextMenuTarget`、
  `:166` 的 `PaneContextMenuValidating`
- `MouseForwarder.swift:28` 的 `PaneContextMenuProviding`

这三个 protocol 的唯一"平台相关性"是方法签名里出现了 `NSMenuItem`
（`:153-160`）—— 但它们之所以这样写，是因为 AppKit 的 selector 机制要求
（`MacMenuBar.runCommand` 通过 `NSMenuItem.representedObject` 转发）。iOS 侧要接
自己的菜单，协议形状本来就应该不同，所以**正确的做法是 iOS 版另写一份协议**，
而不是硬把 AppKit 版塞进共享区。

我验证过的临时处理是"protocol 留在守卫外、`NSMenuItem` 参数不改"，这在
**只求编译**时可行，但 iOS 上没人会调用它们 —— 属于过渡态，不是最终形状。

### 3.3 手工验证过的那 23 个文件

传输 3 个、`KraalUI` 19 个、`KraalTerminalView` 1 个。完整清单和每处 diff
在本文档 §2 的表格里；真要实施时按表格做，不要照搬临时补丁。

---

## 4. 白拿的部分

这几块不用动就值回票价：

### 4.1 输入链路

`TerminalInputDecoder`（`Sources/KraalProtocol/TerminalInputDecoder.swift`）纯
Foundation，把 Ghostty 吐的字节翻译成语义事件。`PaneTerminal.swift:200` 的
`InMemoryTerminalSession(write:)` 已经把"Ghostty → `onInput`"接好了。

而且 iOS 上这段**比 macOS 简单**：软键盘直接产生文本，走 `TextCommit` 就行，
不需要字节级键位映射。`docs/DESIGN.md:716`："iOS 软键盘 → `TextCommit(String)`"。

IME 也有现成的：`docs/DESIGN.md:718` 记着 ghostty 的 `TerminalSurface` 已经处理
`preedit` / `markedText`。

### 4.2 鼠标/触摸 → daemon

`AppStore.sendMouse(_:at:in:paneId:modifiers:lines:)`（`AppStore+Terminal.swift:189`）
是**纯值类型转换**，不碰 AppKit：坐标换算交给 `MouseCoordinateMapper` 和
`PaneMouse`，两个都是纯函数。

也就是说 iOS 的触摸适配层只需要：拿到触点 → 调 `sendMouse`。`MouseForwarder`
里那 413 行真正不可复用的是**事件抓取**（`NSEvent` 窗口级监视器），坐标数学
可以直接搬。

### 4.3 传输层抽象已经留好口子

`ProtocolStream` 是个协议，`StreamFactory.open` 是个 `switch`。加一个 iOS 实现
就是加一个 `case`，上层（`EndpointConnection`、`AppStore`）一行都不用改。

### 4.4 构建

本仓库**没有 `.xcodeproj`**（`Scripts/build-app.sh` 从 SPM 产物手工组装 `.app`，
`docs/ROADMAP.md:172` 也说明"仓库不提交 `.xcodeproj`"）。这是好事：
iOS 侧同样可以先走 `swift build --triple` 验证编译，真机部署再谈工程文件。

`docs/ENVIRONMENT.md:80` 说 `xcodegen 2.46.0` 已装好，可从 `project.yml` 生成 —— 
但仓库里目前**没有** `project.yml`（`git log` 里也没有提交过），这条路是全新的。

---

## 5. 踩过的两个坑

写下来是因为它们会让人白跑一轮：

### 5.1 `#if canImport(Darwin)` 在 iOS 上是 **TRUE**

第一次给 `SSHTransport` 加的是 `#if canImport(Darwin)`（照着
`UnixSocket.swift:13` 和 `RosterFileWatcher.swift:45` 的写法抄的），
iOS 编译照样失败：

```text
SSHTransport.swift:87: error: cannot find type 'Process' in scope
```

`Process` 属于 Foundation 在 macOS 上的扩展，**和 Darwin 能不能 import 无关**。
判据必须是 `#if os(macOS)`。

仓库里现有的 `canImport(Darwin)` 用法都是对的（它们区分的是 Darwin/Glibc 的
`open`/`eventfd` 这类 POSIX 差异），别因为这次踩坑把它们改掉。

### 5.2 不要用 `exclude:` 排除 AppKit 文件

`Package.swift` 的 `target.exclude` 是**无条件**的，排除掉之后 macOS 侧就少了
这些文件，连锁报错：

```text
KraalMacMain.swift:26: error: cannot find type 'MouseForwarder' in scope
KraalMacMain.swift:605: error: cannot find type 'PaneContextMenuProviding' in scope
```

SPM 没有条件 `exclude`。所以唯一的路是整文件 `#if os(macOS)`（见 §3.2b）。

---

## 6. 落地顺序（建议）

1. **P0 SSH**：`libssh2-spm` 接进 `SSHTransport`，用 `kraal` CLI 或现有测试对着
   真实远端 daemon 验通。**先做这个**，因为它是唯一会推翻整体方案的风险点。
2. **P3 + §3 配方**：让 `KraalUI` / `KraalTerminalView` 在 iOS 模拟器编过，
   先做到"单 pane 只读显示"。
3. **iPhone 单列布局**：`RootView` 的 iOS 版。
4. **软键盘 + 触摸手势**：软键盘基本白拿（§4.1），触摸要写 `sendMouse` 适配层。
5. **P1 凭据界面 + Machines 面板决策**：产品决策先定，再动手。
6. **iPad 分屏**：`docs/DESIGN.md:789` 有 iPhone/iPad/Mac 三栏对照表。
7. **真机**：`docs/ENVIRONMENT.md:108` 记的阻塞项 —— Xcode 内登录 Apple ID，
   目前 0 个 provisioning profile。

---

## 7. 未验证的部分

诚实清单。这些**没有**实测，不要引用为结论：

- **任何运行期行为**。§1.3 证明的是"能编过"，模拟器里起进程、连 daemon、
  渲染画面、收到键盘输入，全部**没跑过**。
- **`libssh2` 单 session 多 channel 并发**。这是 `docs/DESIGN.md:1021` 待验证清单
  的第 1 项，至今没做。它决定 iOS 是"1 次握手"还是"每个 pane 一次握手"，
  直接影响体验和远端负载。
- **`herdr remote-client-bridge` 在 `libssh2` 的 exec channel 下能否正常拿到
  `herdr-remote-output-ready:1`**。`bridgeScript` 是纯 shell，理论上没问题，
  但没在 libssh2 上跑过。
- **iOS 后台行为**。`docs/DESIGN.md:809` 记着"进后台约 5s 后挂起，
  `beginBackgroundTask` 实测 25–30s"，那是上游调研的数字，本仓库没复测。
- **`UIGlassEffect`（iOS 26 SDK 符号）在 Xcode 27.1 / iOS 27.1 SDK 下的表现**。
  `docs/ENVIRONMENT.md:64-68` 说 Xcode 16.4 时代会编译失败、Xcode 27 已解除，
  但那条的是 libghostty 自己的 `TerminalInputAccessoryView.swift`，本仓库没碰过。
- **签名与真机部署链路**。除了"证书在 keychain 里、2026-11-20 到期"
  （`docs/ENVIRONMENT.md:100-103`）之外全没走过。
- **`libghostty` 静态链入的 LGPL `libintl`**（`docs/feasibility.md:84` 提到需审查
  版本）。App Store 分发的合规问题，没调研。

---

## 8. 与其它文档的关系

| 文档 | 它说什么 | 本文档补什么 |
| --- | --- | --- |
| `docs/ROADMAP.md` §2 | iOS 阶段的任务清单（1–2 周量级） | **实测**这份清单的工作量；补上 SSH 凭据界面和 Machines 面板这两项（原清单没算） |
| `docs/DESIGN.md` §6.5 / §7 | 触摸映射、尺寸协商、iPhone/iPad 布局 | 那些是设计；本文是"现在代码离那儿多远" |
| `docs/ENVIRONMENT.md` §2 | 依赖的版本与坑（libghostty、libssh2） | 本文第 1 节是这些依赖第一次在 iOS 上被真的编过 |
| `docs/feasibility*.md` | 立项期的可行性推演（2026-10） | 那份是"值不值得做"；本文是"做到哪一步了" |
| `docs/GAP-VS-HERDR.md:399` | 移动端单列布局是已知缺口 | 把它归到 §2 P2 的 `RootView` |

---

## 附：本次调研的复现方式

```bash
# 1. 在副本里做实验，不要碰工作树
rsync -a --exclude .build --exclude .git ./ /tmp/kios/

# 2. 按 §3 打补丁
cd /tmp/kios && …（§3 的内容）

# 3. 两种切片都编一遍
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/usr/bin/swift build --build-path /tmp/kios-ios    --target KraalTerminalView \
    --triple arm64-apple-ios17.0-simulator
/usr/bin/swift build --build-path /tmp/kios-iosdev --target KraalTerminalView \
    --triple arm64-apple-ios17.0

# 4. 回归：macOS 侧不能因为条件编译而少东西
cd /tmp/kios && /usr/bin/swift build --build-path /tmp/kios-mac --build-tests
```

我这边跑完的结果是：第 3 步两条都 `Build complete`，第 4 步 `Build complete`
（`--build-tests` 也过）。副本已删除。
