# 归档：Herdr 1 时代的文档

这里的文档描述的是 **Herdr 1 daemon / bincode endpoint 协议**时期的 Kraal。
2026-11-02 起项目切换到 [herdr-core](../HERDR2.md)（Herdr 2），这些文档不再作为
设计和实现依据，只保留作历史与排查参考。

| 文件 | 原来是什么 | 为什么归档 |
|---|---|---|
| `DESIGN.md` | 1.0 技术设计（endpoint 协议、surface、侧边栏引擎） | 协议与屏幕合成层整体作废 |
| `GAP-VS-HERDR.md` | 与 herdr 1 / herdr-gpui / rootshell 的行为差异清单 | 参考项目不再参考 |
| `REX-UI.md` | 从 Rex 界面借来的主题/材质/密度结论 | 客户端改为对齐官方 herdr-app |
| `PORTED-TESTS.md` | 从三个上游项目移植的测试与 22 条红 | 测试与实现随协议一起删除 |
| `CLI.md` | 借鉴 Rex 的对外接口清单 | 对外接口改为对齐 `herdr-app ls/status/do` |
| `feasibility.md` | 立项期可行性研究 | 结论已被新架构取代 |
| `feasibility-revised.md` | 可行性研究修订版（路线对比） | 同上 |

仍然有效的排查与度量方法保留在 `docs/DEBUGGING.md` 和 `docs/PERFORMANCE.md`；
环境事实在 `docs/ENVIRONMENT.md`；操作步骤在 `docs/RUNNING.md`（随迁移更新）。
