# 跑起来：新 agent / 新机器 / 迁移

<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

这份是**操作清单**，给第一次进入这个仓库的 agent 或人看。它只回答一个问题：
从 clone 到能验证一个 UI 改动，最短路径是什么。

原理和实测数据在别处：`docs/ENVIRONMENT.md`（环境事实）、
`docs/AUTOMATION.md`（方案）、`docs/DEBUGGING.md`（怎么证明一件事是真的）。
`AGENTS.md` 是行为约定。

---

## 0. 三条铁律

1. **不要在用户的桌面上跑 GUI 验证。** `Scripts/gui.sh` 默认后端就是 `vm`。
   改成 `local` 会夺走用户正在用的指针和键盘——真实发生过，打断了用户干活。
2. **`swift test` 全绿不等于改对了。** 本仓库最难的三个 bug 全部通过了单元测试
   却全部没生效（`AGENTS.md` §0.2）。UI 改动必须过 GUI 门禁。
3. **说「修好了」之前先证明它曾经坏。** 注入 bug → 门禁变红 → 还原 → 变绿。
   见 `docs/DEBUGGING.md` §2。

---

## 1. 从零到绿

```bash
cd <repo>

# CLT 的 swift 缺 XCTest.framework，swift test 会报
# "unable to resolve module dependency: 'XCTest'"——看起来像测试坏了。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

/usr/bin/swift test                        # 基线：应当全绿
/usr/bin/swift build --product KraalGUIDriver   # kraal-gui 驱动（gui.sh 需要它）
./Scripts/verify.sh                       # 六道门禁（见下），自己导出 DEVELOPER_DIR
```

`build-app.sh` 只打包 `Kraal.app`，**不构建 `KraalGUIDriver`**——两者是分开的
产物，漏掉后者时 `gui.sh` 会报 `driver not built`。bash

`verify.sh` 的六道：

| 门禁 | 检查什么 |
| --- | --- |
| `swift build` | 全部 target 编译 |
| `swift test` | 全绿（228 个 `@Test` + 26 个 XCTest 方法；汇总行按参数化合并后报 180 tests / 29 suites） |
| `swiftlint` | 零违规（不在默认 PATH，脚本自己加 `~/.pi-lens/bin`） |
| `shellcheck` | `Scripts/*.sh` 零警告（脚本本身就是门禁的一部分） |
| `build-app.sh` | 打出 `build/Kraal.app` |
| `gui.sh run` | 5 个 UI 用例 / 11 条断言，在 VM 里驱动真实窗口 |

`--fast` 跳过最后两道。`KRAAL_SKIP_GUI=1` 只跳 GUI。

---

## 2. 第一次准备 VM

```bash
./Scripts/vm-bootstrap.sh      # 幂等；已有就只做检查
```

它做五件事：检查 `tart` → 没有就 clone（走 `ghcr.nju.edu.cn` 镜像源）→
headless 启动 → **确认 `launchctl managername` 是 `Aqua`** → 检查三条 TCC 授权。

### 第四条它不查：guest 的实际分辨率

`vm-bootstrap.sh` 不检查这一项，因为 `tart get` 会让人误以为已经对了。
**`tart get` 报 1920x1200 不代表 guest 跑在 1920x1200**：macOS 把实际显示模式
存在 `/Library/Preferences/com.apple.windowserver.displays.plist` 里，那份偏好
优先，`tart set --display` 改不动它。

```bash
tart exec kraal-agent /bin/bash -lc \
  'plutil -p /Library/Preferences/com.apple.windowserver.displays.plist' \
  | grep -E 'Wide|High'
#   "Wide" => 1024 / "High" => 768      ← 这就是窗口会被压到 1004x660 的原因
```

偏差症状：`split-right` / `menu-split` / `split-down` / `close-pane` 四个全绿，
**只有 `drag-divider` 报 `stuck: the drag never reached the daemon`**。看起来像
拖拽回归，实际是屏幕太小。修法（在 guest 里用 CoreGraphics 切模式并
`permanently` 保存）见 `docs/ENVIRONMENT.md` §4.6。

