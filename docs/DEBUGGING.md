# 排查方法

这份文档不描述代码怎么工作，只记录**怎么验证一件事是真的**。

Kraal 有一类 bug 特别费时间：终端渲染错乱、切换机器后内容不对、点击没反应。
它们的共同点是**看起来像 A，实际是 B**，而每一次我都先按 A 的方向查了一轮。
下面每一条都对应一次真实白跑，写下来是为了下次少跑那一轮。

---

## 1. 样本本身要能区分「正确」和「错误」

**事故**：用户报「启动后终端空白，切一次 tab 才显示」。我复现时用一个只有 `#`
提示符的空 shell，看到屏幕上只有 `#`，判定「只渲染了第一行」，然后花了几轮去查
`SurfaceANSIRenderer` 的输出行数和 Ghostty 的 tick。

那个 pane 本来就只有 `#`。**图像完全正确，我查的是一个不存在的症状。**

换成有内容的 pane（写几行 `echo`）之后，真正的现象才露出来：**整片空白，连 `#`
都没有**。这和「只画一行」是两个完全不同的方向。

> 样本没内容时，空白和正确长得一模一样。
>
> 动手前先问：这个样本在「对的」和「错的」两种情况下，屏幕上分别是什么？

## 2. A/B 回退能复现，比修完看起来对更重要

修完截图正常，只说明「现在没坏」。把改动 stash 掉还能复现原症状，才说明修的是
那个原因。

```bash
git stash push Sources/SomeFile.swift
./Scripts/build-app.sh && ./Scripts/dev-session.sh start
# 截图：应该复现原症状
git stash pop
```

三个渲染 bug 的结论都是这样确认的。其中「pane 越界」那次，回退后日志从
`grid=118x40` 回到 `grid=128x40`、pane 宽度 977pt 回到 1062pt（越界 58.5pt），
这才敢说修对了。

## 3. 探针要测对对象

**事故**：怀疑 `.position` 让 NSView 撑满父容器，于是我读 `PaneFrameReporter`
的 frame，得到 `actual=1088x742`（容器尺寸），自以为证实了猜测。

那个 reporter 挂在 `.position` 之后的 `.background` 里，**本来就被设计成占满
容器**——源码注释写得很清楚，它靠「容器 rect + pane offset」反算命中区域。

真正该测的是终端视图本身。换一个 scout 用 `swift -` 从 stdin 编译最小复现，
测出的是 `TERM-w1:p1 frame=(0,0,1062,333)`——尺寸正确、位置正确。**我的结论是错的。**

> 加探针前先确认：我读的这个值，是谁写的？它应该是多少？

## 4. 删临时探针不要用跨行正则

**事故**：用 `re.sub(r"\n *// PROBERESET\n.*?\n *\}\n", ...)` 清一段探针，正则
吞掉了 `apply` 后半段的 `guard let grid`、grid mismatch 校验和 `reportCellMetrics`。
文件从 497 行掉到 460 行。

是提交前 `git diff` 看到「删除了 40 行」才发现的。

> 删探针用精确文本匹配（`edit` 工具），不用跨行正则。
>
> 每次清理后必须看 `git diff --stat` 的行数变化是否符合预期。

## 5. 临时改动是一个完整动作，不是一步

加探针只是第一步。完整动作是：

1. 加探针
2. 跑起来验证
3. **还原代码**
4. **用干净环境重启**（清环境变量、清日志）
5. **再确认一次**现象符合预期

只做前两步的后果：下一次启动带着上次的 `launchctl setenv` 或残留代码跑，看起来
像「bug 没修好」。这类事故发生过两次（`KRAAL_SHOW_MACHINES`、
`KRAAL_SHOW_SETTINGS`）。

## 6. 点击自动化：先激活，再谈坐标

在后台会话里点控件没反应，第一怀疑对象是**窗口不在前台**，不是命中区域坏了。

```bash
osascript -e 'tell application "System Events" to tell process "KraalMac-bin" to set frontmost to true'
```

