#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# Kraal 的 macOS agent VM：起停与连通性自检。
#
# 为什么要有这个脚本
# ------------------
# Kraal 的自测需要一台「可以随便糟蹋」的 herdr daemon：GUI 调试会分屏、打字、
# 关 pane、改布局，这些落在真实会话里就是破坏。
#
# 宿主机上做这件事要一个容器（README「在隔离的 Herdr 实例上开发」）；
# 在 macOS 上容器跑不了 macOS，所以改用 Tart 虚拟机：
#
#   kraal-agent  macOS 26.6.2 / 6 vCPU / 12 GB / 80 GB
#                herdr 0.9.5 + pi 1.3.0 + 完整 pi 配置
#
# VM 里禁止跑的：宿主机的东西（不挂共享目录），这样一次跑坏了直接
# `tart delete` + 重新 clone，成本只是几分钟。
#
# 用法
# ----
#   ./Scripts/agent-vm.sh status     # 是否在跑、IP、herdr/pi 版本
#   ./Scripts/agent-vm.sh start      # 起 VM（无窗口），等 guest agent 就绪
#   ./Scripts/agent-vm.sh stop       # 停 VM（不删）
#   ./Scripts/agent-vm.sh probe      # Kraal 走 SSH 连进 VM 的 herdr daemon
#   ./Scripts/agent-vm.sh sh         # 进 VM 拿一个交互 shell
#   ./Scripts/agent-vm.sh exec <cmd> # 在 VM 里跑一条命令
#   ./Scripts/agent-vm.sh destroy    # 删掉 VM（不可恢复）
#
# 前提：tart（brew install --cask zheng/local/tart），VM 已经 pull/clone 过。
# 重建 VM 的完整步骤见 docs/ENVIRONMENT.md §7。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VM="${KRAAL_AGENT_VM:-kraal-agent}"
SSH_USER="${KRAAL_AGENT_VM_USER:-admin}"
RUN_LOG="${TMPDIR:-/tmp}/kraal-agent-vm-run.log"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[36m%s\033[0m\n' "$1"; }

command -v tart >/dev/null || die "tart not installed — brew install --cask zheng/local/tart"

# `tart list --format json | grep -q` would look right and be wrong: grep exits at
# the first match, tart takes SIGPIPE, and pipefail then reports failure for a VM
# that exists. Read the whole document and let python decide.
vm_state() {
    VM_NAME="$VM" tart list --format json 2>/dev/null |
        VM_NAME="$VM" python3 -c "
import json, os, sys
name = os.environ['VM_NAME']
try:
    vms = json.load(sys.stdin)
except Exception:
    print('missing'); raise SystemExit
print(next((v.get('State', '?') for v in vms if v.get('Name') == name), 'missing'))
" 2>/dev/null || echo "missing"
}

[ "$(vm_state)" = "missing" ] && die "VM '$VM' not found — see docs/ENVIRONMENT.md §7"

vm_ip() {
    tart ip "$VM" 2>/dev/null || true
}

# The guest agent answers before the desktop is up; herdr and pi are what we
# actually need, so wait on those instead of on a boot-time guess.
wait_ready() {
    local deadline=$((SECONDS + 180))
    while [ $SECONDS -lt $deadline ]; do
        if tart exec "$VM" /bin/bash -lc 'command -v herdr >/dev/null' >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

# SSH needs the VM's own sshd, which comes up on its own schedule.
wait_ssh() {
    local ip deadline=$((SECONDS + 120))
    ip=$(vm_ip)
    [ -n "$ip" ] || return 1
    while [ $SECONDS -lt $deadline ]; do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 "$SSH_USER@$ip" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

case "${1:-status}" in
status)
    state=$(vm_state)
    info "vm:     $VM ($state)"
    if [ "$state" != "running" ]; then
        exit 0
    fi
    ip=$(vm_ip)
    info "ip:     ${ip:-<none>}"
    if [ -n "$ip" ] && ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$SSH_USER@$ip" true >/dev/null 2>&1; then
        info "ssh:    ok"
    else
        info "ssh:    unreachable"
    fi
    tart exec "$VM" /bin/bash -lc '
        export PATH="$HOME/.local/bin:$PATH"
        printf "herdr:  %s\n" "$(herdr --version 2>/dev/null || echo missing)"
        printf "daemon: %s\n" "$(herdr status server 2>/dev/null | awk -F": " "/^status:/{print \$2}")"
        printf "pi:     %s\n" "$(pi --version 2>/dev/null || echo missing)"
        printf "node:   %s\n" "$(node --version 2>/dev/null || echo missing)"
    ' 2>/dev/null
    ;;

start)
    if [ "$(vm_state)" = "running" ]; then
        info "already running"
        "$0" status
        exit 0
    fi
    info "starting $VM (no window)…"
    nohup bash -c "tart run --no-graphics '$VM' > '$RUN_LOG' 2>&1" >/dev/null 2>&1 &
    if ! wait_ready; then
        die "VM did not become ready in 180 s — see $RUN_LOG"
    fi
    # The daemon is not a login item; the image ships without one.
    #
    # Do not test this with `herdr status server >/dev/null`: it exits 0 whether
    # or not the daemon is up (the report is the status line, not the exit code),
    # so a successful-looking check leaves the VM with no daemon. Read the line.
    # shellcheck disable=SC2016  # $HOME is guest-side, expanded inside the VM
    tart exec "$VM" /bin/bash -lc '
        export PATH="$HOME/.local/bin:$PATH"
        daemon_up() { herdr status server 2>/dev/null | grep -qx "status: running"; }
        if ! daemon_up; then
            nohup herdr server > /tmp/herdr-server.log 2>&1 &
            for _ in $(seq 1 20); do
                daemon_up && break
                sleep 1
            done
        fi
        daemon_up || { echo "daemon failed to start" >&2; exit 1; }
    ' || die "herdr daemon did not start — see /tmp/herdr-server.log inside the VM"
    if wait_ssh; then
        info "ssh ready"
    else
        printf '\033[33mwarning:\033[0m ssh not reachable yet; KRAAL probe will fail until it is\n' >&2
    fi
    "$0" status
    ;;

stop)
    [ "$(vm_state)" = "running" ] || { info "not running"; exit 0; }
    info "stopping ${VM}…"
    # `tart stop` sends ACPI shutdown; the guest agent may already be gone.
    tart stop "$VM" 2>/dev/null || true
    for _ in $(seq 1 20); do
        [ "$(vm_state)" = "running" ] || { info "stopped"; exit 0; }
        sleep 1
    done
    die "VM did not stop — check for an open window or use tart stop --help"
    ;;

probe)
    [ "$(vm_state)" = "running" ] || die "VM not running — run: $0 start"
    ip=$(vm_ip)
    [ -n "$ip" ] || die "no IP for $VM"
    exec ./.build/out/Products/Debug/kraal --ssh "$SSH_USER@$ip" probe
    ;;

sh)
    [ "$(vm_state)" = "running" ] || die "VM not running — run: $0 start"
    ip=$(vm_ip)
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@$ip"
    ;;

exec)
    shift
    [ $# -gt 0 ] || die "usage: $0 exec <command…>"
    exec tart exec "$VM" /bin/bash -lc "$*"
    ;;

destroy)
    [ "$(vm_state)" = "running" ] && tart stop "$VM" 2>/dev/null
    info "deleting ${VM}…"
    tart delete "$VM" || die "delete failed"
    info "deleted — rebuild with the steps in docs/ENVIRONMENT.md §7"
    ;;

*)
    die "unknown command: $1 (try: status|start|stop|probe|sh|exec|destroy)"
    ;;
esac
