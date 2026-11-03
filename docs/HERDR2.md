# herdr-core 架构（HC-only）

2026-11-02 起 Kraal 只支持 **herdr-core**（`hc`）。Herdr 1 的 bincode endpoint、
服务端 workspace/tab/pane、cell→ANSI 渲染和 SSH 桥已全部删除；没有兼容层，
没有 `KRAAL_HC` 开关。本文件记录当前架构与已冻结的决策。

---

## 1. 为什么切

Herdr 1 把布局、PTY、渲染状态都放在 daemon；客户端只能拿到 cell 网格，再自己
重编码成 ANSI 喂终端。结果是：

- 客户端要维护第二份终端状态，差分/宽字符/图形容易和真实程序不一致；
- 每个 UI 动作都要发明一套 endpoint 协议；
- 远程机器由客户端维护 SSH，多机行为分裂。

herdr-core 把终端运行时留在 core，客户端通过 attach 流拿原始 PTY 字节；
布局变成客户端模型 + 一份共享文档。Kraal 因此删掉了整条 cell→ANSI 链路，
渲染交给 Ghostty。

---

## 2. 连接与协议

- API socket：`$XDG_STATE_HOME/herdr-core/<session>/<session>.sock`
  （`HC_SESSION` / `HC_SOCKET` 控制；客户端自己按同样的规则解析）。
- 普通请求：一行 JSON-RPC（`Content-Length` framing 由 `hc` 的 stdio 模式使用；
  unix socket 是 newline-delimited JSON）。
- 流：9 字节帧头
  `[channel u32 LE][kind u8][len u32 LE]`，payload ≤16 MiB。
  kind：`0 DATA`、`1 CREDIT`、`2 CLOSE`、`3 RESIZE`、`4 FOCUS`、`5 FACTS`。
- `hello`：要求 generation=1、版本达标、必需方法齐全；不满足直接失败。
- `CREDIT` 是反压：窗口未归还 credit 时 core 不会再推数据。

### 终端

- `terminal.attach` 首帧是 VT 重放，后续是原始 PTY 字节；两者都直接写入
  Ghostty engine。
- mode-2048 的 `ESC[48;…t` 是 host 尺寸报告，客户端过滤，不写进终端。
- 关闭语义二分：带 JSON reason 的 `CLOSE` = 程序结束；无 reason = 链路丢失。
  不要因为一次 close 就推断所有终端死亡。

### 文档

- 共享布局：`doc {name:"herdr-app"}`，与官方 app 同一份。
- 写入用 CAS；冲突返回 `.conflict(latest:)`，采用最新版本，不做三方合并。
- 只改自己拥有的子树；未知字段原样透传。
- 私有 focus/zoom/settled/recent/active 只写 `view.json`，绝不进共享文档。
- 保存串行化，避免同一 tick 多个写。

### 机器

- `hc machine.*` 是唯一远端入口；机器归 core，客户端只调方法和呈现状态。
- 侧栏 2.5s 轮询；客户端不自己 SSH、不维护远端 herdr 二进制。

### 状态

- agent 状态只信 OSC 7501（`state`、`app`、base64 `title`）。
- `herdr.seen` / `herdr.pinned` 在标签里；done = `turn > seen`。
- seen 只在 app active 且 pane 可见时写，只升不降。
- 新 blocked 或 busy→quiet 且没在看 → toast + 通知 + 声音。

---

## 3. 客户端模型

```
KraalSocket → KraalHC → KraalModel → KraalActions → KraalHCTerminal → KraalMac
```

- `KraalModel`：space/tab/pane 树、命名、focus、zoom、settle，不依赖 UI。
- `KraalActions`：69 条动作目录、参数校验、keys.json；`send:` 直写 PTY，
  global/terminal 分层，坏文件保留上一份可用绑定。
- `KraalHCTerminal`：Ghostty 接线 + SwiftUI chrome + workspace model。
- `KraalSupport`：日志、DevSession，Foundation only。
- `KraalMac`：只做入口、窗口和生命周期；不再持有旧 AppStore。

布局标签：`herdr.space`、`herdr.tab`、`herdr.seen`、`herdr.pinned`。
新 space/tab/split 用 adopt：事件可能先于 reply，按唯一归属、不抢 active、
幂等、`keep:true` 收养真实 id。

---

## 4. 控制面

窗口运行一个本机 unix socket：

- 一行 JSON，一连接一命令；
- 权限 0600；第二个 listener 拒绝启动；退出时 unlink；
- 第二个 app 实例只发 `raise` 然后退出；
- CLI：`kraal commands/ls/status/do/shot`；
- 窗口是唯一写入者；`do` 回读 adopt 后的真实 id，不信调用方猜的 id。

socket 路径：`KRAAL_CONTROL_SOCKET` → `KRAAL_HC_VIEW` 同目录
`control.sock` → `$XDG_CONFIG_HOME/kraal/control.sock`。

---

## 5. 已删除的 Herdr 1 实现

| 删除项 | 原因 |
|---|---|
| `KraalProtocol` / bincode endpoint | 只支持 JSON-RPC |
| `KraalTransport` / `KraalClient` | 由 `KraalHC` 取代 |
| `KraalUI` / `KraalSidebar` / `KraalTerminalView` | 由 `KraalHCTerminal` + Ghostty 取代 |
| cell 网格 / 差分 / ANSI 重编码 | attach 直接给原始字节 |
| 服务端布局 / endpoint busy 重试 | 布局归客户端 |
| SSH 桥 / `herdr machine` 子进程 | 远端归 core |
| 旧 GUI/bench 脚本与旧 probe | 对应旧协议；HC 自动化另起 |
| `KRAAL_HC` 开关、`make run` 旧分支 | 只有一个入口 |

`docs/archive/` 里的旧文档只作历史参考，不再对应当前代码。

---

## 6. 保留的差异

与官方 `herdr-app` 对齐可观察行为（命令面、按键、侧栏模型、文档格式、
控制面词汇），但保留：

- Swift / SwiftUI / AppKit 原生窗口；
- Ghostty（libghostty-spm）做终端渲染；
- 不实现 JS mods；
- AX ratio / 密度档是 Kraal 自有扩展（不影响 `commands --json` 的 69 条）。

---

## 7. 风险与未验证

- Ghostty 的 kitty graphics 像素路径尚未做回归；目前只验证了文本/ANSI。
- Cmd-click 打开 `pane/t7` 需要库提供 openURL/hover delegate，尚未接。
- IME 候选窗、alt-screen 滚轮、文件拖放、`terminal.right_click=program`
  未实现；见 #232。
- GUI 自动化套件已删，重写前 UI 证据靠 VM 手工流程（#235）。
- 性能基线在旧渲染链路上测得，不能代表 HC；#237 重录。
