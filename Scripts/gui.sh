#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# UI verification driver. Builds the app, starts an isolated sandbox daemon,
# drives the real window through Accessibility, and asserts on daemon state.
#
#   ./Scripts/gui.sh probe              # check the host can drive a GUI at all
#   ./Scripts/gui.sh run split-right    # run one case
#   ./Scripts/gui.sh verify             # build + every case (merge gate)
#   ./Scripts/gui.sh list               # show cases
#
# Two backends, one set of cases. The difference is only where execution happens
# and how it is reached (docs/AUTOMATION.md §3.0):
#
#   KRAAL_GUI_BACKEND=local   default; drives Kraal on this machine
#   KRAAL_GUI_BACKEND=vm      drives Kraal inside a Tart VM
#
# Both use a *scratch* daemon. Connecting to the daemon you actually work in
# would break AGENTS.md §0.1 in the worst way: a passing test that split your
# real panes.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

BACKEND="${KRAAL_GUI_BACKEND:-local}"
VM="${KRAAL_GUI_VM:-kraal-agent}"
SCRATCH="${TMPDIR:-/tmp}/kraal-gui-$(id -u)"
# herdr exposes two sockets with different audiences:
#
#   api socket     `herdr` CLI talks here (JSON requests)
#   client socket  Kraal (and the GUI) talk here (bincode endpoint protocol)
#
# A default daemon names them `herdr.sock` and `herdr-client.sock`. Pointing
# HERDR_SOCKET_PATH at a path makes that the *api* socket and appends `-client`
# for the client socket — which is why the first version could never connect:
# it handed Kraal the api socket and every handshake died.
API_SOCKET="$SCRATCH/herdr.sock"
CLIENT_SOCKET="$SCRATCH/herdr-client.sock"
HERDR_HOME="$SCRATCH/herdr-home"
DRIVER="$ROOT/.build/out/Products/Debug/KraalGUIDriver"
ARTIFACTS="$ROOT/artifacts"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }
say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok() { printf '\033[32mok:\033[0m %s\n' "$*"; }
bad() { printf '\033[31mFAILED:\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- safety rails
#
# The one mistake that actually costs the user something. A GUI test is allowed
# to be slow, flaky or wrong; it is never allowed to rearrange the panes the
# user is working in.
guard_scratch() {
    local user_socket="$HOME/.config/herdr/herdr-client.sock"
    if [ "$API_SOCKET" = "$user_socket" ] || [ "$CLIENT_SOCKET" = "$user_socket" ]; then
        die "refusing to drive the user's real daemon ($user_socket)"
    fi
    if [ "$HERDR_HOME" = "$HOME" ]; then
        die "KRAAL_HERDR_HOME must be a scratch dir, not \$HOME"
    fi
    case "$API_SOCKET$CLIENT_SOCKET" in
        "$SCRATCH"*) ;;
        *) die "sockets must live under $SCRATCH" ;;
    esac
}

driver() {
    case "$BACKEND" in
    local) "$DRIVER" "$@" ;;
    vm) tart exec "$VM" "$DRIVER" "$@" ;;
    esac
}

# ---------------------------------------------------------------- herdr helper
#
# The socket path does **not** come from $HOME. herdr resolves the default from
# the account's real home, so `HOME=/tmp/x herdr server` still binds the user's
# own socket — verified the hard way. The only switch is `HERDR_SOCKET_PATH`
# (verified: a separate daemon came up on its own socket with an empty roster).
#
# A scratch `HERDR_HOME` is a *different* concern: it isolates the machine
# roster at ~/.local/state/herdr/client/endpoints.json, which every herdr on
# the account shares. Both are needed, neither replaces the other.
# See docs/ENVIRONMENT.md:185.

herdr() {
    case "$BACKEND" in
    local) env HOME="$HERDR_HOME" HERDR_SOCKET_PATH="$API_SOCKET" herdr "$@" ;;
    vm) tart exec "$VM" /bin/bash -lc \
        "HOME=$HERDR_HOME HERDR_SOCKET_PATH=$API_SOCKET herdr $*" ;;
    esac
}

pane_count() {
    herdr pane list 2>/dev/null \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["panes"]))' 2>/dev/null
}

# ---------------------------------------------------------------- lifecycle

cmd_probe() {
    guard_scratch
    say "backend=$BACKEND"
    [ -x "$DRIVER" ] || die "driver not built; run: swift build --product KraalGUIDriver"
    driver probe
}