不激活就点，事件落到别的窗口，表现是「点了完全没反应」，和「hit area 有死区」
一模一样。

**但激活之后仍然点不中，那就真的是布局问题**——这时该去查
`.frame` / `.padding` / `contentShape` 的实际数值，而不是继续微调坐标。机器行
那次就是：行高 20pt，两个热区都只有 16pt，上下各留 2pt 死区，而行距是 0，
于是每两行之间有连续的 4pt 无响应带。

## 7. 没有证据时，说「没验证」

跨机器 paneId 撞车那条修复，只有单元测试覆盖。我一度说「无法验证，因为只有一台
daemon」——这是错的，沙箱里完全可以再起一个 session（见
[ENVIRONMENT.md §4.4](ENVIRONMENT.md)）。

真正该做的是：**先判断「造不出条件」是不是事实**。多数时候不是，是没想到；
确实造不出来时，就明说哪一条没被验证，不要用「逻辑上应该对」代替证据。

## 8. 「检查通过」可能只是检查没跑

**事故**：`vm-bootstrap.sh --fix-tcc` 从来没生效过，而我两次在文档和回复里说
「它会自动写 TCC 授权」。两个叠加缺陷：

1. 分派处写的是 `provision`（无参数），而函数内用 `"${1:-}" = "--fix-tcc"` 判断
   —— 参数永远进不来，分支进不去。
2. 写入没加 `sudo`：`TCC.db` 是 `root:wheel 0644`，普通用户直接报
   `attempt to write a readonly database`。

真正致命的是它的**输出**：什么都没做，却打印 `ok: all three granted`。
因为分支没进去，连"检查缺失"那一步都没执行。

> **一条命令既检查又修复时，必须先确认它能报出「缺」。**
> 否则「通过」只意味着它没看。

验证这类工具的标准是 **A/B 三步**，缺一步都不算：

```
手工制造缺陷  →  工具必须报错
工具修复      →  必须报"已修"
复查          →  必须报健康
并且，缺陷态下功能用例必须真的失败
```

这次实测：删掉 `kTCCServicePostEvent` → 报 `missing grants` → `--fix-tcc` 报
`granted` → 复查 `all three granted` → `drag-divider` 两条断言全过。

**推论**：任何"检测 + 修复"脚本，第一次运行前先在**已知健康**的环境里跑一遍，
确认它报健康；再手工破坏，确认它报缺失。只验后者会漏掉"永远通过"。

**同日第二例（`gui.sh` 的断言与退出码脱钩）**：`check` 把失败记进
`ASSERTION_FAILURES`，但 `run_case` 只按 `fixture`/`action`/`assert` 的**返回码**
判成败。`assert` 最后一条 `check` 通过就返回 0，于是一个打印了
`✗ the app sent the text as a paste event` 的用例被判为 **passed**，退出码 0 ——
门禁对它专门要抓的那个 bug 无法失败。

它是一次真实观察暴露的：`paste` 用例的第一版 `assert` 以失败的 `check` 开头、
以通过的 `check` 结尾，输出 `✗ … ✓ …` 却显示 `ok: paste passed`。
修法是让 `ASSERTION_FAILURES > 0` 直接参与判定。

> **一条门禁必须能红。** 写完断言先故意让它失败一次（本次是 A/B 回退成
> `sendInput`），看到退出码 1 才算这条门禁存在。

## 9. 前提错了，测试只会加固错误

前八条讲的是「怎么验证代码对不对」。这一条讲更前面的一步：
**代码符合了你的理解，而你的理解是错的。**

**事故**：issue #20 第 7-7 条，daemon 发的 `ClientShellKeyboardReportAll`
被丢弃。`docs/GAP-VS-HERDR.md` 那句写在先：

> "Kitty keyboard 模式的 pane 是否拿到 key release 完全取决于这个开关。"

