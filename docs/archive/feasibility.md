# iOS 原生 Herdr 客户端 — 可行性评估

> 调研时间：2026-10-20 · 本机 herdr 0.9.4（protocol 22），远端实测 0.9.1 / 0.9.4
> 结论先行：**技术上完全可行（分两层，难度差一个数量级）；但同类项目已严重过饱和，需要想清楚差异化。**

---

## 一、Herdr 的 "machines" 到底是怎么连的（实测）

### 1.1 保存的机器列表是**客户端本地状态**，不在服务端

```
~/.local/state/herdr/client/endpoints.json          # SSH 机器目录（id/label/target/session/enabled）
~/.local/state/herdr/client/ssh-metadata/<id>.json  # 每个机器的 os / herdr 可执行文件绝对路径缓存
```

**实测反证**：本机 `herdr machine list --json` 有 3 台；在远端 `hw-nj` 上执行
`herdr machine list --json` 返回 `[]`。

→ 所以 iOS App **不能"从服务器读到同一份 machines 列表"**。要么让用户在 App 里自己填（等于重建一份目录），
要么从跑着 herdr 客户端的 Mac 上把 `endpoints.json` 同步过来（SSH / iCloud / 扫码）。
如果你要的是"看到远程机器上的 workspaces / agents / panes"，那是另一回事 —— 那个完全可行（见 1.3）。

### 1.2 一台机器被添加时需要做的事（Herdr 的真实行为，已抓到 argv）

`herdr machine add` 的本质 = 能力探测 + 起后台 server + 存一条 profile：

```bash
# 能力探测（非交互）
ssh <target> /bin/sh -c '<herdr> --session <name> remote-api-bridge --check'   # → herdr-api-bridge-v1

# 真正的 API 通道（每次请求一条 SSH 连接）
ssh -C -F <临时config> -S <controlpath> -o ControlMaster=auto -o ControlPersist=600 \
    -o BatchMode=yes -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 -o ConnectionAttempts=1 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -T <target> \
    /bin/sh -c 'exec <herdr> --session <name> remote-api-bridge'
```

要点：`-C` 压缩、ControlMaster 复用、`BatchMode`（**不弹密码**）、keepalive 15s×4。
SSH 认证完全交给 OpenSSH，Herdr 自己不存任何凭证。

### 1.3 三层协议（决定工作量）

| 层 | 传输 | 公开程度 | 能做什么 |
|---|---|---|---|
| **A. JSON API** | `remote-api-bridge` 的 stdin/stdout NDJSON；或直连 `herdr.sock` | **正式公开**（`herdr api schema --json`，128 个方法，protocol 22） | 列 workspace/tab/pane/agent、读输出、发 prompt、发按键、建 tab、worktree… |
| **B. 事件流** | 同一个 socket 上的 `events.subscribe`（订阅后长连接推送 NDJSON） | **正式公开** | `pane.agent_status_changed` / `workspace.focused` / `tab.*` 等实时推送 |
| **C. 实时终端字节流** | ① `herdr terminal session observe\|control`（NDJSON + base64 ANSI 帧）<br>② 桌面客户端的 `remote-client-bridge` binary endpoint protocol（`endpoint.hello.v1` / `shell.surface.v1` / `TerminalHello` / `ClientShellHello`） | ① **公开**<br>② **未公开**（只有 codec 名字与 `endpoint_protocol_generation: 1`） | ① 单 pane 观察/接管（输入、resize、scroll、mouse）<br>② 和桌面端逐像素一致的整屏渲染 + 多机联邦 |

**重要实测约束**：`herdr.sock` 与 `remote-api-bridge` 都是 **一条连接只服务一个请求/响应**（除 `events.subscribe` 会保持长连接推事件）。
连续发第二个请求会 BrokenPipe。所以客户端必须做"连接池 / 请求并发上限"（ssh 侧受 `MaxSessions`，默认 10 限制）。

### 1.4 测到的真实延迟（这台 Mac → hw-nj，同局域网/公网混合）

| 方式 | 单次往返 |
|---|---|
| `ssh` + ControlMaster 复用 + `herdr api snapshot` | **20–60 ms** |
| `herdr --machine <label> agent list`（CLI 全流程，含进程启动） | 400–500 ms |
| 裸 `ssh`（无 ControlMaster） | ~250 ms |
| 本机 unix socket 直连 | 1 ms |

