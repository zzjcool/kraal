# 性能测量

`docs/DEBUGGING.md` 讲「怎么验证一件事是真的」，这份讲**怎么量出一件事有多贵**。

两者失败方式不同。调试的失败是「验证了错的对象」；测量的失败是**量出一个数字，
而它根本不是你以为了那个操作的成本**。Swift 在这方面格外刻薄：优化器会删掉它
认为无用的工作，合成数据会和真实数据长得一样但行为不同。

下面每一条都对应本轮实测踩到的坑，数字来自 `85bb4c0` 之后的 release 构建
（Apple M4 Pro VM，8 核 / 16 GB）。

---

## 0. 先跑一遍

```bash
./Scripts/bench.sh            # 两条热点路径
./Scripts/bench.sh render     # 编码成 VT
./Scripts/bench.sh patch      # patch 应用
```

它自己编译一个探针、链接 `.build/release/libKraalProtocol.a`、打印每项耗时与
折算帧率。**必须用 release**：debug 下的数字比 release 慢一到两个数量级，
两个实现之间的相对差会完全不同。

---

## 1. 没被消费的结果会被删掉

**事故**：第一次跑基准，`no-op diff` 报 **0.3 us**。同一份工作换个写法测出来是
**1050 us**。差距 3500 倍，不是波动。

原因是循环里 `renderer.render(frame)` 的返回值没被用。编译器能证明这个调用在
迭代之间结果相同、且无副作用，于是**只保留一次** —— 循环在测「跑一个空转发」。

三条防法，缺一条都可能被骗：

```swift
// 1. 让输出逃逸到全局，编译器无法证明它无用。
nonisolated(unsafe) var sink: UInt64 = 0
sink &+= UInt64(renderer.render(frame).count)

// 2. 不要拿恒定输入喂有状态的 API。renderer 的 `previous` 让它有状态，
//    但输入不变时「第二次调用」依然可被折叠。交替两帧：
for i in 0 ..< n { renderer.render(i % 2 == 0 ? second : first) }

// 3. 把 checksum 打印出来。一行 "checksum 496491600" 就能让人相信
//    循环真的跑了 n 次（也方便发现两次运行的输入不同）。
```

实测三种写法，同一次渲染：

| 写法 | 结果 |
|---|---|
| 复用 renderer + 同一输入 | 0.36 us ← **假的** |
| 每轮新建 renderer（付首帧成本） | 1580 us |
| 复用 renderer + 交替两帧 | 1547 us |

> 数字比预期小一个数量级时，先怀疑它没在跑，而不是先庆祝。

## 1b. 两份数据不能共享存储

比「结果没被消费」更隐蔽的一类：**两次输入是同一个值**。

`Array`（以及其中元素的）比较在两侧**共享同一块 buffer** 时会直接短路返回
`true`。于是「内容完全相同的两帧」如果传的是同一个 `FrameData`，逐格比较一遍
都不用做。

实测同一份 200×50 内容：

| 写法 | `changedRows` 成本 |
|---|---|
| 相同内容，**共享存储**（`first: frame, second: frame`） | **0.15 us** |
| 相同内容，**独立存储**（两次 `decodedFrame`） | **60.1 us** |

差 400 倍。而且它骗过了本仓库的基准：

```
no-op diff      0.33 us（错，共享存储）   →   86.9 us（对，真实解码帧）
```

> 这条比 §1 更该警惕：§1 的错误会让数字**整体偏小**，容易被「这也太快了」察觉；
> 这条只会让**某一个用例**偏小，其余数据全部正常，看上去像「no-op 确实很便宜」。

**判据**：任何「内容相同、应该走同一路径」的对照用例，都必须**各自构造一遍**。
在本仓库里就是两次 `decodedFrame(width, height)`，绝不复用同一个值。

`Scripts/bench.sh` 现在有一道自检，直接验存储地址而不是比时间（比时间是在测
探针，不是在测风险）：

```swift
let sameBuffer = first.buffer.sharesRow(0, with: second.buffer)
```

粒度是**行**而不是整帧，因为 #50 之后 cell 存在一行一个 CoW 数组里（`CellBuffer`）。
`sharesRow` 就是为此存在的：`Array` 的相等比较会在两侧共享同一块 buffer 时短路，
而逐格断言看不到这件事。

注入 `first: frame, second: frame` 会让它打印 `YES -> BROKEN` 并以退出码 1 结束
（已 A/B 验证）。

## 2. 合成数据要和真实数据同形

**事故**：用 `[CellData](repeating: blank, count: 10000)` 造帧，测出深拷贝
**39 us**；换成逐格构造的帧（每格独立 `String`），同样的 CoW 仍然是 39 us，但
**整帧渲染的成本差了 3 倍**。

`repeating:count:` 让 10000 个 cell 共享**同一个** `String` 实例。ARC 操作全部
命中同一块引用计数，而真实解码出来的帧里每格各有自己的 `String`。凡是要测
retain/release、分配、缓存局部性的东西，这两种形状不可互换。