start_daemon() {
    guard_scratch
    mkdir -p "$SCRATCH" "$HERDR_HOME"

    stop_daemon

    # herdr persists its session and restores panes on restart: without this the
    # "fresh" daemon came back with the previous run's panes and every case saw
    # a dirty fixture. `session.json` plus `session-snapshots/` is the state.
    rm -rf "$HERDR_HOME/.config/herdr/session.json" \
           "$HERDR_HOME/.config/herdr/session-snapshots" \
           "$SCRATCH/herdr-client.sock" "$SCRATCH/herdr-client-client.sock"

    case "$BACKEND" in
    local)
        command -v herdr >/dev/null || die "herdr not on PATH"
        # HERDR_SOCKET_PATH is what actually isolates the daemon (see the note
        # above herdr()). HOME is only for the machine roster.
        nohup env HOME="$HERDR_HOME" HERDR_SOCKET_PATH="$API_SOCKET" \
            herdr server >"$SCRATCH/herdr-server.log" 2>&1 &
        echo $! >"$SCRATCH/herdr-server.pid"
        ;;
    vm)
        tart exec "$VM" /bin/bash -lc \
            "pkill -f 'herdr server' 2>/dev/null; sleep 1
             mkdir -p $HERDR_HOME
             nohup env HOME=$HERDR_HOME HERDR_SOCKET_PATH=$API_SOCKET herdr server \
                 >$SCRATCH/herdr-server.log 2>&1 &
             echo \$! > $SCRATCH/herdr-server.pid"
        ;;
    esac

    local deadline=$((SECONDS + 20))
    while [ $SECONDS -lt $deadline ]; do
        if [ -S "$CLIENT_SOCKET" ] && [ -n "$(pane_count)" ]; then
            ok "daemon up, panes=$(pane_count)"
            return 0
        fi
        sleep 0.3
    done
    cat "$SCRATCH/herdr-server.log" >&2
    die "daemon did not come up (api=$API_SOCKET client=$CLIENT_SOCKET)"
}
stop_daemon() {
    case "$BACKEND" in
    local)
        # Find the daemon that holds *our* socket, not its parent and not every
        # process called "herdr server". Two traps hit during development:
        #
        #  - `$!` after `nohup env … herdr server &` is the wrapper shell's pid.
        #    Killing it left the real daemon running and holding the socket.
        #  - `pkill -f "HERDR_SOCKET_PATH=$SOCKET"` never matched, because the
        #    variable is in the process *environment*, not its argv — so it
        #    silently did nothing and each run inherited the previous run's
        #    panes.
        #
        # Asking the kernel who owns the socket is the only reliable answer.
        #
        # One `lsof -U` and a grep, not `lsof -p` per pid: the per-pid loop took
        # 40 seconds and dominated the whole run (100s per case, which then tripped
        # the outer timeout). A single pass takes 0.08s.
        local holder
        holder=$(lsof -U 2>/dev/null | grep -F "$API_SOCKET" | awk '{print $2}' | head -1)
        [ -n "$holder" ] && kill "$holder" 2>/dev/null

        if [ -f "$SCRATCH/herdr-server.pid" ]; then
            kill "$(cat "$SCRATCH/herdr-server.pid")" 2>/dev/null
            rm -f "$SCRATCH/herdr-server.pid"
        fi
        rm -f "$API_SOCKET" "$CLIENT_SOCKET" 2>/dev/null
        ;;
    vm)
        tart exec "$VM" /bin/bash -lc "pkill -f 'herdr server' 2>/dev/null; true" >/dev/null 2>&1
        ;;
    esac
}

launch_app() {
    say "launching Kraal against $CLIENT_SOCKET"
    # KRAAL_DEV_BACKGROUND=1 keeps it out of the Dock and off the pointer. AX
    # presses work anyway (verified), so the app never needs to be frontmost.
    KRAAL_HERDR_SOCKET="$CLIENT_SOCKET" \
    KRAAL_HERDR_HOME="$HERDR_HOME" \
    KRAAL_DEV_BACKGROUND=1 \
    KRAAL_DEV_SESSION="gui-$$" \
    nohup "$ROOT/build/Kraal.app/Contents/MacOS/KraalMac" \
        >"$SCRATCH/app.out" 2>&1 &

    local deadline=$((SECONDS + 25))
    while [ $SECONDS -lt $deadline ]; do
        if driver window 2>/dev/null | grep -q windowNumber=; then
            ok "window up: $(driver window 2>/dev/null)"
            return 0
        fi
        sleep 0.4
    done
    die "Kraal window did not appear; see $SCRATCH/app.out"
}

