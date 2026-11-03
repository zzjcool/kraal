# 开发环境实测记录

实测日期：2026-11-02（宿主 macOS 26，Xcode 26）。版本会变，命令以 `--version`
为准。

## 0. 本机

| 组件 | 版本 / 位置 |
|---|---|
| macOS | 26.x（arm64） |
| Xcode | `/Applications/Xcode.app`（必须，CLT 缺 XCTest） |
| Swift | Xcode toolchain（`DEVELOPER_DIR`） |
| herdr-core | `hc` 0.1.17，`~/.local/bin/hc` 或 PATH |
| Ghostty | `libghostty-spm` binaryTarget |
| Tart | `kraal-agent` VM（可选，UI 验证） |

### 工具链坑

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/usr/bin/swift test
```

`/usr/bin/swift` 默认走 CLT；错误是
`unable to resolve module dependency: 'XCTest'`。不要去找 `Testing.framework`，
CLT 也有它；缺的是 `XCTest.framework`。

`swiftlint` 不在默认 PATH：

```bash
export PATH="$HOME/.pi-lens/bin:$PATH"
swiftlint --quiet Sources Tests
```

## 1. herdr-core 路径

```bash
hc server status
```

默认状态目录：

```
$XDG_STATE_HOME/herdr-core/<session>/<session>.sock
$XDG_STATE_HOME/herdr-core/<session>/...
```

`HC_SESSION` 选会话；`HC_SOCKET` 直接覆盖 API socket。测试必须用临时
`XDG_STATE_HOME` / `XDG_CONFIG_HOME`，不要指向真实目录。

Kraal 自己：

| 变量 | 默认 |
|---|---|
| `KRAAL_HC_SOCKET` | `HcPaths.resolve()` |
| `KRAAL_HC_SSH` | 空；设置后走 `ssh -T <host> hc connect` |
| `KRAAL_HC_SSH_COMMAND` | `hc connect`（远端命令） |
| `KRAAL_HC_VIEW` | `$XDG_CONFIG_HOME/kraal/view.json`（实际由 app 解析） |
| `KRAAL_CONTROL_SOCKET` | `KRAAL_HC_VIEW` 同目录 `control.sock`，否则 `$XDG_CONFIG_HOME/kraal/control.sock` |
| `KRAAL_KEYS` | `~/.config/kraal/keys.json` |
| `KRAAL_DEV_SESSION` | 由 control/view 路径派生 |
| `KRAAL_DEV_BACKGROUND` | debug launcher 默认 `1` |

socket 路径必须 ≤103 字节（macOS `sun_path`），测试一律放 `/tmp`。

## 2. Tart VM

```bash
tart list
tart run --no-graphics kraal-agent
./Scripts/vm-bootstrap.sh
```

- 基础镜像 `ghcr.nju.edu.cn/cirruslabs/macos-tahoe-base:latest`（国内镜像）。
- VM 内必须 `launchctl managername` = `Aqua`，否则合成事件到不了 app。
- 三条 TCC：Accessibility、PostEvent、ScreenCapture，授予
  `tart-guest-agent`；写 TCC.db 需要 guest 内 SIP 关闭。
- `--fix-tcc` 用于升级 Homebrew 包后授权丢失；只在需要时跑。
- VM 没有 Xcode：build/test/package 在宿主，VM 只跑产物。

### 文件传输

`tart cp` 不存在。用：

```bash
tar czf - -C build Kraal.app | tart exec -i kraal-agent /bin/bash -lc 'tar xzf - -C /tmp/...'
tart exec kraal-agent cat /tmp/file > ./file
```

### 导出/导入

```bash
./Scripts/vm-bootstrap.sh export ~/kraal-agent.tvm   # ~22GB，几十秒
./Scripts/vm-bootstrap.sh import ~/kraal-agent.tvm
```

不要把 `.tvm` 直接给别人：它冻结在你的 macOS 补丁级别。给对方基础镜像 +
`vm-bootstrap.sh` 更稳。

## 3. GUI 验证

`./Scripts/gui.sh` 是三层 GUI 门禁（`client` / `core` / `pixels`），默认 Tart VM
`kraal-agent`；`local` 需要 `KRAAL_GUI_ALLOW_HOST=1`。命令、隔离和注入证据见
[AUTOMATION.md](AUTOMATION.md)。门禁没覆盖的 UI 改动仍按那里的 VM 手工配方：
隔离 `HC_SESSION`、推 `hc`/`Kraal.app`/`KraalGUIDriver`、`KRAAL_DEV_BACKGROUND=0`
启动、用 `kraal ls/status` 断言。

宿主锁屏只影响**宿主桌面**的 AX/CGEvent；VM 内 `tart exec` 仍是 Aqua 会话，
不受影响。

## 4. 已知坑

| 现象 | 原因 / 处理 |
|---|---|
| `no such module 'XCTest'` | `DEVELOPER_DIR` 指向 CLT |
| `No such module 'KraalHCTerminal'` | SourceKit-LSP 跨工具链误报；`swift build` 绿就忽略 |
| `kraal ls` exit 2 | 没有窗口，或 control socket 路径不一致 |
| SSH 一直 connecting | 远端 `hc` 不在 PATH / host key / 密钥；`HcSSHLink` 会把 stderr 带进错误 |
| 第二个实例立即退出 | 已有窗口收到 `raise`，单实例转发，正常 |
| AXPress 无效 | VM 未处于 Aqua，或 TCC 丢失 |
| 合成键盘不到窗口 | `KRAAL_DEV_BACKGROUND=1` 时 `.accessory` 无法 frontmost；验证键盘用 `0` |
| 截图全黑 | 窗口被遮挡/无 ScreenCapture；用窗口 id 截 |
| `sun_path` 报错 | socket 路径超过 103 字节，换到 `/tmp` 短路径 |
