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
