# 路线图（HC-only）

目标：Kraal 是 herdr-core（`hc`）的原生 Swift 客户端，行为对齐官方
`herdr-app`；只保留 Swift/SwiftUI/AppKit + Ghostty 的差异。Herdr 1 栈已删除。

状态以代码和 `Scripts/verify.sh` 为准，不以文档为准。

---

## M0 协议与渲染 ✅

- JSON-RPC 明文 + framed streams（9 字节帧头）
- hello 版本/方法门禁
- attach 原始 PTY 字节 → Ghostty
- CREDIT 反压、RESIZE/FOCUS、mode-2048 尺寸报告过滤
- M0 窗口能列终端、attach、显示

判据：`HcWireTests` / `HcHelloTests` / `HcAttachStreamTests` /
`HcTerminalAPITests` 全绿；VM 能 attach 到真实 core。

---

## M1 布局与文档 ✅

- 客户端 space/tab/pane 树（`KraalModel`）
- 官方共享文档 `herdr-app`：CAS、冲突最新胜出、未知字段透传
- 私有 `view.json`：focus/zoom/settled/recent/active
- 新 space/tab/split 收养真实 core id（事件可能先于 reply）
- `herdr.space` / `herdr.tab` / `herdr.seen` 标签

判据：`KraalDocumentModelTests`、`HcLayoutDocumentTests`、
`HcLayoutTreeTests`、`LiveHcDocumentTests` 全绿。

---

## M2 客户端对齐 ✅（#232 仍有 UX 尾项）

- 原生 chrome：侧栏、标签栏、分隔条拖动、命令面板、设置、help、rename
- 69 条动作目录 + keys.json（global/terminal/send 语义）
- OSC 7501 agents 侧栏、toast/peek/pin/unread、done 判定
- Ghostty 终端 UX：选择/复制/粘贴/滚动、右键菜单、focus 同步
- 字号缩放、侧栏开关、设置即时生效
- `kraal commands/ls/status/do/shot` 控制面

判据：`HcWorkspaceModelTests`、`KraalActionTests`、`HcSettingsTests`、
`HcKeymapControllerTests`、`LiveHcPaneTests` 全绿；VM 截图 + control 断言。

剩余（#232）：Cmd-click 打开 `pane/t7`、链接 hover、文件拖放、
`terminal.paste_image`、kitty graphics 像素回归、IME 候选窗、
alt-screen 滚轮、`terminal.right_click=program`。

---

## M3 交付与清理 🚧

已完成：

- Herdr 1 客户端/协议/测试/旧 CLI 子命令删除
- `KraalMac` 单一 HC 入口；无 `KRAAL_HC` 开关
- `KraalSupport`（日志/DevSession）独立
- `kraal` 控制面 + 单实例 raise
- 旧 `gui.sh` / `bench.sh` / 旧 probe 删除

剩余：

| 项 | 说明 |
|---|---|
| #235 GUI 自动化重写 | 44 个旧用例改成 `kraal ls/status/do` + AX；补回 GUI 门禁 |
| #237 性能基线 | attach 吞吐、N pane 主线程占用、输入→回显；新基线 |
| #236 iOS | 先把 `KraalModel`/`KraalHC` 抽成跨平台，再接 SwiftUI iOS |
| #242/#243 | 直连 ssh、VM SSH fixture（core 能力验证） |

验收：`./Scripts/verify.sh` 全绿；GUI 门禁恢复后能故意注入失败并变红。

---

## 不变量

1. 单一协议：只支持 herdr-core generation 1。
2. 客户端不解析终端网格；首帧 VT 重放后原始字节进 engine。
3. 共享文档只写自己的子树；CAS 冲突不做三方合并。
4. 私有状态不进共享文档。
5. 版本门禁失败就明确报错，不做降级猜测。
6. 控制面窗口是唯一写入者；一连接一命令。

细节见 [HERDR2.md](HERDR2.md)。