```swift
// 造得像解码结果：每格独立。
func decodedFrame(_ width: UInt16, _ height: UInt16, seed: UInt32 = 0) -> FrameData {
    var cells = [CellData]()
    cells.reserveCapacity(Int(width) * Int(height))
    for index in 0 ..< Int(width) * Int(height) {
        cells.append(CellData(
            symbol: String(UnicodeScalar(UInt8(97 + (index + Int(seed)) % 26))),
            foreground: UInt32(index % 8), background: 0x1E1E1E,
            modifier: 0, skip: false, hyperlink: nil))
    }
    ...
}
```

> 造样本时问一句：生产环境里这些值是不是同一个实例？

## 3. 拆到能单独归因

一个「整帧 1500 us」的总数不能直接变成 issue。要能说清钱花在哪，否则修的时候
只能猜。这轮用三种拆法：

**A. 单项隔离** —— `FrameData.validate()` 单独测 3.1 us，证明它不是瓶颈。

**B. 对照实验** —— 把样式改成「统一样式」，若 SGR 只需输出一次、成本应大幅下降：

| render 200×50 | 耗时 |
|---|---|
| 统一样式（样式从不变化） | **1229 us** |
| 样式每格都变 | 1628 us |

统一样式仍然 1229 us → **「样式变了才输出」这个优化没有生效**。这一条对照直接
定位了 issue #49 的根因：`StyleCode.encode` 在每格循环里无条件调用，结果被丢弃。

这条对照原本是临时脚本，**没入库**——所以它既无法复跑，也没人会发现它失效。
现在它是 `./Scripts/bench.sh render` 的一个正式用例（`every row changed, uniform`），
并且配了一条自检：两种帧的样式数必须真的不同（`varied > 1 && uniform == 1`），
否则打印 `BROKEN` 并 exit 1。注入回归（把 uniform case 的 `foreground: 3` 改回
`index % 8`）已 A/B 验证会红。

**C. 复现最小动作** —— 直接测 `[String]` 建 + `joined(";")` 10000 次 = 961 us，
与整帧 1500 us 中的 ~1230 us 对上，确认这确实是主要成本。

> 对照实验的价值：它能把「总体慢」变成「这行代码在做无用功」。

## 4. 分清「稳态」和「最坏情况」

同一个渲染器在不同输入下的成本差 5000 倍：

| 场景 | 80×24 | 200×50 | 300×80 |
|---|---|---|---|
| 首帧（pane 出现） | 305 us | 1506 us | 3589 us |
| 冗余快照（内容不变） | 17.2 us | 86.9 us | 209 us |
| 打字（1 格变化） | 29.7 us | 118 us | 257 us |
| **整屏滚动（每行都变）** | **297 us** | **1546 us** | **3603 us** |

只报「平均」会把这些全糊掉。提性能问题时**必须写清是哪一档**，并说明它在真实
使用中对应什么操作（`tail -f`、`htop`、全屏滚动 → 落到最贵那一行）。

注意「冗余快照」这一档**不是免费的**：内容完全不变时仍要全量扫行做比较，
200×50 要 86.9 us、300×80 要 209 us —— 和「1 格变化」几乎同价。这条曾经被记成
0.29 us（共享存储导致的假象，见 §1b），据此得出的「no-op 可以忽略」是错的。

### 4b. #49 修掉之后的数字（2026-10-23 实测）

「整屏滚动」这一档还要再分一次，因为**样式数是独立的一个维度**：

| render 200×50，每行都变 | 修前 | 修后 | 倍数 |
|---|---|---|---|
| 统一样式（一整屏一个颜色） | 1378 us | **209 us** | **6.6×** |
| 样式每格都变（8 个命名色循环） | 1488 us | 1458 us | 1.02× |

修前这两行只差 1.08 倍 —— 这就是 §3 B 那个对照的定量版本：样式数几乎没有影响，
说明编码器对每格都在跑。修后差 7 倍，说明它只在样式真的变化时跑。

**`every row changed` 那一档没有变快，这是正确的。** `bench.sh` 的 `decodedFrame`
把前景色按 `index % 8` 循环，所以相邻格样式都不同 —— 10000 格里有 10000 次真实的
样式变化，编码器必须跑 10000 次。剩下的 ~0.14 us/格 是 `StyleCode.encode` 自己的
成本（建 `[String]` + `joined`），要再快得改 `encode` 内部的字符串拼接，与 #49
的「结果被丢弃」不是同一件事。而统一样式（真实终端最常见的形态：一整屏同色文本）
降到 0.02 us/格，那部分才是纯浪费，已经消掉。

## 5. 折算成帧预算

微秒数字对没写过渲染的人没有直觉。折算成「60 fps 每帧 16.7 ms 里占多少」：

```
每 patch 37.4 us × 60 patch/s × 4 panes = 9.0 ms/帧 (54% 预算)
```

这一句比「37.4 us」更能说明为什么要修。`Scripts/bench.sh patch` 直接把这列打出来。

注意**乘上 pane 数**：单 pane 看着无害的开销，四个 pane 时按倍数叠加。

## 6. 本地微基准之后，要对真实 daemon 再测一遍

微基准能定位「哪一行浪费」，但**不能回答「用户会不会感受到」**。本轮就有一段
必须打到真 daemon 才看得清的差别：

