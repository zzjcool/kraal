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
#   KRAAL_GUI_BACKEND=vm      default; runs entirely inside a Tart VM
#   KRAAL_GUI_BACKEND=local   drives Kraal on this machine (interrupts the user)
#
# Why `vm` is the default: a `local` run owns the pointer and the keyboard while
# it works. During development that interrupted the user mid-task, which is
# exactly what AGENTS.md §0.1 forbids — "no exploration zone" has to include the
# desktop itself, not just the daemon. `local` is for visual judgement that needs
# a real GPU, and it refuses focus-stealing cases unless KRAAL_GUI_ALLOW_FOCUS=1.
#
# Both use a *scratch* daemon. Connecting to the daemon you actually work in
# would break AGENTS.md §0.1 in the worst way: a passing test that split your
# real panes.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Defaults to the VM on purpose. Driving the desktop is the exception: it takes
# the pointer and keyboard away from whoever is using the machine, which is the
# one thing a verification gate must never do unasked. `local` stays available for
# visual work that needs a real GPU.
BACKEND="${KRAAL_GUI_BACKEND:-vm}"
VM="${KRAAL_GUI_VM:-kraal-agent}"
SCRATCH="${TMPDIR:-/tmp}/kraal-gui-$(id -u)"
# The guest gets its own scratch root. Nothing under it is visible to the host
# except through `tart exec`, which is the point: a VM run must not be able to
# touch this machine's files even by accident.
VM_ROOT="/tmp/kraal-gui"
VM_DRIVER="$VM_ROOT/KraalGUIDriver"
VM_APP="$VM_ROOT/Kraal.app"
# herdr exposes two sockets with different audiences:
#
#   api socket     `herdr` CLI talks here (JSON requests)
#   client socket  Kraal (and the GUI) talk here (bincode endpoint protocol)
#
# A default daemon names them `herdr.sock` and `herdr-client.sock`. Pointing
# HERDR_SOCKET_PATH at a path makes that the *api* socket and appends `-client`
# for the client socket — which is why the first version could never connect:
# it handed Kraal the api socket and every handshake died.
#
# Paths are per-backend on purpose. A host path like /var/folders/T/kraal-gui-501
# does not exist inside the guest, so handing it to a VM-side Kraal silently
# produced a client that could not connect. Everything the guest touches lives
# under $VM_ROOT.
if [ "$BACKEND" = "vm" ]; then
    API_SOCKET="$VM_ROOT/herdr.sock"
    CLIENT_SOCKET="$VM_ROOT/herdr-client.sock"
    HERDR_HOME="$VM_ROOT/herdr-home"
else
    API_SOCKET="$SCRATCH/herdr.sock"
    CLIENT_SOCKET="$SCRATCH/herdr-client.sock"
    HERDR_HOME="$SCRATCH/herdr-home"
fi
DRIVER="$ROOT/.build/out/Products/Debug/KraalGUIDriver"
HOST_ARTIFACTS="$ROOT/artifacts"
if [ "$BACKEND" = "vm" ]; then
    ARTIFACTS="$VM_ROOT/artifacts"
else
    ARTIFACTS="$HOST_ARTIFACTS"
fi

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

# Backends are not a preference, they are a safety boundary.
#
# `local` drives the desktop the user is working in. Anything that has to steal
# focus (synthetic clicks, drags, key events) is therefore disruptive by nature —
# during development this cost the user their focus mid-task, which is exactly
# what AGENTS.md §0.1 forbids. Two rules follow:
#
#   1. A case that needs focus may not run on `local` unless the user opts in.
#   2. The GUI gate defaults to `vm`, so the unattended path is the quiet one.
needs_focus_allowed() {
    if [ "$BACKEND" = "vm" ]; then
        return 0
    fi
    [ "${KRAAL_GUI_ALLOW_FOCUS:-0}" = "1" ]
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
    # The real daemon's socket path only means anything on the host. Inside the
    # guest the same path is a different filesystem, so comparing against it there
    # would be theatre — and worse, it is exactly what made the first VM run fail:
    # the rail insisted the socket live under the host's $TMPDIR, which the guest
    # cannot see.
    if [ "$BACKEND" = "vm" ]; then
        case "$API_SOCKET$CLIENT_SOCKET$HERDR_HOME" in
            "$VM_ROOT"*) return 0 ;;
            *) die "vm sockets must live under $VM_ROOT (got $API_SOCKET)" ;;
        esac
    fi

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
    # The guest cannot see the host's .build directory, so it runs its own copy.
    # Arguments are quoted because this goes through a shell in the guest.
    vm) tart exec "$VM" "$VM_DRIVER" "$@" ;;
    esac
}

# ---------------------------------------------------------------- vm plumbing
#
# The guest has no Xcode and slow network (docs/ENVIRONMENT.md §4.5), so the app
# is built on the host and pushed over stdio. `tart exec -i` with a tar pipe is
# the transport: the guest has no sshd and no shared directory.
vm_running() {
    tart list 2>/dev/null | awk -v vm="$VM" '$2 == vm && /running/ { found = 1 } END { exit !found }'
}

vm_start() {
    if vm_running; then
        ok "vm $VM already running"
        return 0
    fi
    say "booting vm $VM (headless)"
    nohup tart run --no-graphics "$VM" >"$SCRATCH/vm.log" 2>&1 &
    local deadline=$((SECONDS + 120))
    while [ $SECONDS -lt $deadline ]; do
        if tart exec "$VM" /bin/bash -lc 'echo ready' >/dev/null 2>&1; then
            ok "vm up"
            return 0
        fi
        sleep 2
    done
    tail -20 "$SCRATCH/vm.log" >&2
    die "vm $VM did not become reachable in 120s"
}

