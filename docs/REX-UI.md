<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
-->

# Rex 的界面里有什么值得借的

实测日期 **2026-10-30**。对象是本机安装的 Rex Beta（`0.0.1793299046-g2307b7`，
pid 26952，窗口 1440×2530pt）。方法只有两种：**截图它的真实窗口**，以及**读它
自己的资源文件**（`Rex Beta.app/Contents/Resources`），加上 `rex -C <client>
actions --json` 导出的动作目录。没有猜的部分会标明「未验证」。

> 结论先写在这儿：Rex 的「好看」不是一条配色，而是三样东西拼起来的——
> **①一整套命名的主题（41 个，每个带 70 个语义色角色）**、**②材质层**
> （玻璃/模糊的 5 种风格，可切）、**③密度**（紧凑/舒适两种行高，正文与
> 元信息分两级字号）。Kraal 目前有 ①的骨架（19 个角色、18 个主题名，
> 来自 herdr），没有 ②的选择器，也没有 ③。

---

## 1. 屏幕上实际看到的东西

窗口从上到下：

1. **左栏（约 200pt）**：顶部一行小图标（三个开关 + 新建），下面按 **主机**
   分组的会话列表。每行是 `图标 + 名称 + 右侧状态点`；名称过长用 `~/kmt`
   这样把家目录折成 `~`，再长才截断。当前会话整行有底色，不靠加粗。
2. **主区分栏头部**：会话名 + 四个小按钮（清屏、重连、终端里搜索、设置）。
3. **命令块（blocks）**：每个「用户输入 → 程序输出」是一个**带边框的卡片**，
   卡片头是 `$ 命令`，卡片体是输出，卡片尾是 **`Took 0.5s`** 这样的元信息；
   还没结束时是一行 `Thinking…`；被折叠的输出显示
   `… (10 earlier lines, ctrl+o to expand)`。这是 Rex 的签名结构。
4. **底部活动条**：CPU / Memory / Network / Tokens 四块，每块一个数字 +
   一条点阵 mini 折线。不是状态栏文字，是**指标**。
5. 再往下是 shell 自己的 powerline prompt（不是 Rex 的 UI）。

窗口本身：圆角、深色、分隔用**极弱发丝线**而不是 Divider 的默认灰。

## 2. 它的设计令牌（从资源文件读出来的）

`Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json`：

```
41 个主题，每个：
  id / name / appearance(dark|light)
  source   : background, foreground, cursor, cursorText,
             selectionBackground, selectionForeground, ansi[16]
  semantic : 70 个角色 —— canvas / surface / surfaceSubtle / surfaceRaised /
             stroke / strokeSubtle / control(+Hover/Pressed) /
             content / contentSecondary / contentTertiary /
             accent(+Solid/OnSolid/Container/Border/Ring/Dim/Line) /
             danger|success|warning|info 各自 6 个 /
             terminal* 全部映回 source
  displayP3: 同上一份，用 color(display-p3 …) 表达
```

`MaterialStyles-{System,Modern,Sequoia,BlendTheme,UseTheme}.json`：
**材质是独立一层**，按 `appearance × density(comfortable|compact) × 状态` 描述
`window.glass` / `activePane.backdrop` 的开关、圆角模式、颜色。也就是说
「换皮」和「换玻璃」是两件事。

语义色不是手填的：把 `surface` 与 `background` 比一下，`canvas == background`，
`surface` 是 background 提亮一点，`stroke` 是再提亮一档，`contentSecondary` 是
foreground 向 background 混；每个主题各自的 accent 决定整条 accent 家族。
**这套角色是从 `source` 推出来的**，主题作者只写 6+16 个终端色。

## 3. 动作目录（`rex actions --json`）

每个动作带 `name / kind / title / category / keywords / args`：

```json
{"name":"client.theme.change","category":"View","keywords":"theme colour color scheme palette appearance"}
```

- `keywords` 是给人搜的：终端里叫 `client.theme.change`，用户打「colour」也该找到。
- `category` 是给面板分组用的（View / Pane / Session / Tab / Host …）。
- `args` 有 schema，所以 `rex do client.theme.change name=…` 不需要额外的帮助页。

Kraal 的 `AppCommand` 有 58 条、标题与菜单一致，但**只有标题可搜**，命令面板
也只放了 4 个内置动作 —— 菜单能做的事，面板里一半找不到。

---

