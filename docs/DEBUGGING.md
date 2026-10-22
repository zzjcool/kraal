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

## 9. 路径含版本号 = 授权会静默失效

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
