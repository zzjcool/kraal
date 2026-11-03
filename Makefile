# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# 一条命令看真实效果：
#
#   make run          # 构建 + 打包 + 启动 herdr-core 窗口
#   make run FOCUS=0  # 让窗口到前台（默认后台，不抢键鼠）
#
# 这里的目标都用**真实环境**：真的 Kraal.app、真的 herdr-core、真的窗口。
# 没有 mock、没有假数据。

SHELL := /bin/bash
.DEFAULT_GOAL := run

# CLT 的 swift 缺 XCTest.framework，swift test 会失败。
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

# swiftlint / shellcheck 不在默认 PATH。
export PATH := $(HOME)/.pi-lens/bin:$(PATH)

APP := build/Kraal.app

# Namespaces the saved window frame and the log file.
SESSION ?= live
# 1 keeps the app from stealing the pointer and keyboard; FOCUS=0 brings it to
# the front (and takes focus).
FOCUS ?= 1
# A debug launch must not share the real control socket with the user's app.
# An explicit KRAAL_CONTROL_SOCKET wins so documented isolated launches work.
CONTROL_SOCKET ?= $(if $(KRAAL_CONTROL_SOCKET),$(KRAAL_CONTROL_SOCKET),/tmp/kraal-mine/control.sock)

.PHONY: help run app build driver test lint shell-lint verify clean \
        check-env socket-status logs stop vm

help: ## 显示可用目标
	@echo "真实环境（连本机 herdr-core）:"
	@echo "  make run            构建 + 打包 + 启动"
	@echo "  make run FOCUS=0    同上，但让窗口到前台（会抢焦点）"
	@echo "  make socket-status  显示 herdr-core 状态"
	@echo "  make logs           跟踪 app 日志"
	@echo "  make stop           退出 app"
	@echo ""
	@echo "构建与门禁:"
	@echo "  make build          只构建（不打包）"
	@echo "  make app            只打包 build/Kraal.app"
	@echo "  make test           swift test"
	@echo "  make verify         构建、测试、lint、打包"
	@echo ""
	@echo "VM:"
	@echo "  make vm             准备/检查隔离 VM"

run: check-env app ## 构建、打包并启动 herdr-core 窗口
	@echo ""
	@echo "==> 启动 Kraal（herdr-core）"
	@if [ "$(FOCUS)" = "1" ]; then echo "    KRAAL_DEV_BACKGROUND=1  (不抢焦点)"; \
	 else echo "    KRAAL_DEV_BACKGROUND=$(FOCUS)  (会到前台，会抢焦点)"; fi
	@echo "    control socket=$(CONTROL_SOCKET)"
	@echo ""
	@KRAAL_DEV_BACKGROUND="$(FOCUS)" \
	 KRAAL_DEV_SESSION="$(SESSION)" \
	 KRAAL_CONTROL_SOCKET="$(CONTROL_SOCKET)" \
	 $(APP)/Contents/MacOS/KraalMac-bin


check-env: ## 确认 hc 与 core 可用
	@if ! command -v hc >/dev/null 2>&1; then \
	    echo "error: 找不到 hc。先安装 herdr-core（docs/RUNNING.md）"; \
	    exit 1; \
	fi
	@if ! hc server status >/dev/null 2>&1; then \
	    echo "error: herdr-core 没在跑。先运行：hc server start"; \
	    exit 1; \
	fi

socket-status: ## 显示 herdr-core 状态
	@hc server status

## ---------------------------------------------------------------- 构建

build: ## 只构建
	@/usr/bin/swift build

app: ## 打包 build/Kraal.app
	@./Scripts/build-app.sh

driver: ## 构建 GUI 自动化驱动
	@/usr/bin/swift build --product KraalGUIDriver

test: ## 跑单元测试
	@/usr/bin/swift test

lint: ## swiftlint
	@which swiftlint >/dev/null || { echo "error: 没有 swiftlint"; exit 1; }
	@swiftlint --quiet Sources Tests && echo "swiftlint: 0 violations"

shell-lint: ## shellcheck 所有脚本
	@which shellcheck >/dev/null || { echo "error: 没有 shellcheck"; exit 1; }
	@for f in Scripts/*.sh; do shellcheck -S warning "$$f" || exit 1; done
	@echo "shellcheck: clean"

verify: ## 构建、测试、lint、打包
	@./Scripts/verify.sh

## ---------------------------------------------------------------- 运行期

logs: ## 跟踪 app 日志
	@LOG=$$(ls -t $(HOME)/Library/Logs/Kraal*.log 2>/dev/null | head -1); \
	if [ -z "$$LOG" ]; then echo "还没有日志——先 make run"; exit 1; fi; \
	echo "==> $$LOG"; exec tail -f "$$LOG"

stop: ## 退出 Kraal
	@-pkill -f "Kraal.app/Contents/MacOS/Kraal" 2>/dev/null && echo "已退出" || echo "没在跑"

vm: ## 准备/检查 VM
	@./Scripts/vm-bootstrap.sh

## ---------------------------------------------------------------- 清理

clean: ## 清掉构建产物（不动 VM）
	@rm -rf .build build artifacts
	@echo "已清理 .build build artifacts（VM 保留）"
