#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# Runs a development copy of Kraal beside whatever else is on the desktop.
#
# Two people (or a person and an agent) driving the same Mac collide in four
# places, and only the first is about the daemon:
#
#   1. the daemon — handled by KRAAL_HERDR_SOCKET (Scripts/build-app.sh pins it);
#   2. focus — a dev launch must not call `activate(ignoringOtherApps:)`;
#   3. window position and log file — namespaced by KRAAL_DEV_SESSION;
#   4. teardown — `pkill -f KraalMac` kills the *user's* app too.
#
# This script owns 2 and 4: it launches the debug bundle with the background
# flag, records the pid it started, and only ever signals that pid. Verification
# is by window number, not by looking at the screen, so nothing has to be
# brought forward to be checked.
#
#   ./Scripts/dev-session.sh start        # launch, or say one is already running
#   ./Scripts/dev-session.sh status       # is it alive, and where is its log
#   ./Scripts/dev-session.sh shot [path]  # capture only its window
#   ./Scripts/dev-session.sh log [lines]  # tail its own log
#   ./Scripts/dev-session.sh stop         # stop the copy this script started
#
# Everything is keyed on the session name, so two dev copies (yours and another
# agent's) can run at once with different KRAAL_DEV_SESSION values and never
# address the same pid file, log file or window.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

APP="$ROOT/build/Kraal.app"
STATE_DIR="${TMPDIR:-/tmp}/kraal-dev-$(id -u)"
mkdir -p "$STATE_DIR"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# The session name the app itself will compute, so this script and the app can
# never disagree about which log file and pid file belong to this copy. Asking
# the built binary is deliberate: re-implementing DevSession's rule in shell is
# how the two drift apart.
session_name() {
    local socket="${KRAAL_HERDR_SOCKET:-/tmp/kraal-mine/herdr-client.sock}"
    if [ -n "${KRAAL_DEV_SESSION:-}" ]; then
        printf '%s' "$KRAAL_DEV_SESSION"
        return
    fi
    # djb2, base 36, modulo 2^24 — mirrors DevSession.derivedName.
    local hash
    hash=$(printf '%s' "$socket" | awk '
        { h = 5381
          for (i = 1; i <= length($0); i++) {
              h = (h * 33 + ORD[substr($0, i, 1)]) % 4294967296
          }
          print h
        }
        BEGIN {
            for (i = 32; i < 127; i++) ORD[sprintf("%c", i)] = i
        }')
    printf 'dev-%s' "$(printf '%s' "$((hash % 16777216))" | awk '
        { n = $1; d = "0123456789abcdefghijklmnopqrstuvwxyz"; out = ""
          if (n == 0) out = "0"
          while (n > 0) { out = substr(d, (n % 36) + 1, 1) out; n = int(n / 36) }
          printf "%s", out }')"
}

SESSION="$(session_name)"
PID_FILE="$STATE_DIR/$SESSION.pid"
LOG_FILE="$HOME/Library/Logs/Kraal-$SESSION.log"

running_pid() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    # `kill -0` alone would accept a recycled pid belonging to some other
    # process. The command line has to still be our bundle.
    if kill -0 "$pid" 2>/dev/null; then
        if ps -o command= -p "$pid" 2>/dev/null | grep -q "Kraal.app/Contents/MacOS/$PRODUCT_PREFIX"; then
            printf '%s' "$pid"
            return 0
        fi
    fi
    rm -f "$PID_FILE"
    return 1
}

PRODUCT_PREFIX="KraalMac"

cmd_start() {
    [ -x "$APP/Contents/MacOS/KraalMac" ] || die "no debug bundle at build/Kraal.app — run ./Scripts/build-app.sh first"
    if pid="$(running_pid)"; then
        printf 'already running: session=%s pid=%s\n' "$SESSION" "$pid"
        return 0
    fi
    # The bundle's own launcher sets KRAAL_DEV_BACKGROUND=1 and the socket. Only
    # the session name is passed in, so this script cannot drift from the
    # launcher's other defaults.
    KRAAL_DEV_SESSION="$SESSION" \
        open -n -g -a "$APP" --env "KRAAL_DEV_SESSION=$SESSION" 2>/dev/null \
        || KRAAL_DEV_SESSION="$SESSION" "$APP/Contents/MacOS/KraalMac" >/dev/null 2>&1 &
    sleep 2
    local pid
    pid="$(pgrep -f "Kraal.app/Contents/MacOS/KraalMac-bin" | head -1)"
    if [ -z "$pid" ]; then
        die "launch failed; check $LOG_FILE"
    fi
    printf '%s' "$pid" > "$PID_FILE"
    printf 'started: session=%s pid=%s\n' "$SESSION" "$pid"
    printf 'log:     %s\n' "$LOG_FILE"
    printf 'note:    background session — it will not take focus or raise itself\n'
}

cmd_status() {
    if pid="$(running_pid)"; then
        printf 'running: session=%s pid=%s\n' "$SESSION" "$pid"
    else
        printf 'stopped: session=%s\n' "$SESSION"
    fi
    printf 'log:     %s%s\n' "$LOG_FILE" "$([ -f "$LOG_FILE" ] && printf '' || printf ' (not created yet)')"
    if [ -f "$LOG_FILE" ]; then
        # The window number is logged at launch precisely so a capture does not
        # need the window to be frontmost, or Accessibility, or a screenshot of
        # the whole screen.
        printf 'window:  %s\n' "$(grep -o 'window: number=[0-9]*' "$LOG_FILE" | tail -1 | cut -d= -f2 | sed 's/^$/unknown/')"
    fi
}

cmd_shot() {
    local out="${1:-$STATE_DIR/$SESSION.png}"
    [ -f "$LOG_FILE" ] || die "no log yet; start the session first"
    local number
    number="$(grep -o 'window: number=[0-9]*' "$LOG_FILE" | tail -1 | cut -d= -f2)"
    [ -n "$number" ] || die "the log has no window number; launch once with the current build"
    # `-l <windowid>` captures that window's own backing store even when another
    # app is in front of it, which is the whole point: no focus, no cursor, no
    # full-screen capture that would include the user's desktop.
    screencapture -x -o -l "$number" "$out" || die "screencapture failed for window $number"
    printf '%s\n' "$out"
}

cmd_log() {
    local lines="${1:-40}"
    [ -f "$LOG_FILE" ] || die "no log at $LOG_FILE"
    tail -n "$lines" "$LOG_FILE"
}

cmd_stop() {
    if ! pid="$(running_pid)"; then
        printf 'not running: session=%s\n' "$SESSION"
        return 0
    fi
    # Only this session's pid. `pkill -f KraalMac` would also take down the
    # user's own copy, which is the failure this script exists to prevent.
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
    printf 'stopped: session=%s pid=%s\n' "$SESSION" "$pid"
}

case "${1:-status}" in
    start) cmd_start ;;
    status) cmd_status ;;
    shot) shift; cmd_shot "${1:-}" ;;
    log) shift; cmd_log "${1:-40}" ;;
    stop) cmd_stop ;;
    *)
        die "unknown command '$1'; expected start|status|shot|log|stop"
        ;;
esac