- 微基准说 `Task { }` 是解码成本的 50 倍（5.8 us vs 0.115 us）→ 看起来像问题
- 真 daemon 上 200 次 Task-per-send，**没有一次超过 1 ms** → 不是问题

方法：复用 `gui.sh` 的 scratch daemon（它已经保证不碰你自己的 workspace），
用 `EndpointConnection` 直连，把探针编成可执行文件推进 guest 跑。

```bash
# 起隔离 daemon（与 gui.sh 同一套隔离约定）
tart exec kraal-agent /bin/bash -lc '
  rm -rf /tmp/perf; mkdir -p /tmp/perf/herdr-home
  export HERDR_SOCKET_PATH=/tmp/perf/herdr.sock HOME=/tmp/perf/herdr-home
  nohup /tmp/kraal-gui/bin/herdr server > /tmp/perf/server.log 2>&1 &
  sleep 3; /tmp/kraal-gui/bin/herdr workspace create --cwd /tmp'

# 探针要链接客户端两个库
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/usr/bin/swiftc -O -o probe probe.swift \
  -I .build/release -L .build/release \
  -lKraalClient -lKraalTransport -lKraalProtocol

# 推进 guest 再跑（注意 socket 在 guest 里，宿主机连不上）
cp probe push/ && tar -czf - -C push probe | tart exec -i kraal-agent \
  /bin/bash -lc 'mkdir -p /tmp/perf/bin && cd /tmp/perf/bin && tar -xzf - && chmod +x probe'
tart exec kraal-agent /bin/bash -lc 'cd /tmp/perf/bin && ./probe /tmp/perf/herdr-client.sock'
```

两个坑：

- **socket 路径在 guest 内**，宿主机 `connect()` 会 `No such file or directory`。
  必须把探针推进去跑。
- `EndpointConnection` 是 actor，`start()` / `sendPaneInput()` 都是 async。
  在同步脚本里要 `Task { } + DispatchSemaphore` 包一层；但**测得这层包装本身
  只有 5.8 us**，不会污染结论。

## 7. 多次运行，看波动而不是单次

单次读数可能是冷缓存。每项跑三次，看离散度：

```
full reps=2000 per=1505.7us
full reps=2000 per=1524.4us
full reps=2000 per=1524.3us      ← 三次差 < 2%，可信
```

如果三次差 10 倍，那说明还有别的变量在动（首次分配、JIT、调度），此时应该先
找出它，而不是取平均。

---

## 8. 不要用现成 CLI 当计时器

`kraal` CLI（`Sources/KraalCLI/KraalCLI.swift`）看上去是最顺手的探针：一条命令就能
握手 + 拿 surface。**它内置两处固定等待，会让任何端到端计时失真**：

| 位置 | 代码 | 后果 |
|---|---|---|
| `KraalCLI.swift:244` | `Task.sleep(nanoseconds: 20_000_000)` | 等 surface 的轮询间隔 → **计时精度下限 ~20 ms** |
| `KraalCLI.swift:389` | `Task.sleep(nanoseconds: 200_000_000)` | `runInput` 发送前硬等 → **测按键延迟必须扣掉 200 ms** |

本轮实测印证：`kraal screenshot` 在 80×24、120×40、200×60 三种尺寸下分别是
42-47 ms、81-115 ms、43-79 ms —— **不随尺寸单调**。主导项是进程启动与那两处
sleep，不是解码。用它测编解码吞吐会得出「大屏比小屏快」这种荒谬结论。

> 而且 CLI 一次运行只有一条连接、发一次请求，**无法在同一进程内做多次测量** ——
> 而进程启动本身就有 5-7 ms（实测 `kraal --socket /tmp/nonexistent.sock` 7.4 ms）。

正确做法：像 `Scripts/bench.sh` 那样，把被测代码直接链进一个探针进程，循环 N 次。
需要真实 daemon 时用 `EndpointConnection` 直连（见 §6），不要绕 CLI。

顺带两条关于路径的事实（scout 核实）：

- `build/debug/kraal` **不存在**；正确的是 `.build/debug/kraal`
- `.build/debug` 和 `.build/release` 都是**符号链接**，指向 `out/Products/<Config>`，
  会随最后一次构建的工具链漂移（`AGENTS.md` §3 有完整解释）
- `Scripts/gui.sh:70` 与 `Scripts/agent-vm.sh:203` **硬编码 Debug 路径**，不认
  `-c release` —— 想用 release 产物跑 GUI 用例需要自己改，别以为传 `-c release` 就行

## 附：本仓库的性能现状（2026-10-23 实测）

已确认的热点，各有独立 issue：

| 热点 | 位置 | 200×50 成本 | issue |
|---|---|---|---|
| ~~`StyleCode.encode` 每格建 `[String]` + `joined`~~ | `SurfaceANSIRenderer.swift:222` | ~~~1230 us/帧（整屏变化时）~~ → 统一样式 209 us（**已修**） | #49 |
| ~~patch 应用时整屏 CoW 深拷贝~~ | ~~`AppStore+Events.swift:146`~~ → `CellBuffer.swift` | ~~37.4 us/patch（4 pane = 54% 预算）~~ → **1.4 us/patch（2%）**；残留与高度线性（~10 ns/行），**不是 O(1)**（**已修**） | #50 |
| 每键多发一条 `pane.focus` | `KraalMacMain.swift:97` | 每键 0.036 → 0.248 ms（7×） | #55 |
| 日志格式化在 enabled 检查前求值 | `KraalLog.swift:108` | 每键 0.96 us（关闭时照付） | #56 |
| `DateFormatter` 每条日志新建 | `KraalLog.swift:102` | 32.3 us（共享版 0.67 us） | #56 |
| no-op diff 用例共享存储 | `Scripts/bench.sh`（已修） | 曾报 0.29 us，真值 86.9 us | #54 |

