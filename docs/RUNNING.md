# 怎么跑起来

这份是 HC-only 版本的最短路径。只支持 **herdr-core 0.1.16+**（当前实测
`0.1.17`），不再有 Herdr 1 daemon。

## 0. 一次检查

```bash
hc --version
hc server status
xcrun --find swift
```

- `hc` 必须在 PATH 上。没有就装 herdr-core。
- `hc server status` 报 `live: 1` / `status: running`；没有就 `hc server start`。
- `swift` 必须来自 Xcode，不是 CommandLineTools。`swift test` 需要
  `XCTest.framework`，CLT 没有。

## 1. 快速体验

```bash
cd kraal
make run FOCUS=0
```

`make run` 会：

1. 用 Xcode 工具链 `swift build`；
2. 运行 `Scripts/build-app.sh`，生成 `build/Kraal.app`；
3. 直接启动 `KraalMac-bin`，连本机 core；
4. 控制 socket 默认在 `/tmp/kraal-mine/control.sock`。

`FOCUS=0` 到前台；默认 `FOCUS=1` 是后台窗口，不抢键鼠。

停止：

```bash
make stop
```

看日志：

```bash
make logs
```

## 2. 用隔离 core 跑

不要拿正在用的 core 做实验。最小隔离：

```bash
export HC_SESSION=qa
export XDG_STATE_HOME=/tmp/kraal-qa/state
export XDG_CONFIG_HOME=/tmp/kraal-qa/config
hc server start

KRAAL_HC_VIEW=/tmp/kraal-qa/view.json \
KRAAL_CONTROL_SOCKET=/tmp/kraal-qa/control.sock \
KRAAL_KEYS=/tmp/kraal-qa/keys.json \
  make run FOCUS=0
```

或直接启动打包后的二进制：

```bash
KRAAL_HC_VIEW=/tmp/kraal-qa/view.json \
KRAAL_CONTROL_SOCKET=/tmp/kraal-qa/control.sock \
KRAAL_DEV_BACKGROUND=0 \
  build/Kraal.app/Contents/MacOS/KraalMac-bin
```

清理：

```bash
pkill -f KraalMac-bin
HC_SESSION=qa XDG_STATE_HOME=/tmp/kraal-qa/state \
XDG_CONFIG_HOME=/tmp/kraal-qa/config hc server stop
```

## 3. 控制面

```bash
export KRAAL_CONTROL_SOCKET=/tmp/kraal-qa/control.sock
kraal ls
kraal status
kraal do space.new --name demo
kraal shot /tmp/demo.png
```

没有窗口时 exit 2；动作失败 exit 1。`kraal commands` 不需要窗口。

## 4. SSH 直连（未纳管 core）

如果目标 core 没有加进 `hc machine`，或者客户端没有本机 core，可以直接把
`ssh -T host hc connect` 当传输：

```bash
KRAAL_HC_SSH=user@host make run FOCUS=0

# 远端使用隔离会话，避免碰默认 core
KRAAL_HC_SSH=user@host \
KRAAL_HC_SSH_COMMAND='HC_SESSION=qa XDG_STATE_HOME=/tmp/qa/state hc connect' \
  make run FOCUS=0
```

远端 `hc` 必须在非交互 shell 的 `PATH` 上（或写绝对路径）。这条路径不经过
`machine.*`，不会自动重连/管理远端 core；重连由 `HcClient` 以新 ssh 进程重试。

## 5. 测试 / lint / 打包

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

./Scripts/verify.sh          # build + test + lint + shellcheck + app
./Scripts/verify.sh --fast   # 跳过 app
```

单独跑：

```bash
swift test
swift test --filter KraalHCTerminalTests
KRAAL_LIVE_HC_TESTS=1 swift test --filter LiveHcPaneTests
swiftlint --quiet Sources Tests
shellcheck -S warning Scripts/*.sh
```

live 套件会自建 `HC_SESSION` 和临时 XDG 目录，不会碰默认 core。

## 6. 新机器 / VM

宿主：

```bash
./Scripts/vm-bootstrap.sh          # 幂等：检查/创建 kraal-agent + TCC
./Scripts/vm-bootstrap.sh --fix-tcc
```

VM 里没有 Xcode，所以**构建/测试/打包在宿主做**；UI 和截图在 VM 做。
完整配方（推 `hc`、`Kraal.app`、`KraalGUIDriver`，启动隔离 core）见
`docs/AUTOMATION.md`。

## 7. 常见问题

| 现象 | 原因 |
|---|---|
| `no such module 'Testing'` / `XCTest` | `DEVELOPER_DIR` 指向了 CLT |
| `no running Kraal window at ...` | app 没开，或 `KRAAL_CONTROL_SOCKET` 不一致 |
| `hc: ready ...` 后没有 pane | core 在跑，但 layout 文档为空；`kraal do space.new` |
| SSH 连接一直 `connecting` | 远端 `hc` 不在 PATH，或 host key/密钥未授权；看 `HcSSHLink` 收集的 stderr |
| 第二个实例一闪而过 | 已有窗口响应了 `raise`，这是单实例转发，不是崩溃 |
| 点 pane 没焦点 | 检查 `kraal status focused_pane`；HC 点击会同步模型焦点 |
| 屏幕截图全黑 | 窗口被遮挡/无 Screen Recording 权限；用 `screencapture -l <windowNumber>` |