# Pushes the driver, the app bundle and a copy of herdr into the guest.
#
# herdr is pushed too: the guest has no Homebrew and its network is unreliable,
# and the point of the run is to exercise Kraal, not to provision a machine.
vm_deploy() {
    [ -x "$DRIVER" ] || die "no driver at $DRIVER; run: swift build --product KraalGUIDriver"
    [ -d "$ROOT/build/Kraal.app" ] || die "no build/Kraal.app; run: ./Scripts/build-app.sh"
    say "deploying to vm $VM"
    tart exec "$VM" /bin/bash -lc "mkdir -p $VM_ROOT" >/dev/null 2>&1 \
        || die "cannot create $VM_ROOT in the guest"

    # One tar stream per artefact. `-i` is mandatory: without it stdio is not
    # wired up and the guest writes a zero-byte file (hit during VM probing).
    # `cd` into the destination rather than passing `-C`: `tar -xzf - -C dir`
    # silently extracted into the wrong place through `tart exec -i`, and the
    # failure surfaced as a confusing chmod error on a file that was never there.
    tar -czf - -C "$(dirname "$DRIVER")" "$(basename "$DRIVER")" \
        | tart exec -i "$VM" /bin/bash -lc "cd $VM_ROOT && tar -xzf - && chmod +x $VM_DRIVER" \
        || die "failed to push the driver into the guest"

    tar -czf - -C "$ROOT/build" Kraal.app \
        | tart exec -i "$VM" /bin/bash -lc "rm -rf $VM_APP && cd $VM_ROOT && tar -xzf -" \
        || die "failed to push Kraal.app into the guest"

    # `type -P` and not `command -v`: this file defines a `herdr()` wrapper, and
    # inside that scope `command -v herdr` returns the *function* name, so the tar
    # below looked for a file called "herdr" in a directory called nothing.
    local herdr_bin
    herdr_bin=$(type -P herdr) || die "herdr not on PATH"
    tar -czf - -C "$(dirname "$herdr_bin")" "$(basename "$herdr_bin")" \
        | tart exec -i "$VM" /bin/bash -lc "mkdir -p $VM_ROOT/bin && cd $VM_ROOT/bin && tar -xzf -" \
        || die "failed to push herdr into the guest"

    # The app is ad-hoc signed on the host; copying it into the guest keeps the
    # signature but the quarantine attribute would make Gatekeeper refuse it.
    tart exec "$VM" /bin/bash -lc \
        "xattr -dr com.apple.quarantine $VM_APP 2>/dev/null; true" >/dev/null 2>&1
    ok "deployed driver + Kraal.app + herdr"
}

# Copies the artefacts the guest produced back to the host.
#
# The run writes to the guest's paths (logs, AX dumps, screenshots), so a case is
# only reviewable after these come back. Missing files are not an error: not every
# case produces every artefact.
vm_collect() {
    local guest_dir="$1" dest="$2"
    tart exec -i "$VM" /bin/bash -lc "cd $guest_dir 2>/dev/null && tar -czf - . 2>/dev/null" \
        | tar -xzf - -C "$dest" 2>/dev/null || true
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
    # The guest has no herdr on PATH — it gets an explicit copy at $VM_ROOT/bin,
    # because it has no Homebrew and its network is unreliable. Calling plain
    # `herdr` here produced "command not found" from inside the VM while the
    # daemon itself was running fine.
    vm) tart exec "$VM" /bin/bash -lc \
        "HOME=$HERDR_HOME HERDR_SOCKET_PATH=$API_SOCKET $VM_ROOT/bin/herdr $*" ;;
    esac
}

pane_count() {
    herdr pane list 2>/dev/null \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["panes"]))' 2>/dev/null
}

workspace_count() {
    herdr workspace list 2>/dev/null \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["workspaces"]))' 2>/dev/null
}

# Whether the daemon currently holds a worktree group, and how much of one.
#
# `grouped` — at least one repo key is shared by a main checkout and a linked
#   worktree. That pair is the daemon's own rule for a group
#   (`sidebar.rs:573-601`), and it is what makes `workspace.close` refuse without
#   `close_group`. Two unrelated workspaces are not a group.
# `partial` — only one side of a pair survived, which is the half-closed state a
#   botched close leaves behind.
# `alone`  — one workspace, no group; nothing left to close.
# `empty`  — no workspaces at all.
# The workspace id of the group's main checkout, which is the only member the
# daemon refuses to close alone (`actions.rs:899-917`).
main_checkout_workspace_id() {
    herdr workspace list 2>/dev/null | python3 -c '
import json, sys
by_key = {}
for workspace in json.load(sys.stdin)["result"]["workspaces"]:
    worktree = workspace.get("worktree")
    if not worktree:
        continue
    by_key.setdefault(worktree["repo_key"], []).append(
        (workspace["workspace_id"], worktree["is_linked_worktree"])
    )
for members in by_key.values():
    if any(linked for _, linked in members) and any(not linked for _, linked in members):
        for workspace_id, linked in members:
            if not linked:
                print(workspace_id); sys.exit(0)
' 2>/dev/null
}

workspace_group_state() {
    herdr workspace list 2>/dev/null | python3 -c '
import json, sys
workspaces = json.load(sys.stdin)["result"]["workspaces"]
if not workspaces:
    print("empty"); sys.exit(0)
by_key = {}
for workspace in workspaces:
    worktree = workspace.get("worktree")
    if not worktree:
        continue
    by_key.setdefault(worktree["repo_key"], []).append(worktree["is_linked_worktree"])
for key, linked_flags in by_key.items():
    has_linked = any(linked_flags)
    has_parent = not all(linked_flags)
    if has_linked and has_parent:
        print("grouped"); sys.exit(0)
    if has_linked or has_parent:
        # More than one workspace on a key with only one side present is the
        # inconsistent state worth flagging; a single workspace is just alone.
        if len(linked_flags) > 1:
            print("partial"); sys.exit(0)
if len(workspaces) == 1:
    print("alone")
else:
    # Several workspaces, none of them grouped: closing one must not touch the
    # others, so this is not the half-closed state either.
    print("ungrouped")
' 2>/dev/null
}

