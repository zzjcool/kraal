#!/bin/bash
# End-to-end proof for issue #34's clipboard path: a pane writes OSC 52, the
# daemon forwards it, and this client must put it on the macOS pasteboard.
#
# Not a `gui.sh` case on purpose: the clipboard write happens in the app, and
# this needs no window and no synthetic input, so a window launch (plus the
# focus rules that come with one) would buy nothing. The daemon lifecycle is
# duplicated from `gui.sh` rather than sourced because that script drives a
# command dispatch at the bottom and cannot be imported.
#
# The guest has no `timeout` command (docs/ENVIRONMENT.md §4.6), so every call
# that can block is bracketed by a background watchdog here. Without that, a
# `herdr` invocation with no live server hangs forever and the probe looks like
# a hung machine — which is exactly what happened on the first attempt.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }

VM="${KRAAL_GUI_VM:-kraal-agent}"
VM_ROOT=/tmp/kraal-gui
API="$VM_ROOT/herdr.sock"
CLIENT="$VM_ROOT/herdr-client.sock"
APP="$VM_ROOT/Kraal.app/Contents/MacOS/KraalMac"
SESSION="osc52-$$"
RUN_TIMEOUT=45
PASS=0
FAIL=0

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok() { printf '\033[32mok:\033[0m %s\n' "$*"; }
bad() { printf '\033[31mFAIL:\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
# `check` takes an explicit result code: `[ x ] ; check ... $?` is SC2319 because
# `$?` then refers to the condition, not to a command.
check() {
    if [ "$2" = 0 ]; then ok "$1${3:+ ($3)}"; PASS=$((PASS + 1))
    else bad "$1${3:+ ($3)}"; fi
}

# Runs a guest command with a host-side watchdog. Prints its output.
gexec() {
    local out
    out=$(mktemp)
    ( tart exec "$VM" /bin/bash -lc "$1" >"$out" 2>&1 ) &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$RUN_TIMEOUT" ]; then
            kill -9 "$pid" 2>/dev/null
            echo "TIMEOUT after ${RUN_TIMEOUT}s: $1" >>"$out"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    cat "$out"
    rm -f "$out"
}

herdrv() {
    gexec "HOME=$VM_ROOT/herdr-home HERDR_SOCKET_PATH=$API $VM_ROOT/bin/herdr $*"
}

stop_all() {
    gexec "pkill -f '$APP' 2>/dev/null
           pkill -f 'herdr server' 2>/dev/null
           true" >/dev/null 2>&1
    sleep 1
}

say "resetting scratch state"
stop_all
gexec "rm -f $API $CLIENT; rm -rf $VM_ROOT/herdr-home/.config/herdr/session.json \
       $VM_ROOT/herdr-home/.config/herdr/session-snapshots; true" >/dev/null 2>&1

say "deploying the current build into the guest"
# Without this the probe ran against whatever Kraal.app was left in /tmp from an
# earlier session (14:15, before the base64 fix) and reported the *old* bug as if
# it were current: the clipboard really did receive the base64 blob, because the
# binary that wrote it predated the decoder. `gui.sh` deploys on every run for
# exactly this reason; a probe that skips it measures the wrong binary.
tar -czf - -C "$ROOT/build" Kraal.app \
    | tart exec -i "$VM" /bin/bash -lc "rm -rf $VM_ROOT/Kraal.app && cd $VM_ROOT && tar -xzf -" \
    || die "failed to push Kraal.app into the guest"
gexec "xattr -dr com.apple.quarantine $VM_ROOT/Kraal.app 2>/dev/null; true" >/dev/null 2>&1
ok "deployed"

say "starting a scratch daemon"
# `herdr server … &` alone makes `tart exec` hang even with nohup: the command
# is backgrounded but the *session* still holds the pipe, so the host waits
# forever. `gui.sh` gets away with it by ending the same `bash -lc` with an
# explicit `sleep`, which is what makes the exec return; this probe reproduced
# the hang for 10 minutes by omitting it (docs/ENVIRONMENT.md §4.6: the guest has
# no `timeout`, so nothing breaks the wait on its own).
DAEMON_OUT=$(gexec "cd $VM_ROOT && mkdir -p $VM_ROOT/herdr-home
  nohup env HOME=$VM_ROOT/herdr-home HERDR_SOCKET_PATH=$API \
      $VM_ROOT/bin/herdr server > $VM_ROOT/osc52-daemon.log 2>&1 &
  sleep 2
  echo started")
echo "$DAEMON_OUT" | grep -q started; check "daemon launch accepted" $?

# Poll for the socket instead of sleeping a fixed amount: the first attempt
# assumed 2s and the daemon was not always up yet.
SOCK=""
for _ in $(seq 1 20); do
    SOCK=$(gexec "ls $API 2>/dev/null || true" | tr -d '\r\n')
    [ -n "$SOCK" ] && break
    sleep 1
done
[ -n "$SOCK" ]; check "daemon socket appeared" $? "$SOCK"
[ -n "$SOCK" ] || { echo "daemon log:"; gexec "tail -20 $VM_ROOT/osc52-daemon.log"; exit 1; }

say "creating a workspace"
gexec "HOME=$VM_ROOT/herdr-home HERDR_SOCKET_PATH=$API $VM_ROOT/bin/herdr workspace create" >/dev/null 2>&1
PANE=$(herdrv pane list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(sorted(p["pane_id"] for p in d["result"]["panes"])[0])
except Exception:
    print("")
' 2>/dev/null)
[ -n "$PANE" ]; check "a pane exists" $? "$PANE"
[ -n "$PANE" ] || { echo "pane list was empty"; exit 1; }

say "putting a known value on the clipboard first"
# So a pass cannot come from the value already being there.
gexec "osascript -e 'set the clipboard to \"NOT_THE_PANE_VALUE\"'" >/dev/null 2>&1
BEFORE=$(gexec 'osascript -e "the clipboard as text"' 2>/dev/null | tr -d '\r')
echo "  before: $BEFORE"

say "launching Kraal against the scratch daemon"
gexec "cd $VM_ROOT
  KRAAL_HERDR_SOCKET=$CLIENT KRAAL_HERDR_HOME=$VM_ROOT/herdr-home \
  KRAAL_DEV_BACKGROUND=1 KRAAL_DEV_SESSION=$SESSION \
  nohup $APP > $VM_ROOT/osc52-app.out 2>&1 </dev/null &
  echo launched" >/dev/null 2>&1
APP_UP=$(gexec "sleep 4; pgrep -f '$APP' >/dev/null && echo yes || echo no" | tr -d '\r\n')
RC=1; [ "$APP_UP" = "yes" ] && RC=0
check "Kraal is running against the scratch daemon" "$RC"

say "pane writes OSC 52 — the payload used to be dropped here"
# `pane run` takes the pane id as a *positional* argument; `--pane <id>` is
# parsed as the command to run and the CLI answers `pane_not_found: pane --pane
# not found`. That error was swallowed by `>/dev/null 2>&1`, so the probe spent
# several runs reporting "the clipboard did not change" while the real problem
# was that no command ever ran. Errors from here are shown now.
RUN_OUT=$(gexec "HOME=$VM_ROOT/herdr-home HERDR_SOCKET_PATH=$API $VM_ROOT/bin/herdr pane run \
  $PANE 'printf \"\\033]52;c;%s\\a\" \"\$(printf KRAAL_OSC52_OK | base64)\"'")
echo "  pane run: $(echo "$RUN_OUT" | head -2)"
sleep 3

AFTER=$(gexec 'osascript -e "the clipboard as text"' 2>/dev/null | tr -d '\r')
echo "  after:  $AFTER"

RC=1; [ "$AFTER" = "KRAAL_OSC52_OK" ] && RC=0
check "the pane's OSC 52 payload reached the macOS pasteboard" "$RC" "$AFTER"
RC=1; [ "$AFTER" != "$BEFORE" ] && RC=0
check "the clipboard actually changed" "$RC" "$BEFORE -> $AFTER"

say "the app reports what it applied"
EFFECTS=$(gexec "grep -h 'effects:' ~/Library/Logs/Kraal-$SESSION.log 2>/dev/null" | tr -d '\r')
echo "$EFFECTS" | grep -q 'clipboard='
check "the app logged a clipboard effect" $? "$(echo "$EFFECTS" | grep 'clipboard=' | tail -1)"

say "cleanup"
stop_all

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
