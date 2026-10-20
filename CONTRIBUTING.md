# 贡献指南

## 许可证

本项目以 **Apache License, Version 2.0** 发布（全文见 [LICENSE](LICENSE)）。

第三方归属声明见 [NOTICE](NOTICE)。

## 提交即授权（inbound = outbound）

根据 Apache License 2.0 第 5 条，除非你以书面形式明确声明「Not a Contribution」，
你**有意提交**用于纳入本项目的任何贡献，都自动按 Apache License 2.0 的条款授权，
无需额外签署协议。

这意味着你提交的代码、文档、脚本都会被以 Apache-2.0 分发。请确认你有权这样做
（例如：这些代码不是你的雇主独占所有，或你已获得授权）。

## 源文件头

新建源文件时，请加上以下声明。Swift / C / Rust 用 `//`，Python / Shell 用 `#`，
Markdown 用 `<!-- -->`。

```text
Copyright 2026 zzjcool

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

另外建议在文件首行加机器可读标识：

```text
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 zzjcool
```

## 修改上游衍生代码时的额外义务

Apache License 2.0 第 4 条要求：

1. 分发时附上 LICENSE 副本；
2. **对被修改的文件加上显著说明，注明你改过**（第 4(b) 条）；
3. 保留源文件中的版权、专利、商标与归属声明；
4. 上游若有 NOTICE，需随衍生作品传递其内容。

涉及 `NOTICE` 中列出的上游项目（herdr、herdr-gpui）时，请在提交信息里说明
改动来源与范围，便于维护归属记录。

## 商标

Apache License 2.0 不授予商标权（第 6 条）。请勿使用 Herdr 的名称或标识
暗示官方关系或获得背书。
