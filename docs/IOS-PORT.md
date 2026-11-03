# iOS 移植状态

结论：**未开始**。当前 Package.swift 只声明 macOS 14+；`KraalHCTerminal` 直接
import SwiftUI/AppKit，`KraalMac` 是 macOS 入口。HC 架构本身是跨平台友好的，
但还没有 iOS target。

可复用的层：

- `KraalSocket`：Unix socket（iOS 沙箱内可用；App Group 容器）。
- `KraalHC`：JSON-RPC / framed streams / events / doc / machine。
- `KraalModel`：布局树与命名，不依赖 AppKit。
- `KraalActions`：动作目录与参数校验。

阻塞项（按优先级）：

1. **终端渲染**：libghostty-spm 的 iOS 支持要与 macOS 版本对齐；先做最小
   `UIViewRepresentable` 和 attach 字节进 engine。
2. **连接方式**：iOS 没有本机 `hc`；需要 `ssh host hc connect` 或官方 relay
   方案（#242）。客户端不能自己维护 SSH 会话。
3. **控制面**：`kraal` CLI 不存在于 iOS；控制 socket 只保留给 macOS app。
4. **文件/剪贴板**：paste_image、拖放、DocumentPicker 需要单独设计。
5. **输入**：硬件键盘、IME、Ctrl/Esc 组合键要在 iOS 上重新验证。

在 M0–M3 的 macOS 验收完成前不动 iOS。相关 issue：#236。