据此推出的修法很自然：开了 report-all，就该把 key 事件的
`tracksRelease` 也置为 true —— 否则「程序知道要收 release、事件里却说没有」。
改完 7 处、补上测试、`verify.sh` 全绿、A/B 回退也能红，**然后把它合并了**。

第二天一份只读侦察报告指出上游把这两件事拆成两个开关。核实：

| 概念 | 由什么决定 |
|---|---|
| 宿主是否上报所有按键 | `ClientShellKeyboardReportAll`（`render.rs:205-226`） |
| 一个 press 之后是否会跟 release | key 自身 `generated_text.is_none() \|\| has_physical_identity()`（`protocol/wire.rs:315`） |

真正致命的是 daemon 怎么用这个字段：

```rust
// server/clients.rs:275-311
Key { kind: Press, tracks_release: true, .. } => {
    shell_held_inputs.insert(id, ..);   // press 被挂起，等配对 release 再发
}
```

而 Kraal **从不产生** `ClientKeyKind.release`（`.release` 有定义、编码器也支持，
但全仓零调用点）。所以「修好」的版本会让**开了这个模式的程序完全收不到按键** ——
比原来的静默丢弃更糟。

### 为什么所有门禁都没拦住

| 门禁 | 为什么无效 |
|---|---|
| `swift test` | 测试是**按错误前提写的**：断言 `tracksRelease == true`。前提错，测试就是把错误焊死 |
| A/B 回退 | 删掉修复 → 红。它证明的是「测试在这行代码上生效」，不是「这行代码是对的」 |
| `verify.sh` 全绿 | 只说明代码符合我的理解 |
| 代码审查 | 没有第二轮独立视角 |

> **测试的断言方向由前提决定。前提错了，测试只会加固错误。**

### 唯一有效的检查

**回到上游代码确认字段语义，而不是相信文档摘要。**

这次有效的动作是二选一：

1. 读发出方：`wire.rs:315` 那行 `tracks_release = ...` 的**实际表达式**
2. 读消费方：`clients.rs:275-311` 怎么用这个布尔

其中 (2) 更关键 —— 它告诉我**这个字段一旦为 true 会发生什么**（挂起输入），
而 (1) 只告诉我它在什么条件下为 true。**能看出后果的那个方向，才拦得住错误。**

### 沉淀成规则

- **改 wire 字段前，先找消费方**。协议文档只说字段叫什么，消费方的代码才决定
  它意味着什么。
- **`docs/` 的性质断句要分开看**。「上游代码在第 X 行做了 Y」可核实；
  「A 取决于 B」是**推演**，会错。本文自己就出过这种错。
- **A/B 回退证明不了方向**。它能证明「测试覆盖了这行」，不能证明「这行是对的」。
  两件事都成立才算修好。
- 修完之后留一条**反向断言**：把「错误做法」写成测试。这次的正解是
  `report-all-keys does not claim to track releases` —— 断言即使
  `reportsAllKeys == true` 也不得声称跟踪 release。反向断言比正向断言更能
  防住「同一个人第二次犯同一个错」。

对应提交：`766836a`（错误的修复）→ `d5aed59`（撤回并修正文档）。

## 10. 路径含版本号 = 授权会静默失效

TCC 的 `client` 列存**解析符号链接后的绝对路径**，而 Homebrew 的 Cellar 路径含
版本号：

```
TCC 里存:  /opt/homebrew/Cellar/tart-guest-agent/0.15.0/bin/tart-guest-agent
实际执行:  /opt/homebrew/bin/tart-guest-agent -> ../Cellar/.../0.15.0/bin/...
```

`brew upgrade` 之后符号链接指向新版本目录，TCC 里那条旧路径再也没有进程匹配。
**条目仍然存在**，所以"授权在不在"的检查永远通过，而症状和完全没授权一样。

> 按路径授权的东西，路径里不能有版本号；有的话，升级就是一次静默失效。