已定位但**尚未提 issue**（成本已知，影响面待评估）：

| 观察 | 位置 | 实测成本 |
|---|---|---|
| `paneFrame` 在 revision 判据**之前**无条件逐格拷贝 | `PaneTerminal.swift:130` | 见下：#50 第一版让它多付一次逐行拷贝，现已改为直接交行。存储单步可复现（37.5 -> 0.033 us）；整条路径的耗时未独立复现，见下节 |
| `render` 每帧新建 `Data()` 无 `reserveCapacity` | `SurfaceANSIRenderer.swift:58` | 未单独测（整屏 300×80 输出约 90 KB，会有多次扩容） |
| `linkURI` 每个 cell 都调用，带链接时每次重新 sanitize 整个 URI | `SurfaceANSIRenderer.swift:297` | 未单独测（同一行同一 URI 出现 N 次就 sanitize N 次） |
| `changedRows` 无单元格级 diff，一行变一格整行重写 | `SurfaceANSIRenderer.swift:164` | 已含在「1 格变化」29.7-257 us 里 |

#### `paneFrame`：本次改动自己制造、又自己还回去的那笔存储拷贝

`paneFrame` 的形态没变（逐格裁一个 pane），变的是「怎么交给 `FrameData`」。

**只有存储那一步可以当作结论引用**（同一个进程内可复现）：

```
200×50 裁剪结果交给 FrameData，只算存储这一步（release）
width 200   flat→chunk 37.5 us    rows→init 0.033 us
```

`Array(slice)` 不与源共享存储 —— 这是 `CellBuffer(rows:width:)` 存在的唯一理由，
也是这次 M4 的核心证据。

> **已删除的归因（未独立复现，不要引用）**
>
> 本节早先有一张 A/B/C 三行表（父提交逐格下标 / 按行读进 flat 再切块 / 按行读进
> `[[CellData]]`），声称 A 是 96.1–102.8 us、C 是 62.3–65.1 us，并把「C 相对 A 的
> −35%」归因于「A 走逐格下标而 C 走 `ArraySlice`」。
>
> 审查员用同形态探针独立复现失败：A 组量到 51.7 / 25.9 us（不是 96.1 / 49.2），
> 逐格下标 vs 按行读只差 1.5–3.5 us，A→C 的差价是 ~4%（不是 −35%）。数字差近 2 倍，
> 归因方向也不成立。
>
> 结论：**逐格下标不是这次改动的收益来源**，别引用那张表。`paneFrame` 整体时间的
> 可信范围以 `Scripts/bench.sh` 复测为准；这里只保留可复现的存储单步。

健康、不需要动的部分（同样实测）：

| 路径 | 成本 |
|---|---|
| 构造一个 200×50 解码帧 | 57 us |
| `FrameData.validate()`（整帧到达时一次，不再每 patch 一次） | 3.1 us |
| retain 一个帧（CoW 共享） | 0.01 us |
| 行级 diff 检测（10000 格，行未改动时 O(1)） | 61 us |
| 解码一个按键（`TerminalInputDecoder`） | 0.115 us |
| `inputDecoders` 字典取存一个 decoder | 0.038 us |
| `Task { }` 创建 + hop | 5.8 us |

> 记下健康数据同样重要：下次有人怀疑这些地方慢时，不必重测。

### #50 修掉之后的数字（2026-10-23 实测）

### 症状与分项

patch 只改 1 格，成本却只跟 pane 面积有关，与 patch 大小无关：

| pane 尺寸 | 修前每 patch | 60fps × 4 panes |
|---|---|---|
| 80×24 | 10.8 us | 2.60 ms/帧（16%） |
| 200×50 | 40.3 us | 9.66 ms/帧（58%） |
| 300×80 | 95.3 us | 22.9 ms/帧（137%，掉帧） |

分项（200×50）：整屏 CoW 深拷贝 ~38 us；`frame.validate()` 全量扫描 ~3 us。

### 第一件必须先排掉的事：`surface?.apply(patch)` 并不能修它

issue 建议「用 inout 直接改 store 的 surface」。**这条不成立**，实测过：

```
in-place write, sole owner                       0.001 us
in-place write, second ref alive (contents read) 0.004 us   ← 慢的不是 write，是写的那一刻的 CoW
copy-mutate-assign, copy held opaquely           → buffer moved: true
```

指针比对（`withUnsafeBufferPointer` 的 `baseAddress`）证明：只要还有第二个引用，
**原地写同样会搬迁整块 buffer**。而 patch 到达的那一刻至少有三个引用活着 ——

- store 的 `surface`
- 每个 `GhosttyPaneView` 拿到的 `PaneSurfaceFrame`
- `SurfaceANSIRenderer.previous`
- `PaneTerminalModel.frameGrid`