`api snapshot` 一次返回 12 workspaces / 15 panes / 7 agents ≈ 19.6 KB。
→ **首屏用 snapshot，后续用 events 增量**，这个模型在移动网络上成立。

---

## 二、难点分层（决定这活值不值得做）

### 易（1–2 周级）：只读 + 轻控制
- SSH 客户端（`libssh2` / `swift-nio-ssh`）连上 → 跑 `herdr api snapshot` 或 `remote-api-bridge` → 解 JSON → SwiftUI 原生列表。
- 能做：Agent 列表（按 blocked/working/done 排序）、workspace/pane 树、`pane.read` 拉最近输出、`agent.prompt` 发一句话、`pane.send_keys` 发 Esc/Ctrl-C/Tab。
- 依赖：`herdr >= 0.7.x`；SSH 一侧只要 OpenSSH 默认配置（不需要开 stream-local forward，因为走 exec 通道）。

### 中（2–4 周级）：真终端
两条路，选一：
1. **`herdr terminal session control <pane> --takeover --cols --rows`**（推荐起步）
   - 实测：0.5 s 内出首帧，之后按需推 `{"bytes":"<base64 ANSI>"}`；stdin 收 `terminal.input / resize / scroll / mouse / release`。
   - 文档明确它**不依赖**桌面端的私有 endpoint 协议，是给第三方 bridge 用的。
   - 缺点：一次只能控一个 pane；且是"接管"，会抢走桌面端的输入/尺寸所有权（`--takeover`）。
2. 反解 `remote-client-bridge` 的 endpoint 协议 → 和桌面端一致的多 pane 整屏渲染。
   - 收益大、代价大：协议未公开、版本会动（`endpoint_protocol_generation`），本质上是在跟一个每周发版的私有协议赛跑。

终端渲染引擎：iOS 上现实选择只有 `libghostty-spm`（Metal，MIT，但静态链入过 LGPL 的 libintl，需审查版本）或 `SwiftTerm`（MIT，成熟但 Metal 默认关、手势要自己写）。

### 难（跨版本持续投入）：后台与推送
- iOS 进后台 ≈ 5 s 后挂起，`beginBackgroundTask` 实测只有 **25–30 s** 额度（Heeler 把 grace 设成 15 s 到点主动断开）。
  → **SSH 长连接在后台必然死**，"agent 变成 blocked 时通知我"必须靠推送。
- APNs 需要服务端持有 `.p8`（且与 bundle id 绑定）→ **必须自建一个 relay**。
- 隐私友好的做法（Heeler 已实现）：主机侧插件用 per-host 密钥 AES-GCM 加密后再 POST，relay 只签 JWT 转发密文，看不到内容。
- Live Activity 的 `content-state` **无法端到端加密**（系统要自己解码），只能牺牲部分隐私。

### App Store 层面（不是拦路虎，但要做功课）
- SSH/开发者工具非受限品类，Heeler 已上架（Developer Tools，4+，iOS 18+，免费，10 个评分）。
- 审核需要可用的 demo：SSH 客户端无法给真实主机 → 需要内置 demo 模式（**待验证**实际接受度）。
- 出口合规：SSH 属豁免加密，声明 `ITSAppUsesNonExemptEncryption = NO`（Heeler 就是这么做的）。
- 4.2.7 远程桌面条款是否套用到 SSH shell：**待验证**（Heeler 未被卡）。

---

## 三、竞品现状：这是红海，不是空地

App Store 搜 "herdr" 有 **27 条**相关，其中 herdr 专属原生 iOS App 至少 10 个；GitHub 上 `herdr-mobile` / `herdr-client` topic 还有十几个半成品。

