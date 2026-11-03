# UI 验证（VM + 控制面）

旧 `Scripts/gui.sh` 和 44 个 Herdr 1 用例已删除。HC 的自动化重写在
[#235](https://github.com/zzjcool/kraal/issues/235)；在那之前，UI 改动按本文
在 Tart VM 里留证据。原则不变：**断言 core/控制面状态，不猜测我们发出的请求**。

## 0. 为什么在 VM

驱动真实窗口会抢走指针和键盘。VM 是 `kraal-agent`（Tart，headless），
`tart exec` 落在 guest 的 Aqua 会话里，宿主锁屏不影响 VM 内的窗口、AXPress、
合成键盘和 `screencapture`。

```bash
./Scripts/vm-bootstrap.sh          # 创建/检查 VM + Aqua + TCC
./Scripts/vm-bootstrap.sh --fix-tcc
```

## 1. 宿主准备

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Scripts/build-app.sh
swift build --product kraal-gui
swift build --product kraal
```

VM 里没有 Xcode，所以产物都在宿主构建。

## 2. 推进 VM

`tart cp` 不存在；用 tar 流。以 `/tmp/kraal-hc-gui` 为例：

```bash
VM=kraal-agent
ROOT=/tmp/kraal-hc-gui
RUN=$ROOT/run
mkdir -p "$RUN/bin" "$RUN/state" "$RUN/config"

# app bundle（保留可执行位）
tar czf - -C build Kraal.app | tart exec -i "$VM" \
  /bin/bash -lc "rm -rf $ROOT/Kraal.app && tar xzf - -C $ROOT"

# driver + CLI
for bin in kraal-gui kraal; do
  tar czf - -C .build/out/Products/Debug "$bin" | tart exec -i "$VM" \
    /bin/bash -lc "mkdir -p $RUN/bin && tar xzf - -C $RUN/bin && chmod +x $RUN/bin/$bin"
done

# core 二进制：路径以 which hc 为准
tar czf - -C "$(dirname "$(command -v hc)")" "$(basename "$(command -v hc)")" \
  | tart exec -i "$VM" /bin/bash -lc "mkdir -p $RUN/bin && tar xzf - -C $RUN/bin && chmod +x $RUN/bin/hc"
```

取回文件用 `tart exec "$VM" cat /path`（不要用不存在的 `tart cp`）。

## 3. 启动隔离 core

```bash
tart exec "$VM" /bin/bash -lc "
  cd $RUN &&
  HC_SESSION=qa \
  XDG_STATE_HOME=$RUN/state \
  XDG_CONFIG_HOME=$RUN/config \
  $RUN/bin/hc server start
"
```

确认：

```bash
tart exec "$VM" /bin/bash -lc "
  HC_SESSION=qa XDG_STATE_HOME=$RUN/state XDG_CONFIG_HOME=$RUN/config \
  $RUN/bin/hc server status
"
```

socket 是 `$RUN/state/herdr-core/qa/qa.sock`。

## 4. 启动 app

```bash
tart exec "$VM" /bin/bash -lc "
  KRAAL_HC_SOCKET=$RUN/state/herdr-core/qa/qa.sock \
  KRAAL_HC_VIEW=$RUN/view.json \
  KRAAL_CONTROL_SOCKET=$RUN/control.sock \
  KRAAL_KEYS=$RUN/keys.json \
  KRAAL_DEV_SESSION=qa-ui \
  KRAAL_DEV_BACKGROUND=0 \
  $ROOT/Kraal.app/Contents/MacOS/KraalMac-bin >$RUN/app.log 2>&1 &
"
```

- `KRAAL_DEV_BACKGROUND=0` 是**合成键盘**的前提；否则 `.accessory` 无法成为
  frontmost，`CGEvent` 不会落到窗口。
- `KRAAL_HC_VIEW` 同目录会派生 `control.sock`；显式给路径避免和别的窗口撞。
- 日志：`~/Library/Logs/Kraal-qa-ui.log`（guest 内）。
- 启动后看 `hc: control listening at ...` 和 `hc: ready core=...`。

## 5. 用控制面取证据

```bash
tart exec "$VM" /bin/bash -lc "
  KRAAL_CONTROL_SOCKET=$RUN/control.sock $RUN/bin/kraal ls
"
tart exec "$VM" /bin/bash -lc "
  KRAAL_CONTROL_SOCKET=$RUN/control.sock $RUN/bin/kraal status
"
```

动作：

```bash
tart exec "$VM" /bin/bash -lc "
  KRAAL_CONTROL_SOCKET=$RUN/control.sock \
  $RUN/bin/kraal do pane.split --direction right
"
```

断言要看 `ls` / `status` 的前后差异（pane 数、tab、focus、scrollback、
document version），不是看动作返回的 `ok`。

## 6. 驱动 UI

```bash
DRV="$RUN/bin/kraal-gui"

# 截图全窗口
tart exec "$VM" /bin/bash -lc "$DRV shot -o $RUN/shot.png"
tart exec "$VM" cat "$RUN/shot.png" > /tmp/shot.png

# AX 树
tart exec "$VM" /bin/bash -lc "$DRV ax --json" > /tmp/ax.json

# 点击、按键、打字、滚轮
tart exec "$VM" /bin/bash -lc "$DRV click --at 640,400"
tart exec "$VM" /bin/bash -lc "$DRV key --char k --mod cmd"
tart exec "$VM" /bin/bash -lc "$DRV type --text 'rename'"
tart exec "$VM" /bin/bash -lc "$DRV scroll --at 640,400 --lines -3"
```

`kraal-gui press --title X` 遇到重名（菜单 vs Edit 菜单）时用
`--allow-ambiguous` 或 `--within-*`。`click` 目前没有 `--mod`，Cmd-click
需要后续扩展。

## 7. 取证清单

一个 UI 修复至少留：

1. 失败现象（截图或日志）；
2. 触发前后 `kraal ls` / `status` 的 JSON diff；
3. 成功状态截图；
4. 日志里对应的 `hc:` 行；
5. 如果改了 wire/字段，附 core 侧 `hc get/list/read --json` 证据。

## 8. 清理

```bash
tart exec "$VM" /bin/bash -lc "pkill -f KraalMac-bin || true"
tart exec "$VM" /bin/bash -lc "
  HC_SESSION=qa XDG_STATE_HOME=$RUN/state XDG_CONFIG_HOME=$RUN/config \
  $RUN/bin/hc server stop || true
"
```

不要 `pkill -f KraalMac`：会连启动器一起杀，且可能匹配到别的会话。