### 三条前置条件，缺了会表现为「产品 bug」

| 检查 | 为什么必需 | 缺了的表现 |
| --- | --- | --- |
| `launchctl managername` = `Aqua` | `tart exec` 落在 Aqua 会话，合成事件才进得了 app。SSH 落在 Background，进不去 | 拖拽/点击类用例全失败 |
| tart-guest-agent 有 `Accessibility` / `PostEvent` / `ScreenCapture` | **被授权的是 guest agent，不是 sshd，也不是 Kraal** | 只缺 `PostEvent` 时 `AXPress` 全绿但拖拽失效；缺 `ScreenCapture` 时截图是全黑 PNG |
| guest 内 SIP 关闭 | 写 `TCC.db` 需要（base 镜像默认关） | 无法授权 |

修复：`./Scripts/vm-bootstrap.sh --fix-tcc`，之后 `killall tccd` 并重启 agent。

细节见 `docs/ENVIRONMENT.md` §4.6。

---

## 3. 日常改一个 UI 功能

```bash
# 1. 改代码
# 2. 打包（VM 里没有 Xcode，必须在宿主做）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Scripts/build-app.sh

# 3. 跑一个用例（每次都会重新部署 + 起干净 daemon）
./Scripts/gui.sh run split-right

# 4. 看断言
#   ✓ pane count grows by one (1 -> 2)
#   ✓ split geometry is two equal halves (ratio=0.5 widths=[59, 60] focused=w1:p2)
```bash

用例列表：`./Scripts/gui.sh list`（`split-right` / `menu-split` / `split-down` /
`close-pane` / `drag-divider`）。

### 加一个新用例

在 `Scripts/gui.sh` 里写四个函数，然后把名字加进 `all_cases`：

```bash
case_focus_pane() {
    requires() { echo ax; }        # 或 echo focus：需要前台，锁屏/local 会拒绝
    fixture()  { ...; }            # 建起始状态，返回 1 = 建不出来
    action()   { driver press --title "Focus Right"; }
    assert()   { check "说明" "$?" "实测值"; }
}
```

两个必踩的坑：

- `before` 必须在 **`fixture` 之后**读。早读会让「只创建了 fixture pane」也满足
  `after == before + 1`，报 pass 但根本没发生动作（踩过）。
- `requires` 的匹配是文本，写 `echo focus` 即可；**不要**依赖格式，
  曾经因为多了个分号导致 `drag-divider` 被静默降级成 ax 用例。

### 加完必须验证它能红

```bash
# 故意改坏被断言的行为，重建，确认对应用例 exit 1
git stash                      # 或手工注入
./Scripts/build-app.sh && ./Scripts/gui.sh run <case>; echo $?   # 期望 1
git stash pop
```bash

---

## 4. 断言写在哪一层

| 档 | 手段 | 用途 | 强度 |
| --- | --- | --- | --- |
| ① | `herdr pane layout`：`splits[].ratio`、`panes[].rect`、`focused_pane_id` | 布局/比例/聚焦 | 最强 |
| ② | AX 树（`kraal-gui ax --json`） | 控件是否存在、是否可 press | 强；终端 pane 内部为零 |
| ③ | 截图 | 错位、遮挡 | 弱，仅辅助 |

- **`pane list` 没有几何**，只有 `pane layout` 有。它俩不是一回事。
- `pane list` 的顺序不稳定（非字典序、非创建序），**按 `pane_id` 建集合比较**。
- 「数量对了」不等于「对了」：注入 `ratio: 0.85` 时数量断言 ✓、几何断言 ✗。

---

## 5. 驱动命令

```bash
D=./.build/out/Products/Debug/KraalGUIDriver
$D probe                                    # AX 授权、能否看见窗口
$D ax --json                                # 整棵 AX 树（agent 读这个）
$D press --title "Split Right"              # 不抢焦点，锁屏也可用
$D menu --menu View --item "Split Right"    # 先展开指定菜单再点
$D click --at X,Y [--right]                 # 窗口相对坐标，需要前台
$D click --at-screen X,Y [--right]          # 屏幕坐标（AX frame 空间），需要前台
$D drag --from X,Y --to X,Y                 # 窗口相对坐标，需要前台
$D key --char w --mod cmd                   # 需要前台
$D window                                   # frame + windowNumber
```