同类风险：`python` 的 venv 路径、`node` 的 nvm 路径、`/Applications/Foo 1.2.app`。
检查这类问题时**不要只查条目存在**，要查 `client` 值是否等于当前实际运行的路径：

```bash
ps -Ao comm | grep foo        # 实际在跑的
# 和 TCC/config 里记的比对，而不是只数条数
```

---

## 11. 一个观察面代替不了另一个：AXTitle ≠ AXValue

要自动化地「点某一行」，会自然地去找那一行的 `AXTitle`。SwiftUI `Text` 不给：

```text
$ kraal-gui ax --json --depth 20
AXStaticText title='' desc='' id='' value='alpha-b'
```

一行文本的内容在 **`AXValue`** 里，而 `AXTitle`/`AXDescription` 都是空的。产品代码也没写
`accessibilityIdentifier`（`Selector.swift` 开头就写明零个）。所以按 title 找元素时：

```text
$ kraal-gui press --title "alpha-b"
kraal-gui: no element matching title=alpha-b
```

这看起来像「界面没画出来」，实际上是**读错了属性**。同样的分叉出现在按钮上：面板里的
`Rename` / `Remove` 只有 `AXDescription`、`AXTitle` 为空（`press --desc Rename` 就成功）。

**教训**：换一种元素类型就重新确认一遍属性面。一次 `ax --json --depth 20 | grep` 就能回答
「这个控件到底把文字放在哪个属性上」，比猜三次快。

**并且不要再猜「怎么写法才能出 `AXTitle`」。** 2026-10-23 在 macOS 27.0.1 / 26A434 上
逐个实测了 20 种 SwiftUI `Button` 写法（朴素、`label:` 闭包、`.borderless`、`.help`、
`Label`、`.bordered`、`.borderedProminent`、`.link`、`.keyboardShortcut`、
`.accessibilityLabel`、`.accessibilityElement(children:)`、`.accessibilityRepresentation`、
`.accessibilityValue` …），**全部** `title=''`，文字都在 `AXDescription` 里；同一个窗口里
裸的 AppKit `NSButton` 则**带** title。为排除「title 存在但不是 String」这个混杂因素，
还把 driver 临时改成打印 `CFTypeID` —— 那些属性的 `copy()` 直接返回 nil。

所以在本项目里：

| 元素 | 文字在 | 能不能 `press --title` |
| --- | --- | --- |
| SwiftUI `Text` | `AXValue` | 不适用 |
| SwiftUI `Button` | `AXDescription` | **不能**，用 `--desc` |
| AppKit `NSButton` | `AXTitle` | 能 |

issue #71 当初的判断（`.borderless` + `.help()` 是原因、`.accessibilityLabel` 会写 title）
**两条都不对**：`--title` 在 SwiftUI 上不可达，而 `.accessibilityLabel` 改的是 `desc`。
所以那个 issue 的正解不是「补 title」，而是**让 desc 唯一**：机器面板的行内按钮现在叫
`Rename <机器名>` / `Remove <机器名>`，rename sheet 打开时 `desc=Rename` 从 3 个候选降回
1 个，`press --desc` 不再需要 `--index` 猜。

**推论**：门禁不要断言不可达的属性。`Scripts/gui.sh` 的 `machines-controls` 因此
**故意不测** `--title`，只测「每个控件有一个唯一稳定的 desc」—— 断言一个永远不可能成立
的东西，比没有门禁更糟。

`kraal-gui ax` 现在同时输出 `value`，`press`/`select` 也支持 `--value` —— 但**侧边栏行仍然
点不动**：`onTapGesture` 不响应 `AXPress`，真实点击只能靠 CGEvent，而这就又回到了
「先激活窗口，再算坐标」。定位可以用 `value`（`Scripts/gui.sh` 的 `sidebar_row_point`），
点击不行。

---

## 12. 坐标有两个坐标系，混用不报错，只是点错地方

`kraal-gui ax` 的 `frame` 是**屏幕坐标**（`CGWindow` 那个空间），`kraal-gui click --at` 的参数
是**窗口相对坐标**：

