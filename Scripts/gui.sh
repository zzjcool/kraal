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

# Derived from the socket path so two concurrent runs cannot collide on a log
# file, and so the name here matches what KraalLog picks.
SESSION="${KRAAL_DEV_SESSION:-gui-$$}"

# True when the login window owns the session. Synthetic events are posted to
# whatever is frontmost; while locked that is loginwindow, so they silently do
# nothing useful.
screen_locked() {
    local front
    front=$(python3 -c '
import subprocess, json
out = subprocess.run(["ioreg", "-n", "Root", "-d1"], capture_output=True, text=True).stdout
print("locked" if "<key>IOConsoleLocked</key>" in out and
      "<true/>" in out.split("<key>IOConsoleLocked</key>")[1][:40] else "unlocked")
' 2>/dev/null)
    [ "$front" = "locked" ]
}

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
    KRAAL_DEV_SESSION="$SESSION" \
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


# ---------------------------------------------------------------- assertions
#
# Three tiers, strongest first (docs/AUTOMATION.md §4):
#
#   1. daemon state       survives renderer bugs, so a pass here means the command
#                         reached the daemon and was applied
#   2. AX tree            proves the UI exists and is reachable
#   3. screenshot         weakest; says nothing about correctness
#
# Every assertion prints what it checked. A gate that cannot explain itself is
# indistinguishable from a gate that always passes.

ASSERTIONS=()
ASSERTION_FAILURES=0

# Record one assertion. `detail` is printed either way so a passing run still
# shows what was actually verified.
check() {
    local what="$1" result="$2" detail="${3:-}"
    if [ "$result" -eq 0 ]; then
        ASSERTIONS+=("pass|$what|$detail")
        printf '  \033[32m✓\033[0m %s%s\n' "$what" "${detail:+ ($detail)}"
    else
        ASSERTIONS+=("FAIL|$what|$detail")
        ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
        printf '  \033[31m✗\033[0m %s%s\n' "$what" "${detail:+ ($detail)}"
    fi
    return "$result"
}

# `herdr pane layout` is the geometry oracle. `pane list` has no sizes at all,
# which is why the first version of this script could not tell a correct split
# from one that produced two panes with the wrong ratio.
# First pane id, sorted so it does not depend on the daemon's map order (which
# is neither insertion nor lexical — verified with three samples).
first_pane_id() {
    herdr pane list 2>/dev/null | python3 -c '
import json, sys
print(sorted(p["pane_id"] for p in json.load(sys.stdin)["result"]["panes"])[0])
'
}

pane_layout() {
    herdr pane layout 2>/dev/null
}

# Runs a python snippet against the layout JSON on stdin. Keeps the geometry
# checks readable and keeps `jq` out of the dependency list.
layout_check() {
    python3 -c "$1"
}

# ---------------------------------------------------------------- cases
#
# A case is up to four shell functions:
#
#   fixture   create the starting state (returns 1 if it cannot)
#   action    perform the UI interaction
#   assert    verify, using check(); returns 1 on any failure
#   requires  optional; "focus" means the case cannot run while the screen is
#             locked (synthetic events need a frontmost app), "ax" means it can

# split_right through the menu bar. The baseline case: if this fails, nothing
# else is meaningful.
case_split_right() {
    requires() { echo ax; }
    fixture() {
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
        check "pane count grows by one" \
            "$([ "$after" = "$((before + 1))" ] && echo 0 || echo 1)" "$before -> $after" || return 1
        # Geometry is what the count cannot see: a split that produces two panes
        # at a 0.9 ratio is broken and would pass a count-only assertion.
        local geometry
        geometry=$(pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
panes = layout["panes"]
splits = layout["splits"]
problems = []
if len(splits) != 1:
    problems.append(f"expected 1 split, got {len(splits)}")
else:
    ratio = splits[0]["ratio"]
    if abs(ratio - 0.5) > 0.05:
        problems.append(f"split ratio is {ratio}, expected ~0.5")
    if splits[0]["direction"] != "right":
        problems.append("split direction is " + splits[0]["direction"] + ", expected right")
widths = sorted(p["rect"]["width"] for p in panes)
if len(widths) == 2 and widths[1] - widths[0] > 2:
    problems.append(f"pane widths are lopsided: {widths}")
focused = layout["focused_pane_id"]
if focused not in [p["pane_id"] for p in panes]:
    problems.append(f"focused pane {focused} is not in the layout")
if problems:
    print("; ".join(problems)); sys.exit(1)
print(f"ratio=0.5 widths={widths} focused={focused}")
')
        check "split geometry is two equal halves" "$?" "$geometry" || return 1
        local tabs
        tabs=$(herdr pane list | layout_check '
import json, sys
panes = json.load(sys.stdin)["result"]["panes"]
tabs = {p["tab_id"] for p in panes}
ids = [p["pane_id"] for p in panes]
if len(tabs) != 1:
    print(f"expected 1 tab, got {sorted(tabs)}"); sys.exit(1)
if len(set(ids)) != len(ids):
    print(f"duplicate pane ids: {ids}"); sys.exit(1)
print(f"tabs=1 panes={ids}")
')
        check "split stays inside one tab, ids distinct" "$?" "$tabs"
    }
}

# Same command, reached through the app menu instead of a bare AXPress.
#
# A separate case on purpose: `press --title` only finds items in menus macOS has
# already populated, and it cannot tell the View menu's `Split Right` from the
# context menu's. `menu` opens the named menu first and scopes the search to it,
# which is the path a user actually takes.
case_menu_split() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "1" ]
    }
    action() {
        driver menu --menu View --item "Split Right"
    }
    assert() {
        local before="$1" after
        after=$(pane_count)
        check "menu item splits the pane" \
            "$([ "$after" = "$((before + 1))" ] && echo 0 || echo 1)" "$before -> $after" || return 1
        local direction
        direction=$(pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
splits = layout["splits"]
if len(splits) != 1:
    print(f"expected 1 split, got {len(splits)}"); sys.exit(1)
print(splits[0]["direction"])
')
        check "menu split produced a right split" \
            "$([ "$direction" = "right" ] && echo 0 || echo 1)" "direction=$direction"
    }
}

# Split Down: proves the direction is honoured rather than hard-coded.
case_split_down() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "1" ]
    }
    action() {
        driver press --title "Split Down"
    }
    assert() {
        local before="$1" after
        after=$(pane_count)
        check "pane count grows by one" \
            "$([ "$after" = "$((before + 1))" ] && echo 0 || echo 1)" "$before -> $after" || return 1
        local geometry
        geometry=$(pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
splits = layout["splits"]
panes = layout["panes"]
problems = []
if len(splits) != 1:
    problems.append(f"expected 1 split, got {len(splits)}")
elif splits[0]["direction"] != "down":
    problems.append("direction is " + splits[0]["direction"] + ", expected down")
heights = sorted(p["rect"]["height"] for p in panes)
if len(heights) == 2 and heights[1] - heights[0] > 2:
    problems.append(f"pane heights are lopsided: {heights}")
if problems:
    print("; ".join(problems)); sys.exit(1)
print(f"direction=down heights={heights}")
')
        check "split-down stacks two equal rows" "$?" "$geometry"
    }
}