五条实现事实（都踩过）：

- **`AXPress` 不需要焦点**；合成事件需要。锁屏时前台是 `loginwindow`，
  `CGEvent` 会落到空处。
- **AX 图不是树**：`AXMenuBar` 可从 `AXApplication` 和 app children 两条路径到达。
  DFS 必须带 visited 集合，否则 `Split Right` 匹配 13 个元素。
- **窗口几何来自 `CGWindowListCopyWindowInfo`**。macOS 27 上 `AXWindows` 返回
  app 自身、`AXPosition`/`AXSize` 报 AXError -25205（Finder 也一样）。
- **拖拽只发一次 `leftMouseDragged`**。多步会让 `DragGesture.translation`
  累积（实测 16 步 40pt = 9.4 倍）。
- 标题不唯一：`Split Right` 在 View 菜单和右键菜单各一份，用 `--menu` 或
  `--within-*` 限定。`press` 匹配到多个会**拒绝执行**。

---

## 6. 退出码与产物

```text
0  通过
1  断言失败 —— 产品 bug，改代码
2  驱动/环境失败 —— 报 blocker，不要改业务代码
3  被测 app 崩溃
```

不要把 2 当成 1。锁屏、缺 TCC、VM 没起来都属于 2。

产物在 `artifacts/<runid>/`（不入库）：`summary.json`（含 `assertions[]`）、
`ax-before/after.json`、`pane-before/after.json`、`kraal.log`、`app.out`、
失败时 `shot-failure.png`。

**`assertions` 是空的**说明门禁没说它检查了什么——曾经因为 `assert` 跑在子 shell
里，断言全丢而 `status` 仍写 `passed`。

---

## 7. 迁移到另一台机器

代码和脚本跟着 git clone 走。机器上要重建的是三样：工具链、VM 镜像、herdr。

### 7.1 先分清两件事：自己搬家 vs 给别人

这两个场景的最优解**完全不同**，别混：

| 场景 | 做法 | 代价 |
| --- | --- | --- |
| **自己换机器** | `tart export` → 搬文件 → `tart import` | 22GB 中转，导出 32s + 导入 17s |
| **给别人用** | 让对方自己 `./Scripts/vm-bootstrap.sh` | 他拉 26.4GB，实测 **25 分钟** |

**给别人时不要传 .tvm。** 实测确认：公开基础镜像
`ghcr.nju.edu.cn/cirruslabs/macos-tahoe-base:latest` 已经自带全部前置条件——

```text
SIP          disabled     ← 写 TCC.db 所需，镜像默认就是关的
autologin    admin
session      Aqua         ← 合成事件需要，镜像默认就是 Aqua
TCC 授权      Accessibility / Microphone / PostEvent / ScreenCapture 全部 auth_value=2
```

我用这个干净镜像拖了一个新 VM，**没做任何手工配置**，直接
`gui.sh run split-right` → 三条断言全过。所以他只需要 clone 代码 + 跑脚本：

```bash
git clone https://github.com/zzjcool/kraal.git && cd kraal
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Xcode 必需
brew install cirruslabs/cli/tart                                  # 若未安装
./Scripts/vm-bootstrap.sh        # 拉 26.4GB，实测 25 分钟
/usr/bin/swift build --product KraalGUIDriver
./Scripts/build-app.sh
./Scripts/gui.sh run             # 5 用例 / 11 断言
```

他要付的代价，逐项都有实测数字：

