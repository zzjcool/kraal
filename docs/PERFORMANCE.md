# 性能测量

旧的 `bench.sh` 测的是 Herdr 1 的 cell→ANSI 编码和 patch 应用，已随旧渲染链路
删除；那些数字不能再当 HC 基线。新基线在 [#237](https://github.com/zzjcool/kraal/issues/237)。

在重录之前，先守住方法学：

## 1. 测 release，不测 debug

```bash
swift build -c release --product KraalMac
swift build -c release --product kraal
```

debug 的泛型/边界检查会让 10x 级别的差异看起来像产品问题。记录配置和
`swift --version`。

## 2. 样本要能区分对错

- 终端吞吐：用固定字节数的程序输出（例如 `yes | head -c 50M`），不是空 shell。
- attach 恢复：首帧 VT 重放 vs 后续流分开计时。
- N pane：固定 pane 数、固定输出速率；分别记主线程 CPU 和总 CPU。
- 输入延迟：从写入 PTY 到屏幕出现固定标记，重复 ≥30 次取中位数/p95；不要
  只报一次「感觉很快」。

## 3. 防优化器

- 计时区间外读结果（`blackHole` / 汇总 checksum）。
- 不要用会被常量折叠的空循环。
- 基准进程和被测窗口分开；避免基准工具抢主线程。
- 用真实 socket + 真实 core；fake core 只用来测 wire，不测端到端。

## 4. 记录

每次记录：日期、机器、macOS/Xcode/hc 版本、命令、样本数、中位数/p95、是否
release。回归判定要同一个脚本、同一台机器、同一负载；跨机器数字只作参考。

## 5. 当前已知

- Ghostty 渲染线程独立；Kraal 主线程主要成本在 SwiftUI 状态更新和 attach
  字节转发。
- 10 MB scrollback 上限先到时约 9.3k 行（取决于行宽），这是 Ghostty 配置
  行为，不是 Kraal 缓冲。
- 还没做 kitty graphics 像素路径的吞吐/内存测量。