# Close Pane via the menu bar: the inverse of split, and the first case that has
# to prove a pane *disappeared*.
case_close_pane() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        if [ "$(pane_count)" = "1" ]; then
            herdr pane split --pane "$(first_pane_id)" --direction right >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "2" ]
    }
    action() {
        driver press --title "Close Pane"
    }
    assert() {
        local before="$1" after
        after=$(pane_count)
        check "pane count shrinks by one" \
            "$([ "$after" = "$((before - 1))" ] && echo 0 || echo 1)" "$before -> $after" || return 1
        local remaining
        remaining=$(pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
panes = layout["panes"]
splits = layout["splits"]
problems = []
if len(panes) != 1:
    problems.append(f"expected 1 pane left, got {len(panes)}")
if splits:
    problems.append(f"a lone pane must have no splits, got {len(splits)}")
if problems:
    print("; ".join(problems)); sys.exit(1)
print("1 pane, 0 splits")
')
        check "layout collapses to a single unsplit pane" "$?" "$remaining"
    }
}

# ---------------------------------------------------------------- runner

# Reads a case's declared requirement without executing the case.
#
# The first version ran the case function and then called `requires`, which
# executed `fixture`/`action`/`assert` definitions with no arguments and, when the
# case did not exist, reported "no such case" for a case that was right there.
case_needs() {
    local name="$1"
    local text
    text=$(declare -f "case_${name//-/_}" 2>/dev/null) || { echo ""; return; }
    case "$text" in
    *"requires() { echo focus"*) echo focus ;;
    *) echo ax ;;
    esac
}

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
    ASSERTIONS=()
    ASSERTION_FAILURES=0

    # A case may declare that it needs a frontmost app. Synthetic events go to
    # whoever is frontmost, so running those while the screen is locked posts them
    # at loginwindow — which looks exactly like a broken feature. Refuse early with
    # an environment error (exit 2) instead of a product failure (exit 1).
    local needs
    needs=$(case_needs "$name")
    if [ "$needs" = "focus" ] && screen_locked; then
        bad "$name needs an unlocked screen (synthetic events go to loginwindow)"
        printf '    skip: unlock the machine, or run an ax-only case\n'
        return 2
    fi

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
            # Run `assert` in *this* shell, not in a command substitution. Inside
            # `$(assert ...)` every `check` call appends to a copy of ASSERTIONS
            # that dies with the subshell, so summary.json recorded "passed" with
            # an empty assertion list — a gate that cannot say what it checked.
            # The log is captured with a redirect instead.
            local assert_log="$dir/assert.log"
            if ! assert "$before" >"$assert_log" 2>&1; then
                failure="assert"
            fi
            # Always surface the assertions, pass or fail: a passing run should
            # still show what was verified.
            cat "$assert_log"
        fi
    fi

    herdr pane list >"$dir/pane-after.json" 2>/dev/null
    driver ax --out "$dir/ax-after.json" >/dev/null 2>&1
    driver shot -o "$dir/shot-after.png" >/dev/null 2>&1
    cp "$SCRATCH/app.out" "$dir/app.out" 2>/dev/null
    cp "$SCRATCH/herdr-server.log" "$dir/herdr-server.log" 2>/dev/null
    # Kraal writes to ~/Library/Logs/Kraal-<session>.log, not to stderr, and the
    # session name is derived from KRAAL_DEV_SESSION. Without this copy the log
    # never reached the artifacts, even though docs/AUTOMATION.md promised it.
    cp "$HOME/Library/Logs/Kraal-$SESSION.log" "$dir/kraal.log" 2>/dev/null

    local after
    after=$(pane_count)
    local status="passed"
    local code=0
    if [ -n "$failure" ]; then
        status="failed"; code=1
        # Only on failure: a screenshot costs a second and proves least.
        driver shot -o "$dir/shot-failure.png" >>"$dir/app.out" 2>&1
    fi

    local assertions_json="[]"
    if [ ${#ASSERTIONS[@]} -gt 0 ]; then
        assertions_json=$(printf '%s\n' "${ASSERTIONS[@]}" | layout_check '
import json, sys
rows = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    status, what, detail = (line.split("|", 2) + ["", ""])[:3]
    rows.append({"status": "pass" if status == "pass" else "FAIL",
                 "what": what, "detail": detail})
print(json.dumps(rows, indent=2))
')
    fi
    cat >"$dir/summary.json" <<JSON
{
  "case": "$name",
  "backend": "$BACKEND",
  "status": "$status",
  "exitCode": $code,
  "failureType": "${failure:-none}",
  "panesBefore": "$before",
  "panesAfter": "$after",
  "assertions": $assertions_json
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

all_cases() { echo "split-right menu-split split-down close-pane"; }

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