## 4. 对照表：Rex 有 / Kraal 现在怎样

| 能力 | Rex | Kraal（2026-10-30） |
|---|---|---|
| 命名主题 | 41 个，自带深浅 | 18 个名字，**来自 herdr 的 `[theme]`**，客户端不自带主题文件 |
| 语义色角色 | 70 个（含 danger/success 家族） | 19 个（accent/surface/text/状态色） |
| 外观模式 | `appearance.switch_mode`（light/dark/auto） | 有 `auto_switch`，但只能在 `config.toml` 里改 |
| 换主题 | `theme.change`（模糊匹配）+ `theme.import` | 改 `config.toml` 后 `Reload Config` |
| 材质 | 5 种可选（System/Modern/Sequoia/…） | 一档玻璃（`.glassPanel`），无选择器 |
| 密度 | 紧凑 / 舒适 | 一种 |
| 字号 | `font.increase/decrease/reset` | **无**（cell 尺寸由引擎默认） |
| 命令面板 | 全部动作 + keywords + category | 4 个内置 + 用户命令 + Go To，**只按标题子串过滤** |
| 搜索 | `find.open`（终端内） | 无 |
| 提示符跳转 | `prompt.previous/next` | 无 |
| 面板均衡 | `pane.balance` | 无 |
| 命令块 | 每段输出一张卡片 + 耗时 | 无（直通 VT 网格） |
| 活动条 | CPU/内存/网络/token mini 图 | 状态栏文字（attention 计数） |

## 5. 这一轮借了什么

**命令面板 = 全量命令 + 关键字 + 分类 + 模糊排序**（Rex 的做法，见 §3）。

- `Sources/KraalUI/AppCommandCatalog.swift`：`AppCommand.Category`
  （workspace/tab/pane/view，带 SF Symbol）、`AppCommand.keywords`（38 条同义词，
  `toggleZoom` 可被 "max"/"fullscreen" 找到），编号家族（`focus_workspace_N`）
  用规则生成而不是抄 9 份。
- `Sources/KraalUI/PaletteSearch.swift`：纯函数排序。分词后**每个词都必须命中**；
  命中标题 > 关键字 > 分类；整词 > 前缀 > 子串；≥3 字符才做子序列模糊。
- `Sources/KraalUI/CommandPalette.swift`：行来自 `AppCommand.allCases`，
  走 `perform(command, on:env:)` —— **和菜单同一条路径**，不是第二份实现；
  重命名这类需要对话框的命令由面板自己弹（`renamePrompt`）。
- `RootView` 把菜单那套 `CommandEnvironment` 传进面板（侧栏/状态栏开关、
  设置、快捷键、copy mode）；`KraalMacMain` 提供 copy mode 的入口。
- 测试 `Tests/KraalClientTests/PaletteSearchTests.swift` 12 条：空查询保序、
  "max"→Toggle Pane Zoom、"kill"→三个 Close、双词 AND、"tzm" 子序列、
  每条命令都有关键字、每条命令都能用自己的 id 词搜到。

**密度两档**（`Toggle Sidebar Density`，Rex 的 `client.sidebar.density.toggle`）：

- `KraalUI/Density.swift`：`comfortable`（= 历史值，行内上下各 2pt、选项卡 4pt）与
  `compact`（行内 0、选项卡 2pt）。**逐面写死而不是乘一个系数** —— 乘系数要求每个
  `padding(...)` 都记得乘，漏一处就是半紧凑。
- 环境值 `\.density`，行/选项卡自己读；`WindowActions.densityToggleCount` 让菜单
  能触发，`UserDefaults["KraalSidebarDensity"]` 持久化。
- 门禁 `sidebar-density` 量的是**行距**（两个侧栏标签在 AX 里的 y 差）：`19 → 15 → 19`。

**字号三键**（`Increase / Decrease / Reset Font Size`，Rex 的 `client.font.*`）：

- `KraalUI/FontScale.swift`：基准 13pt（libghostty 自己的默认）、步长 1、范围 8…32，
  纯函数。
- `PaneTerminalPool.fontSize` → `withFontSize`；改了丢模型重建（和背景/主题同一套）。
- 关键坑：**清掉模型不够** —— 视图手里还握着旧的模型引用，没有别的变化就不会重新取。
  `WindowActions.fontChangeCount` → `RootView` 给 `PaneLayoutView` 的 `.id()`
  换一个身份，树重建才会走到 `pool.model(for:)`。第一次跑门禁时 cell 8.5 → 8.5，
  就是这一步缺着。