```swift
let clamped = CGPoint(x: window.frame.origin.x + offsetX, y: window.frame.origin.y + offsetY)
```

VM 里窗口在 `(0, 350)`，所以把 AX 的 `y=729` 直接传给 `click --at` 得到的是
`screen(590,1087)` —— 已经在窗口内容区之外。而**它不会报错**，只会点到别的东西或者什么都不点。

实测症状：重命名 sheet 的输入框“点不中”，`type` 报 `typed via AX` 但名单没变，看日志像
「提交按钮没触发」。真实原因是焦点从未到达输入框 —— 三层错误叠在一起，而最底层那个是
两个坐标系。

**教训**：坐标类工具第一次用先做一次往返验证（点一个已知元素，从那边的日志/状态确认命中），
不要拿它去诊断别的问题。用 `ax` 读元素，把那个**屏幕**坐标原样交给 `click --at-screen`；
只有自己按窗口几何算出偏移时才用 `click --at`（窗口相对）。

**已修（issue #72）**：`click` 加了 `--at-screen`，且越界不再 clamp。原实现是

```swift
let clamped = CGPoint(x: window.frame.origin.x + min(max(offsetX, 0), width - 1), …)
```

越界点被拉到窗口边缘，点击「成功」、用例后面的断言失败，读起来像产品 bug。现在两种形式都
先校验落点在窗口 frame 内，越界 `fail(.harness, …)` 退出码 2，消息里带窗口 frame 和实际
算出的屏幕坐标。回归护栏是 `Scripts/gui.sh run click-coordinates`，它同时断言：
`--at-screen` 原样点、`--at` 只加一次窗口原点、三种越界/混用各自被拒。

判据用**窗口 frame**而不是内容区：AX 把 window 元素报成整个 frame（含标题栏），
而 app 确实会往标题栏画东西，按内容区收窄会在没证据的前提下拒掉合法点。

### 12.1 同一类错误的第二个方向：原点之外还有**方向**（issue #103，2026-10-25）

修完「屏幕 vs 窗口」这个空间混淆后，同一个像素断言又量错了一次，因为还有第二个自由度：
**y 从哪一端数**。

- `pane_window_rect` 输出的是 **top-down**（y 从顶边往下，和窗口布局一致）
- `CGContext` / `CGImage` 的位图行号是 **bottom-up**（y 从底边往上）

`CGRect.intersection` 不报错，`context.draw` 也不报错。实测症状：断言报
`matched=4032`（绿），但这个 4032 是从**另一条带子**里数出来的，恰好 blob 在两条带子的
交集里。判据是 `sampled`：请求 `959×664 = 636776`，实际 `301126 = 959×314`。

两个空间错误叠加时更难看出来，因为**数字都在合理范围内**。护栏有两条，缺一不可：

1. `sampled == w * h * scale²` 的**对账断言** —— 它不看内容，只看「量的地方对不对」
2. 驱动在裁剪发生时**报错退出**，而不是静默缩小区域 —— `fail(.harness, "region clamped
   from WxH to WxHx — the rect and the image are in different coordinate spaces")`

还有一条只对「值不值得信」有用的：`--match` 的谓词解析**不能 fail-open**。实测一个笔误
`r>>200` 让断言从「图在不在」退化成「恒真」——`Int(">200") ?? 0` 把比较符吃掉了。
断言变恒真是最坏的一类假绿：它绿得比真绿还稳。

**这一条的要害**：翻转像素读法的变体我试了三个才对（`-minY` 反、`+minY` 全 0、
`-(imageHeight - maxY)` 正确），**三个变体都不报错** —— 前两个只是给了错的数。所以
「推导出来的」不算数，注释里记的是实测出来的那一个。

---

## 附：观察工具