所以复制不是 copy-assign 造成的，是**值的存储形态**造成的。只有让存储本身廉价可复制，
才能消掉这笔钱。

### 为什么不是 `final class CellBuffer`（issue 的另一条建议）

引用类型让复制免费，但也让语义变了：patch 会**写穿**到 renderer 已经画过的
`previous` 里，`changedRows` 于是拿新内容跟它自己比，判定「没变化」，不重绘 ——
屏幕停在旧画面上，任何地方都不报错。

这条不是推理，是有测试钉住的：`PatchCopyOnWriteTests.publishedCopyIsIndependent`
在注入「行共享一个 class」后立刻变红（本轮的 A/B 注入之一）。

**一条更正**：第一版这里还写了「`@Observable` 那一侧同理，没有属性被写，SwiftUI 不会
invalidation」。这条**不成立**，实测反驳了它：嵌套 class + 原地 `surface?.apply(...)`
**会**触发 observation —— 访问器走的是被追踪属性的 `_modify`，`willSet`/`didSet` 照常
发。所以拒掉 `final class` 的理由只有上面那条写穿，写穿一条就足够了。`StorePatchTests`
里那条 `withObservationTracking` 用例保留，但注释已改成「钉住 copy-assign 这个实现
细节」，**不再**声称它能抓 class 方案。

### 实际修法

`CellBuffer`（`Sources/KraalProtocol/CellBuffer.swift`）：**一行一个 CoW 数组**。

- 复制 → 共享未改动的行（O(1) retain），只有被 patch 的那一行真的复制；
- 值语义保留，diff 与 `@Observable` 都不受影响；
- 分块是内部实现，相等性比较 cell 而非布局。

`FrameData.cells: [CellData]` 变成 `FrameData.buffer: CellBuffer`，且 `flatCells`
**故意不给 setter** —— 这样编译器会强制每个调用点显式面对存储形态，不会有人
顺手又写回一个整屏数组写。

### 修后实测（同一个探针源码，编译在父提交与本提交上各跑一次）

探针 `Scripts/bench.sh patch` 只走**公开 wire API**（`ServerMessageDecoder` +
`apply`），所以同一份源码能编在两棵树上，before/after 才是可比的。

| pane | 修前 | 修后 | 倍数 |
|---|---|---|---|
| 80×24，1 格 | 8.1–10.8 us | 0.72–1.09 us | **~11×** |
| 200×50，1 格 | 40.3–40.4 us | 1.42–1.52 us | **~27×** |
| 300×80，1 格 | 95.3–97.9 us | 1.76–2.04 us | **~52×** |
| 200×50，整行（200 格） | 40.2–41.5 us | 2.29–2.37 us | **~17×** |

折算成帧预算（60fps × 4 panes，200×50）：**9.66 ms → 0.37 ms**，占 16.7 ms 的
58% → 2%。

**面积相关性消失了**：修前 300×80 是 80×24 的 12 倍，修后只差 2 倍（那 2 倍是
真正的写入量，不是整屏复制）。

### 残留成本：与 pane **高度**线性，不是 O(1)

第一版文档把这次修法写成「写入量 = 被 patch 的行」，那是错的。外层 `rows: [[CellData]]`
本身也是一个 CoW 数组：写任意一行，都要把这 `height` 个行句柄整体搬迁一次。宽度维度
确实消掉了，高度维度**没有**。

实测（宽固定 200，只写 1 格，第二个引用活着，即每一轮都必须搬迁外层数组；
release，每个尺寸跑 5 次取最小值）：

| pane | 每 patch（最好值） | 每行 |
|---|---|---|
| 200×10 | 0.83 us | 83 ns/行 |
| 200×100 | 1.63–1.68 us | 16 ns/行 |
| 200×300 | 3.84–3.88 us | 13 ns/行 |
| 200×600 | 6.90 us | 11.5 ns/行 |
| 200×1200 | 12.3–13.0 us | 10.3 ns/行 |

**斜率 ≈ 10 ns/行**（(12.9 − 0.83) us / (1200 − 10) 行 = 10.1 ns/行），外加约 0.7 us
的固定成本（一次 buffer 复制 + 一次回读）。行数小的时候固定项占主导，所以前两行看着
「每行」很贵，那是分母的错觉。

> 审查员在忠实模型上量到的是 ~6 ns/行；我这份是 ~10 ns/行。方向一致（线性、与高度
> 成正比），斜率差 1.7 倍，原因是模型不同（我这版含一次 `copy = stored` 与两次回读，
> 更接近真实 patch 路径）。**两个数都写在这儿，别把其中一个当定值引用。**

300×80 时 1.7 us/patch，占 16.7 ms 帧预算的 2%，**可接受，但不是 O(1)**。

为什么不再往下修：唯一的办法是给外层数组再套一层 box，让搬迁退化成一次 retain。
代价是所有读路径（渲染器逐行 diff、pane 裁剪、`cell(column:row:)`）都要多一次间接寻址
—— 而这条路径已经是 2% 预算。收益 ~1 us、风险是给每次读加一层间接，不做。

### 第二笔：`validate()` 不再每 patch 全量扫