# Prints the app's most recent `layout: container=WxH` measurement as "W H".
#
# The drag coordinate needs the width of the terminal container, which is the
# window minus the sidebar. That number was previously written down as 959 — it
# was correct for a 1180pt window and wrong for every other size, and a narrow
# window (VM screen 1024x768) pushed the computed divider position into the right
# hand pane. The drag then landed on a terminal instead of the divider and the
# case reported "stuck: the drag never reached the daemon", which reads like a
# product bug. Ask the app instead of remembering.
container_size() {
    local log="Kraal-$SESSION.log" line
    case "$BACKEND" in
    local) line=$(tail -200 "$HOME/Library/Logs/$log" 2>/dev/null | grep 'layout: container=' | tail -1) ;;
    vm) line=$(tart exec "$VM" /bin/bash -lc "tail -200 ~/Library/Logs/$log 2>/dev/null" 2>/dev/null \
            | grep 'layout: container=' | tail -1) ;;
    esac
    [ -n "$line" ] || return 1
    printf '%s' "$line" | sed -n 's/.*container=\([0-9]*\)x\([0-9]*\).*/\1 \2/p'
}

# ---------------------------------------------------------------- lifecycle

cmd_probe() {
    guard_scratch
    say "backend=$BACKEND"
    [ -x "$DRIVER" ] || die "driver not built; run: swift build --product KraalGUIDriver"
    # The probe runs the driver *inside* the guest, so the backend has to be
    # provisioned first — otherwise the first thing a new user sees is a tart
    # exit code instead of "here is what is wrong with this machine".
    if [ "$BACKEND" = "vm" ]; then
        mkdir -p "$SCRATCH"
        [ -d "$ROOT/build/Kraal.app" ] || die "no build/Kraal.app; run: ./Scripts/build-app.sh"
        vm_start
        vm_deploy
    fi
    driver probe
}

start_daemon() {
    guard_scratch
    mkdir -p "$SCRATCH"
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /bin/bash -lc "mkdir -p $VM_ROOT $HERDR_HOME" >/dev/null 2>&1
    else
        mkdir -p "$HERDR_HOME"
    fi

    stop_daemon

    # herdr persists its session and restores panes on restart: without this the
    # "fresh" daemon came back with the previous run's panes and every case saw
    # a dirty fixture. `session.json` plus `session-snapshots/` is the state.
    rm -rf "$HERDR_HOME/.config/herdr/session.json" \
           "$HERDR_HOME/.config/herdr/session-snapshots" \
           "$SCRATCH/herdr-client.sock" "$SCRATCH/herdr-client-client.sock"

    case "$BACKEND" in
    local)
        type -P herdr >/dev/null || die "herdr not on PATH"
        # HERDR_SOCKET_PATH is what actually isolates the daemon (see the note
        # above herdr()). HOME is only for the machine roster.
        nohup env HOME="$HERDR_HOME" HERDR_SOCKET_PATH="$API_SOCKET" \
            herdr server >"$SCRATCH/herdr-server.log" 2>&1 &
        echo $! >"$SCRATCH/herdr-server.pid"
        ;;
    vm)
        # Every path here is a guest path. Passing the host's $SCRATCH through
        # produced "/var/folders/...: No such file or directory" from inside the
        # VM, where that directory does not exist.
        tart exec "$VM" /bin/bash -lc \
            "pkill -f 'herdr server' 2>/dev/null; sleep 1
             mkdir -p $HERDR_HOME
             nohup env HOME=$HERDR_HOME HERDR_SOCKET_PATH=$API_SOCKET \
                 $VM_ROOT/bin/herdr server >$VM_ROOT/herdr-server.log 2>&1 &
             echo \$! > $VM_ROOT/herdr-server.pid
             sleep 2
             echo started"
        ;;
    esac

    local deadline=$((SECONDS + 20))
    while [ $SECONDS -lt $deadline ]; do
        if [ -n "$(pane_count)" ]; then
            ok "daemon up, panes=$(pane_count)"
            return 0
        fi
        sleep 0.3
    done
    case "$BACKEND" in
    local) cat "$SCRATCH/herdr-server.log" >&2 ;;
    vm) tart exec "$VM" /bin/bash -lc "cat $VM_ROOT/herdr-server.log" >&2 ;;
    esac
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
        # herdr restores panes from $HERDR_HOME across restarts, so a plain kill
        # leaves the next run with this run's panes — the fixture then sees
        # panes=2 and fails for a reason that has nothing to do with the product.
        # The local arm already deletes this state; the vm arm has to do the same
        # in the guest.
        tart exec "$VM" /bin/bash -lc \
            "pkill -f 'herdr server' 2>/dev/null; sleep 1
             rm -rf $HERDR_HOME/.config/herdr/session.json \
                    $HERDR_HOME/.config/herdr/session-snapshots \
                    $API_SOCKET $API_SOCKET-client 2>/dev/null
             true" </dev/null >/dev/null 2>&1
        ;;
    esac
}

