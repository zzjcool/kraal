# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# 一条命令看真实效果：
#
#   make run          # 连你自己的 herdr daemon，构建 + 打包 + 启动
#   make              # 同上（默认目标）
#
# 这里的每个目标都用**真实环境**：真的 Kraal.app、真的 herdr daemon、真的窗口。
# 没有 mock、没有假数据。GUI 自动化测试另有一套（`make gui-*`，跑在 VM 里），
# 两者不要混。

SHELL := /bin/bash
.DEFAULT_GOAL := run

# CLT 的 swift 缺 Testing.framework / XCTest.framework，swift test 会报
# "no such module 'Testing'"。这不是测试坏了，是工具链不对。
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

# swiftlint / shellcheck 不在默认 PATH。
export PATH := $(HOME)/.pi-lens/bin:$(PATH)

APP             := build/Kraal.app
DRIVER          := .build/out/Products/Debug/KraalGUIDriver
# The debug bundle's launcher defaults to this sandbox socket. It is a leftover
# from an old ssh forward and nothing listens on it, so leaving it alone is how
# you get the connection panel instead of your panes.
DEFAULT_SANDBOX := /tmp/kraal-mine/herdr-client.sock
REAL_SOCKET     := $(HOME)/.config/herdr/herdr-client.sock

# Overridable: `make run SOCKET=/path/to/other-herdr-client.sock`
SOCKET ?= $(REAL_SOCKET)
# Namespaces the saved window frame and the log file. "live" says what it is:
# a session pointed at the real daemon.
SESSION ?= live
# 1 keeps the app from stealing the pointer and keyboard; the window still
# renders and is still capturable. Set FOCUS=0 to let it come to the front.
FOCUS ?= 1

.PHONY: help run app build driver test lint shell-lint verify clean \
        check-env socket-status logs stop gui-list gui-run gui-verify vm

## ---------------------------------------------------------------- 默认

help: ## 显示可用目标
	@echo "真实环境（连你自己的 daemon）:"
	@echo "  make run            构建 + 打包 + 启动（连真实 daemon）"
	@echo "  make run FOCUS=0    同上，但让窗口到前台（会抢焦点）"
	@echo "  make socket-status  显示连的是哪个 socket、是否活着"
	@echo "  make logs           跟踪 app 日志"
	@echo "  make stop           退出 app"
	@echo ""
	@echo "构建与门禁:"
	@echo "  make build          只构建（不打包）"
	@echo "  make app            只打包 build/Kraal.app"
	@echo "  make test           swift test"
	@echo "  make verify         六道门禁全跑"
	@echo ""
	@echo "GUI 自动化（跑在 VM 里，不碰你的桌面）:"
	@echo "  make gui-list       列出用例"
	@echo "  make gui-run        跑全部用例"
	@echo "  make gui-run CASE=drag-divider   跑单个"
	@echo "  make vm             准备/检查 VM"

# Launches `KraalMac-bin`, not the bundle's `KraalMac` launcher. The launcher is a
# bash script, and a script as CFBundleExecutable makes NSRunningApplication
# report pid=-1 for the app — verified: Finder/Safari report real pids, only the
# script-wrapped app reports -1. That breaks anything that finds the app by pid
# (`kraal-gui window` did). Launching the real binary directly keeps the pid
# honest; the launcher's env defaults are passed explicitly below instead.
run: check-env app ## 连真实 daemon 启动（默认）
	@echo ""
	@echo "==> 启动 Kraal，连 $(SOCKET)"
	@if [ "$(FOCUS)" = "1" ]; then echo "    KRAAL_DEV_BACKGROUND=1  (不抢焦点)"; \
	 else echo "    KRAAL_DEV_BACKGROUND=$(FOCUS)  (会到前台，会抢焦点)"; fi
	@echo "    KRAAL_HERDR_HOME=$(HOME)      (真实机器名册)"
	@echo ""
	@KRAAL_HERDR_SOCKET="$(SOCKET)" \
	 KRAAL_HERDR_HOME="$(HOME)" \
	 KRAAL_DEV_BACKGROUND="$(FOCUS)" \
	 KRAAL_DEV_SESSION="$(SESSION)" \
	 nohup "$(APP)/Contents/MacOS/KraalMac-bin" >/tmp/kraal-run.out 2>&1 &
	@sleep 2
	@echo "==> 已启动。日志："
	@$(MAKE) --no-print-directory logs-path