| 项目 | ★ | 技术栈 | 连接方式 | 上架 | 备注 |
|---|---|---|---|---|---|
| **ZingerLittleBee/Heeler** | 612 | Swift 6 + libghostty + libssh2 | **SSH direct-streamlocal 直连 `herdr.sock`** | ✅ 免费 | 赛道标杆：Console / Composer / 真终端 / QR 配对 / E2EE 推送 + Live Activity / SFTP / Chat 读 transcript |
| jerryfane/herdrup | 231 | Swift + Citadel | SSH，**需装作者 fork 的 herdr** | ✅ | Gram 式对话、预测输入、Guest 分享 |
| AltanS/collie | 1401 | TS PWA | `tailscale serve` | ❌ PWA | 说 "never funnel"；多机 Crews |
| devswha/herdr-web-ui | 1215 | TS PWA | 插件起本地服务 + tailscale | ❌ | Chat↔终端互切、Web Push |
| kosumic/whip | 107 | React Native + Rust(russh) | SSH 直连，零服务端 | ✅ iOS+Android | 终端显示延迟宣称 31 ms median |
| cobanov/herdrchat | 24 | Expo RN | SSH | ✅ | 聊天气泡优先 |
| multiplex-term/Multiplex | 15 | Swift + SwiftTerm | SSH，主打 tmux | ✅ Vision/iPad/iPhone | |
| lucasscariot/herdie | 5 | Swift + Rust core | SSH 直连 | ✅ | 已停滞 ~6 周 |
| 0cv/herdr-mobile-relay | 300 | Go + Web | 自建 relay / CF Tunnel / WebRTC | ❌ PWA | AGPL |
| patricio0312rev/anyssh | 9 | Swift + libssh2 | SSH 通用客户端 + herdr 适配 | ✅ | |

**共性事实**：
- 除 Moshi（573 评分，但是通用 SSH/mosh 终端）外，**所有 herdr 专属 App 评分数 0–10**，没人跑出规模 → 需求真实但盘子小。
- 状态仪表盘 / 聊天气泡 / 按键板 / 附件 / QR 配对 / worktree —— 这 6 项每家都有，重做等于零差异。
- 唯一走 `direct-streamlocal`（真 socket 协议而不是 CLI）的只有 Heeler。其余多数是在 SSH 上跑 CLI 解析 JSON。

**官方态度**：
- `herdrdev` 组织只有 `herdr`、`herdr-nix` 两个仓库，全 Rust，**没有任何移动端仓库**；客户端矩阵写的是 "TUI · CLI · plain SSH, more coming"。
- 官方对"手机"的唯一投入是 **TUI 窄屏布局**（`ui.mobile_width_threshold`）+ 文档里教用户 `ssh` 上去跑 herdr。
- **但 Herdr Cloud 已经挂在官网上等 waitlist**："Your machines. One Herdr. No SSH setup." —— 一旦落地，会直接抹平所有第三方靠"SSH + Tailscale/relay 配对"建立的差异化。

---

## 四、结论与建议

### 可行性：成立
- 你要的"填完连接信息 → 用原生界面看远程 herdr 的 workspace/agent/终端"，**没有任何协议层面的拦路石**，全部是公开 API。
- 只读+轻控制版：1–2 周能出可用 Demo；加真终端 2–4 周；加推送+后台 再加 2–3 周（含 relay）。

### 三点必须提前接受的事实
1. **machines 列表是客户端本地的**。App 里必然要重建一份（或从 Mac 同步 `endpoints.json`），不存在"服务端读出同一份"。
2. **一条连接一个请求**。所有性能和稳定性设计都绕这个展开（连接池 + ControlMaster 复用 + snapshot/events 增量）。
3. **不做 `remote-client-bridge` 私有协议**就别指望做到和桌面端一致的整屏渲染，只能做单 pane 接管（`terminal session control`）。

### 如果真要做，建议的切入姿势
- **协议层照抄 Herdr**：能力探测 `remote-api-bridge --check` → 常态走 `remote-api-bridge`（NDJSON），SSH 参数照抄（`-C`、ControlMaster、keepalive、BatchMode）。
- **不要重写局域网穿透**：把 Herdr Cloud 当作"未来的免费连接层"，自己只做 UI 层价值。
- **差异化只能在还没被占的地方**：Agent 审批/Review 闭环（行内批注直接回传给 agent）、语音即控制流、watchOS/Vision/灵动岛常驻态势、团队席位与审计留痕。纯"又一个终端 App"没有胜算。
- **最小可验证实验**（1 天）：拿一台 Mac 当 relay 都不用，直接 App 里 `ssh hw-nj '/usr/bin/herdr api snapshot'`，渲染出 agent 列表 + `agent.prompt` 发一句话 —— 这就已经能验证 80% 的产品假设了。