launch_app() {
    say "launching Kraal (backend=$BACKEND) against $CLIENT_SOCKET"
    # KRAAL_DEV_BACKGROUND=1 keeps it out of the Dock and off the pointer. AX
    # presses work anyway (verified), so a case that only needs AX never has to be
    # frontmost. Cases that post synthetic events flip this to 0 — see needs_focus.
    local background=1
    [ "$(case_needs "$CURRENT_CASE")" = "focus" ] && background=0

    case "$BACKEND" in
    local)
        KRAAL_HERDR_SOCKET="$CLIENT_SOCKET" \
        KRAAL_HERDR_HOME="$HERDR_HOME" \
        KRAAL_DEV_BACKGROUND="$background" \
        KRAAL_DEV_SESSION="$SESSION" \
        nohup "$ROOT/build/Kraal.app/Contents/MacOS/KraalMac" \
            >"$SCRATCH/app.out" 2>&1 &
        ;;
    vm)
        # Start the app inside the guest's Aqua session. `tart exec` lands there
        # (docs/ENVIRONMENT.md §4.5), which is what makes synthetic events work
        # in the VM at all.
        tart exec "$VM" /bin/bash -lc \
            "pkill -f '$VM_APP/Contents/MacOS/KraalMac' 2>/dev/null; sleep 1
             cd $VM_ROOT
             KRAAL_HERDR_SOCKET=$CLIENT_SOCKET KRAAL_HERDR_HOME=$HERDR_HOME \
             KRAAL_DEV_BACKGROUND=$background KRAAL_DEV_SESSION=$SESSION \
             nohup $VM_APP/Contents/MacOS/KraalMac > $VM_ROOT/app.out 2>&1 </dev/null &
             disown 2>/dev/null
             echo launched" \
            </dev/null >/dev/null 2>&1
        ;;
    esac

    local deadline=$((SECONDS + 25))
    while [ $SECONDS -lt $deadline ]; do
        if driver window 2>/dev/null | grep -q windowNumber=; then
            ok "window up: $(driver window 2>/dev/null)"
            return 0
        fi
        sleep 0.4
    done
    case "$BACKEND" in
    local) die "Kraal window did not appear; see $SCRATCH/app.out" ;;
    vm)
        tart exec "$VM" /bin/bash -lc "cat $VM_ROOT/app.out 2>/dev/null | tail -20" >&2
        die "Kraal window did not appear in $VM"
        ;;
    esac
}

stop_app() {
    case "$BACKEND" in
    local)
        "$DRIVER" quit >/dev/null 2>&1
        pkill -f 'Kraal.app/Contents/MacOS/KraalMac-bin' 2>/dev/null
        pkill -f 'Kraal.app/Contents/MacOS/KraalMac' 2>/dev/null
        # Give it a moment, then stop insisting. A stuck quit must never hang the
        # whole run — the point of this gate is to finish with a verdict.
        local waited=0
        while [ $waited -lt 20 ]; do
            pgrep -f 'Kraal.app/Contents/MacOS/KraalMac' >/dev/null || return 0
            sleep 0.2
            waited=$((waited + 1))
        done
        pkill -9 -f 'Kraal.app/Contents/MacOS/KraalMac' 2>/dev/null
        ;;
    vm)
        # Only ever touch the guest's copy. This arm previously fell through to
        # the host's pkill, which would have killed a Kraal the user was using.
        tart exec "$VM" "$VM_DRIVER" quit >/dev/null 2>&1
        tart exec "$VM" /bin/bash -lc \
            "pkill -f '$VM_APP/Contents/MacOS/KraalMac' 2>/dev/null; true" >/dev/null 2>&1
        ;;
    esac
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


# Assert the pane scrollbar is drawn inside its own pane.
#
# Why this needs a GUI case at all: the lane's position is `rect(for:)` (container
# coordinates) rebased onto the pane, and that rebase is invisible to `swift test`
# — a SwiftUI `body` has no inspectable output. An early version attached the
# overlay *after* `.position`, where the view's bounds are the whole pane
# container, so subtracting the pane origin a second time put every lane one
# pane-width to the left and pinned it to the container's top edge. The pane at the
# origin looked right, which is why the unit tests passed.
#
# The assertion reads the app's own `scrollbar:` log line, which prints both
# rectangles. That is a measurement of what SwiftUI actually laid out, not a
# re-statement of the arithmetic under test.
case_scrollbar() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        # Two panes, because the bug is invisible with one: the pane at the origin
        # is exactly the case where a doubled subtraction still gives the right
        # answer.
        if [ "$(pane_count)" = "1" ]; then
            herdr pane split --pane "$(first_pane_id)" --direction right >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "2" ] || return 1
        # Scrollback is what makes the daemon send a `scrollbar_rect` at all:
        # without history there is no lane, and the case would assert nothing.
        herdr pane run "$(first_pane_id)" "seq 1 300" >/dev/null 2>&1 || true
        sleep 2
        pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