`PaneSurfaceFrame.apply` → `validatePatch` 过去调 `frame.validate()`，会遍历全部
cell 检查 hyperlink 索引。而 `PaneSurfacePatch` **不携带 hyperlinks、也无法替换
hyperlinks 数组**，所以它不可能让未被触碰的行的索引失效。

改成 `validateGrid()`（O(1)：cell 数 + cursor 边界），patch 自己写入的行仍逐格校验。
全量扫描搬到它本来该在的地方 —— **整帧到达时**（`AppStore.handleSurface`）。

这里有个必须说清的坑：搬之前查过，`FrameData.validate()` 唯一的调用点就是 patch
路径 —— 也就是说那次「每 patch 全量扫描」也是**唯一**一次校验，根本没有别处在校验
到达的 surface。所以这次不是「删掉一个检查」，而是「把检查从每帧一次搬到每 surface
一次」，覆盖率不变、频率降两个数量级。`AppStore.handleSurface` 现在会拒绝校验失败
的整帧并给出原因（`surface rejected: ...`），`arrivalRejectsDanglingLink` 盯着这条。

### 第三笔：patch 被拒后的恢复路径

`handleSurfacePatch` 的注释一直写着「ask for a fresh surface」，但代码只写了
`lastError`。baseline 一旦分叉，后续每个 patch 都会被拒，屏幕永久停在分叉帧上，
而 tab bar 只是多一个小图标。现在真的会 `resyncSurface()`（有 `reprojectSurface`
就走它，没有就重握手），并用 `surfaceResyncRequests` 暴露给测试。

**这一笔补过一次（审查发现）**：第一版没有 latch。`resyncInFlight` 在**请求完成**
时就清掉，而刷新后的 surface 要更晚才到 —— 分叉期间每个被拒的 patch 都会
再发一轮两条命令；旧 daemon 那条分支更糟，没有 in-flight 状态，`resetBackoff: true`
每次把 `reconnectAttempt` 归零并断开端点，等于每秒重连一次、永不停止。
`resyncInFlight` 因窗口被 latch 严格包含而删掉（留着它反而会让
第二个 guard 吞掉更晚的合法请求）。

**latch 的复位点（2026-10-23 收尾修正；7 个 `clearResyncLatch()` + 2 个
`releaseResyncLatch(_:)` 调用点）**。原文写的是「在**新的 surface
被采纳**时才复位」，那是不完整的：一次 resync 的答案经常根本走不到「被采纳」这一步。
现在的分类与复位点：

| 事件 | 复位方式 | 理由 |
| --- | --- | --- |
| `handleSurface` 采纳了新 surface（`AppStore+Events.swift:244`） | `clearResyncLatch()` | 问题已解决，预算归零 |
| `handleSurface` **拒绝了**到达帧（`:234`） | `clearResyncLatch()` | 答案到了但不可用；不带它永远无法再问 |
| `handleSurface` 两条早退（`:169` / `:182`，经 `noteDroppedResyncAnswer`） | `releaseResyncLatch()` | 答案**被丢弃**：这是 resync 的常规落点，不是异常 |
| `handleSnapshot` 里 revision 前进 / focused tab 变了 / boot 变了（`:119` / `:138`） | `release` / `clear` | 投影被重编号（`client_shell.surface.set` 的回复先于 surface 到达）；新 boot 则是旧语境彻底没了 |
| `handleWelcome`（`:29`，新连接） | `clearResyncLatch()` | latch 属于旧连接 |
| `selectEndpoint`（`AppStore+Endpoints.swift:589`）/ `rebuildEndpoints`（`:236`）/ `disconnect`（`AppStore.swift:257`） | `clearResyncLatch()` | 那条连接/那台机器的语境没了 |
| 请求根本没发出去（`:480`，`reprojectSurface` 返回 false，被在飞的 toggle 吞掉） | `clearResyncLatch()` | 没问过，就没有问题待了结 |

`releaseResyncLatch` 与 `clearResyncLatch` 是**两个**函数，不是笔误：前者用于「证据较弱」
的路径，受 `resyncLatchReleaseLimit`（2）约束 —— 因为 resync 在飞的时候客户端停在投影
P 而 daemon 在推 P+1，**每一帧**都是「投影动了」的证据，无上限地释放就是把 latch 卡死
换成「每帧一次 resync」（H1 的反向形态）。后者只用于「问题已了结」的路径，预算归零。

### H1（收尾）：拒绝也必须认领帧号

`Surface.swift:232` 的 `surfaceRevision = patch.surfaceRevision` 只在**成功**路径，所以
任何被拒的 patch 都让客户端 revision 落后一帧，而 daemon 照常提交该帧。下一帧的
`baseSurfaceRevision` 就是 N+1，于是 identity guard 先命中 `patchIdentity`（可恢复类），
发出一次 resync —— 「系统性拒绝不 resync」于是变成「拒绝/分叉交替」，每两帧翻一次。

现在不可恢复分支在拒掉 cells 的同时**认领帧号**（不动 cells）：daemon 的 baseline 确实
前进了，客户端是「决定不跟这一帧的 cells」，而不是「落后了」。