stop_app() {
    "$DRIVER" quit >/dev/null 2>&1
    pkill -f 'Kraal.app/Contents/MacOS/KraalMac-bin' 2>/dev/null
    pkill -f 'Kraal.app/Contents/MacOS/KraalMac' 2>/dev/null
    # Give it a moment, then stop insisting. A stuck quit must never hang the
    # whole verification run — the point of this gate is to finish with a verdict.
    local waited=0
    while [ $waited -lt 20 ]; do
        pgrep -f 'Kraal.app/Contents/MacOS/KraalMac' >/dev/null || return 0
        sleep 0.2
        waited=$((waited + 1))
    done
    pkill -9 -f 'Kraal.app/Contents/MacOS/KraalMac' 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- cases
#
# A case is three shell functions. Fixture and assertion both go through the
# scratch daemon, so they never depend on how Kraal renders anything.

case_split_right() {
    # A fresh daemon has no panes at all, so the fixture has to create the
    # starting state instead of asserting it already exists. `workspace create`
    # also creates the root pane (w1:p1) — that is the thing to split.
    fixture() {
        # A fresh daemon reports zero panes, but a daemon left over from an
        # earlier run may already have some. Create a workspace only when the
        # roster is empty, so the fixture is idempotent against both.
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "1" ]
    }
    action() {
        driver press --title "Split Right"
    }
    assert() {
        local before="$1" after
        after=$(pane_count)
        [ "$after" = "$((before + 1))" ] || {
            echo "pane count did not grow: $before -> $after"
            return 1
        }
        # Same tab, distinct ids: a split must not create a new tab, and it must
        # not silently reuse the source pane.
        herdr pane list | python3 -c '
import json, sys
panes = json.load(sys.stdin)["result"]["panes"]
tabs = {p["tab_id"] for p in panes}
ids = [p["pane_id"] for p in panes]
assert len(tabs) == 1, f"expected 1 tab, got {tabs}"
assert len(set(ids)) == len(ids), f"duplicate pane ids: {ids}"
print("tabs=1 panes=" + ",".join(ids))
'
    }
}

# ---------------------------------------------------------------- runner

run_case() {
    local name="$1"
    local runner="case_${name//-/_}"
    if ! declare -F "$runner" >/dev/null; then
        die "no such case '$name' (see: $0 list)"
    fi

    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)-$name"
    local dir="$ARTIFACTS/$run_id"
    mkdir -p "$dir"

    say "case $name  ($run_id)"
    stop_app
    stop_daemon
    start_daemon
    launch_app

    driver ax --out "$dir/ax-before.json" >/dev/null 2>&1
    herdr pane list >"$dir/pane-before.json" 2>/dev/null
    driver shot -o "$dir/shot-before.png" >/dev/null 2>&1

    local before
    $runner
    local failure=""
    if ! fixture; then
        failure="fixture"
    else
        # `before` must be read AFTER the fixture: the fixture is what creates the
        # starting state (a fresh daemon has zero panes). Reading it earlier made
        # `before=0`, so a run that only created the fixture pane still satisfied
        # `after == before + 1` and reported a pass for a split that never happened.
        before=$(pane_count)
        if [ -z "$before" ]; then
            failure="harness"
            echo "cannot read pane count after the fixture ran" >&2
        elif ! action; then
            failure="action"
        else
            local detail
            if ! detail=$(assert "$before" 2>&1); then
                failure="assert"
                echo "$detail" >&2
            fi
        fi
    fi

    herdr pane list >"$dir/pane-after.json" 2>/dev/null
    driver ax --out "$dir/ax-after.json" >/dev/null 2>&1
    driver shot -o "$dir/shot-after.png" >/dev/null 2>&1
    cp "$SCRATCH/app.out" "$dir/app.out" 2>/dev/null
    cp "$SCRATCH/herdr-server.log" "$dir/herdr-server.log" 2>/dev/null

    local after
    after=$(pane_count)
    local status="passed"
    local code=0
    [ -n "$failure" ] && { status="failed"; code=1; }

    cat >"$dir/summary.json" <<JSON
{
  "case": "$name",
  "backend": "$BACKEND",
  "status": "$status",
  "exitCode": $code,
  "failureType": "${failure:-none}",
  "panesBefore": "$before",
  "panesAfter": "$after"
}
JSON

    stop_app
    stop_daemon

    if [ "$code" -eq 0 ]; then
        ok "$name passed (panes $before -> $after)"
    else
        bad "$name failed at $failure (panes $before -> $after)"
        printf '    artifacts: %s\n' "$dir"
    fi
    return "$code"
}

all_cases() { echo "split-right"; }

# ---------------------------------------------------------------- entrypoint

cmd_list() { all_cases; }

cmd_run() {
    [ -d "$ROOT/build/Kraal.app" ] || die "no build/Kraal.app; run: ./Scripts/build-app.sh"
    local failed=0
    if [ $# -eq 0 ]; then
        for c in $(all_cases); do run_case "$c" || failed=1; done
    else
        for c in "$@"; do run_case "$c" || failed=1; done
    fi
    return "$failed"
}

cmd_verify() {
    say "building"
    ./Scripts/build-app.sh >"$SCRATCH-build.log" 2>&1
    local code=$?
    if [ $code -ne 0 ]; then
        tail -20 "$SCRATCH-build.log"
        die "build failed"
    fi
    ok "build"
    cmd_run "$@"
}

# The dispatch arms must propagate the exit status: `cmd_run` returns 1 when a
# case fails, and a bare `case` arm discards it — so the injection test printed
# "FAILED" on stdout while the script still exited 0. That is precisely the
# green-looking gate this exercise exists to remove.
case "${1:-}" in
probe) cmd_probe ;;
list) cmd_list ;;
run) shift; cmd_run "$@"; exit $? ;;
verify) shift; cmd_verify "$@"; exit $? ;;
*) sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 2 ;;
esac