sys.exit(0 if len(layout["panes"]) == 2 and layout["splits"] else 1)
'
    }
    action() {
        # Nothing to do: the scrollbar is drawn by the pane's own view, so all this
        # case needs is for a frame to have been laid out. The `sleep` gives the
        # next surface frame — and therefore the next scrollbar log line — time to
        # arrive.
        sleep 2
        return 0
    }
    assert() {
        local lines verdict
        # `collect_app_log` takes a **host** directory (`host_dir`), not the guest
        # one: with the vm backend it pipes the log out of the guest. Passing
        # `$dir` here wrote nothing and the case failed with "no such file" — the
        # same shape of bug this exercise treats as a gate failure.
        collect_app_log "$host_dir"
        lines=$(grep -c 'scrollbar: ' "$host_dir/kraal.log" 2>/dev/null || echo 0)
        check "the app laid out at least one scrollbar" \
            "$([ "$lines" -gt 0 ] && echo 0 || echo 1)" "$lines log lines"

        verdict=$(python3 - "$host_dir/kraal.log" <<'PYEOF'
import re, sys

# scrollbar: w1:p1 lane=[x,y w x h] pane=WxH cells=N
pattern = re.compile(
    r"scrollbar: (\S+) lane=\[(-?\d+),(-?\d+) (\d+)x(\d+)\] "
    r"pane=(\d+)x(\d+) cells=(\d+)"
)
problems = []
seen = 0
for line in open(sys.argv[1], errors="replace"):
    match = pattern.search(line)
    if not match:
        continue
    seen += 1
    pane_id = match.group(1)
    lx, ly = int(match.group(2)), int(match.group(3))
    lw, lh = int(match.group(4)), int(match.group(5))
    pw, ph = int(match.group(6)), int(match.group(7))
    cells = int(match.group(8))

    if cells <= 0:
        continue
    # The lane lives inside the pane's own box. A doubled rebase makes lx negative
    # by one pane width, which this catches.
    if lx < 0 or ly < 0:
        problems.append(f"{pane_id}: lane origin {lx},{ly} is outside the pane")
    if lw > pw or lh > ph:
        problems.append(f"{pane_id}: lane {lw}x{lh} is larger than pane {pw}x{ph}")
    # The lane abuts the *outer* rect's last column, while `pane` here is the
    # inner rect the daemon already narrowed by that same column
    # (`ui/panes.rs:290-311`). So `lx + lw == pw + lane_width` is correct, and the
    # tolerance is one lane width, not one point.
    #
    # The doubled-rebase bug this guards makes `lx` negative (shifted left by a
    # whole pane) or `ly` negative (pinned to the container's top for every pane
    # below the first), which these two checks still catch.
    if lx + lw > pw + lw + 1:
        problems.append(f"{pane_id}: lane right edge {lx + lw} past pane width {pw}")
    if ly + lh > ph + 1:
        problems.append(f"{pane_id}: lane bottom {ly + lh} past pane height {ph}")

if seen == 0:
    problems.append("no scrollbar geometry was logged (no lane, or no scrollback)")
if problems:
    print("; ".join(problems[:4]))
    sys.exit(1)
print(f"{seen} lane(s) inside their pane")
PYEOF
)
        check "every scrollbar lane sits inside its own pane" "$?" "$verdict"
    }
}