**这条是「防未来 / 防其它 daemon 配置」，不是「修掉了一个每帧 flood」。** 对 herdr 0.9.5，
retained-patch 路径在 popup 打开时直接 fallback 到整帧渲染，daemon 根本不在 popup 期间发
patch；本客户端的 optional codecs 也默认关。所以「一次 popup 一分钟 = 3600 轮命令」是
**推演，未在真实 daemon 上复现**（仓库规矩：不把推测写成实测）。被修的是一个真实存在于
分类逻辑里的不一致，只是它的触发条件在当前 daemon 上够不到。

顺带纠正一条旧说法：「拒绝即无副作用」不再成立（revision 会前进）。已复核三处受 revision
影响的决策，见 `handleSurfacePatch` 里那段注释（它们不在这里重复，因为写得比这张表长）。

还有一条代价没写进那张表：认领帧号后，**非 popup 类拒绝失去了唯一的自动恢复出口**——
它们现在既不重绘也不 resync，只写 `lastError`。当前不可达（herdr 0.9.5 的 retained 路径
在几何/hyperlink 变化时直接 fallback 整帧），若将来 daemon 行为变了，要重新评估这条。

### 第四笔（审查修正）：到达帧校验差点变成「屏幕定格」

第一版把 `frame.validate()` 搬到 `AppStore.handleSurface`，然后对任何校验失败
`return`。`validateGrid()` 会把 **cursor 越界**判成失败，而终端的 pending-wrap 状态
（`cursor.column == width`）是合法且常见的 —— 于是 daemon 一旦发这种帧，`surface`
永远不被采纳（启动时是 nil，也就是黑屏；否则永远停在上一个 tab 的画面），
唯一症状是 tab bar 上一个图标。

现在的规则分两类，不是一刀切：

| 检查 | 到达的整帧 | 为什么 |
|---|---|---|
| cell 数 != `width * height` | **拒绝** | 真的坏了：第一行之后每一行都错位 |
| cursor 越界 | **clamp 后采纳** | pending-wrap 合法；`SurfaceANSIRenderer.resolveHostCursor` 本来就在 clamp 它画的那份，所以下游接得住 |

`arrivalRejectsDanglingLink` / `invalidSurfaceRejected` / `pendingWrapCursorAdopted`
三条钉住这三格（`cellCountStillRefused` 已被 `invalidSurfaceRejected` 覆盖，不再单列）。

A/B：把 clamp 去掉，`pendingWrapCursorAdopted` 立刻变红（4 条断言全挂）；装回去就绿。

### 第五笔（审查修正）：`write(_:at:)` 的兜底分支部分写入却报成功

`CellBuffer.write` 原来在「这一串放不进任何一行」时退化成逐格 `write`，而逐格 `write`
越界时**静默返回**，循环结束照样 `return true` —— 部分写入、报成功。
触发条件是 `frame.width` 与 buffer 分块不一致（`width` 是 `public var`），而
「`validate()` 会拒绝这种帧」的说法**不成立**：4×4（16 格）改成 8×2 后 count 仍是 16，
`validateGrid` 通过，之后行索引全部错位。

两处一起改：兜底分支改成 `return false`；`PaneSurfaceFrame.apply` 先写进局部
`var next`，全部成功后才 `frame = next`。

**「原子性免费」是过度声明，但这组百分比也一并废了（不可复现）。**

曾写过：原子版（`var next = frame` 写副本再发布）相对原地写 200×50 多 +0.069 us
（6.3%）、200×300 +0.41 us（11%）、200×1200 +1.69 us（13.6%），并归因于「原子版让
外层 `rows` 数组多搬迁一次」。

**这组数字没有探针，而且已复现不出来。** 2026-10-23 收尾时在 `bench.sh patch` 段加了
一条对照（copy-then-publish vs write-in-place，只算存储那一步，两臂都留一个活引用
防止优化器删掉复制），三次运行的结果是：

| 尺寸 | copy-then-publish | write-in-place | 差值 |
|---|---|---|---|
| 80×24 | 0.55–0.58 us | 0.53–0.57 us | 噪声以内 |
| 200×50 | 1.30–1.47 us | 1.25–1.35 us | 0–0.2 us（≈0–15%，但方向不稳定） |
| 300×80 | 1.46–1.58 us | 1.49–1.56 us | 噪声以内 |
| 200×300 | 3.90–4.11 us | 4.24–4.44 us | **反向**（原地写更慢） |
| 200×1200 | 12.4–14.5 us | 12.8–15.3 us | **反向**（原地写更慢） |

结论只能写成定性的：**原子版没有可稳定测出的额外代价，也没有「随高度增长」的趋势**。
原来那组「+6.3% / +11% / +13.6%」不再引用——它们在对照探针里复现不出来，且高行数处
方向是反的。机制上也可以解释：`var next = frame` 只多一次外层数组值的 retain，而
`write(_:at:)` 本来就要为被改的那一行做一次 CoW 复制，两者不是同一量级。

要重新提这个问题，先跑 `./Scripts/bench.sh patch` 看最后那段对照，不要引用历史数字。

A/B 两次注入：恢复逐格兜底 → 测试红（「期望抛错但没抛」+「buffer 变了」）；
`apply` 改回非原子 → 也红（「部分写入留在 buffer 里」）。