```bash
# 只截自己那个窗口，不需要激活、不需要 Accessibility
screencapture -x -o -l "$(./Scripts/dev-session.sh status | grep -oE 'window: +[0-9]+' | grep -oE '[0-9]+')" out.png

# CLI 探针：不启动 UI 也能看 surface 内容
.build/debug/kraal --socket /tmp/kraal-mine/herdr-client.sock screenshot

# 两台 daemon 是否真的不同机器
.build/debug/kraal --socket <A> | grep ^boot
.build/debug/kraal --socket <B> | grep ^boot
```

Ghostty 用 Metal 绘制，AX 树几乎是空的，所以**不要指望用 Accessibility 读终端
内容**——读屏幕内容用 `kraal screenshot`，读渲染结果用窗口截图。

### TOML 手写解析的三个真实缺陷（2026-10-22）

`KeybindingProfile` 手工解析 daemon 的 `[keys]` 表（不引入 TOML 依赖，理由见该
文件头注释）。第一次实现有三个 bug，全部「静默丢数据」而不是报错——用户看到的是
「我改的配置没生效」，而不是「解析失败」。

| 缺陷 | 原因 | 用户看到 |
| --- | --- | --- |
| 多行数组整块丢失 | 先按 `\n` 切行，再逐行解析。`prefix = [` 那一行没有 `]`，被跳过；续行没有 `=`，也被跳过 | 该绑定从面板消失 |
| `key = "a\"b"` 被丢弃 | `scalar` 拒绝任何内部含引号的值 | 合法配置变成缺失行 |
| `split_vertical = "prefix+["` 吞掉后续 | 计数括号时不区分是否在字符串内 | 该行之后的所有绑定消失 |

**判断依据不是「TOML 允许什么」，而是「daemon 会发什么」**：`prefix = ["ctrl+a"`
后跟新语句在真实 TOML 里是**语法错误**，daemon 不会产生它。所以解析器实际面对的是
**截断文档**（写到一半被杀），此时括号不平衡就无法区分「续行」与「新键」。正确做法是
把余下内容视为该值的一部分、并在 flush 时丢弃这个不平衡的值——前面已读到的绑定保留。

一条老测试本来断言相反（跳过 `[` 行、保留 `new_tab`），那个期望是错的，已改。

### 第二轮 review 又抓到一类：注释

修复后的版本仍有一个 major：**值末尾的 `#` 注释从不清除**。

| 输入 | 后果 | 实测 |
| --- | --- | --- |
| `new_tab = "prefix+t"  # see [docs` | 注释里的 `[` 让 `bracketDelta` 报 1，后续所有行被当成续行 | **整张表 0 条** |
| `prefix = ["ctrl+a"]  # note` | 值不以 `]` 结尾，一个绑定丢失 | 1 条（应为 2） |
| `[keys]  # the keys table` | 表头全等比较失败 | **整张表 0 条** |

所以现在**先剥注释再解析**，且剥离必须 string-aware（`prefix+#` 里的 `#` 不是注释）——
用 `split(separator: "#")` 会引入新的一类丢数据。

另一条 minor：`\n` 转义会解成真换行，`trimmingCharacters` 只去首尾，中间的换行留在绑定里
（SwiftUI 渲染成行高不齐）。改为一律拒绝含换行的项，而不是静默压成 `ab`——后者会显示
一个不存在的绑定。

注入验证（第二轮，三条都能红）：

| 注入 | 结果 |
| --- | --- |
| 关掉注释剥离 | ✘ 4 条 |
| 注释剥离改成朴素 `split(separator: "#")` | ✘ `a hash inside a quoted binding is kept` |
| 只 trim 不拒绝中间换行 | ✘ `an escape-decoded newline does not become a multi-line binding` |

第一轮注入验证（三条都能红）：

| 注入 | 结果 |
| --- | --- |
| 关掉多行续接 | ✘ `a multi-line array binding is not dropped` |
| 括号计数忽略引号 | ✘ `a bracket inside a quoted binding is not a bracket` |
| `scalar` 重新拒绝内部引号 | ✘ `an escaped quote inside a binding is resolved, not rejected` |