# Drag the divider, then assert the daemon's ratio moved.
#
# This case replaced `KRAAL_PROBE_DIVIDER_DRAG`, which was the only end-to-end
# evidence for `e82c104` (the divider follows the pointer). The probe is gone; the
# unit tests cover the point-to-cell arithmetic but cannot see whether a drag
# actually reaches `set_split_ratio`, so this case is what keeps that path honest.
#
# It also found a real bug on first use: a drag moved the divider 2x the pointer,
# because `onChanged` and `onEnded` each sent the same cumulative translation and
# the daemon applied both. Fixed by anchoring the calculation on the pre-drag
# position, which makes it idempotent.
#
# It is also the reason the backend defaults to `vm`: a drag is a synthetic mouse
# event, so it needs the app frontmost and moves the real pointer. On `local` this
# would take the pointer away from whoever is working.
case_drag_divider() {
    requires() { echo focus; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        if [ "$(pane_count)" = "1" ]; then
            herdr pane split --pane "$(first_pane_id)" --direction right >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "2" ] || return 1
        # Give the layout a moment to settle after the split.
        sleep 1
        pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
sys.exit(0 if len(layout["splits"]) == 1 else 1)
'
    }
    action() {
        # The divider's position comes from the daemon's own geometry, converted
        # from terminal cells to window points, then offset by the window origin.
        # Hard-coding a coordinate is the failure mode from VM probe E15: it looks
        # right on one window size and misses on every other.
        #
        # `pane_layout` is piped in rather than shelled out from inside python:
        # the herdr invocation needs the scratch socket, which only this script's
        # `herdr()` wrapper supplies.
        local window_info coords
        window_info=$(driver window)
        coords=$(pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
splits = layout["splits"]
if not splits:
    sys.exit(1)
print(splits[0]["ratio"])
')
        [ -z "$coords" ] && { echo "cannot read the split ratio"; return 1; }
        # Window origin from the driver; the container's size from the app's own
        # `layout:` log line. Both are measurements, so the case works at any
        # window size instead of only at the 1180pt default it was tuned against.
        local origin_x origin_y
        origin_x=$(printf '%s' "$window_info" | sed -n 's/.* x=\(-\{0,1\}[0-9]*\) .*/\1/p')
        origin_y=$(printf '%s' "$window_info" | sed -n 's/.* y=\(-\{0,1\}[0-9]*\) .*/\1/p')
        local container_w container_h
        read -r container_w container_h <<EOF
$(container_size)
EOF
        if [ -z "${container_w:-}" ] || [ -z "${container_h:-}" ]; then
            echo "cannot read the container size from the app's layout log"
            return 1
        fi
        # The sidebar is whatever the window has left over: the container starts
        # where the sidebar ends, so the divider's window-relative x is
        # (window width - container width) + ratio * container width.
        local window_w
        window_w=$(printf '%s' "$window_info" | sed -n 's/.* w=\([0-9]*\).*/\1/p')
        local sidebar_w=$((window_w - container_w))
        local divider_x divider_y
        divider_x=$(python3 -c "print(int($origin_x + $sidebar_w + float('$coords') * $container_w))")
        divider_y=$((origin_y + container_h / 2))
        # One mouse-dragged event, 80pt right. No stream of steps: measured in the
        # VM, 16 steps of 40pt moved the ratio by 0.39 (a 9.4x overshoot) because
        # `DragGesture.translation` is cumulative from the press point, so each
        # extra event adds another delta. One step lands within 0.042 (~40pt).
        driver drag --from "$divider_x,$divider_y" \
            --to "$((divider_x + 80)),$divider_y"
        # Hand both the starting ratio and the container width to the assertion:
        # it has to check the magnitude, and the expected magnitude depends on how
        # wide the container actually is. A divider that jumps to 0.9 on an 80pt
        # nudge is broken in the same way a stuck one is.
        printf '%s' "$coords" > "$host_dir/ratio-before.txt"
        printf '%s' "$container_w" > "$host_dir/container-width.txt"
    }
    assert() {
        local before after
        # A drag must not change how many panes exist: a divider that closes one
        # instead of moving it would otherwise still satisfy the ratio check if
        # the daemon happened to rebalance.
        check "dragging leaves the pane count alone" \
            "$([ "$(pane_count)" = "$1" ] && echo 0 || echo 1)" "$1 -> $(pane_count)" || return 1
        before=$(cat "$host_dir/ratio-before.txt" 2>/dev/null)
        local container_w
        container_w=$(cat "$host_dir/container-width.txt" 2>/dev/null)
        after=$(pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
splits = layout["splits"]
if len(splits) != 1:
    sys.exit(1)
print(splits[0]["ratio"])
')
        if [ -z "$before" ] || [ -z "$after" ] || [ -z "$container_w" ]; then
            check "dragging the divider moves the split ratio" 1 "could not read a ratio"
            return 1
        fi
        # 80pt out of the container is 80/container_w of the ratio, so the expected
        # value follows the actual container width instead of assuming 959pt. The
        # tolerance is ±0.02, which is deliberately tight: measured against the
        # fixed app, a drag lands within ~0.005 of the expected value at every
        # distance from 20pt to 160pt (the residual is a constant ~5pt from the
        # gesture's start threshold, not a multiplier). A tolerance wide enough to
        # absorb the 2x duplicate-send bug would have hidden it — that bug showed
        # +0.046 at 40pt, a factor of nine above the residual.
        local verdict
        verdict=$(python3 -c "
before, after = float('$before'), float('$after')
expected = before + 80.0 / float('$container_w')
delta = after - before
if abs(delta) < 0.02:
    print(f'stuck: ratio {before:.3f} -> {after:.3f}, the drag never reached the daemon')
    raise SystemExit(1)
if abs(after - expected) > 0.06:
    print(f'wrong magnitude: {before:.3f} -> {after:.3f}, expected ~{expected:.3f} (off by {after - expected:+.3f})')
    raise SystemExit(1)
print(f'ratio {before:.3f} -> {after:.3f} (expected ~{expected:.3f}, error {after - expected:+.3f})')
")
        check "dragging the divider moves the ratio by the dragged distance" "$?" "$verdict"
    }
}

# Close a real worktree group through the File menu.
#
# Issue #21: `workspace.close` was sent without `close_group`, so the daemon
# refused every close of a grouped workspace with `workspace_group_close_required`
# — in band, as a decodable body — and the menu item looked like a no-op. Unit
# tests could not see it because they asserted on the request body this client
# sent, not on whether the daemon accepted it (AGENTS.md §0.2).
#
# Two facts from the daemon decide what this case has to do (measured, 0.9.5):
#
#   * Only a *main checkout* (`is_linked_worktree == false`) is refused. Closing a
#     linked worktree on its own is allowed, because that does not take the group
#     with it. `actions.rs:899-917` filters to `!space.is_linked_worktree`.
#   * A workspace made by `workspace create --cwd` has no worktree metadata until
#     `worktree create` runs; only then does the daemon compute `repo_key` for
#     both sides. So the fixture must create the worktree *before* it can see a
#     group, and must close the main checkout, not the linked one.
#
# What was measured with the daemon as the judge:
#   A. close_group=false on the main checkout -> `workspace_group_close_required`,
#      and workspace list still showed w1 + w5.
#   B. close_group=true  -> {"type":"ok"}, and list dropped to the unrelated
#      workspace alone.
case_close_workspace_group() {
    requires() { echo ax; }
    fixture() {
        # A scratch repo to branch from. The daemon's own worktree root keeps the
        # checkout inside its HERDR_HOME, so nothing leaks into the host's tree.
        local repo="$HERDR_HOME/close-group-fixture"
        tart exec "$VM" /bin/bash -lc "
            rm -rf $repo
            mkdir -p $repo && cd $repo || exit 1
            git init -q || exit 1
            git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init || exit 1
        " >/dev/null 2>&1 || { echo "cannot create the fixture repo at $repo"; return 1; }
        # worktree create acts on the *focused* workspace and refuses with
        # `not_git_worktree` when that one is not inside a checkout — the exact
        # error seen when the previous case's pane still held focus. So create the
        # workspace, then focus it before asking for a worktree.
        local created workspace_id
        created=$(herdr workspace create --cwd "$repo" 2>&1) \
            || { echo "workspace create failed: $(printf '%s' "$created" | head -c 300)"; return 1; }
        workspace_id=$(printf '%s' "$created" | python3 -c '
import json, sys
print(json.load(sys.stdin)["result"]["workspace"]["workspace_id"])
' 2>/dev/null)
        [ -n "$workspace_id" ] || { echo "cannot read the new workspace id"; return 1; }
        herdr workspace focus "$workspace_id" >/dev/null 2>&1 \
            || { echo "cannot focus $workspace_id"; return 1; }
        # This also backfills the main checkout's worktree metadata, which is what
        # makes the daemon see a group at all. A unique branch per run: the scratch
        # HERDR_HOME survives between cases (only session.json is cleared), so a
        # fixed name collides on the second run and `worktree create` fails.
        created=$(herdr worktree create --branch "close-group-$$" 2>&1) \
            || { echo "worktree create failed: $(printf '%s' "$created" | head -c 300)"; return 1; }
        local groups
        groups=$(workspace_group_state)
        [ "$groups" = "grouped" ] || { echo "not grouped: $groups"; return 1; }
        # Focus the main checkout: the File menu closes the focused workspace, and
        # only a main checkout is refused when `close_group` is false
        # (`actions.rs:899-917`).
        local main_id
        main_id=$(main_checkout_workspace_id)
        [ -n "$main_id" ] || { echo "no main checkout in the group"; return 1; }
        herdr workspace focus "$main_id" >/dev/null 2>&1 \
            || { echo "cannot focus $main_id"; return 1; }
    }
    action() {
        # File > Close Workspace is the AppKit path — the one that had no
        # confirmation dialog available to it.
        driver menu --menu File --item "Close Workspace"
        # The app answers the refusal with a confirmation. This case deliberately
        # stops at the dialog: what it asserts is that the *request* carried the
        # group flag, that the daemon refused it, and that the refusal closed
        # nothing. Clicking through the dialog here would fold the confirmation
        # path into the same test and hide a regression in either half; the
        # retry-with-true path is covered by the daemon-level A/B recorded in the
        # PR (`close_group=true` closed the group, `false` was refused).
        sleep 2
    }
    assert() {
        local before="$1" after log
        log="$host_dir/kraal.log"
        # 1. The request that went out carried the flag. Without it the daemon
        #    cannot tell "this workspace" from "the group", which is issue #21.
        if check "workspace.close was sent with close_group" \
            "$(grep -q 'workspace.close .*close_group=false' "$log" 2>/dev/null && echo 0 || echo 1)" \
            "$(grep -o 'workspace.close [^:]*' "$log" 2>/dev/null | tail -1)"; then :; else return 1; fi
        # 2. The daemon refused it, and the app knew why. `call: REFUSED` is
        #    printed from the in-band error branch; the second line is the app
        #    deciding to ask the user instead of showing a bare error.
        if check "the refusal was recognised as a group close" \
            "$(grep -q 'refused workspace.close alone (workspace_group_close_required), asking' "$log" 2>/dev/null && echo 0 || echo 1)" \
            "$(grep -o 'refused workspace.close alone ([a-z_]*), asking' "$log" 2>/dev/null | tail -1)"; then : else return 1; fi
        # 3. Nothing was closed. This is the half that would go unnoticed: a client
        #    that dropped the flag but still closed would pass check 1 on a stale
        #    log and quietly destroy a group the user only asked to close once.
        after=$(workspace_count)
        check "the refused close closed nothing" \
            "$([ "$after" = "$before" ] && echo 0 || echo 1)" "$before -> $after workspaces"
    }
}

# Paste must go out as a paste event, not as keystrokes.
#
# Issue #20: `NSText.paste` through the responder chain did nothing at all (no
# view in the pane implements it) and the context menu called `sendInput(Data)`
# directly, so a pasted newline arrived as Enter and a multi-line paste ran every
# line. The wire has a separate `paste` event; this case pins that the app uses it.
#
# Asserted on the app's own log (`paste: N chars to <pane>`, written by
# `AppStore.sendPaste`) plus the negative: no `clientShellPaneInput` carrying text
# commits may be logged for the same paste. Both halves matter — a build that
# logged the paste line and *also* sent the bytes would look fixed and still run
# the user's command twice.
case_paste() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" -ge 1 ] || return 1
        # Put multi-line text on the pasteboard inside the guest. A single line
        # would pass even with the bug, because the only difference is what a
        # newline means.
        case "$BACKEND" in
        vm) printf 'echo AAA\necho BBB\n' | tart exec -i "$VM" /bin/bash -lc "pbcopy" ;;
        local) printf 'echo AAA\necho BBB\n' | pbcopy ;;
        esac
    }
    action() {
        driver menu --menu Edit --item "Paste"
        sleep 2
    }
    assert() {
        local log="$host_dir/kraal.log"
        check "the app sent the text as a paste event" \
            "$(grep -q 'paste: .* chars to ' "$log" 2>/dev/null && echo 0 || echo 1)" \
            "$(grep -o 'paste: [0-9]* chars to [a-zA-Z0-9:]*' "$log" 2>/dev/null | tail -1)"
        check "no raw text commit carried the same paste" \
            "$(grep -q 'sendInput: .* bytes' "$log" 2>/dev/null && echo 1 || echo 0)" \
            "$(grep -o 'sendInput: .*' "$log" 2>/dev/null | tail -1)"
    }
}