## ---------------------------------------------------------------- 检查

check-env: ## 确认 socket / app / 工具链都在
	@test -x "$(DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" || { \
	    echo "error: 这不是 Xcode 的工具链：$(DEVELOPER_DIR)"; \
	    echo "       要的是 .../Xcode.app/Contents/Developer（CLT 缺 Testing.framework，swift test 会失败）"; \
	    exit 1; }
	@if [ ! -S "$(SOCKET)" ]; then \
	    echo "error: socket 不存在：$(SOCKET)"; \
	    echo ""; \
	    echo "  这说明 herdr daemon 没在跑，或者它用的是别的路径。先确认："; \
	    echo "    ls -l $(HOME)/.config/herdr/*.sock"; \
	    echo ""; \
	    echo "  注意有两套 socket，别搞混："; \
	    echo "    herdr.sock          —— CLI 的 JSON API（变量 HERDR_SOCKET_PATH）"; \
	    echo "    herdr-client.sock   —— Kraal 用的 bincode 协议（本目标要的是这个）"; \
	    exit 1; \
	fi
	@if [ ! -S "$(DEFAULT_SANDBOX)" ] || ! lsof -U 2>/dev/null | grep -q "kraal-mine"; then \
	    echo "note: $(DEFAULT_SANDBOX) 是失效的沙箱 socket（debug bundle 的默认值）。"; \
	    echo "      不覆盖它就会显示连接面板——这正是 make run 存在的原因。"; \
	fi

socket-status: ## 显示 socket 状态
	@echo "Kraal socket (bincode):  $(SOCKET)"
	@if [ -S "$(SOCKET)" ]; then echo "  存在 ✓"; else echo "  不存在 ✗"; fi
	@echo ""
	@echo "debug bundle 默认值（沙箱，通常连不上）："
	@if [ -S "$(DEFAULT_SANDBOX)" ]; then \
	    echo "  $(DEFAULT_SANDBOX) 存在，但："; \
	    lsof -U 2>/dev/null | grep "kraal-mine" | head -1 | sed 's/^/    /' || echo "    没有进程监听"; \
	else echo "  不存在"; fi

## ---------------------------------------------------------------- 构建

build: ## 只构建
	@/usr/bin/swift build

# CONFIG=release 打 release 包（`make app CONFIG=release`）
CONFIG ?= debug

app: ## 打包 build/Kraal.app
	@./Scripts/build-app.sh $(CONFIG)

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

verify: ## 六道门禁
	@./Scripts/verify.sh

## ---------------------------------------------------------------- 运行期

logs: ## 跟踪 app 日志
	@LOG=$$(ls -t $(HOME)/Library/Logs/Kraal*.log 2>/dev/null | head -1); \
	if [ -z "$$LOG" ]; then echo "还没有日志——先 make run"; exit 1; fi; \
	echo "==> $$LOG"; exec tail -f "$$LOG"

logs-path: ## 只打印日志路径
	@ls -t $(HOME)/Library/Logs/Kraal*.log 2>/dev/null | head -1 || echo "(暂无)"

stop: ## 退出 Kraal
	@-pkill -f "Kraal.app/Contents/MacOS/Kraal" 2>/dev/null && echo "已退出" || echo "没在跑"

## ---------------------------------------------------------------- GUI 自动化

gui-list: driver ## 列出 GUI 用例
	@./Scripts/gui.sh list

gui-run: driver app ## 跑 GUI 用例（VM 后端，不碰你的桌面）
	@./Scripts/gui.sh run $(CASE)

gui-verify: ## 断言层自检
	@./Scripts/gui.sh verify

vm: ## 准备/检查 VM
	@./Scripts/vm-bootstrap.sh

## ---------------------------------------------------------------- 清理

clean: ## 清掉构建产物（不动 VM）
	@rm -rf .build build artifacts
	@echo "已清理 .build build artifacts（VM 保留）"