- 日志：`terminal font: 15 (change=increase)`；门禁断言 `layout:` 里的 `cell=`。

**主题目录 = Ghostty 的开源主题文件**（2026-10-30 追加）。

- `Sources/KraalUI/Resources/themes/` 里是 **51 个 Ghostty 主题文件**，逐字复制，
  `ATTRIBUTION.md` 记来源与许可（Ghostty / iTerm2-Color-Schemes，MIT）。
- `Sources/KraalProtocol/GhosttyTheme.swift`：解析 `palette = N=#hex` /
  `background` / `foreground` / `cursor-*` / `selection-*`；**只缺 required 键才返回
  nil**（背景、前景、16 色必填），坏文件被跳过而不是半应用。
- `Sources/KraalUI/Palette+Ghostty.swift`：**19 个界面角色全部从这 6+16 个颜色
  推出来**（surface = 背景向文字混 5/9/14%，overlay/subtext 反向混，状态色 = ANSI）。
  这就是 §2 里 Rex 的做法，只是角色少一些。
- `Sources/KraalUI/ThemePicker.swift` + `Change Theme…` 命令：带色卡预览的选择器，
  搜索复用 `PaletteSearch`；选中写 `UserDefaults["KraalThemeName"]`，
  `KRAAL_THEME` 环境变量优先（门禁用）。第一行是「Follow config.toml」= 撤销。
- 终端侧：`PaneTerminalPool.ghostty` / `PaneTerminal(ghostty:)` 把前景、光标、
  **16 个调色板色**交给引擎（`withForeground` / `withCursorColor` / `withPalette`）。
  没选主题时仍走原来那条：只有背景与选中色。
- 日志：`theme: applied X (source=ghostty|config appearance=…)`、
  `terminal theme: <name> fg=… bg=… ansi1=… ansi4=…`。

测试：`GhosttyThemeTests` 8 条（格式/坏文件/短 hex/亮度）、
`GhosttyThemeCatalogTests` 10 条（**51 个文件全部解析**、id 唯一、深浅分组、
名字各种拼写、派生角色单调、**每个主题 fg/bg 亮度差 >0.25**、pick 覆盖 config、
未知 pick 回退）。

**没有借的，以及为什么：**

- **主题文件本身**：Rex 的 `themes.json` 是它的资产，直接拷进 Kraal 会有授权问题。
  可以借的是**结构**（source + 派生语义角色 + 显式覆盖），配色另找开源方案。
- **命令块**：需要 shell 集成（OSC 133）并改写渲染路径（Kraal 画的是 VT 网格，
  不做整屏重排）。代价远大于收益，除非将来做「输出折叠」。
- **活动条**：Kraal 的指标在 daemon 侧不一定有（CPU/内存要本机采样，跨机还要
  走 socket），先不做。

## 6. 下一步（按性价比排）

1. ~~字号三键~~ 已完成（见 §5）：门禁 `font-size` 断言 cell `8.0 → 9.0 → 8.0`，
   并抓到了「清模型不重建视图」这个真 bug。
2. ~~主题选择器~~ 已完成（见 §5），且**没有**动用户的 `config.toml`：
   选中的主题只是客户端覆盖，`config.toml` 仍是默认值的来源。
3. ~~密度切换~~ 已完成（见 §5）：行距 `19 → 15 → 19`，选项卡同档。
4. **语义角色补齐**：把 `danger/success/warning/info` 家族加进 `Palette`，
   现在这些状态色是散在视图里的 `.red`/`.green`。

## 7. 怎么验证这一轮

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/usr/bin/swift test --filter PaletteSearchTests     # 12 条
PATH="$HOME/.pi-lens/bin:$PATH" swiftlint --quiet Sources Tests
```

**未验证的部分**：命令面板在真实窗口里的样子（sheet 的文本框是否自动获得焦点、
58 行滚动是否顺手）只做过 `swift build` 与单测，没有 GUI 断言。要补的门禁是
一条 `palette-search` 用例：`do --item "Command Palette"` → 输入 "kill" →
Return → `herdr tab list` 从 2 条变 1 条；注入「把 `commandItems` 换回 4 个内置」
应当变红。这条在 VM 里跑之前不能算数。