# ---------------------------------------------------------------- runner# ---------------------------------------------------------------- runner

# Reads a case's declared requirement without executing the case.
#
# The first version ran the case function and then called `requires`, which
# executed `fixture`/`action`/`assert` definitions with no arguments and, when the
# case did not exist, reported "no such case" for a case that was right there.
case_needs() {
    local name="$1"
    local text
    text=$(declare -f "case_${name//-/_}" 2>/dev/null) || { echo ""; return; }
    # Match the *declaration*, not a canonical spelling. The first version looked
    # for `requires() { echo focus` and missed `requires() { echo focus; }` — the
    # semicolon `declare -f` prints — so `drag-divider` silently ran as an
    # ax-only case, the app was launched as .accessory, and the drag failed with
    # "could not bring Kraal to the front". A requirement that is silently
    # downgraded is worse than no requirement.
    case "$text" in
    *"echo focus"*) echo focus ;;
    *) echo ax ;;
    esac
}

# Kraal writes to ~/Library/Logs/Kraal-<session>.log, not to stderr, and the
# session name is derived from KRAAL_DEV_SESSION. Without this copy the log never
# reached the artifacts, even though docs/AUTOMATION.md promised it.
#
# Callable mid-case: assertions that reason about what the app decided (did it
# send the group flag? did it ask for confirmation?) need the log while they run,
# not only in the artefact directory afterwards.
collect_app_log() {
    local host_dir="$1"
    if [ "$BACKEND" = "vm" ]; then
        tart exec -i "$VM" /bin/bash -lc \
            "cat ~/Library/Logs/Kraal-$SESSION.log 2>/dev/null" > "$host_dir/kraal.log" 2>/dev/null
    else
        cp "$HOME/Library/Logs/Kraal-$SESSION.log" "$host_dir/kraal.log" 2>/dev/null
    fi
}