### 本轮踩到的探针坑（补进 §1 / §1b）

1. **第二次报 0.00 us**：第一版 in-place 探针里那个「第二个引用」只被读了一次
   `.count`，优化器证明它的内容不可观测，把整块复制删了。改成每轮读它的内容后
   才量出真值。凡是「共享 vs 不共享」的对比，都要确认两边的内容真的被消费。
2. **合成循环不是产品代码**：`bench.sh` 原来的 patch 段手写
   `copy.cells[0] = ...; stored = copy`，形态对但不是被修的那行代码，改完它不会变。
   现在走解码 + `apply`。
3. **A/B 必须同一份源码**：所以 patch 段刻意只用公开 API。render 段做不到
   （要直接问存储），因此前后两棵树各自跑自己的 render 段，不可比 —— 这也写进了
   脚本注释。
4. **`--json` 用 awk 过滤 stdout，只认得 `$NF == "fps"`**：render 段每行以 `fps` 结尾，
   patch 段以 `(2% of 16.7ms)` 结尾 —— 于是 `./Scripts/bench.sh patch --json`
   只吐 3 条 `validate()` 行，**本次核心指标 1.4 us 一条都读不到**，而人眼模式看着
   完全正常。现在 JSON 由探针自己发（`KRAAL_BENCH_JSON=1`，label 和字段都在手上），
   不再靠列位置猜。A/B：把 awk 过滤器装回去，`patch --json` 又只剩 3 行。

### 端到端：真实 daemon 上量到的往返

最后一条必须对着**真实 daemon** 测，本地微基准看不到网络与合成节奏。方法：起隔离
daemon（`gui.sh` 那套 scratch 环境），用 `EndpointConnection` 直连，记录「发出一个
按键」到「收到下一次 surface」的时间。

| 测量 | p50 | p90 | p99 | max |
|---|---|---|---|---|
| 端点请求 RTT（socket 往返，不含渲染） | 0.135 ms | 0.193 | 3.50 | 3.50 ms |
| 按键 → surface 回来 | 0.17 ms | 0.35 ms | 26.5 ms | 28.9 ms |
| Task-per-send 200 次 | 0.034 ms | 0.049 | 0.153 | 1.00 ms |

三个结论，都反直觉：

1. **socket 往返没有长尾**（max 3.5 ms），而 surface 推送有 26-29 ms 的偶发长尾。
   说明长尾来自 daemon 侧的帧合成节奏，**不是客户端能修的**。不要为此开 issue。
2. **Task-per-send 200 次没有一次超过 1 ms** —— `AppStore.sendInput` 每键建一个
   `Task` 看着可疑，实测不是瓶颈（`Task { }` 本身 5.8 us，是解码 0.115 us 的
   50 倍，但绝对值小到无感）。
3. **连发比单发快**：10 键连发合计 p50 0.51 ms（每键 0.051 ms），单键 p50 0.18 ms。
   daemon 会合批，客户端逐键发送不会放大成本。

> 反直觉的地方最值得先实测。这三条里有两条是我原本准备开 issue 的，
> 量完发现不成立 —— 而「不开」和「开」一样是结论。

### Kitty graphics 编码（issue #105，2026-10-24）

`GraphicsEncoder` 在**每一帧**都会跑，所以它的稳态成本必须可以忽略。

```
./Scripts/bench.sh graphics
```

release 构建，宿主 M1 Pro。64×64 RGBA 图（4 字节/像素 = 16 KiB 原始数据），
60fps 单帧预算 16.7 ms：

| 场景 | 每次 | 占预算 |
|---|---:|---:|
| 首帧（上传 + 放置） | 14.31 us | 0.09% |
| 缓存命中（同一 scene 再来一帧） | 1.12 us | 0.007% |
| 空 scene（没有图的 pane） | 0.11 us | 0.0007% |

三个量级分明（14.31 / 1.12 / 0.11），这本身就是「三条测的不是同一件事」的证据 ——
如果某条其实测了别的东西，它们会趋同。

**为什么首帧 14 us 是可接受的**：它每个 asset 只付一次。缓存命中走的是字典查找 +
签名比对，1.12 us 对 16.7 ms 是 0.007%，可以按「免费」对待。

**方法学**：`measure` 的循环体把输出长度累加进一个逃逸的全局，防止优化器把整段删掉
（§1 的坑）。首帧那条每次新建 encoder，所以缓存不可能命中；缓存命中那条复用同一个
encoder。空 scene 那条测的是「没有图的 pane 每帧付多少」。

**未验证**：真实照片（非全零数据）的 base64 编码成本。base64 不压缩，理论上与数据
内容无关，但缓存行行为可能不同，全零数据略乐观。

---

## 写性能 issue 的模板

本轮两个 issue 用的是同一结构，它让结论可复核：

1. **实测数据表** —— 分场景、分尺寸，写清 release / 硬件
2. **成本定位** —— A/B 对照，指出具体哪一行在浪费
3. **折算** —— 换算成帧预算，乘上 pane 数
4. **为什么值得修** —— 对应哪个真实操作
5. **修法建议** —— 标明「待验证」，不假装已证明
6. **复现方法** —— 含踩过的坑，让下一个人别重踩
