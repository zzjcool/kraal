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

**C. 复现最小动作** —— 直接测 `[String]` 建 + `joined(";")` 10000 次 = 961 us，
与整帧 1500 us 中的 ~1230 us 对上，确认这确实是主要成本。

> 对照实验的价值：它能把「总体慢」变成「这行代码在做无用功」。

## 4. 分清「稳态」和「最坏情况」

同一个渲染器在不同输入下的成本差 5000 倍：

| 场景 | 80×24 | 200×50 | 300×80 |
|---|---|---|---|
| 首帧（pane 出现） | 305 us | 1506 us | 3589 us |
| 冗余快照（内容不变） | 0.29 us | 0.33 us | 0.38 us |
| 打字（1 格变化） | 29.7 us | 118 us | 257 us |
| **整屏滚动（每行都变）** | **297 us** | **1546 us** | **3603 us** |

只报「平均」会把这些全糊掉。提性能问题时**必须写清是哪一档**，并说明它在真实
使用中对应什么操作（`tail -f`、`htop`、全屏滚动 → 落到最贵那一行）。

## 5. 折算成帧预算

微秒数字对没写过渲染的人没有直觉。折算成「60 fps 每帧 16.7 ms 里占多少」：

```
每 patch 37.4 us × 60 patch/s × 4 panes = 9.0 ms/帧 (54% 预算)
```

这一句比「37.4 us」更能说明为什么要修。`Scripts/bench.sh patch` 直接把这列打出来。

注意**乘上 pane 数**：单 pane 看着无害的开销，四个 pane 时按倍数叠加。

## 6. 多次运行，看波动而不是单次

单次读数可能是冷缓存。每项跑三次，看离散度：

```
full reps=2000 per=1505.7us
full reps=2000 per=1524.4us
full reps=2000 per=1524.3us      ← 三次差 < 2%，可信
```

如果三次差 10 倍，那说明还有别的变量在动（首次分配、JIT、调度），此时应该先
找出它，而不是取平均。

---

## 附：本仓库的性能现状（2026-10-22 实测）

已确认的两个热点，各有独立 issue：

| 热点 | 位置 | 200×50 成本 | issue |
|---|---|---|---|
| `StyleCode.encode` 每格建 `[String]` + `joined` | `SurfaceANSIRenderer.swift:222` | ~1230 us/帧（整屏变化时） | #49 |
| patch 应用时整屏 CoW 深拷贝 | `AppStore+Events.swift:146` | 37.4 us/patch（4 pane = 54% 预算） | #50 |

健康、不需要动的部分（同样实测）：

| 路径 | 成本 |
|---|---|
| 构造一个 200×50 解码帧 | 57 us |
| `FrameData.validate()` | 3.1 us |
| retain 一个帧（CoW 共享） | 0.01 us |
| 行级 diff 检测（10000 格） | 104 us |

> 记下健康数据同样重要：下次有人怀疑这些地方慢时，不必重测。

---

## 写性能 issue 的模板

本轮两个 issue 用的是同一结构，它让结论可复核：

1. **实测数据表** —— 分场景、分尺寸，写清 release / 硬件
2. **成本定位** —— A/B 对照，指出具体哪一行在浪费
3. **折算** —— 换算成帧预算，乘上 pane 数
4. **为什么值得修** —— 对应哪个真实操作
5. **修法建议** —— 标明「待验证」，不假装已证明
6. **复现方法** —— 含踩过的坑，让下一个人别重踩