run_case() {
    local name="$1"
    local runner="case_${name//-/_}"
    if ! declare -F "$runner" >/dev/null; then
        die "no such case '$name' (see: $0 list)"
    fi

    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)-$name"
    # `dir` is what the runner writes to (guest paths under vm); `host_dir` is
    # where the user will look. With the vm backend they differ, so artefacts are
    # collected into host_dir at the end of the case.
    local host_dir="$HOST_ARTIFACTS/$run_id"
    local dir="$ARTIFACTS/$run_id"
    mkdir -p "$host_dir"
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /bin/bash -lc "mkdir -p $dir" >/dev/null 2>&1
    else
        mkdir -p "$dir"
    fi

    CURRENT_CASE="$name"
    say "case $name  ($run_id)"
    ASSERTIONS=()
    ASSERTION_FAILURES=0

    # A case may declare that it needs a frontmost app. Synthetic events go to
    # whoever is frontmost, so running those while the screen is locked posts them
    # at loginwindow — which looks exactly like a broken feature. Refuse early with
    # an environment error (exit 2) instead of a product failure (exit 1).
    local needs
    needs=$(case_needs "$name")
    if [ "$needs" = "focus" ]; then
        # Refuse before touching anything. On `local` this would take the pointer
        # and the keyboard away from whatever the user is doing — the exact
        # interruption AGENTS.md §0.1 exists to prevent.
        if ! needs_focus_allowed; then
            bad "$name posts synthetic events and would steal focus on this machine"
            printf '    refused: set KRAAL_GUI_ALLOW_FOCUS=1 if you are not using the\n'
            printf '    machine, or run it in the VM (KRAAL_GUI_BACKEND=vm).\n'
            return 2
        fi
        if [ "$BACKEND" = "local" ] && screen_locked; then
            bad "$name needs an unlocked screen (synthetic events go to loginwindow)"
            printf '    skip: unlock the machine, or run an ax-only case\n'
            return 2
        fi
    fi

    stop_app
    stop_daemon
    start_daemon
    launch_app

    # These are host-side shell redirections, so they must target host_dir: under
    # the vm backend `dir` is a guest path that does not exist here.
    driver ax --out "$host_dir/ax-before.json" >/dev/null 2>&1
    herdr pane list >"$host_dir/pane-before.json" 2>/dev/null
    driver shot -o "$host_dir/shot-before.png" >/dev/null 2>&1

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
            # Pull the app log *before* the assertions run: some cases assert on
            # what the app logged (a refusal it had to handle, a command it decided
            # not to send), and the collection at the end of the case happens after
            # `assert` has already run.
            collect_app_log "$host_dir"
            local assert_log="$host_dir/assert.log"
            if ! assert "$before" >"$assert_log" 2>&1; then
                failure="assert"
            fi
            # Always surface the assertions, pass or fail: a passing run should
            # still show what was verified.
            cat "$assert_log"
        fi
    fi

    herdr pane list >"$host_dir/pane-after.json" 2>/dev/null
    driver ax --out "$host_dir/ax-after.json" >/dev/null 2>&1
    driver shot -o "$host_dir/shot-after.png" >/dev/null 2>&1
    if [ "$BACKEND" = "vm" ]; then
        tart exec -i "$VM" /bin/bash -lc \
            "cat $VM_ROOT/app.out 2>/dev/null; echo; cat $VM_ROOT/herdr-server.log 2>/dev/null" \
            > "$host_dir/app.out" 2>/dev/null
    else
        cp "$SCRATCH/app.out" "$host_dir/app.out" 2>/dev/null
        cp "$SCRATCH/herdr-server.log" "$host_dir/herdr-server.log" 2>/dev/null
    fi
    collect_app_log "$host_dir"

    local after
    after=$(pane_count)
    local status="passed"
    local code=0
    # A case whose `assert` recorded a failed `check` is failed, even though the
    # function returned 0. Without this, an `assert` that ends on a passing check
    # after a failing one reported the case as passed — observed directly: the
    # `paste` case printed "✗ the app sent the text as a paste event" and exited 0,
    # so the gate could not fail on the very bug it was written for.
    if [ -z "$failure" ] && [ "$ASSERTION_FAILURES" -gt 0 ]; then
        failure="assert"
    fi
    if [ -n "$failure" ]; then
        status="failed"; code=1
        # Only on failure: a screenshot costs a second and proves least.
        #
        # The output path went to `$dir` (a *guest* path under the vm backend) while
        # the redirect around it is host-side, so the failure path printed
        # "app.out: No such file or directory" and the shot's own complaints were
        # lost. The shot belongs in the guest; the log of it belongs on the host.
        driver shot -o "$dir/shot-failure.png" >>"$host_dir/failure-shot.log" 2>&1
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
    cat >"$host_dir/summary.json" <<JSON
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

    if [ "$BACKEND" = "vm" ]; then
        vm_collect "$dir" "$host_dir"
    fi

    stop_app
    stop_daemon

    if [ "$code" -eq 0 ]; then
        ok "$name passed (panes $before -> $after)"
    else
        bad "$name failed at $failure (panes $before -> $after)"
        printf '    artifacts: %s\n' "$host_dir"
    fi
    return "$code"
}

all_cases() { echo "split-right menu-split split-down close-pane close-workspace-group paste drag-divider scrollbar"; }

# ---------------------------------------------------------------- entrypoint

cmd_list() { all_cases; }

cmd_run() {
    [ -d "$ROOT/build/Kraal.app" ] || die "no build/Kraal.app; run: ./Scripts/build-app.sh"
    if [ "$BACKEND" = "vm" ]; then
        mkdir -p "$SCRATCH"
        vm_start
        vm_deploy
    fi
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