| 项 | 代价 |
| --- | --- |
| 基础镜像下载 | 26.4GB，**25 分钟**（走 `ghcr.nju.edu.cn` 镜像源） |
| 磁盘 | VM 50GB 稀疏，实占 **32GB**；tart 缓存再 **30GB** |
| Xcode | **只有 `swift test` 需要**：`Testing.framework`/`XCTest.framework` 只随 Xcode 提供，CLT 里没有。`swift build`、`build-app.sh`、`gui.sh run` 用 CLT 也能跑 |
| guest 内配置 | **零**——镜像已自带 Aqua、SIP off、四条 TCC 授权 |

### 7.2 自己换机器：`tart export` / `import`

只在**想省掉那 25 分钟重装**、或 VM 里攒了不想重做的状态时才值得：

```bash
./Scripts/vm-bootstrap.sh export ~/kraal-agent.tvm    # 实测 32s，22GB
./Scripts/vm-bootstrap.sh import ~/kraal-agent.tvm    # 实测 17s
```

导入后**不要重新 provision**：TCC 授权、SIP、autologin 都在镜像里。实测验证过
导入的副本 `launchctl managername` 仍是 `Aqua`、SIP 仍关闭、4 条授权完好、
用例直接通过。

`import` 拒绝覆盖同名 VM（否则 tart 只回 "is running"，像 tart 的 bug）。
换名字用 `KRAAL_GUI_VM=xxx`。

**给别人时想用 .tvm 也是错的选择**：22GB 文件传输本身就比他自己拉 26GB 快不了
多少，还带来版本漂移——他的镜像会永久冻结在你的 macOS 补丁级别上，而他重新
clone 会拿到最新的。

### 7.3 迁移时最容易静默失效的四个点

这四个的共同点是**不报错，只是行为不对**，看起来都像产品 bug：

| # | 点 | 失效时的表现 | 原因 |
| --- | --- | --- | --- |
| 1 | `launchctl managername` 不是 `Aqua` | 拖拽/点击类用例全失败 | `tart exec` 落在 Background 会话，`CGEvent` 进不了 app |
| 2 | `tart-guest-agent` 缺 `PostEvent` | `AXPress` 全绿，只有拖拽失败 | 被授权的是 guest agent，不是 sshd / Kraal |
| 3 | 缺 `ScreenCapture` | `screencapture` exit 0 但写出全黑 PNG | 无权限时它不报错 |
| 4 | **`brew upgrade tart-guest-agent`** | 上面三条授权**全部失效** | TCC 按绝对路径匹配，而路径含版本号：`/opt/homebrew/Cellar/tart-guest-agent/0.15.0/bin/...`。升级后 `Cellar` 下的版本目录变了，旧条目不再匹配 |

第 4 条是 2026-10-22 查 TCC.db 时发现的：`/opt/homebrew/bin/tart-guest-agent`
是指向 `Cellar/0.15.0/...` 的符号链接，TCC 里存的是解析后的真实路径。
所以 **guest 里升级 Homebrew 包后必须重跑 `--fix-tcc`**。

`vm-bootstrap.sh` 无参数运行会检查上面 1–3；第 4 条它查不出来（授权条目新旧并存，
旧的那条永远"存在"），只能靠「升级后重跑 `--fix-tcc`」这个纪律。

### 7.4 不需要迁移的东西

`gui.sh` 每次 `run` 都会重新推送这些到 guest，所以**不用**装进镜像：

- `kraal-gui`（驱动）
- `Kraal.app`
- `herdr` 二进制

guest 里也**不需要** Xcode（app 在宿主打包）、不需要联网。
本机专属、不应同步：`artifacts/`、`.pi/`、`~/Library/Logs/Kraal-*.log`。

## 8. 已知未完成

| 项 | 状态 |
| --- | --- |
| `local` 后端的 focus 类用例 | 未验证（只在 VM 里验证过） |
| `vm` 后端的失败截图 | 依赖 guest 内屏幕录制授权，未单独验证 |
| 视觉定稿 | 必须 `local` + 真 GPU；VM 虚拟 GPU 的材质不可信 |
| 合盖远程（P3） | 未开始，需先验 `pmset -a disablesleep 1` 与 Tailscale |

细节见 `docs/AUTOMATION.md` §12 与 `docs/ENVIRONMENT.md` §8.7。
