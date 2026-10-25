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
# Where the fixture's saved-machine roster lives. Separate from HERDR_HOME on
# purpose: `herdr machine` reads `~/.local/state/herdr/client/endpoints.json` under
# `$HOME`, not under the socket directory, so isolating the daemon does not
# isolate the roster. `KRAAL_HERDR_HOME` is what the app passes to its `herdr`
# child, so pointing both at this one directory makes the fixture's machines the
# only machines either side can see.
if [ "$BACKEND" = "vm" ]; then
    ROSTER_HOME="$VM_ROOT/roster-home"
else
    ROSTER_HOME="$SCRATCH/roster-home"
fi
DRIVER="$ROOT/.build/out/Products/Debug/KraalGUIDriver"
HOST_ARTIFACTS="$ROOT/artifacts"

# Where the app under test keeps its `UserDefaults`.
#
# Per *case*, not one shared domain: the sidebar remembers its split and its agent
# ordering, so a case that drags the divider would otherwise change what the next
# case starts from — and, worse, the real `cool.zzj.kraal` domain, because the app
# reads `.standard` unless told otherwise. `SidebarPreferences.defaults` honours this
# variable; `run_case` assigns it before launching.
#
# Empty until a case runs: referring to `$SESSION` here would be an unbound variable
# under `set -u`, because the session name is derived later in this file.
PREFS_SUITE=""
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
# Rebuild the driver before it is pushed anywhere.
#
# `build-app.sh` builds `KraalMac` only, so a driver edit was invisible: the
# previously built binary was pushed, and an A/B on driver code went green because
# *the change never reached the guest*. Measured during issue #92 — reverting
# `--char` to its old first-character behaviour left the case passing until this
# build was added, after which it failed with the bug's exact signature
# (`exit=0 sent key 'escape' (keycode 14)`, i.e. the letter `e`).
#
# Cheap (a no-op build is ~1 s) and it removes a silent-false-pass mode, which is
# worth more than the second.
build_driver() {
    local swift=/usr/bin/swift
    [ -x "$swift" ] || swift=$(command -v swift) || die "no swift toolchain"
    DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
        "$swift" build --product KraalGUIDriver >/dev/null 2>&1 \
        || die "failed to build KraalGUIDriver"
}

# Refuse to run against a stale app bundle.
#
# `build-app.sh` must be re-run after any app change, and forgetting it makes an
# A/B test green for the wrong reason: the bundle still holds the *old* code, so
# the injected regression never ships. Measured during issue #55 — the A/B was
# green until `build-app.sh` was re-run, because `build/Kraal.app` predated the
# edit by a minute.
#
# A timestamp check turns that silent false pass into a one-line error naming the
# command to run. It compares against the newest source rather than trying to
# rebuild here: packaging is `build-app.sh`'s job, and doing it twice per case
# would make the suite much slower for no benefit.
check_app_fresh() {
    local app="$ROOT/build/Kraal.app"
    local newest
    newest=$(find "$ROOT/Sources" -name '*.swift' -newer "$app" -print -quit 2>/dev/null)
    if [ -n "$newest" ]; then
        die "build/Kraal.app is older than $newest; run: ./Scripts/build-app.sh"
    fi
}

vm_deploy() {
    check_app_fresh
    build_driver
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

    # The API helper, so a case can call endpoint methods the CLI has no verb for.
    tar -czf - -C "$ROOT/Scripts" herdr-api.py \
        | tart exec -i "$VM" /bin/bash -lc "cd $VM_ROOT && tar -xzf -" \
        || die "failed to push herdr-api.py into the guest"

    # The mouse probe. A TUI that reports what it receives is the only way to tell
    # "the app never sent the event" from "the app sent it and the program ignored
    # it" — both look like a dead click from the outside (issue #95).
    tar -czf - -C "$ROOT/Scripts" tui-mouse-probe.py key-probe.py kitty-graphics-probe.py \
        | tart exec -i "$VM" /bin/bash -lc "cd $VM_ROOT && tar -xzf -" \
        || die "failed to push the probes into the guest"

    # The `kraal` CLI. The machines fixture reads a daemon's `boot` id with it: pane
    # ids repeat across daemons (both machines have a `w1:p1`), so the boot id is the
    # only cheap proof that two roster entries are two servers. It is a debug binary
    # that already exists after `swift build`, so this costs one tar and no build.
    local kraal_cli="$ROOT/.build/out/Products/Debug/kraal"
    if [ -x "$kraal_cli" ]; then
        tar -czf - -C "$(dirname "$kraal_cli")" kraal \
            | tart exec -i "$VM" /bin/bash -lc "cd $VM_ROOT && tar -xzf - && chmod +x $VM_ROOT/kraal" \
            || die "failed to push the kraal CLI into the guest"
    fi

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
    ok "deployed driver + Kraal.app + herdr + kraal CLI"
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
        vm_deploy                      # builds the driver, then pushes it
    else
        # The local backend runs the host's driver in place, so it needs the same
        # rebuild — otherwise a driver edit is tested against the previous binary.
        build_driver
    fi
    driver probe
}

# Writes a daemon config from stdin, for cases that need one.
#
# The daemon reads `$HOME/.config/herdr/config.toml`, and `HOME` here is the scratch
# `HERDR_HOME` — which is why a scratch home is good for more than the machine
# roster: a case can change server-side behaviour (a `[[keys.command]]` entry, say)
# without touching the developer's own config.
#
# Guest and host paths differ, so this writes through the right side per backend —
# the same trap `deploy` hit when a host `$SCRATCH` path was handed to the guest.
write_config() {
    local dir="$HERDR_HOME/.config/herdr"
    local staging="$SCRATCH/config-staging"
    # Staged on the host and pushed with tar, not piped through `tart exec -i`.
    #
    # A multi-line heredoc into `tart exec -i` truncated after the first line —
    # measured: the guest config came out as `[[keys.command]]` and nothing else, so
    # the daemon registered no command and the case failed with "no Popup command in
    # the snapshot", which points at the daemon rather than at the plumbing. This is
    # the same transport `vm_deploy` uses for the driver and the app.
    mkdir -p "$staging"
    cat >"$staging/config.toml"
    case "$BACKEND" in
    local)
        mkdir -p "$dir"
        cp "$staging/config.toml" "$dir/config.toml"
        ;;
    vm)
        tart exec "$VM" /bin/bash -lc "mkdir -p $dir" >/dev/null 2>&1 \
            || { rm -rf "$staging"; return 1; }
        tar -czf - -C "$staging" config.toml \
            | tart exec -i "$VM" /bin/bash -lc "cd $dir && tar -xzf -" \
            || { rm -rf "$staging"; return 1; }
        ;;
    esac
    rm -rf "$staging"
    return 0
}

# Restarts the scratch daemon and waits until it answers again.
#
# Needed by cases that change `config.toml`: the command registry is built once at
# startup, so `server.reload_config` does not pick up a new `[[keys.command]]`.
restart_daemon() {
    start_daemon >/dev/null 2>&1 || return 1
    return 0
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
        KRAAL_HERDR_HOME="$ROSTER_HOME" \
        KRAAL_DEV_BACKGROUND="$background" \
        KRAAL_DEV_SESSION="$SESSION" \
        KRAAL_PREFS_SUITE="$PREFS_SUITE" \
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
             KRAAL_HERDR_SOCKET=$CLIENT_SOCKET KRAAL_HERDR_HOME=$ROSTER_HOME \
             KRAAL_DEV_BACKGROUND=$background KRAAL_DEV_SESSION=$SESSION \
             KRAAL_PREFS_SUITE=$PREFS_SUITE \
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

# Runs one of the repo's Python helpers, wherever this run's backend lives.
#
# The guest cannot see the host's checkout, so the script is deployed into
# `$VM_ROOT` and run there. Python is used rather than `herdr <verb>` because the
# CLI has no generic "call this endpoint method" verb, and some methods
# (`command.invoke`, which is what opens a popup) have no verb at all.
run_py() {
    local script="$1"
    shift
    case "$BACKEND" in
    local) python3 "$ROOT/Scripts/$script" "$@" ;;
    vm) tart exec "$VM" python3 "$VM_ROOT/$script" "$@" ;;
    esac
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

# All pane ids, sorted. Same reasoning as `first_pane_id`: the daemon's map order
# is not insertion order, so a case that wants "the other pane" cannot use index.
pane_ids() {
    herdr pane list 2>/dev/null | python3 -c '
import json, sys
print("\n".join(sorted(p["pane_id"] for p in json.load(sys.stdin)["result"]["panes"])))
'
}

# Whether the program in this pane asked for mouse reports.
#
# The surface, not `pane list`: the pane record carries no mouse field at all, and
# the daemon only tells the app about it in `client_shell.surface.get`, which is why
# the whole app-side routing depends on `paneGeometry(...).mouseReporting`.
pane_reports_mouse() {
    local target="$1"
    run_py herdr-api.py --socket "$API_SOCKET" --method session.snapshot 2>/dev/null \
        | python3 -c '
import json, sys
target = sys.argv[1]
try:
    payload = json.load(sys.stdin)
    surface = (payload.get("result") or {}).get("surface") \
        or (payload.get("result") or {}).get("snapshot", {}).get("surface") \
        or {}
except Exception:
    sys.exit(1)
for pane in surface.get("panes") or []:
    if pane.get("pane_id") == target:
        sys.exit(0 if pane.get("mouse_reporting") else 1)
sys.exit(1)
' "$target"
}

# A screen point inside a pane's body, from the daemon's own layout.
#
# `pane layout` gives cell rectangles; the app's window is on screen at a known
# origin, so the two have to be joined here. Conversion goes through the window
# frame the driver reports rather than through constants, because the VM's window
# geometry changes with the display it boots into (docs/DEBUGGING.md §12).
# A screen point inside a pane's body, from the daemon's own layout.
#
# Two coordinate systems have to be joined: the daemon measures panes in cells
# inside the surface grid, and the screen measures points. The AX tree does not
# help — panes are drawn by Ghostty's layer and do not appear in it at all (only
# the window, one group, and the sidebar do; verified on the vm window). What the
# app *does* log is the container rectangle it laid the surface out in, in
# content-view points, and the driver reports where that view sits on screen.
#
#     layout: container=1219x2434 grid=143x131 ...
#
# So: cell → fraction of the grid → point inside the container → screen point.
# The pane's rectangle in **screen** coordinates, as "X Y W H".
#
# Same derivation as `pane_body_point`, but returning the whole rect instead of its
# centre: pixel assertions need the region, not a click target. Screen coordinates,
# matching `driver click --at-screen` and `screencapture`; the window-internal
# coordinates `driver click --at` uses are AppKit bottom-left and must not be mixed
# in (docs/DEBUGGING.md §12).
pane_screen_rect() {
    local target="$1"
    local window_text layout_text container
    window_text=$(driver window 2>/dev/null) || return 1
    layout_text=$(machine_layout "${2:-}" 2>/dev/null) || layout_text=$(pane_layout 2>/dev/null) || return 1
    container=$(collect_app_log_tail 2>/dev/null | grep -a 'layout: container=' | tail -1)
    [ -n "$container" ] || return 1
    python3 -c '
import json, re, sys

target = sys.argv[1]
window_text, layout_text, container_line = sys.argv[2], sys.argv[3], sys.argv[4]

win = re.search(r"x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+)", window_text)
if not win:
    sys.exit(1)
win_x, win_y, win_w, win_h = (int(v) for v in win.groups())

cont = re.search(r"container=(\d+)x(\d+) grid=(\d+)x(\d+)", container_line)
if not cont:
    sys.exit(1)
cont_w, cont_h, grid_cols, grid_rows = (int(v) for v in cont.groups())

layout = json.loads(layout_text)["result"]["layout"]
target_pane = next((p for p in layout["panes"] if p["pane_id"] == target), None)
if target_pane is None:
    sys.exit(1)

rect = target_pane["rect"]
left_inset = win_w - cont_w
top_inset = win_h - cont_h
x = win_x + left_inset + rect["x"] / grid_cols * cont_w
y = win_y + top_inset + rect["y"] / grid_rows * cont_h
w = rect["width"] / grid_cols * cont_w
h = rect["height"] / grid_rows * cont_h
print(f"{int(x)} {int(y)} {int(w)} {int(h)}")
' "$target" "$window_text" "$layout_text" "$container"
}

# The pane's rectangle **inside the window**, as "X Y W H".
#
# Different space from `pane_screen_rect`: a `screencapture -l` image is the window,
# so its origin is the window's top-left, not the screen's. Feeding a screen-space
# rect to a window image does not fail — it silently clamps to the overlap, and the
# pixel count then describes a band nobody asked about (measured: a 959x664 rect
# against a 1180x760 window became 959x314, and the "4032 magenta pixels" that
# assertion reported came from that band).
pane_window_rect() {
    local target="$1"
    local window_text layout_text container
    window_text=$(driver window 2>/dev/null) || return 1
    layout_text=$(machine_layout "${2:-}" 2>/dev/null) || layout_text=$(pane_layout 2>/dev/null) || return 1
    container=$(collect_app_log_tail 2>/dev/null | grep -a 'layout: container=' | tail -1)
    [ -n "$container" ] || return 1
    python3 -c '
import json, re, sys

target = sys.argv[1]
window_text, layout_text, container_line = sys.argv[2], sys.argv[3], sys.argv[4]

win = re.search(r"x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+)", window_text)
if not win:
    sys.exit(1)
_, _, win_w, win_h = (int(v) for v in win.groups())

cont = re.search(r"container=(\d+)x(\d+) grid=(\d+)x(\d+)", container_line)
if not cont:
    sys.exit(1)
cont_w, cont_h, grid_cols, grid_rows = (int(v) for v in cont.groups())

# The real position of the container inside the window, reported by the app. Deriving it
# as `windowHeight - containerHeight` was wrong by the title bar plus the gap below
# the container: it produced 96 where the container starts at 71, and the 25pt
# shift never showed up in click tests (same cell) while it moved every pixel
# assertion (issue #103).
origin = re.search(r"containerOrigin=(-?\d+),(-?\d+)", container_line)
if not origin:
    sys.exit(1)
left_inset, top_inset = int(origin.group(1)), int(origin.group(2))

layout = json.loads(layout_text)["result"]["layout"]
target_pane = next((p for p in layout["panes"] if p["pane_id"] == target), None)
if target_pane is None:
    sys.exit(1)

rect = target_pane["rect"]
x = left_inset + rect["x"] / grid_cols * cont_w
y = top_inset + rect["y"] / grid_rows * cont_h
w = rect["width"] / grid_cols * cont_w
h = rect["height"] / grid_rows * cont_h
print(f"{int(x)} {int(y)} {int(w)} {int(h)}")
' "$target" "$window_text" "$layout_text" "$container"
}

pane_body_point() {
    local target="$1"
    local window_text layout_text container
    window_text=$(driver window 2>/dev/null) || return 1
    layout_text=$(machine_layout "${2:-}" 2>/dev/null) || layout_text=$(pane_layout 2>/dev/null) || return 1
    # The most recent layout line: the container follows the window, and a resize
    # (which the vm's window does on launch) makes older lines wrong.
    container=$(collect_app_log_tail 2>/dev/null | grep -a 'layout: container=' | tail -1)
    if [ -z "$container" ]; then
        echo "no 'layout: container=' line in the app log" >&2
        return 1
    fi
    python3 -c '
import json, re, sys

target = sys.argv[1]
window_text, layout_text, container_line = sys.argv[2], sys.argv[3], sys.argv[4]

win = re.search(r"x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+)", window_text)
if not win:
    sys.exit(1)
win_x, win_y, win_w, win_h = (int(v) for v in win.groups())

# "container=<w>x<h> grid=<cols>x<rows>"
cont = re.search(r"container=(\d+)x(\d+) grid=(\d+)x(\d+)", container_line)
if not cont:
    sys.exit(1)
cont_w, cont_h, grid_cols, grid_rows = (int(v) for v in cont.groups())

layout = json.loads(layout_text)["result"]["layout"]
panes = layout["panes"]
target_pane = next((p for p in panes if p["pane_id"] == target), None)
if target_pane is None:
    sys.exit(1)

# The container is anchored top-leading inside the content view, whose top-left is
# the window origin plus the title bar. The driver already reports the window in
# screen space with the title bar included, so the container origin is the window
# origin plus a fixed inset (measured: 221,71 on a 1180x760 window).
rect = target_pane["rect"]
cx = (rect["x"] + rect["width"] / 2) / grid_cols
cy = (rect["y"] + rect["height"] / 2) / grid_rows
# Inset of the surface container inside the window, as a fraction is wrong — the
# sidebar is a fixed width. Derive it from the container size instead: the surface
# is right-aligned and its height is the window height minus the title bar.
left_inset = win_w - cont_w
top_inset = win_h - cont_h
print(f"{int(win_x + left_inset + cx * cont_w)},{int(win_y + top_inset + cy * cont_h)}")
' "$target" "$window_text" "$layout_text" "$container"
}

# The last N lines of the app log, for cases that need a decision the app logged
# while the case was running.
collect_app_log_tail() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec -i "$VM" /bin/bash -lc \
            "tail -200 ~/Library/Logs/Kraal-$SESSION.log 2>/dev/null"
    else
        tail -200 "$HOME/Library/Logs/Kraal-$SESSION.log" 2>/dev/null
    fi
}

# A screen point inside the window but outside the surface — the sidebar — for
# dismissing a menu without acting on a pane.
pane_dismiss_point() {
    local window_text
    window_text=$(driver window 2>/dev/null) || return 1
    printf '%s' "$window_text" | python3 -c '
import re, sys
match = re.search(r"x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+)", sys.stdin.read())
if not match:
    sys.exit(1)
win_x, win_y, win_w, win_h = (int(v) for v in match.groups())
# The sidebar is a fixed 220pt on the leading edge (measured in the vm window:
# `AXScrollArea` at x=0 w=220). A point 100pt in and 40pt down from the top is
# inside it and inside the window.
print(f"{win_x + 100},{win_y + 40}")
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
#   daemon_config  (optional) write config.toml before the daemon starts
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


# Assert a popup the daemon pushes is actually drawn, and its keys go to it.
#
# Neither half is testable in a unit test. `PopupGeometryTests` pins the box
# arithmetic; what it cannot prove is the *link* — that `PaneSurfaceFrame.popup`
# reaches a view at all, that the view is laid out at the daemon's box, and that a
# keypress is addressed to the popup's terminal id rather than to the pane
# underneath. Issue #36 is precisely that the decoder produced a popup and nothing
# ever drew it, so "the geometry function is correct" is not the claim being tested.
#
# The discriminating assertion is the popup's own log line, emitted from inside the
# SwiftUI body — the only inspectable trace of "this got laid out".
# The daemon decides whether a popup exists; a client cannot ask for one. A popup is
# a `[[keys.command]]` entry with `type = "popup"`, and the only way to open it is
# `command.invoke` naming an id the daemon minted — `cmd_<random>_0`, not something a
# caller can predict.
#
# Written before the daemon starts because the command registry is built once at
# startup: `server.reload_config` afterwards would not pick it up, and restarting
# under a live app leaves it connected to a socket nobody is listening on.
case_popup_config() {
    write_config <<'TOML'
[[keys.command]]
key = "prefix+g"
command = "seq -f 'popup-line%g' 1 40; sleep 300"
type = "popup"
width = 60
height = 12
TOML
}

case_popup() {
    requires() { echo ax; }
    fixture() {
        # A restarted daemon comes up with one pane already (it restores a shell),
        # so only create a workspace when there is none — calling `workspace create`
        # unconditionally left two panes and the case failed in `fixture` with
        # "panes -> 2" before it ever reached the popup.
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "1" ] || return 1
        return 0
    }
    action() {
        # The id comes out of the app's own log, not out of `herdr api snapshot`.
        #
        # Measured: the JSON snapshot the CLI prints carries no `commands` at all —
        # the command manifest only travels in the bincode `ClientShellSnapshot`
        # (tag 12). So the CLI is the wrong oracle here, and the app is the right
        # one: it is the thing that has to receive the command, and its log says
        # both how many commands arrived and which are popups.
        # Pull the app log to the host first: `dir` is a guest path under the vm
        # backend, so reading it from here found nothing and every run reported
        # "the app saw no Popup command" even when the command was there.
        collect_app_log "$host_dir"
        local command_id
        command_id=$(grep -o 'ids=[^ ]*' "$host_dir/kraal.log" 2>/dev/null \
            | tail -1 | sed 's/ids=//')
        if [ -z "$command_id" ]; then
            echo "the app saw no Popup command in its snapshot:" >&2
            grep 'snapshot: ' "$host_dir/kraal.log" 2>/dev/null | tail -1 >&2
            return 1
        fi
        echo "popup command: $command_id"
        # The same method the command palette calls. The daemon spawns the popup's
        # terminal and pushes it in the next surface frame; nothing needs to be
        # enabled on the client side.
        if ! run_py herdr-api.py --socket "$API_SOCKET" \
            --method command.invoke \
            --params "{\"command_id\": \"$command_id\"}" >/dev/null; then
            echo "command.invoke refused" >&2
            return 1
        fi
        sleep 3
        return 0
    }
    assert() {
        collect_app_log "$host_dir"

        # Client side: the popup was laid out. Without this line nothing proves the
        # view exists at all — which is exactly issue #36's complaint.
        local popup_line
        popup_line=$(grep 'popup: ' "$host_dir/kraal.log" 2>/dev/null | tail -1)
        check "the popup was laid out in the window" \
            "$([ -n "$popup_line" ] && echo 0 || echo 1)" "${popup_line:-no popup laid out}"
        [ -n "$popup_line" ] || return 0

        # The interior is the box minus its border and its scrollbar gutter:
        # 60 - 2 border - 1 gutter = 57 columns, 12 - 2 = 10 rows. A mismatch means
        # Ghostty was handed a grid the daemon did not render, and every row reflows.
        case "$popup_line" in
        *inner=57x10*) sized=0 ;;
        *) sized=1 ;;
        esac
        check "the interior matches the requested size" "$sized" "$popup_line"

        # Nothing typed a key here on purpose. Synthetic key events need a frontmost
        # window, and this case runs with `KRAAL_DEV_BACKGROUND=1`, so a `driver key`
        # would prove only that the event went nowhere. What is asserted instead is
        # that the popup reached the layout *with its own terminal id*, which is what
        # `routeInput` branches on: a keystroke from that model is addressed to that
        # id, never to a pane. The distinguishing bug — keys landing in the shell
        # underneath — needs a real foreground session, and is covered by reading
        # `routeInput` rather than by faking focus.
        case "$popup_line" in
        *"term_"*) identified=0 ;;
        *) identified=1 ;;
        esac
        check "the popup carries its own terminal id" "$identified" \
            "routeInput keys on this id, not on a pane id"

        # The popup's frame reached its terminal.
        #
        # Deliberately *not* claimed here: that this would catch a missing replay
        # after `prepareForNewTerminalView()`. It would not. In this fixture the
        # popup's grid already exists by the time `applyPopup` runs (the window is
        # live before the popup opens), so the first frame is painted directly
        # instead of being parked and dropped — measured: removing the replay leaves
        # this assertion green and the log unchanged (`popup frame: … painted=683`).
        # The park-then-drop path needs a popup opened before its terminal attaches,
        # which this fixture cannot produce. See #107's comment for the reasoning and
        # what an honest test would have to set up.
        local frame_line
        frame_line=$(grep 'popup frame: ' "$host_dir/kraal.log" 2>/dev/null | tail -1)
        check "the popup's frame reached its terminal" \
            "$([ -n "$frame_line" ] && echo 0 || echo 1)" "${frame_line:-no popup frame painted}"
    }
}


# Assert copy mode reaches the daemon's history, not just the local screen.
#
# Why this cannot be a unit test: the state machine is tested exhaustively in
# `CopyModeTests`, but that proves nothing about the *link* — whether ⌘F actually
# enters, whether a key reaches the monitor rather than Ghostty, and whether the
# text that lands on the clipboard came from the daemon's scrollback. All three
# are wiring, and all three can be broken while every unit test passes.
#
# The decisive assertion is the clipboard's content: the pane is filled with
# numbered lines, the mode is scrolled into history, one line is selected with
# `V`, copied with `y`, and the clipboard must contain that exact number.
# Assert that scrolling actually moves the picture, not just the scrollbar.
#
# The reported symptom was exact: the scrollbar thumb moved, the terminal content
# did not. Both come from the same surface frame, so this is the sharpest possible
# client-side bug — the frame arrived and was thrown away.
#
# Why it happens: `pane.scroll` is a *view* operation. It renders a different
# viewport into `cells` but never bumps `content_seq` (`pane.rs:3408-3413`), so
# `content_revision` is unchanged, and the grid is unchanged too. `apply(surface:)`
# only repainted for a changed revision or a changed grid, so it returned early and
# the new viewport was dropped. The scrollbar reads `scroll.offset_from_bottom`, a
# different field, and moved correctly — which is why the two disagreed.
#
# The assertion has to be on the *rendered text*, not on the offset: the offset was
# never the broken part.
case_scroll() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "1" ] || return 1
        # Numbered lines give every row an identity, so "which lines are on screen"
        # is answerable. Retried and verified against the daemon rather than slept
        # on: `pane run` sometimes lands before the shell is ready and is dropped.
        local maxoff
        for _ in 1 2 3 4 5; do
            herdr pane run "$(first_pane_id)" "seq -f 'line-%g' 1 200" \
                >/dev/null 2>&1 || true
            sleep 1
            maxoff=$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
panes = json.load(sys.stdin)["result"]["panes"]
print((panes[0].get("scroll") or {}).get("max_offset_from_bottom", 0))
' 2>/dev/null)
            if [ -n "$maxoff" ] && [ "$maxoff" -gt 0 ] 2>/dev/null; then
                echo "scrollback ready: max_offset=$maxoff"
                return 0
            fi
        done
        echo "no scrollback accumulated" >&2
        return 1
    }
    action() {
        # What the pane shows at the bottom of the scrollback, straight from the
        # daemon. This is the oracle for "which rows are visible".
        FIRST_VISIBLE=$(herdr pane read "$(first_pane_id)" --source visible 2>/dev/null \
            | grep -o 'line-[0-9]*' | head -1)
        echo "before scroll, first visible: ${FIRST_VISIBLE:-none}"

        # `pane.scroll` is socket-only; `herdr pane` has no scroll verb.
        run_py herdr-api.py --socket "$API_SOCKET" --method pane.scroll \
            --params "{\"pane_id\": \"$(first_pane_id)\", \"offset_from_bottom\": 30}" \
            >/dev/null || { echo "pane.scroll refused" >&2; return 1; }
        sleep 2

        AFTER_VISIBLE=$(herdr pane read "$(first_pane_id)" --source visible 2>/dev/null \
            | grep -o 'line-[0-9]*' | head -1)
        echo "after scroll, first visible: ${AFTER_VISIBLE:-none}"
        return 0
    }
    assert() {
        collect_app_log "$host_dir"

        # The daemon's own idea of the visible rows must have moved. If this fails
        # the scroll never happened and the rest of the case proves nothing.
        check "the daemon scrolled the pane's viewport" \
            "$([ -n "$AFTER_VISIBLE" ] && [ "$AFTER_VISIBLE" != "$FIRST_VISIBLE" ] && echo 0 || echo 1)" \
            "before=${FIRST_VISIBLE:-none} after=${AFTER_VISIBLE:-none}"

        # And the client must have painted that frame. Before the fix the same
        # frame arrived with an unchanged revision and was dropped, so the log shows
        # the scroll being applied and no repaint following it.
        local painted
        painted=$(grep 'scroll repaint:' "$host_dir/kraal.log" 2>/dev/null | tail -1)
        check "the scrolled frame was repainted" \
            "$([ -n "$painted" ] && echo 0 || echo 1)" \
            "${painted:-no scroll repaint logged}"
    }
}


# Assert copy mode reaches the daemon's history, not just the local screen.
#
# Why this cannot be a unit test: the state machine is tested exhaustively in
# `CopyModeTests`, but that proves nothing about the *link* — whether ⌘F actually
# enters, whether a key reaches the monitor rather than Ghostty, and whether the
# text that lands on the clipboard came from the daemon's scrollback. All three
# are wiring, and all three can be broken while every unit test passes.
#
# The decisive assertion is the clipboard's content: the pane is filled with
# numbered lines, the mode is scrolled into history, one line is selected with
# `V`, copied with `y`, and the clipboard must contain that exact number.
case_scrollprobe() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "1" ] || return 1
        # Enough scrollback that `max_offset_from_bottom` is non-zero. Retried and
        # verified against the daemon, not slept on: `pane run` sometimes lands
        # before the shell is ready and is silently dropped.
        local maxoff
        for _ in 1 2 3 4 5; do
            herdr pane run "$(first_pane_id)" "seq -f 'line-%g' 1 200" \
                >/dev/null 2>&1 || true
            sleep 1
            maxoff=$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
panes = json.load(sys.stdin)["result"]["panes"]
print((panes[0].get("scroll") or {}).get("max_offset_from_bottom", 0))
' 2>/dev/null)
            if [ -n "$maxoff" ] && [ "$maxoff" -gt 0 ] 2>/dev/null; then
                echo "scrollback ready: max_offset=$maxoff"
                return 0
            fi
        done
        echo "no scrollback accumulated" >&2
        return 1
    }
    action() {
        # `herdr pane` has no scroll verb; `pane.scroll` is socket-only.
        local pane
        pane=$(first_pane_id)
        run_py herdr-api.py --socket "$API_SOCKET" --method pane.scroll \
            --params "{\"pane_id\": \"$pane\", \"offset_from_bottom\": 30}" \
            >/dev/null || { echo "cannot scroll" >&2; return 1; }
        sleep 2
        return 0
    }
    assert() {
        collect_app_log "$host_dir"
        grep 'probe:' "$host_dir/kraal.log" 2>/dev/null | tail -8
        return 0
    }
}


case_copy_mode() {
    # Synthetic keys need a frontmost app, so this is a focus-requiring case.
    requires() { echo focus; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        [ "$(pane_count)" = "1" ] || return 1
        # Numbered output gives every line a unique, greppable identity. `seq` is
        # used rather than a format string so the line text is a plain integer.
        #
        # Filled in a loop and verified against the daemon, because `pane run`
        # occasionally lands before the shell is ready: without this the case
        # failed intermittently with `viewport=0...38` and an empty selection,
        # which looked exactly like a copy-mode bug.
        for _ in 1 2 3 4 5; do
            herdr pane run "$(first_pane_id)" "seq -f 'line%g' 1 200" >/dev/null 2>&1 || true
            sleep 1
            # Scrollback exists once the pane has more text than one screen; the
            # daemon reports it as a non-zero scroll max.
            if pane_layout | layout_check '
import json, sys
layout = json.load(sys.stdin)["result"]["layout"]
ok = any(p.get("scroll") and p["scroll"]["max_offset_from_bottom"] > 0
         for p in layout["panes"])
sys.exit(0 if ok else 1)
'; then
                break
            fi
        done
        # Scroll back so the viewport sits in history — copy mode's whole reason for
        # existing. Without this the selection would be from the visible screen,
        # which the mouse could already reach.
        herdr pane scroll --up 60 "$(first_pane_id)" >/dev/null 2>&1 || true
        sleep 1
        return 0
    }
    action() {
        # Clear the clipboard first. Without this the assertion below could pass on
        # whatever a previous case left behind — the guest had `echo AAA` on it, and
        # the first run of this case "failed" only because the expected text was
        # missing, not because the old value matched.
        tart exec "$VM" /bin/bash -lc "printf '' | pbcopy" >/dev/null 2>&1 || true

        # Enter through the menu, which is also the documented path (⌘F resolves
        # through the same command). A failure here means the wiring, not the keys.
        #
        # `menu` needs both the bar item and the item inside it — passing only a
        # title silently did nothing, and the case failed at `action` with no log
        # line to explain why.
        driver menu --menu Edit --item "Copy Mode…" >/dev/null 2>&1 || return 1
        sleep 1
        # `g` moves to the top of the viewport first: the entry cursor is the
        # terminal's own, which sits at the bottom row — and the bottom row of a
        # viewport scrolled into history is often past the end of the text, which
        # the daemon refuses with `selection_unavailable`.
        driver key --char g >/dev/null 2>&1 || return 1
        sleep 1
        # `V` selects the whole line, `y` copies and leaves.
        driver key --char V --mod shift >/dev/null 2>&1 || return 1
        sleep 1
        driver key --char y >/dev/null 2>&1 || return 1
        sleep 2
        return 0
    }
    assert() {
        local log
        collect_app_log "$host_dir"

        local entered
        entered=$(grep -c 'copymode: entered' "$host_dir/kraal.log" 2>/dev/null || echo 0)
        check "copy mode was entered" \
            "$([ "$entered" -gt 0 ] && echo 0 || echo 1)" "$entered log lines"

        # The copy line records how much text arrived from the daemon. It is the
        # only evidence that the round trip finished before the clipboard is read.
        local copied_line
        copied_line=$(grep 'copymode: copied' "$host_dir/kraal.log" 2>/dev/null | tail -1)
        check "the selection was read from the daemon" \
            "$([ -n "$copied_line" ] && echo 0 || echo 1)" "${copied_line:-no copy recorded}"

        # The clipboard must hold one of the numbered history lines. Reading it in
        # the guest is deliberate: that is where the app put it.
        local clip
        clip=$(tart exec "$VM" /bin/bash -lc "pbpaste 2>/dev/null" 2>/dev/null | tr -d '\r')
        local matched=1
        case "$clip" in
        *line[0-9]*) matched=0 ;;
        esac
        check "the clipboard holds a line from the pane's history" "$matched" \
            "clipboard: $(printf '%s' "$clip" | head -c 80)"
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


# The coordinate contract behind issue #72: `click --at` is window-relative,
# `click --at-screen` is a screen point, and a point outside the window is refused
# instead of clamped onto its edge.
#
# Both halves are asserted, because each one alone is satisfiable by a driver that
# is wrong:
#
#   * the *printed conversion* proves the two spaces are not the same arithmetic —
#     `--at-screen X,Y` must report screen(X,Y) unchanged, `--at X,Y` must report
#     screen(X+origin, Y+origin);
#   * the *daemon state* proves the screen form actually landed on the row it
#     named. Measured in the VM before the fix, with the window at (0,350): the row
#     at screen y=468 was clicked at screen y=818 and the daemon's focused
#     workspace did not move — and nothing in the output said the coordinate was
#     in the wrong space.
case_click_coordinates() {
    requires() { echo focus; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1
        herdr workspace create >/dev/null 2>&1
        sleep 1
        # Distinct labels so a row is addressable by its own text, not by position:
        # the sidebar shows the workspace label and nothing else.
        herdr workspace rename w1 coord-one >/dev/null 2>&1 || return 1
        herdr workspace rename w2 coord-two >/dev/null 2>&1 || return 1
        herdr workspace focus w1 >/dev/null 2>&1
        sleep 3
        return 0
    }
    action() {
        driver window >"$host_dir/window.txt" 2>&1
        # The window frame is not the surface: the sidebar is on the left and the
        # title bar above, so mapping cell space onto the window put the click in
        # the sidebar. The AX tree is the only place the real container rectangle is
        # visible from outside the app.
        driver ax --json --depth 30 >"$host_dir/ax.json" 2>&1
        local point
        point=$(sidebar_row_point coord-two) || {
            echo "no sidebar row with value coord-two (issue #71: rows are AXValue only)"
            return 1
        }
        printf '%s' "$point" >"$host_dir/row-point.txt"
        # The row's screen point, straight from AX, through the screen form. This is
        # the path issue #72 asked for: no subtraction at the call site.
        driver click --at-screen "$point" >"$host_dir/click-screen.txt" 2>&1
        echo "exit=$?" >>"$host_dir/click-screen.txt"
        sleep 3
        herdr workspace list >"$host_dir/ws-after-screen.json" 2>&1

        # The same offset form the other cases use, for comparison. It is not a
        # duplicate of the above: the two runs are the A/B of the coordinate spaces.
        local win_x win_y
        win_x=$(sed -n 's/.* x=\(-\{0,1\}[0-9]*\) .*/\1/p' "$host_dir/window.txt")
        win_y=$(sed -n 's/.* y=\(-\{0,1\}[0-9]*\) .*/\1/p' "$host_dir/window.txt")
        driver click --at "120,200" >"$host_dir/click-offset.txt" 2>&1
        echo "exit=$?" >>"$host_dir/click-offset.txt"

        # The three refusals. Recorded rather than asserted in `action`, because a
        # refusal is a *harness* outcome (exit 2) and the assertion has to read the
        # message and the exit code together.
        local win_w win_h
        win_w=$(sed -n 's/.* w=\([0-9]*\).*/\1/p' "$host_dir/window.txt")
        win_h=$(sed -n 's/.* h=\([0-9]*\).*/\1/p' "$host_dir/window.txt")
        # Exactly the mistake from the issue, in the offset form: an AX frame is
        # larger than any legal offset in at least one axis once the window origin
        # is added to it. `w,h` is the bound itself, which is out of range by
        # definition (the range is half-open), so this does not depend on the
        # window's position on screen.
        driver click --at "$win_w,$win_h" >"$host_dir/refuse-offset.txt" 2>&1
        echo "exit=$?" >>"$host_dir/refuse-offset.txt"
        local outside_x=$((win_x + win_w + 40))
        local inside_y=$((win_y + 100))
        driver click --at-screen "$outside_x,$inside_y" >"$host_dir/refuse-offwindow.txt" 2>&1
        echo "exit=$?" >>"$host_dir/refuse-offwindow.txt"
        driver click --at "120,200" \
            --at-screen "$((win_x + 120)),$((win_y + 200))" >"$host_dir/refuse-both.txt" 2>&1
        echo "exit=$?" >>"$host_dir/refuse-both.txt"
    }
    assert() {
        local win_x win_y point
        win_x=$(sed -n 's/.* x=\(-\{0,1\}[0-9]*\) .*/\1/p' "$host_dir/window.txt")
        win_y=$(sed -n 's/.* y=\(-\{0,1\}[0-9]*\) .*/\1/p' "$host_dir/window.txt")
        point=$(cat "$host_dir/row-point.txt" 2>/dev/null)

        # 1. The screen form moved the daemon's focus to the workspace whose row was
        #    clicked. A driver that treated `--at-screen` as window-relative would
        #    land `win_y` points low and focus nothing.
        local focused
        focused=$(WSJSON="$host_dir/ws-after-screen.json" python3 -c '
import json, os
with open(os.environ["WSJSON"]) as handle:
    workspaces = json.load(handle)["result"]["workspaces"]
print(",".join(sorted(w["workspace_id"] for w in workspaces if w["focused"])))
') || focused=""
        check "click --at-screen on a sidebar row focuses that workspace" \
            "$([ "$focused" = "w2" ] && echo 0 || echo 1)" \
            "ax frame $point, focused workspace after the click: ${focused:-none} (expected w2)"

        # 2. `--at-screen` passes the point through unchanged: the reported screen
        #    coordinate is the AX frame itself, with no window origin added. This is
        #    the A/B against assertion 3 — same window, same driver, different space.
        local screen_log printed
        screen_log=$(cat "$host_dir/click-screen.txt" 2>/dev/null)
        printed=$(printf '%s' "$screen_log" | sed -n 's/^clicked screen(\(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\)).*/\1,\2/p')
        check "click --at-screen clicks the screen point unchanged" \
            "$([ -n "$printed" ] && [ "$printed" = "$point" ] && echo 0 || echo 1)" \
            "asked for $point, clicked $printed (the window origin must not be added)"

        # 3. `--at` adds the window origin exactly once: the same numbers mean a
        #    different screen point here, which is why mixing them was silent.
        local offset_log offset_printed
        offset_log=$(cat "$host_dir/click-offset.txt" 2>/dev/null)
        offset_printed=$(printf '%s' "$offset_log" | sed -n 's/.* -> screen(\(-\{0,1\}[0-9]*\),\(-\{0,1\}[0-9]*\).*/\1,\2/p')
        check "click --at adds the window origin exactly once" \
            "$([ "$offset_printed" = "$((win_x + 120)),$((win_y + 200))" ] && echo 0 || echo 1)" \
            "offset 120,200 at window origin $win_x,$win_y -> screen $offset_printed"

        # 4. An out-of-window point in the offset form is refused, and the message
        #    says both spaces are involved. Before the fix this was clamped to the
        #    window edge and clicked there — a case then failed later, reading like
        #    a product bug (issue #72).
        local log
        log=$(cat "$host_dir/refuse-offset.txt" 2>/dev/null)
        check "an out-of-window --at point is refused, not clamped to the edge" \
            "$(printf '%s' "$log" | grep -q '^exit=2$' \
                && printf '%s' "$log" | grep -q 'is outside the window' \
                && printf '%s' "$log" | grep -q 'would land at screen' \
                && echo 0 || echo 1)" \
            "$(printf '%s' "$log" | head -1 | cut -c1-120)"

        # 5. A screen point outside the window is refused too, and the message
        #    quotes the window frame so the reader can see which number is wrong.
        log=$(cat "$host_dir/refuse-offwindow.txt" 2>/dev/null)
        check "a screen point outside the window is refused, with the frame quoted" \
            "$(printf '%s' "$log" | grep -q '^exit=2$' \
                && printf '%s' "$log" | grep -q 'screen point .* is outside the window' \
                && printf '%s' "$log" | grep -q 'window frame x=' \
                && echo 0 || echo 1)" \
            "$(printf '%s' "$log" | head -1 | cut -c1-120)"

        # 6. Two spaces in one call is a caller mistake, not a preference: which one
        #    did they mean? Refusing beats picking the first, which is how a whole
        #    case can run against the wrong point.
        log=$(cat "$host_dir/refuse-both.txt" 2>/dev/null)
        check "passing --at and --at-screen together is refused" \
            "$(printf '%s' "$log" | grep -q '^exit=2$' \
                && printf '%s' "$log" | grep -q 'not both' && echo 0 || echo 1)" \
            "$(printf '%s' "$log" | head -1 | cut -c1-120)"
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

# ---------------------------------------------------------------- machines
#
# Two machines on one box, reached the way the product reaches a remote machine:
# a second daemon behind `ssh <this host> herdr remote-client-begin`, driven by a
# roster that lives in a scratch HOME.
#
# Why this does not need a second VM or a container: `herdr --session <name>` is a
# whole separate daemon — its own socket, its own boot id, its own panes — and
# `herdr machine add` prepares such a session for you (it starts the daemon). The
# guest's sshd is already running, so loopback SSH is the transport under test.
#
# Facts this fixture depends on, all measured against herdr 0.9.5:
#
#   * `machine add` only accepts a session daemon that IT started. A daemon started
#     by hand is refused with "remote server is not ready for saved machines", even
#     with HERDR_MACOS_SERVER_CONTEXT=user + HERDR_SESSION. So: never start one by
#     hand; let `add` do it, and reset with `herdr --session X server stop` + `rm`.
#   * saved machines use strict host-key checking, so `known_hosts` must be seeded
#     first. Kraal's own SSH pass uses `accept-new`; the CLI's preflight does not.
#   * the roster is `~/.local/state/herdr/client/endpoints.json` under `$HOME`, so
#     `KRAAL_HERDR_HOME` isolates it. The app already honours that (KraalMacMain).
#
# The roster is written by `machine add` rather than by hand: hand-writing it works
# for reading, but the fixture should exercise the same write path the panel does.

# Runs a command in the guest (or here) with the machine fixture's HOME.
roster_cmd() {
    case "$BACKEND" in
    local) env HOME="$ROSTER_HOME" herdr "$@" ;;
    vm) tart exec "$VM" /bin/bash -lc \
        "HOME=$ROSTER_HOME $VM_ROOT/bin/herdr $*" ;;
    esac
}

# The SSH target the fixture's machines point at: this host, over loopback.
#
# The user name is *not* `id -un` on the host: under the vm backend the machine
# being added is the guest, whose own account is `admin`, and adding
# `zheng@127.0.0.1` there fails authentication. Resolving it inside the backend
# is the only spelling that is right for both.
fixture_ssh_target() {
    local user
    case "$BACKEND" in
    local) user=$(id -un) ;;
    vm) user=$(tart exec "$VM" /bin/bash -lc 'id -un' 2>/dev/null | tr -d '\r\n') ;;
    esac
    [ -n "$user" ] || return 1
    printf '%s@127.0.0.1' "$user"
}

# The roster as `label<TAB>session` lines — what the sidebar is supposed to show.
roster_labels() {
    roster_cmd machine list --json 2>/dev/null | python3 -c '
import json, sys
try:
    machines = json.load(sys.stdin)
except Exception:
    raise SystemExit
for machine in machines:
    print(machine["label"] + "\t" + (machine.get("session") or ""))
'
}

# The API socket of one of the fixture's machine daemons.
#
# Two sockets, two audiences: `herdr-client.sock` speaks the inary endpoint
# protocol Kraal uses, `herdr.sock` is what the `herdr` CLI speaks. Reading a pane
# count with the *client* socket answers `EmptyResponse` — measured, not guessed:
#
#   HERDR_SOCKET_PATH=…/herdr-client.sock herdr pane list
#   -> Error: Custom { kind: Other, error: EmptyResponse }
#
# So a CLI assertion must point at `herdr.sock` and a Kraal/probe assertion at
# `herdr-client.sock`; the same `<session>/` directory holds both.
#
# Deliberately NOT under `$ROSTER_HOME`: `machine add` puts the roster under
# `$HOME` but prepares the remote session in the account's real
# `~/.config/herdr/sessions/<name>` (issue #75). Hard-coding the scratch path here
# was what made boot ids read as `none` while `machine status` said `reachable`.
machine_socket() {
    printf '%s/.config/herdr/sessions/%s/%s' "$1" "$2" "$3"
}

machine_client_socket() { machine_socket "$1" "$2" herdr-client.sock; }
machine_api_socket() { machine_socket "$1" "$2" herdr.sock; }

# The home the fixture's daemons actually live in: the real one, on both backends.
machine_home() {
    case "$BACKEND" in
    local) printf '%s' "$HOME" ;;
    vm) tart exec "$VM" /bin/bash -lc 'printf %s "$HOME"' 2>/dev/null | tr -d '\r\n' ;;
    esac
}

# "<label> head=<boot id>" for every session daemon the fixture runs.
# The boot id is what proves two machines are two daemons; pane ids are not
# enough, because both machines will have a `w1:p1`.
fixture_boots() {
    local real_home
    real_home=$(machine_home) || return 1
    local label session
    roster_labels | while IFS=$'\t' read -r label session; do
        [ -n "$session" ] || continue
        local boot client
        client=$(machine_client_socket "$real_home" "$session")
        case "$BACKEND" in
        local)
            boot=$("$ROOT/.build/out/Products/Debug/kraal" \
                --socket "$client" probe --timeout 12 2>/dev/null \
                | sed -n 's/^boot \([^ ]*\).*/\1/p')
            ;;
        vm)
            boot=$(tart exec "$VM" /bin/bash -lc \
                "$VM_ROOT/kraal --socket $client probe --timeout 12" \
                2>/dev/null | sed -n 's/^boot \([^ ]*\).*/\1/p')
            ;;
        esac
        printf '%s head=%s\n' "$label" "${boot:-none}"
    done
}

# Pane count on one of the fixture's machines (`machine_panes alpha-a`).
machine_panes() {
    local session
    session=$(roster_labels | awk -F'\t' -v want="$1" '$1 == want { print $2; exit }')
    [ -n "$session" ] || { echo ""; return 1; }
    local real_home
    real_home=$(machine_home) || { echo ""; return 1; }
    case "$BACKEND" in
    local)
        env HERDR_SOCKET_PATH="$(machine_api_socket "$real_home" "$session")" \
            herdr pane list 2>/dev/null \
            | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["panes"]))'
        ;;
    vm)
        tart exec "$VM" /bin/bash -lc \
            "HERDR_SOCKET_PATH=$real_home/.config/herdr/sessions/$session/herdr.sock $VM_ROOT/bin/herdr pane list" \
            2>/dev/null \
            | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["panes"]))'
        ;;
    esac
}

# `herdr pane layout` against a named fixture machine's own daemon.
#
# `pane_layout` reads the *local* daemon, and on a case that switched to a remote
# machine those are different servers with sometimes identical pane ids (`w1:p1` on
# both). Reading the wrong one produced an "expected pane" that could never match,
# which looked like a routing bug and was a harness bug.
machine_layout() {
    local label="$1" session real_home
    session=$(roster_labels | awk -F'\t' -v want="$label" '$1 == want { print $2; exit }')
    [ -n "$session" ] || return 1
    real_home=$(machine_home) || return 1
    case "$BACKEND" in
    local)
        env HERDR_SOCKET_PATH="$(machine_api_socket "$real_home" "$session")" \
            herdr pane layout 2>/dev/null
        ;;
    vm)
        tart exec "$VM" /bin/bash -lc \
            "HERDR_SOCKET_PATH=$real_home/.config/herdr/sessions/$session/herdr.sock $VM_ROOT/bin/herdr pane layout" \
            2>/dev/null
        ;;
    esac
}

# Loopback SSH for the guest's own sshd, plus the known_hosts entry the CLI's
# strict host-key checking demands. Idempotent.
machines_prereqs() {
    local script='
set -e
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519
cp ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ssh-keyscan -t ed25519 127.0.0.1 >> ~/.ssh/known_hosts 2>/dev/null || true
sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 \
    "$(id -un)@127.0.0.1" true
'
    case "$BACKEND" in
    local) bash -lc "$script" >/dev/null 2>&1 ;;
    vm) tart exec "$VM" /bin/bash -lc "$script" >/dev/null 2>&1 ;;
    esac
}

# Stops anything this fixture started. Called by every machines case's cleanup
# hook so a failed run does not leave daemons behind, and again at the start of
# each fixture: a failed run must not make the next one fail for its own mess
# (the first attempt at this case inherited `alpha-a` from an aborted run and
# reported three roster entries where it expected two).
#
# The session directories have to be removed from `$HOME/.config/herdr/sessions`,
# NOT from $ROSTER_HOME. Measured: `herdr machine add` writes the roster under
# `$HOME` (so KRAAL_HERDR_HOME isolates it) but prepares the *remote* session in
# the account's real `~/.config/herdr/sessions/<name>` — neither `HOME` nor
# `XDG_CONFIG_HOME` moves it. So the roster half is isolated and the session half
# is not, and a teardown that only deletes $ROSTER_HOME leaves live daemons and
# stale entries in `herdr session list` behind (issue #75).
machines_teardown() {
    # Two loops and two name sources, on purpose.
    #
    # The **names** cannot come from the roster: `case_machines_*_app_setup` calls
    # this function *before* it adds anything, so `roster_labels` is empty at that
    # point and a roster-driven loop would be dead code there. The fixture only
    # ever creates these two, so they are the list.
    #
    # The **path** must be `$HOME`, not `$ROSTER_HOME`, and that distinction is
    # the whole of issue #75. `$HOME` moves the roster; the session directory and
    # its socket are created by the bridge on the *remote* side (here 127.0.0.1,
    # the same account), so they land under the real home. Pointing this at
    # `$ROSTER_HOME/.config/herdr/sessions/...` was a silent no-op — measured:
    #
    #     server is not running or cannot be reached at
    #       /tmp/kraal-gui-501/roster-home/.config/herdr/sessions/fx-verify75/herdr.sock
    #       No such file or directory (os error 2)
    #
    # ...while the real `~/.config/herdr/sessions/fx-verify75` was untouched.
    #
    # The `roster_labels` loop stays for any future fixture that adds entries
    # before calling teardown, and because it is the only path that knows names
    # the fixed list does not.
    local session
    { roster_labels 2>/dev/null; printf 'fx-alpha\t%s\nfx-beta\t%s\n' fx-alpha fx-beta; } \
        | while IFS=$'\t' read -r _ session; do
        [ -n "$session" ] || continue
        case "$BACKEND" in
        local)
            env HERDR_SOCKET_PATH="$HOME/.config/herdr/sessions/$session/herdr.sock" \
                herdr server stop >/dev/null 2>&1
            ;;
        vm)
            tart exec "$VM" /bin/bash -lc \
                "HERDR_SOCKET_PATH=\$HOME/.config/herdr/sessions/$session/herdr.sock $VM_ROOT/bin/herdr server stop" \
                >/dev/null 2>&1
            ;;
        esac
    done
    case "$BACKEND" in
    local) rm -rf "$ROSTER_HOME" ;;
    vm) tart exec "$VM" /bin/bash -lc "rm -rf $ROSTER_HOME" >/dev/null 2>&1 ;;
    esac
    # The part `$HOME` does not move: the real account's session directories. The
    # stop already happened in the loop above; this removes what is left on disk
    # (and catches a session whose daemon was already gone).
    local sessions='for s in fx-alpha fx-beta; do
        rm -rf "$HOME/.config/herdr/sessions/$s"
    done'
    case "$BACKEND" in
    local) bash -lc "$sessions" >/dev/null 2>&1 ;;
    vm)
        tart exec "$VM" /bin/bash -lc \
            "for s in fx-alpha fx-beta; do
                 rm -rf \$HOME/.config/herdr/sessions/\$s
             done" >/dev/null 2>&1
        ;;
    esac
}

# The screen point to click for a sidebar row whose text is `label`.
#
# Two facts make this necessary rather than nice:
#
#   1. The repo writes no `accessibilityIdentifier`s, and SwiftUI puts a `Text`'
#      content in `AXValue` — so the row is addressable by *value*, not by title
#      (issue #71).
#   2. `onTapGesture` responds to real clicks only; an `AXPress` does nothing, so
#      the row cannot be "pressed" and the case must synthesise a click.
#
# Hence: read the row's frame from AX and click it. The frame is a **screen**
# coordinate (that is what AXPosition returns), so the value goes straight to
# `click --at-screen` — no arithmetic at the call site. It used to be handed to
# `click --at` after subtracting the window origin here, which is issue #72: one
# subtraction per caller, silent when wrong, and a click 350pt off read like a
# product bug. Output is `X,Y` because that is the argument shape both forms take.
#
# A hard-coded y broke the first version: with two workspaces on Local, the machine
# rows sat lower and the click landed on Local's own row, so the case failed with
# "the split landed on alpha-a" while the product was fine.
sidebar_row_point() {
    local label="$1" ax
    ax=$(driver ax --json --depth 22 2>/dev/null) || return 1
    printf '%s' "$ax" | LABEL="$label" python3 -c '
import json, os, sys
label = os.environ["LABEL"]
tree = json.load(sys.stdin)
nodes = tree["nodes"]
hit = None
for node in nodes:
    if node.get("value") == label and node.get("role") == "AXStaticText":
        frame = node.get("frame") or {}
        if "x" in frame and frame["x"] < 260:
            hit = frame
            break
if hit is None:
    sys.exit(1)
print("{},{}".format(hit["x"] + 20, hit["y"] + hit["h"] // 2))
' || return 1
}

# Machines in the sidebar, by clicking a machine row and checking which daemon
# the next command lands on.
#
# The assertion is daemon-side on purpose: the row is a SwiftUI `Text`, so it has
# no AXTitle (only AXValue), and `SELECT * FROM pixels` is not a gate. What a
# machine row *means* is "commands from now on go to that daemon", and that is
# observable through `pane list` on the second machine.
# The roster must exist BEFORE the app launches, because the app reads it exactly
# once at startup (and again only when Settings writes a profile). `fixture` runs
# after `launch_app`, which is right for daemon state and wrong for this: building
# the roster there had the app draw an empty list while the file on disk held both
# entries — issue #69's reload gap, hit from the harness side.
#
# Top level, not nested in the case: a nested function only exists once the outer
# one runs, and this hook has to run before it. (The same trap the `daemon_config`
# comment below documents.)
case_machines_switch_app_setup() {
    machines_teardown           # start from an empty roster, always
    machines_prereqs || { echo "loopback ssh unavailable"; return 1; }
    local target
    target=$(fixture_ssh_target) || return 1
    roster_cmd machine add "$target" --remote-session fx-alpha --label alpha-a \
        >/dev/null 2>&1 || { echo "machine add alpha-a failed for $target"; return 1; }
    roster_cmd machine add "$target" --remote-session fx-beta --label alpha-b \
        >/dev/null 2>&1 || { echo "machine add alpha-b failed for $target"; return 1; }
    # Both machines must be reachable before the case is meaningful; a roster
    # entry that never connects would make the switch assertion vacuous.
    local statuses
    statuses=$(roster_cmd machine status 2>/dev/null)
    printf '%s\n' "$statuses" | grep -q 'reachable' || {
        echo "no machine reported reachable: $(printf '%s' "$statuses" | head -c 200)"
        return 1
    }
    return 0
}

case_machines_switch() {
    requires() { echo focus; }
    fixture() {
        # The daemon fixture only: a pane to split, and the roster already in place.
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1
        [ "$(roster_labels | wc -l | tr -d ' ')" = "2" ] || {
            echo "the app_setup hook did not leave two machines in the roster"
            return 1
        }
        return 0
    }
    action() {
        # Two machine rows sit under the `machines` heading, after Local's own
        # workspace rows. Locate the row by its text instead of by a remembered y:
        # Local's workspace count changes the offsets, and the first version of this
        # case clicked a workspace row while everything else was correct.
        local point
        point=$(sidebar_row_point alpha-b) || {
            echo "no sidebar row with value alpha-b (issue #71: rows are AXValue only)"
            return 1
        }
        # `--at-screen`: the AX frame is already a screen point, so nothing is
        # offset here (issue #72). A driver that treated this form as
        # window-relative would click 350pt low and land off the row.
        driver click --at-screen "$point"
        sleep 3
    }
    assert() {
        local before_a after_a before_b after_b
        before_a=$(machine_panes alpha-a)
        before_b=$(machine_panes alpha-b)
        check "both fixture machines are real daemons" \
            "$([ -n "$before_a" ] && [ -n "$before_b" ] && echo 0 || echo 1)" \
            "alpha-a=$before_a panes, alpha-b=$before_b panes" || return 1

        # The switch's whole job: the next command goes to the other daemon.
        # alpha-b is the row the action clicked, so its pane count is the one that
        # must grow — a command that quietly stayed on alpha-a would be the bug.
        driver press --title "Split Right" >/dev/null 2>&1
        sleep 3
        after_a=$(machine_panes alpha-a)
        after_b=$(machine_panes alpha-b)
        check "the split landed on the selected machine" \
            "$([ "$after_b" = "$((before_b + 1))" ] && [ "$after_a" = "$before_a" ] && echo 0 || echo 1)" \
            "alpha-a $before_a->$after_a, alpha-b $before_b->$after_b"
    }
}

# The roster the app draws must match the roster on disk. This is the read half
# of the machines panel, and it is the assertion that catches the sidebar showing
# a stale list (the reload trigger is the bug in #69).
case_machines_roster_app_setup() {
    machines_teardown           # start from an empty roster, always
    machines_prereqs || return 1
    local target
    target=$(fixture_ssh_target) || return 1
    roster_cmd machine add "$target" --remote-session fx-alpha --label roster-a \
        >/dev/null 2>&1 || return 1
    roster_cmd machine add "$target" --remote-session fx-beta --label roster-b \
        >/dev/null 2>&1 || return 1
    return 0
}

# A click in a pane whose program reports the mouse (issue #95).
#
# The failure this exists for cannot be seen from the app side: whether the event
# was never sent, sent to the wrong pane, sent in the wrong coordinate space, or
# sent correctly and ignored by the program all look like "clicking does nothing".
# So the program itself records the bytes it received, and the assertion is on
# those bytes.
case_mouse_tui() {
    requires() { echo focus; }
    fixture() {
        # A fresh daemon has no panes at all (`daemon up, panes=0`), so the
        # workspace has to be created before there is anything to split.
        if [ "$(pane_count)" -eq 0 ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
            sleep 2
        fi
        # Split so there is a pane that is *not* focused: routing to the wrong pane
        # is one of the failures this case has to be able to see.
        # Positional pane id, not `--target-pane-id`: that flag does not exist and
        # the split was silently skipped, which the case reported as "the program
        # never claimed mouse reporting" (a downstream symptom of a fixture that
        # never ran). `herdr pane split --help` is the authority.
        herdr pane split "$(first_pane_id)" --direction down >/dev/null 2>&1 || true
        # Focus the *other* pane after splitting. `pane split` focuses the new pane,
        # and clicking a pane that is already focused cannot show the bug this case
        # is about: the first click on an unfocused pane is either swallowed by a
        # focus change or forwarded, and only the second one ever worked.
        sleep 2
        local target
        target=$(printf '%s\n' "$(pane_ids)" | tail -1)
        if [ -z "$target" ]; then
            echo "no pane to probe after the split"
            return 1
        fi
        # host_dir, not dir: `dir` is a *guest* path under the vm backend, and this
        # shell is the host. Writing to it here failed with "No such file or
        # directory" for a directory that existed — on the other machine.
        if ! printf '%s' "$target" >"$host_dir/target-pane.txt"; then
            echo "cannot record the target pane"
            return 1
        fi
        # Deliberately focus the *other* pane. `pane split` leaves the new pane
        # focused, and a click on an already-focused pane cannot show the bug: an
        # unfocused view forwards nothing, so the click is swallowed and the pane
        # never becomes focused either.
        herdr pane focus --pane "$(first_pane_id)" >/dev/null 2>&1 || true
        sleep 1
        # The probe claims mouse reporting the way a real TUI does, records every
        # byte, and leaves the pane usable. It runs for exactly as long as the case
        # needs, then exits on its own so the pane is not left in raw mode.
        herdr pane run "$target" \
            "python3 $VM_ROOT/tui-mouse-probe.py 45 $dir/mouse-events.txt" \
            >/dev/null 2>&1 || return 1
        # The program claiming the mouse is what makes this case meaningful, and the
        # only observer that can see it is the program itself: the CLI's JSON API
        # (`session.snapshot`) carries workspace/tab/pane metadata and no mouse
        # state at all. The probe writes its claim to a marker file for the same
        # reason — asking the daemon would mean speaking Kraal's bincode protocol
        # from bash.
        local tries=0
        while [ "$tries" -lt 40 ]; do
            if tart exec "$VM" /bin/bash -lc "test -s $dir/mouse-events.txt.ready" 2>/dev/null; then
                return 0
            fi
            tries=$((tries + 1))
            sleep 0.25
        done
        echo "probe never started (pane $target)"
        return 1
    }
    action() {
        driver window >"$host_dir/window.txt" 2>&1
        # The AX tree, because the window frame is not the surface: the sidebar is on
        # the left and the title bar above, so mapping cell space onto the *window*
        # put the click in the sidebar and the program correctly saw nothing.
        driver ax --json --depth 30 >"$host_dir/ax.json" 2>&1
        local point
        point=$(pane_body_point "$(cat "$host_dir/target-pane.txt")") || {
            echo "cannot compute a point inside the target pane"
            return 1
        }
        printf '%s' "$point" >"$host_dir/click-point.txt"
        # A real click, not AXPress: only a synthetic event exercises the mouse path
        # (AXPress goes through the accessibility action, which panes do not have).
        driver click --at-screen "$point" >"$host_dir/click.txt" 2>&1
        echo "exit=$?" >>"$host_dir/click.txt"
        sleep 1
        driver scroll --at-screen "$point" --lines 3 >"$host_dir/scroll.txt" 2>&1
        echo "exit=$?" >>"$host_dir/scroll.txt"
        sleep 2
    }
    assert() {
        # The probe writes in the guest under the vm backend, and the artefact
        # collection that would bring that file to the host runs *after* `assert`.
        # So the file has to be read where it is, not after it has been copied.
        local events="$host_dir/mouse-events.txt"
        if [ "$BACKEND" = "vm" ]; then
            tart exec -i "$VM" /bin/bash -lc "cat $dir/mouse-events.txt 2>/dev/null" \
                >"$events" 2>/dev/null
        else
            cp "$dir/mouse-events.txt" "$events" 2>/dev/null
        fi
        if [ ! -s "$events" ]; then
            check "program received a mouse press" 1 \
                "no bytes at all: the event never reached the program"
            return 1
        fi
        local parsed
        parsed=$(
            python3 - "$events" <<'PYEOF'
import ast
import sys

press = release = wheel = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    data = ast.literal_eval(line)
    # SGR mouse reports: ESC [ < button ; column ; row M|m
    # `M` is press (or wheel), `m` is release. Bit 6 of the button (>= 64) means
    # the wheel, which is how a program tells a scroll from a click.
    for chunk in data.split(b"\x1b[<")[1:]:
        if not chunk:
            continue
        final = chunk[-1:]
        if final not in (b"M", b"m"):
            continue
        try:
            button = int(chunk[:-1].split(b";")[0])
        except ValueError:
            continue
        if button >= 64:
            wheel += 1
        elif final == b"M":
            press += 1
        else:
            release += 1
print(f"press={press} release={release} wheel={wheel}")
sys.exit(0 if press >= 1 and release >= 1 else 1)
PYEOF
        )
        check "program received a press and its release" "$?" "$parsed"
        local wheel_only
        wheel_only=$(printf '%s' "$parsed" | sed -n 's/.*wheel=\([0-9]*\)/\1/p')
        check "program received a wheel report" \
            "$([ "${wheel_only:-0}" -ge 1 ] && echo 0 || echo 1)" "wheel=$wheel_only"
        # The pair must be one click, not several: the drag-jitter filter exists so a
        # stationary click is not reported as a drag (issue #95).
        local press_only
        press_only=$(printf '%s' "$parsed" | sed -n 's/^press=\([0-9]*\).*/\1/p')
        check "a stationary click is one press, not a drag storm" \
            "$([ "${press_only:-99}" = "1" ] && echo 0 || echo 1)" "press=$press_only"
        # And the report is in the *target pane's* own coordinates. A router that
        # picked the neighbour would send bytes too — same format, same count, a row
        # measured against the wrong pane — so counting alone would pass while the
        # click landed somewhere else. The row has to fit the pane it was aimed at.
        local target_row
        target_row=$(python3 - "$events" <<'PYEOF'
import ast
import sys

rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    for chunk in ast.literal_eval(line).split(b"\x1b[<")[1:]:
        if not chunk or chunk[-1:] not in (b"M", b"m"):
            continue
        try:
            parts = chunk[:-1].split(b";")
            rows.append(int(parts[2]))
        except (IndexError, ValueError):
            continue
print(max(rows) if rows else -1)
PYEOF
)
        local pane_rows
        pane_rows=$(pane_layout 2>/dev/null | python3 -c '
import json, sys
target = sys.argv[1]
layout = json.load(sys.stdin)["result"]["layout"]
for pane in layout["panes"]:
    if pane["pane_id"] == target:
        print(pane["rect"]["height"])
        break
' "$(cat "$host_dir/target-pane.txt")")
        # And the click focused the pane it landed in. Asserted against the daemon,
        # not the app's own state: focus is the daemon's to decide, and the whole
        # point is that a click on an unfocused pane goes nowhere without this.
        local focused_now
        focused_now=$(herdr pane list 2>/dev/null | python3 -c '
import json, sys
for pane in json.load(sys.stdin)["result"]["panes"]:
    if pane.get("focused"):
        print(pane["pane_id"])
        break
')
        check "the click focused the pane it landed in" \
            "$([ "$focused_now" = "$(cat "$host_dir/target-pane.txt")" ] && echo 0 || echo 1)" \
            "focused=$focused_now target=$(cat "$host_dir/target-pane.txt")"
        check "the click reported a row inside the target pane" \
            "$([ "${target_row:-0}" -ge 0 ] && [ "${target_row:-99}" -lt "${pane_rows:-1}" ] && echo 0 || echo 1)" \
            "row=$target_row of $pane_rows"
    }
}

# Right-clicking a pane on an **SSH** machine must raise the pane menu (issue #89).
#
# The report: a local pane shows Kraal's pane menu, an SSH pane shows nothing. The
# two candidate causes are indistinguishable from outside the app — `paneLocation`
# picking the wrong pane (the bug behind #88) and the SSH pane's frame never
# reaching `paneViewFrames` both end as "no menu, no log line". So the assertion
# here is on what the *app* decided, which it now logs.
case_context_menu_remote_app_setup() {
    machines_teardown
    machines_prereqs || { echo "loopback ssh unavailable"; return 1; }
    local target
    target=$(fixture_ssh_target) || return 1
    roster_cmd machine add "$target" --remote-session fx-menu --label menu-a \
        >/dev/null 2>&1 || { echo "machine add menu-a failed for $target"; return 1; }
    roster_cmd machine status 2>/dev/null | grep -q reachable || {
        echo "menu-a never became reachable"
        return 1
    }
    return 0
}

case_context_menu_remote() {
    requires() { echo focus; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1
        [ "$(roster_labels | wc -l | tr -d ' ')" = "1" ] || {
            echo "the app_setup hook did not leave the remote machine in the roster"
            return 1
        }
        # Switch to the remote machine. Its pane is the one this case right-clicks.
        local point
        point=$(sidebar_row_point menu-a) || {
            echo "no sidebar row with value menu-a"
            return 1
        }
        driver click --at-screen "$point" >/dev/null 2>&1 || return 1
        sleep 3
        # The remote daemon's own pane count is the proof the switch happened; the
        # case is vacuous otherwise.
        local panes
        panes=$(machine_panes menu-a)
        [ -n "$panes" ] && [ "$panes" -ge 1 ] || {
            echo "the remote machine has no panes to right-click (panes=$panes)"
            return 1
        }
        # Two panes, because one cannot distinguish a correct hit test from a
        # broken one: with a single pane every y resolves to it either way, so the
        # case passed even with #88's double inversion reintroduced (verified — the
        # A/B did not go red until this split was added).
        driver press --title "Split Down" >/dev/null 2>&1 || true
        sleep 3
        panes=$(machine_panes menu-a)
        [ "${panes:-0}" -ge 2 ] || {
            echo "the remote machine still has one pane; the case cannot tell right from wrong (panes=$panes)"
            return 1
        }
        return 0
    }
    action() {
        driver window >"$host_dir/window.txt" 2>&1
        # The *lower* pane. With a split, a double-inverted y maps this point onto
        # the upper pane instead, which is exactly the #88 failure — so aiming at
        # one specific pane is what makes the routing assertion mean something.
        local lower
        lower=$(machine_layout menu-a 2>/dev/null | python3 -c '
import json, sys
panes = json.load(sys.stdin)["result"]["layout"]["panes"]
# Only panes with a real size: a workspace that has accumulated splits keeps the
# closed ones in the layout with width/height == 0. Taking the plain maximum `y`
# picked one of those, so the expected id was a pane that is not on screen at all
# (measured: expected w1:pN (116x0) while the menu was correctly raised for w1:p2,
# the only visible pane). Requiring a painted size picks a pane a pointer can
# actually land on, which is what this case is about.
visible = [p for p in panes if p["rect"]["width"] > 0 and p["rect"]["height"] > 0]
if not visible:
    sys.exit(1)
print(max(visible, key=lambda p: p["rect"]["y"])["pane_id"])
')
        printf '%s' "$lower" >"$host_dir/expected-pane.txt"
        local point
        point=$(pane_body_point "$lower" menu-a) || {
            echo "cannot compute a point inside the lower remote pane"
            return 1
        }
        printf '%s' "$point" >"$host_dir/right-click-point.txt"
        driver click --at-screen "$point" --right >"$host_dir/right-click.txt" 2>&1
        echo "exit=$?" >>"$host_dir/right-click.txt"
        sleep 2
        # `NSMenu.popUpContextMenu` runs a modal menu-tracking loop, so the app is
        # *inside* that call while the menu is open — the `contextmenu:` log line
        # comes after it returns. Reading the menu therefore has to go through AX,
        # which still answers during menu tracking.
        driver ax --depth 30 >"$host_dir/ax-menu.txt" 2>&1
        # Dismiss with a click elsewhere rather than a key: `driver key --char escape`
        # sends the letter e, not ESC (issue #92), and a wrong key would leave the
        # menu open and wedge the next case.
        # Inside the window but away from the pane: (5,5) is outside it and the
        # driver correctly refuses (issue #72), which left the menu open.
        local dismiss_point
        dismiss_point=$(pane_dismiss_point) || dismiss_point="118,360"
        driver click --at-screen "$dismiss_point" >"$host_dir/dismiss.txt" 2>&1
        # The dismiss click is processed by the menu's own tracking loop, so the
        # `contextmenu:` line appears only after that loop returns. Poll the log
        # rather than guessing a sleep length.
        local tries=0
        while [ "$tries" -lt 20 ]; do
            collect_app_log "$host_dir"
            if grep -aq 'contextmenu: pane=' "$host_dir/kraal.log" 2>/dev/null; then
                return 0
            fi
            tries=$((tries + 1))
            sleep 0.5
        done
        return 0
    }
    assert() {
        local log="$host_dir/kraal.log"
        local expected
        expected=$(cat "$host_dir/expected-pane.txt" 2>/dev/null)

        # Which pane the app acted on. `contextmenu: pane=<id>` is the product's own
        # log line, written by `showPaneContextMenu` — not a probe — so the case
        # asserts on the same evidence a user's log would show. Absent means the
        # event never reached the forwarder, or it decided not to raise a menu
        # (cause A in the issue: `paneLocation` picked a pane whose program
        # reports the mouse, so the menu was correctly handed to the program).
        local raised
        raised=$(grep -ao 'contextmenu: pane=[^ ]*' "$log" 2>/dev/null | tail -1 \
            | sed 's/contextmenu: pane=//')
        check "the app raised the pane menu" \
            "$([ -n "$raised" ] && echo 0 || echo 1)" "pane=${raised:-none (no menu raised)}"

        # And for the pane that was actually under the pointer. A router that picked
        # the neighbour still raises a menu — for the wrong pane — so this is the
        # assertion that separates a working hit test from a broken one. It is also
        # exactly what #88 broke.
        check "the menu was raised for the lower pane it was aimed at" \
            "$([ -n "$raised" ] && [ "$raised" = "$expected" ] && echo 0 || echo 1)" \
            "raised=${raised:-none} expected=${expected:-none}"

        # The menu actually being on screen, which is a different claim from the
        # routing decision: the decision can be right and the menu still not appear.
        # AX is the observer that can see it during menu tracking.
        local menu_items
        menu_items=$(grep -cE 'Split Right|Split Down|Close Pane|Toggle Pane Zoom' \
            "$host_dir/ax-menu.txt" 2>/dev/null || echo 0)
        check "the pane menu was on screen with its items" \
            "$([ "${menu_items:-0}" -ge 3 ] && echo 0 || echo 1)" \
            "menu item lines in AX: $menu_items"

    }
}

# A session name that is legal but whose socket path overflows (issue #90).
#
# Two limits, one input field: `isValidSessionName` allows 64 characters, while the
# path those characters produce has a platform ceiling that depends on `$HOME`. A
# 64-character name used to pass validation and then fail somewhere else with a
# `pathTooLong` that said nothing about the field the user typed in. The fix refuses
# it where both facts are known, and the message has to carry the budget — the one
# number the user can act on, and the only place it is visible.
# A session name that is legal but whose socket path overflows (issue #90).
#
# Two limits, one input field: `isValidSessionName` allows 64 characters, while the
# path those characters produce has a platform ceiling that depends on `$HOME`. A
# 64-character name used to pass validation and then fail somewhere else with a
# `pathTooLong` that said nothing about the field the user typed in. The fix refuses
# it where both facts are known, and the message has to carry the budget — the one
# number the user can act on, and the only place it is visible.
#
# The UI surface is the **connection sheet**, not the machines settings: the settings
# panel has no session field, and the sheet only appears while disconnected, so this
# case launches the app against a socket that does not exist.
case_session_name_budget() {
    requires() { echo ax; }
    fixture() {
        # Nothing to prepare in the daemon: this case never reaches it.
        return 0
    }
    action() {
        # The connection sheet's trigger is the toolbar's network button, reachable
        # by its help text because the button has no title.
        # The accessibility description of a SwiftUI toolbar button is its system image
        # name (`network`), not the `.help` text — verified from the AX dump, the
        # same way issue #71 established that a Button has no AXTitle here.
        driver press --desc "network" >"$host_dir/press-network.log" 2>&1 || true
        sleep 2
        driver ax --json --depth 26 >"$host_dir/ax-sheet.json" 2>/dev/null
        local long_name
        long_name=$(python3 -c 'print("z" * 64)')
        printf '%s' "$long_name" >"$host_dir/long-name.txt"
        # Set the field's value directly. A SwiftUI `TextField` in a sheet is not
        # focused, so the focused-element path of `type` wrote nowhere and the field
        # kept its old text (observed: value stayed `default`). Addressed by its
        # current value instead, which is how the AX dump identifies it.
        driver type --value "default" --text "$long_name" \
            >"$host_dir/type.log" 2>&1 || true
        sleep 2
        driver ax --json --depth 26 >"$host_dir/ax-after.json" 2>/dev/null
    }
    assert() {
        local budget
        budget=$(python3 -c '
import os
home = os.path.expanduser("~")
fixed = len(home) + len("/.config/herdr/sessions/") + len("/herdr-client.sock")
print(min(64, max(0, 103 - fixed)))
')
        printf '%s' "$budget" >"$host_dir/budget.txt"

        local shown
        shown=$(python3 - "$host_dir/ax-after.json" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    tree = json.load(handle)
text = []
for node in tree["nodes"]:
    for key in ("value", "desc", "title"):
        field = node.get(key)
        if isinstance(field, str) and field:
            text.append(field)
print("\n".join(text))
PYEOF
)
        check "the sheet shows a refusal rather than a socket path" \
            "$(printf '%s' "$shown" | grep -q 'Shorten the name' && echo 0 || echo 1)" \
            "$(printf '%s' "$shown" | grep -a 'Shorten the name' | head -1)"

        check "the refusal states the budget for this machine" \
            "$(printf '%s' "$shown" | grep -q "at most ${budget} characters" && echo 0 || echo 1)" \
            "expected 'at most $budget characters', saw: $(printf '%s' "$shown" | grep -a 'at most' | head -1)"

        check "the refusal states the platform limit" \
            "$(printf '%s' "$shown" | grep -q 'allows 103' && echo 0 || echo 1)" \
            "$(printf '%s' "$shown" | grep -a 'allows' | head -1)"
    }
}

# A pane with an image encodes it into kitty bytes (issue #105, parent #37).
#
# The chain that was broken: the daemon sends graphics as a *scene*
# (`PaneSurfaceFrame.graphics`), the client read `PaneSurfaceFrame.frame.graphics`
# instead — the ANSI path's field, which the daemon leaves empty for semantic
# clients. Every layer decoded, nothing ever reached the terminal, and no unit test
# could see it because nobody called the encoder.
#
# The assertion is the product's own log line, emitted only for frames that carry
# non-empty encoded bytes. That matters: asserting "the encoder was called" would
# pass with an encoder that returns `Data()`.
case_kitty_graphics() {
    requires() { echo ax; }
    fixture() {
        if [ "$(pane_count)" -eq 0 ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
            sleep 2
        fi
        local target
        target=$(first_pane_id) || return 1
        printf '%s' "$target" >"$host_dir/target-pane.txt"
        # The probe transmits a real kitty image (`a=T`), writes a marker once the
        # bytes are out, and holds the pane open long enough for the daemon to
        # composite a frame with it.
        herdr pane run "$target" \
            "python3 $VM_ROOT/kitty-graphics-probe.py 30 $dir/graphics-probe.txt" \
            >/dev/null 2>&1 || return 1
        local tries=0
        while [ "$tries" -lt 60 ]; do
            if tart exec "$VM" /bin/bash -lc "test -s $dir/graphics-probe.txt.ready" 2>/dev/null; then
                return 0
            fi
            tries=$((tries + 1))
            sleep 0.25
        done
        echo "the probe never transmitted an image (pane $target)"
        return 1
    }
    action() {
        # Give the daemon time to composite a frame that carries the image and push
        # it to the client, then let the client paint it.
        sleep 4
        # The pixel evidence (#103). Everything above proves bytes reached the
        # terminal; none of it proves a picture is on the screen — and that gap is
        # where this repository's most expensive bugs lived. A screenshot cropped to
        # the pane is the only thing that closes it.
        local target rect
        target=$(cat "$host_dir/target-pane.txt" 2>/dev/null)
        # Guest paths, not host ones: `driver` runs inside the vm under the vm
        # backend, so a host path is a path on the other machine (docs §4.4 of
        # ENVIRONMENT.md). The reports are copied out afterwards.
        # Guest paths, not host ones: `driver` runs inside the vm under the vm
        # backend, so a host path is a path on the other machine (docs/ENVIRONMENT.md
        # §4.4). The reports are copied out afterwards.
        local with_image="$dir/with-image.png"
        driver shot -o "$with_image" >"$host_dir/shot.txt" 2>&1
        echo "exit=$?" >>"$host_dir/shot.txt"
        # Window space, because `screencapture -l` produced a window image
        # (`shot.txt` reports `window=<n>`). A screen-space rect here would clamp
        # silently — see `pane_window_rect` for the measurement that caught it.
        if ! rect=$(pane_window_rect "$target" 2>/dev/null); then
            echo "no pane rect" >"$host_dir/rect.txt"
            return 0
        fi
        printf '%s' "$rect" >"$host_dir/rect.txt"
        # The probe draws a solid magenta rectangle. The predicate is loose on
        # purpose: the image is scaled onto a cell grid, so its edges blend.
        driver pixels --in "$with_image" --rect "$rect" \
            --match "r>200,g<80,b>200" >"$host_dir/pixels.txt" 2>&1
        echo "exit=$?" >>"$host_dir/pixels.txt"

        # The control: the probe deletes its image (`a=d,d=A`) when it exits, so
        # waiting for it to finish and re-measuring gives the same region with no
        # image in it. Both numbers come from one run, which is the point — a
        # hardcoded "before" could be measured on a different machine.
        #
        # The probe runs for 30s (see `fixture`); this waits for it to exit without
        # guessing at a fixed sleep: `pane read` reports the shell prompt coming back.
        local waited=0
        while [ "$waited" -lt 45 ]; do
            if tart exec "$VM" /bin/bash -lc "test -s $dir/graphics-probe.txt.deleted" 2>/dev/null; then
                break
            fi
            waited=$((waited + 1))
            sleep 1
        done
        # The probe writes `.deleted` only after it has written the delete sequence.
        # Without this check, a probe that never cleaned up would simply be waited
        # out and then measured: `after` would read 4032 and the case would report
        # "the image is still on screen", which reads like a product bug.
        printf '%s' "$waited" >"$host_dir/waited.txt"
        sleep 2
        driver shot -o "$dir/after.png" >/dev/null 2>&1
        driver pixels --in "$dir/after.png" --rect "$rect" \
            --match "r>200,g<80,b>200" >"$host_dir/after-pixels.txt" 2>&1
    }
    assert() {
        local sent
        if [ "$BACKEND" = "vm" ]; then
            sent=$(tart exec -i "$VM" /bin/bash -lc "head -1 $dir/graphics-probe.txt 2>/dev/null" 2>/dev/null)
        else
            sent=$(head -1 "$dir/graphics-probe.txt" 2>/dev/null)
        fi
        check "the program transmitted a kitty image" \
            "$([ -n "$sent" ] && echo 0 || echo 1)" "${sent:-nothing was written}"

        # The product log line. `collect_app_log_tail` reads the guest's log under
        # the vm backend, which is where the app writes it.
        # The line that carried the image, not the last one: the probe deletes its
        # image when it exits (`a=d,d=A`), and that produces a later
        # `assets=0 … encoded=0` frame. Taking `tail -1` would assert on the
        # deletion instead of the upload (measured: the run went red after the
        # control was added, purely from this).
        local line
        line=$(collect_app_log_tail 2>/dev/null | grep -a 'graphics: pane=' \
            | grep -a 'assets=[1-9]' | tail -1)
        printf '%s\n' "${line:-<none>}" >"$host_dir/graphics-log.txt"
        check "the pane encoded the daemon's graphics scene" \
            "$([ -n "$line" ] && echo 0 || echo 1)" \
            "${line:-no 'graphics: pane=' line; the scene never reached the encoder}"
        # The bytes are what proves an upload happened rather than an empty frame
        # being logged. `assets` and `placements` come straight from the scene.
        check "the encoded frame carries an asset and a placement" \
            "$(printf '%s' "$line" | grep -qE 'assets=[1-9]' && printf '%s' "$line" | grep -qE 'placements=[1-9]' && echo 0 || echo 1)" \
            "${line:-<none>}"
        # `painted`, not `encoded`: the renderer is allowed to skip graphics it
        # believes are unchanged (`lastGraphics`), so "the encoder produced bytes"
        # says nothing about whether the terminal was written. Both numbers are on
        # the line precisely so this assertion can be about the second one.
        # `kitty=`, the count of kitty sequences in what the *renderer* wrote. A byte
        # count would not do: the text frame alone is a few kilobytes, so
        # "painted > 1000" passes with no image at all (verified by injecting a
        # renderer that drops graphics — painted fell 26546 -> 4542 and still passed).
        local kitty
        kitty=$(printf '%s' "$line" | sed -n 's/.*kitty=\([0-9]*\).*/\1/p')
        check "the renderer wrote kitty sequences to the terminal" \
            "$([ -n "$kitty" ] && [ "$kitty" -ge 2 ] && echo 0 || echo 1)" \
            "kitty sequences in the renderer output: ${kitty:-<none>}"

        # And the picture is on the screen. `matched` is magenta-ish pixels inside
        # the pane's screen rect: a solid 64x64 image scaled onto the cell grid is
        # hundreds of pixels, so the threshold is a floor, not a tight bound. The
        # rect is asserted to exist first — a missing rect would otherwise read as
        # "zero magenta pixels", which is the same number a missing image gives.
        local pixels_line rect_line
        pixels_line=$(cat "$host_dir/pixels.txt" 2>/dev/null | head -1)
        rect_line=$(cat "$host_dir/rect.txt" 2>/dev/null)
        check "the pane's rect inside the window was located" \
            "$(printf '%s' "$rect_line" | grep -qE '^[0-9]+ [0-9]+ [0-9]+ [0-9]+$' && echo 0 || echo 1)" \
            "${rect_line:-no rect for the pane; see rect.txt}"
        # The control (#103): the same region, sampled before the probe ran, has
        # essentially no magenta. Without it "4032 magenta pixels" could be the
        # pane's own background, a theme colour, or a stale frame from a previous
        # run — the assertion would pass on a machine where the image never draws.
        local before_matched
        before_matched=$(grep -o 'matched=[0-9]*' "$host_dir/after-pixels.txt" 2>/dev/null | head -1 | cut -d= -f2)
        check "the pane has no magenta once the image is deleted" \
            "$([ -n "$before_matched" ] && [ "$before_matched" -lt 50 ] && echo 0 || echo 1)" \
            "magenta pixels after the probe deleted its image: ${before_matched:-<not measured>}"

        # The probe recorded that it deleted its image. Without this, a probe that
        # never cleaned up would be waited out and then measured; `after` would read
        # 4032 and the failure would read as "the image is still on screen" — a
        # product bug report for a harness problem.
        local waited
        waited=$(cat "$host_dir/waited.txt" 2>/dev/null)
        check "the probe recorded its image deletion" \
            "$([ -n "$waited" ] && [ "$waited" -lt 45 ] && echo 0 || echo 1)" \
            "waited ${waited:-?}s for the .deleted marker"

        # The region actually sampled has to be the pane's rect. This is the guard
        # for coordinate-space mistakes, which are silent by nature: a screen-space
        # rect against a window image clamps to the overlap and the count then
        # describes a band nobody asked for (measured once: 959x664 became 959x314
        # and `matched` still looked plausible). `sampled` is `w*h*scale^2`, so a
        # clamp shows up here even when `matched` happens to survive it.
        local sampled region
        sampled=$(printf '%s' "$pixels_line" | sed -n 's/.*sampled=\([0-9]*\).*/\1/p')
        region=$(printf '%s' "$pixels_line" | sed -n 's/.*region=\([0-9]*x[0-9]*\).*/\1/p')
        local want_want
        want_want=$(printf '%s' "$rect_line" | awk '{ printf "%d", $3 * $4 }')
        check "the sampled area is the whole pane rect" \
            "$([ -n "$sampled" ] && [ "$sampled" -eq "$want_want" ] && echo 0 || echo 1)" \
            "sampled=${sampled:-<none>} want=$want_want (region=${region:-?})"

        local matched
        matched=$(printf '%s' "$pixels_line" | sed -n 's/.*matched=\([0-9]*\).*/\1/p')
        # Upper bound as well as lower: a full-screen magenta window would satisfy
        # "more than 200" too, and that is not an image in the pane.
        check "the image is visible on the screen" \
            "$([ -n "$matched" ] && [ "$matched" -gt 200 ] && [ "$matched" -lt "$((want_want / 2))" ] \
                && echo 0 || echo 1)" \
            "magenta pixels in the pane: ${matched:-<none>} (${pixels_line:-no pixels run})"
    }
}

# Named keys really reach the program (issue #92).
#
# `kraal-gui key --char escape` used to take the first character of its argument
# and post the letter `e` — successfully, exit 0. A case that meant to press ESC
# pressed `e` and reported success, which is the same class of trap as issue #72:
# the harness sent something other than what it was asked to, and nothing said so.
#
# The assertion is on the bytes the program in the pane received. "The key was
# sent" is not observable from outside — and the whole defect was that the driver
# believed it had sent it.
case_key_named() {
    requires() { echo focus; }
    fixture() {
        if [ "$(pane_count)" = "0" ]; then
            herdr workspace create >/dev/null 2>&1 || return 1
        fi
        local target
        target=$(first_pane_id) || return 1
        printf '%s' "$target" >"$host_dir/target-pane.txt"
        # The probe switches the terminal to raw mode and writes a `.ready` marker.
        # Keys sent before that are interpreted by the terminal itself — ESC would be
        # eaten there and never reach the program, which is a false failure that
        # looks exactly like the bug.
        herdr pane run "$target" "python3 $VM_ROOT/key-probe.py 40 $dir/key-events.txt" \
            >/dev/null 2>&1 || return 1
        local tries=0
        while [ "$tries" -lt 40 ]; do
            if tart exec "$VM" /bin/bash -lc "test -s $dir/key-events.txt.ready" 2>/dev/null; then
                return 0
            fi
            tries=$((tries + 1))
            sleep 0.25
        done
        echo "key probe never entered raw mode (pane $target)"
        return 1
    }
    action() {
        # ESC first: it is the key the issue is about, and it is the one a wrong
        # `--char` turns into a printable letter.
        driver key --name escape >"$host_dir/key-escape.txt" 2>&1
        echo "exit=$?" >>"$host_dir/key-escape.txt"
        sleep 1
        driver key --name tab >"$host_dir/key-tab.txt" 2>&1
        echo "exit=$?" >>"$host_dir/key-tab.txt"
        sleep 1
        # And a plain character, to show the two channels did not collapse into one.
        driver key --char a >"$host_dir/key-a.txt" 2>&1
        echo "exit=$?" >>"$host_dir/key-a.txt"
        sleep 1
        # A wrong name must be refused, loudly. Run last so its failure cannot be
        # confused with the keys above.
        driver key --name notakey >"$host_dir/key-bad.txt" 2>&1
        echo "exit=$?" >>"$host_dir/key-bad.txt"
        sleep 1
        # And a key *name* passed to --char: the original mistake, which used to
        # succeed by sending a letter.
        driver key --char escape >"$host_dir/key-barchar.txt" 2>&1
        echo "exit=$?" >>"$host_dir/key-barchar.txt"
        sleep 1
        # A burst of keys into one pane, for issue #55: every keystroke used to post
        # its own `pane.focus`, 7x the socket cost of the keystroke itself. Driven
        # here rather than in a unit test because the count that matters is what the
        # app actually sends, and only its log knows that.
        for _ in $(seq 1 20); do
            driver key --char b >/dev/null 2>&1 || true
        done
        sleep 2
    }
    assert() {
        local events="$host_dir/key-events.txt"
        if [ "$BACKEND" = "vm" ]; then
            tart exec -i "$VM" /bin/bash -lc "cat $dir/key-events.txt 2>/dev/null" \
                >"$events" 2>/dev/null
        else
            cp "$dir/key-events.txt" "$events" 2>/dev/null
        fi

        # ESC is 0x1b. Tab is 0x09, and `a` is 0x61. The program saw the raw bytes,
        # so this is the program's own account rather than the driver's belief.
        local seen
        seen=$(python3 - "$events" <<'PYEOF'
import ast
import sys

blob = b""
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                blob += ast.literal_eval(line)
except OSError:
    pass
print(" ".join(f"{byte:02x}" for byte in blob))
PYEOF
)
        printf '%s' "$seen" >"$host_dir/seen-bytes.txt"

        check "the program received ESC as a real escape byte" \
            "$(printf '%s' "$seen" | tr ' ' '\n' | grep -qx '1b' && echo 0 || echo 1)" \
            "bytes seen: ${seen:-none}"

        # Tab, not the letter `t`: the same failure mode, one key over.
        check "the program received TAB and not the letter t" \
            "$(printf '%s' "$seen" | tr ' ' '\n' | grep -qx '09' && echo 0 || echo 1)" \
            "bytes seen: ${seen:-none}"

        # And `--char a` still works, so the fix did not route everything through
        # the name table.
        check "the program received a plain character" \
            "$(printf '%s' "$seen" | tr ' ' '\n' | grep -qx '61' && echo 0 || echo 1)" \
            "bytes seen: ${seen:-none}"

        # The two refusals. `exit=` was captured right after each command, so a
        # silent success cannot hide here.
        local bad_exit bad_char_exit
        bad_exit=$(sed -n 's/^exit=//p' "$host_dir/key-bad.txt" 2>/dev/null | tail -1)
        bad_char_exit=$(sed -n 's/^exit=//p' "$host_dir/key-barchar.txt" 2>/dev/null | tail -1)
        check "an unknown key name is refused, not posted as something else" \
            "$([ "${bad_exit:-0}" != "0" ] && echo 0 || echo 1)" \
            "exit=$bad_exit $(grep -a 'no key named' "$host_dir/key-bad.txt" 2>/dev/null | head -1)"

        # The original mistake: a key name in `--char`. It must say what to do
        # instead, because silently sending `e` is how this issue happened.
        check "a key name passed to --char is refused with a pointer to --name" \
            "$([ "${bad_char_exit:-0}" != "0" ] \
                && grep -aq 'use --name' "$host_dir/key-barchar.txt" 2>/dev/null \
                && echo 0 || echo 1)" \
            "exit=$bad_char_exit $(head -1 "$host_dir/key-barchar.txt" 2>/dev/null)"

        # Issue #55: 23 keystrokes into the same pane must not produce 23 focus
        # requests. The ceiling is 2 rather than 1 so a legitimate re-focus (a
        # snapshot that arrived naming no pane, which invalidates the belief) does
        # not make the case flaky — what is being ruled out is "one per keystroke".
        local focus_calls
        focus_calls=$(grep -ac "call: ok pane.focus" "$host_dir/kraal.log" 2>/dev/null || true)
        check "typing does not re-focus the pane on every keystroke" \
            "$([ "${focus_calls:-99}" -le 2 ] && echo 0 || echo 1)" \
            "pane.focus calls=${focus_calls:-none} for 23 keystrokes into one pane"
    }
}

case_machines_roster() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1
        [ "$(roster_labels | wc -l | tr -d ' ')" = "2" ] || {
            echo "the app_setup hook did not leave two machines in the roster"
            return 1
        }
        return 0
    }
    action() {
        # Nothing to click: the roster is read at launch, which is one of the two
        # moments the app actually reloads it.
        sleep 2
    }
    assert() {
        local expected heads
        expected=$(roster_labels | cut -f1 | sort)
        check "the roster has both saved machines" \
            "$([ "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" = "2" ] && echo 0 || echo 1)" \
            "$(printf '%s' "$expected" | tr '\n' ' ')" || return 1

        # Two distinct boot ids is the claim "these are two daemons", which is what
        # makes the case worth running at all — and it is also the setup every
        # later cross-machine assertion depends on.
        heads=$(fixture_boots | sed -n 's/.*head=//p' | sort -u)
        check "the two machines are different daemons" \
            "$([ "$(printf '%s\n' "$heads" | wc -l | tr -d ' ')" = "2" ] && echo 0 || echo 1)" \
            "$(printf '%s' "$heads" | tr '\n' ' ')"

        # The app logged the roster it loaded; that line is the app's own account
        # of what it drew, and it exists precisely because the sidebar has no AX
        # text to read (issue #71).
        local log="$host_dir/kraal.log"
        check "the app loaded the same two machines" \
            "$(grep -aq 'endpoints: 2 saved machine(s)' "$log" 2>/dev/null && echo 0 || echo 1)" \
            "$(grep -ao 'endpoints: .*' "$log" 2>/dev/null | tail -1)"
    }
}

# The machines panel's controls must be addressable **by name**, not by
# position (issue #71).
#
# The reported symptom: every Row-level control answered `AXDescription=\"Rename\"`
# with `AXTitle=''`, so `press --title Rename` found nothing and the driver had to
# fall back to `press --desc Rename --index N`. With one Rename per row plus the
# rename sheet's own submit button, `--index` meant guessing which control got
# pressed.
#
# Measured while fixing it (macOS 27.0.1 / build 26A434, in this VM): **no**
# SwiftUI `Button` reports `AXTitle`. Twenty spellings were tried — plain
# `Button(\"X\"){}`, `label:` closure, `.borderless`, `.help`, `Label`, `.bordered`,
# `.borderedProminent`, `.link`, `.keyboardShortcut`, `.accessibilityLabel`,
# `.accessibilityElement(children:)`, `.accessibilityRepresentation`, `.accessibilityValue`
# — and every one produced `title=''` with the text in `AXDescription`. A bare
# `NSButton` in the same window reported the title it was given, so `AXTitle` is
# reachable in this app; SwiftUI simply does not write it. The issue's diagnosis
# (`.buttonStyle(.borderless)` + `.help()`) is therefore wrong, and
# `.accessibilityLabel` does **not** write `AXTitle` either — it rewrites `desc`.
#
# So the fix makes the *description* unambiguous instead: the row buttons carry
# the machine label (`Rename ctrl-a`), which also separates them from the
# sheet's plain `Rename`. This case is the gate for exactly that.
#
# `--title` is deliberately not asserted on anywhere here: it cannot pass, and a
# gate that asserts something unreachable is worse than no gate. The measurable
# claim is "each control has a unique, stable name a driver can pass to
# `press --desc`", and that is what the checks below mean.
case_machines_controls_app_setup() {
    machines_teardown
    machines_prereqs || return 1
    local target
    target=$(fixture_ssh_target) || return 1
    roster_cmd machine add "$target" --remote-session fx-alpha --label ctrl-a \
        >/dev/null 2>&1 || return 1
    roster_cmd machine add "$target" --remote-session fx-beta --label ctrl-b \
        >/dev/null 2>&1 || return 1
    return 0
}

case_machines_controls() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1
        return 0
    }
    action() {
        # Settings via the menu: AXPress needs no focus, so this case stays an
        # `ax` case and can run while the machine is in use.
        driver menu --menu Kraal --item "Settings…" >/dev/null 2>&1 || true
        sleep 3
        driver ax --json --depth 26 >"$host_dir/ax-settings.json" 2>/dev/null
        # Open the rename sheet by pressing the row's own button, by name. `|| true`
        # on purpose: a missing element is an assertion failure below, not a
        # harness failure, so the dumps still land as artefacts to look at.
        driver press --desc "Rename ctrl-a" >"$host_dir/press-row-rename.log" 2>&1 || true
        sleep 2
        # With the sheet open, both the rows and the sheet are in one tree. That is
        # the moment the old build had three answers to `desc=Rename` (two rows plus
        # the sheet) and a caller had to pass `--index`.
        driver ax --json --depth 26 >"$host_dir/ax-rename-sheet.json" 2>/dev/null
        driver press --desc "Cancel" >/dev/null 2>&1 || true
        sleep 2
        driver press --desc "Remove ctrl-a" >"$host_dir/press-row-remove.log" 2>&1 || true
        sleep 2
        driver ax --depth 26 >"$host_dir/ax-remove-alert.txt" 2>&1
        driver press --desc "Cancel" >/dev/null 2>&1 || true
        sleep 2
        driver press --desc "Add Machine" >"$host_dir/press-add.log" 2>&1 || true
        sleep 2
        driver ax --depth 26 >"$host_dir/ax-add-sheet.txt" 2>&1
        driver press --desc "Cancel" >/dev/null 2>&1 || true
        sleep 1
        return 0
    }
    assert() {
        # One tree, several questions asked of it. The JSON carries `desc`, `role`
        # and `pressable` per node — the same view an agent driving this app has.
        local counts
        counts=$(AXJSON="$host_dir/ax-settings.json" python3 -c '
import json, sys, os
path = os.environ["AXJSON"]
with open(path) as handle:
    tree = json.load(handle)
desc = {}
for node in tree["nodes"]:
    if node.get("role") != "AXButton":
        continue
    key = node.get("desc") or ""
    desc[key] = desc.get(key, 0) + 1
named_rename = sum(n for d, n in desc.items() if d.startswith("Rename "))
named_remove = sum(n for d, n in desc.items() if d.startswith("Remove "))
print(named_rename, named_remove, desc.get("Add Machine", 0), desc.get("Rename", 0))
') || counts="0 0 0 0"
        local row_rename row_remove add_machine
        read -r row_rename row_remove add_machine _ <<<"$counts"

        # Each row gets its own two descriptions, so a row is addressable without
        # an index. Two rows => two distinct `Rename <label>` strings.
        check "each row's Rename is named after its machine" \
            "$([ "${row_rename:-0}" = "2" ] && echo 0 || echo 1)" \
            "$row_rename button(s) with a distinct \"Rename <label>\" description"
        check "each row's Remove is named after its machine" \
            "$([ "${row_remove:-0}" = "2" ] && echo 0 || echo 1)" \
            "$row_remove button(s) with a distinct \"Remove <label>\" description"

        # `Add Machine` — the `Label(...)` button the issue also named. It was
        # already unique before the fix; it is here so a future edit that renames
        # it fails loudly instead of silently making the panel unaddressable again.
        check "Add Machine is addressable by name" \
            "$([ "${add_machine:-0}" = "1" ] && echo 0 || echo 1)" \
            "desc=Add Machine matches ${add_machine:-0} element(s)"

        # The sheet-open tree is the one that used to be ambiguous.
        local sheet_open
        sheet_open=$(AXJSON="$host_dir/ax-rename-sheet.json" python3 -c '
import json, os
with open(os.environ["AXJSON"]) as handle:
    tree = json.load(handle)
plain = [n for n in tree["nodes"]
         if n.get("role") == "AXButton" and (n.get("desc") or "") == "Rename"]
named = [n for n in tree["nodes"]
         if n.get("role") == "AXButton" and (n.get("desc") or "").startswith("Rename ")]
print(len(plain), len(named))
') || sheet_open="9 9"
        local plain_open named_open
        read -r plain_open named_open <<<"$sheet_open"

        # The A/B in one assertion. Measured on the pre-fix build with this same
        # sheet open: three buttons answered `desc=Rename` (two rows plus the
        # sheet), which is what forced `--index` on the caller. Now the only plain
        # `Rename` is the sheet's own submit button.
        check "with the rename sheet open, only the sheet answers plain Rename" \
            "$([ "${plain_open:-9}" = "1" ] && echo 0 || echo 1)" \
            "plain desc=Rename matches ${plain_open:-?} element(s) with the sheet open"
        check "the rows stay named while the sheet is open" \
            "$([ "${named_open:-9}" = "2" ] && echo 0 || echo 1)" \
            "${named_open:-?} \"Rename <label>\" button(s) visible behind the sheet"

        # The press logs are the other half: the driver has to have *found* each
        # control by the name this case claims. An assertion on the tree alone
        # would pass even if `press` could not resolve the same string.
        local pressed
        pressed=$(cat "$host_dir"/press-*.log 2>/dev/null)
        check "the driver pressed every Row control by name" \
            "$([ "$(printf '%s' "$pressed" | grep -c '^pressed ')" = "3" ] && echo 0 || echo 1)" \
            "$(printf '%s' "$pressed" | grep '^pressed ' | tr '\n' ' ')"
        check "no press was ambiguous or unmatched" \
            "$(printf '%s' "$pressed" | grep -qvE '^pressed |^$' && echo 1 || echo 0)" \
            "$(printf '%s' "$pressed" | grep -vE '^pressed |^$' | head -2 | tr '\n' ' ')"
    }
}

# ---------------------------------------------------------------- runner# ---------------------------------------------------------------- runner

# Appends one roster row pointing at a port nothing listens on, so the CLI reports
# `error` for it. Used by `machines-reachability`: `machine add` verifies a host
# before saving and would refuse to create an entry that is known to be dead, so
# the dead half of the fixture has to be written by hand.
#
# **Why a dead port and not a nonexistent session.** The first version of this
# fixture used a session name nothing had created, and it went green for the wrong
# reason: the app's sidebar dials every roster entry, and that dial is the same
# bridge `herdr machine add` uses — it *starts* the remote server. By the time the
# panel probed, the session existed and the row read `reachable`. Measured in the
# failing run: `machines: status 2 row(s) -> reach-a[8f6ca3cc]=reachable,
# reach-b[deadbeef]=reachable`, while the same command had reported `error` for
# `reach-b` seconds earlier. A refused TCP port cannot be revived, so the row stays
# dead no matter what the app does.
#
# The file shape is herdr's own (`src/client/endpoint/catalog.rs:71-77`):
# `{"version":1,"ssh":[…]}` with `deny_unknown_fields`, so no extra key may be
# invented — measured: adding `"selected"` to a row makes the whole catalog
# unreadable ("unknown field `selected`").
roster_add_dead_row() {
    # `$1` is read into a local immediately. Bash scopes dynamically, so a bare
    # `$target` here would silently resolve to the *caller's* `local target` — the
    # caller's live loopback machine — and the "dead" row would point at a host the
    # app can revive. Measured: that is exactly what the first two runs did.
    local target="$1"
    local roster="$ROSTER_HOME/.local/state/herdr/client/endpoints.json"
    # No single quotes inside: this string is handed to the guest's shell wrapped
    # in them.
    local script='import json, os
path = os.environ["ROSTER"]
catalog = json.load(open(path))
catalog["ssh"].append({
    "id": "deadbeefdeadbeefdeadbeefdeadbeef",
    "label": "reach-b",
    "target": os.environ["TARGET"],
    "session": "kraal-73-dead",
    "enabled": True,
})
json.dump(catalog, open(path, "w"))'
    case "$BACKEND" in
    local) ROSTER="$roster" TARGET="$target" python3 -c "$script" ;;
    vm) tart exec "$VM" /bin/bash -lc "ROSTER=$roster TARGET=$target python3 -c '$script'" ;;
    esac
}

# Whether the machines panel shows each machine's reachability (issue #73).
#
# `HerdrMachineClient.status()` was never called, so the panel drew a dead
# machine exactly like a live one — and `machine status --json` exits **1** when
# any machine is down, so even a caller would have thrown the answer away as an
# error. The panel now probes on first appearance and on Refresh, and renders the
# CLI's own word beside each row.
#
# This case asserts **both halves of the axis**, which is why the fixture is one
# live machine and one deliberately dead one:
#
#   * `reach-a` is a real session daemon started by `machine add`, so the CLI
#     reports `reachable`;
#   * `reach-b` is a hand-written row with a session name nothing ever created, so
#     the CLI reports `error` and names the command that would bring it back. That
#     `error` string is what the row shows as the reason, and it is the field the
#     client used to discard along with the non-zero exit code.
#
# Asserting only "reachable appears" would pass against a panel that drew one word
# for everything; only "unreachable appears" would pass against one that drew
# nothing for the healthy case. Both, plus the reason text, is what makes this a
# gate rather than a screenshot.
#
# Cost: the probe is one SSH round trip per machine, and the dead one has to time
# out — a few seconds, once per case. That is exactly what the feature costs in
# production, so the case measures what it claims to.
case_machines_reachability_app_setup() {
    machines_teardown
    machines_prereqs || return 1
    local target
    target=$(fixture_ssh_target) || return 1
    roster_cmd machine add "$target" --remote-session fx-alpha --label reach-a \
        >/dev/null 2>&1 || return 1
    # Port 1 on loopback: nothing listens, and nothing the app does can change
    # that. `ssh://` is the spelling `machine add` itself stores.
    roster_add_dead_row "ssh://kraal-73-dead@127.0.0.1:1" || return 1
    # The fixture is only meaningful if the CLI really reports one of each — and
    # exits 1 while doing it. Checked before the app launches, so a broken fixture
    # cannot be misread as a broken product.
    local statuses exit_code
    statuses=$(roster_cmd machine status --json 2>/dev/null)
    exit_code=$?
    [ "$exit_code" = "1" ] || {
        echo "expected machine status to exit 1 with a dead machine, got $exit_code"
        return 1
    }
    printf '%s' "$statuses" | python3 -c '
import json, sys
rows = {row["label"]: row for row in json.load(sys.stdin)}
assert rows["reach-a"]["status"] == "reachable", rows.get("reach-a")
assert rows["reach-b"]["status"] == "error", rows.get("reach-b")
assert rows["reach-b"]["error"], "the dead row must carry an explanation"
' || { echo "fixture statuses wrong: $(printf '%s' "$statuses" | head -c 300)"; return 1; }
    return 0
}

case_machines_reachability() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1
        return 0
    }
    action() {
        # Settings via the menu: AXPress needs no focus, so this stays an `ax`
        # case. The probe runs on the panel's first appearance, so opening the
        # window is the only trigger needed.
        driver menu --menu Kraal --item "Settings…" >/dev/null 2>&1 || true
        # Long enough for the appearance probe: one SSH round trip for the live
        # machine, one that has to conclude the dead session is gone.
        sleep 12
        driver ax --json --depth 26 >"$host_dir/ax-reachability.json" 2>/dev/null
        return 0
    }
    assert() {
        # The pills are SwiftUI `Text`, so they live in `AXValue` and nowhere else
        # (issue #71 measured that this repo writes no accessibility identifiers).
        local counts
        counts=$(AXJSON="$host_dir/ax-reachability.json" python3 -c '
import json, os
with open(os.environ["AXJSON"]) as handle:
    tree = json.load(handle)
values = {}
for node in tree["nodes"]:
    if node.get("role") == "AXStaticText":
        value = node.get("value") or ""
        values[value] = values.get(value, 0) + 1
print(values.get("reachable", 0), values.get("unreachable", 0))
') || counts="0 0"
        local reachable unreachable
        read -r reachable unreachable <<<"$counts"

        # At least one, not exactly one: the panel is not the only place the word
        # can appear (a tooltip or a footer would add one), and the claim being
        # gated is that the live row is drawn as reachable at all.
        check "the live machine is drawn as reachable" \
            "$([ "${reachable:-0}" -ge "1" ] && echo 0 || echo 1)" \
            "\"reachable\" appears ${reachable:-0} time(s) in the panel's AX tree"
        check "the dead machine is drawn as unreachable" \
            "$([ "${unreachable:-0}" = "1" ] && echo 0 || echo 1)" \
            "\"unreachable\" appears ${unreachable:-0} time(s) in the panel's AX tree"

        # The reason came from the CLI `error` field — the actionable half, and
        # the part a client judging the exit code first never saw.
        #
        # The expected text is taken from the CLI **in this same assert**, not
        # hard-coded: an earlier version pinned "remote Herdr server is stopped",
        # which is what a *missing session* produces, while a refused port says
        # "remote platform detection failed: … Connection refused". The panel was
        # rendering the right string both times; the assertion was checking the
        # wrong one. Asking the CLI what it says and looking for that is immune to
        # which failure mode the fixture happens to hit.
        local expected_reason shown_reason
        expected_reason=$(roster_cmd machine status --json 2>/dev/null | python3 -c '
import json, sys
try:
    rows = {row["label"]: row for row in json.load(sys.stdin)}
except Exception:
    raise SystemExit
print((rows.get("reach-b", {}).get("error") or "")[:60])
')
        shown_reason=$(AXJSON="$host_dir/ax-reachability.json" EXPECTED="$expected_reason" python3 -c '
import json, os
expected = os.environ["EXPECTED"]
with open(os.environ["AXJSON"]) as handle:
    tree = json.load(handle)
if not expected:
    raise SystemExit
for node in tree["nodes"]:
    value = node.get("value") or ""
    if expected in value:
        print(value[:160])
        break
')
        check "the dead machine's reason is shown, not just its state" \
            "$([ -n "$shown_reason" ] && echo 0 || echo 1)" \
            "CLI said [${expected_reason:-<nothing>}], panel showed [${shown_reason:-<nothing matching>}]"

        # The app's own account of the probe. Matched on the count and on the two
        # labels, not on the profile ids: the ids are the fixture's, and pinning
        # them here as well would duplicate what the AX assertions already prove.
        local log="$host_dir/kraal.log"
        check "the app logged one probe covering both machines" \
            "$(grep -aq 'machines: status 2 row(s)' "$log" 2>/dev/null && echo 0 || echo 1)" \
            "$(grep -ao 'machines: status .*' "$log" 2>/dev/null | tail -1)"
        check "the logged probe records one reachable row and one error row" \
            "$(grep -ao 'machines: status .*' "$log" 2>/dev/null | tail -1 \
                | grep -q 'reach-a\[[0-9a-f]*\]=reachable' \
                && grep -ao 'machines: status .*' "$log" 2>/dev/null | tail -1 \
                | grep -q 'reach-b\[deadbeef\]=error' \
                && echo 0 || echo 1)" \
            "log line: $(grep -ao 'machines: status .*' "$log" 2>/dev/null | tail -1)"
    }
}

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



    # The pre-start hook, as a *top-level* function named after the case.
    #
    # It cannot be declared inside the case body: a nested function only exists once
    # the outer one runs, and the hook has to run before that. Asking bash to run
    # `case_popup_config` when it may not exist is fine — nothing happens.
    daemon_config() { "case_${name//-/_}_config" 2>/dev/null || true; }

    # The *app's* pre-start hook: state that has to exist before Kraal launches,
    # because Kraal reads it exactly once at launch.
    #
    # The machines roster is the case that forced this. `fixture` runs after
    # `launch_app`, which is right for a daemon fixture (a fresh daemon has no
    # panes) and wrong for anything the app reads at startup: the case asked for
    # two saved machines, the app had already listed an empty roster, and the
    # assertion failed with "endpoints: 0 saved machine(s)" even though the roster
    # on disk had both. That is issue #69's reload gap seen from the harness side.
    app_setup() { "case_${name//-/_}_app_setup" 2>/dev/null || true; }

    # A fresh defaults domain per case, so one case cannot hand the next a
    # pre-dragged divider or a pre-set agent ordering. The stale domain from an
    # earlier run of the same case is removed too: "the case passed last time" must
    # not be part of its starting state.
    PREFS_SUITE="kraal.gui.$name"
    defaults delete "$PREFS_SUITE" >/dev/null 2>&1 || true

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
    # Start from no config at all, then let the case write one.
    #
    # The removal has to happen *here* and not inside `start_daemon`: `start_daemon`
    # runs after `daemon_config`, so cleaning up in there deleted the config the case
    # had just written — the popup case failed with "the app saw no Popup command"
    # for exactly that reason. And it has to go through the backend, because under
    # `vm` the whole `$HERDR_HOME` is a guest path and a host-side `rm` deletes
    # nothing while reporting success.
    #
    # Leaving the previous case's config in place was the other half of the problem:
    # popup's `[[keys.command]]` leaked into copy-mode, whose pane then accumulated
    # no scrollback and copied nothing — a failure that looked like a copy-mode
    # regression.
    case "$BACKEND" in
    local) rm -f "$HERDR_HOME/.config/herdr/config.toml" ;;
    vm)
        tart exec "$VM" /bin/bash -lc \
            "rm -f $HERDR_HOME/.config/herdr/config.toml" >/dev/null 2>&1
        ;;
    esac

    # A case that needs server-side behaviour (a `[[keys.command]]` entry, say) must
    # write config.toml *before* the daemon reads it. Doing that inside `fixture` is
    # wrong: by then `launch_app` has already started, and restarting the daemon
    # under a live app leaves it connected to a socket nobody is listening on.
    daemon_config
    start_daemon
    app_setup
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
    # Only the machines cases create session daemons; calling this unconditionally
    # would run `herdr machine list` for every other case and slow the gate down.
    case "$name" in
    machines-*) machines_teardown ;;
    esac

    if [ "$code" -eq 0 ]; then
        ok "$name passed (panes $before -> $after)"
    else
        bad "$name failed at $failure (panes $before -> $after)"
        printf '    artifacts: %s\n' "$host_dir"
    fi
    return "$code"
}

all_cases() { echo "click-coordinates split-right menu-split split-down close-pane close-workspace-group paste drag-divider scrollbar copy-mode popup scroll mouse-tui machines-roster machines-switch machines-controls machines-reachability context-menu-remote session-name-budget key-named kitty-graphics sidebar-sections sidebar-split-geometry sidebar-divider-drag sidebar-independent-scroll sidebar-footer-attention sidebar-collapse sidebar-agent-sort sidebar-footer-controls"; }

# Both sidebar panes are visible at once (issue #115).
#
# The sidebar used to be a segmented control: spaces *or* agents, one at a time.
# Upstream puts spaces above agents in one column (`src/ui/sidebar.rs:30-66`), and
# the difference is observable in the AX tree — the two headings are separate
# AXStaticText nodes, and both must be present without any interaction.
#
# Asserting on the headings rather than on pixels: "spaces" and "agents" are the
# pane titles, so their presence together *is* the claim. Under the old segmented
# control only the selected pane's content was built at all, so one heading was
# always missing.
# Make sure the sidebar is expanded before a case that reads its two panes.
#
# The collapsed state is persisted (`SidebarPreferences.collapsedKey`), so any case
# that collapses leaves the *next* case starting narrow — inside one `gui.sh run` the
# cases share an app, so this is not hypothetical: `sidebar-collapse` runs after
# `sidebar-split-geometry` in the list order and the geometry case then reported
# "missing headings: ['agents']".
#
# Pressing until the sidebar is wide makes the precondition explicit rather than
# assumed, and is idempotent when it is already expanded (the loop body never runs).
ensure_sidebar_expanded() {
    local width
    width=$(python3 "$ROOT/Scripts/sidebar-width.py" "$host_dir/ax.json" 2>/dev/null) || {
        driver ax --json --depth 22 >"$host_dir/ax.json" 2>&1 || return 1
        width=$(python3 "$ROOT/Scripts/sidebar-width.py" "$host_dir/ax.json" 2>/dev/null) \
            || return 1
    }
    local attempt=0
    while [ "$width" -lt 100 ] && [ "$attempt" -lt 3 ]; do
        driver press --id "sidebar.collapse.toggle" >/dev/null 2>&1 || return 1
        sleep 1
        driver ax --json --depth 22 >"$host_dir/ax.json" 2>&1 || return 1
        width=$(python3 "$ROOT/Scripts/sidebar-width.py" "$host_dir/ax.json" 2>/dev/null) \
            || return 1
        attempt=$((attempt + 1))
    done
    [ "$width" -ge 100 ]
}

case_sidebar_sections() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        ensure_sidebar_expanded || {
            echo "cannot expand the sidebar"
            return 1
        }
        driver ax --json --depth 22 >"$host_dir/ax.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
    }
    assert() {
        python3 "$ROOT/Scripts/sidebar-pane-headings.py" "$host_dir/ax.json" \
            >"$host_dir/headings.txt" 2>&1 || true
        local line
        line=$(cat "$host_dir/headings.txt")
        # Exactly one of the two top titles, and the agents pane beside it. "Both"
        # would mean two panes claim the top slot; "neither" means the pane is not
        # drawn at all.
        check "the sidebar shows a top pane heading and the agents heading" \
            "$(printf '%s' "$line" | grep -qcE '^top=(spaces|machines) agents=1$' \
                && echo 0 || echo 1)" \
            "$line"
    }
}

# The two panes divide the sidebar height and leave room for both (issue #115).
#
# Upstream clamps the split so neither pane can be squeezed away
# (`src/ui/sidebar.rs:42-43`). Measured through the AX frames of the two headings:
# the agents heading must sit *below* the spaces heading, which is only true if
# they are two stacked panes rather than one swapped view.
case_sidebar_split_geometry() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        ensure_sidebar_expanded || {
            echo "cannot expand the sidebar"
            return 1
        }
        driver ax --json --depth 22 >"$host_dir/ax.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
    }
    assert() {
        # The shared script, not an inline one: the top pane's title is `" spaces"`
        # with one machine and `" machines"` with several (`render.rs:271-310`), and an
        # inline copy that only knows "spaces" failed as soon as the fixture had two
        # machines. One reader for both titles is the reason this file exists.
        python3 "$ROOT/Scripts/sidebar-heading-tops.py" "$host_dir/ax.json" \
            >"$host_dir/layout.txt" 2>&1 || true
        local line
        line=$(cat "$host_dir/layout.txt")
        local top_y agents_y
        top_y=$(printf '%s' "$line" | cut -d' ' -f1)
        agents_y=$(printf '%s' "$line" | cut -d' ' -f2)
        check "the agents pane is stacked below the top pane" \
            "$([ -n "$top_y" ] && [ -n "$agents_y" ] && [ "$agents_y" -gt "$top_y" ] \
                && echo 0 || echo 1)" \
            "$line (top_y agents_y)"
    }
}

# Dragging the divider moves the split and remembers it (issue #117).
#
# Upstream treats the rule between the two panes as a hit target and turns the
# pointer's row into a ratio (`src/client/shell/mouse.rs:1971-1974`), clamped
# through `ui/sidebar.rs:42-43`. The assertion is on the *geometry of the two
# headings* after the drag: moving the divider must move the agents heading, and
# nothing else in the sidebar resizes, so a heading that did not move means the
# drag never reached the split.
#
# The divider is found by its accessibility identifier, not estimated from the two
# headings. Two estimates were tried first and both landed inside the spaces pane:
# the split is `heights(total, ratio).spaces` tall, which is not a fixed offset from
# either heading, and the window origin the driver reports disagreed with the app's
# own by 260 pt. Reading the rule's own rectangle removes both assumptions.
case_sidebar_divider_drag() {
    requires() { echo focus; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        ensure_sidebar_expanded || {
            echo "cannot expand the sidebar"
            return 1
        }
        driver ax --json --depth 22 >"$host_dir/ax-before.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
        local geometry
        geometry=$(python3 "$ROOT/Scripts/sidebar-divider-geometry.py" \
            "$host_dir/ax-before.json") || {
            echo "cannot locate the divider: $geometry"
            return 1
        }
        printf '%s\n' "$geometry" >"$host_dir/before.txt"

        local cy window_y from_y to_y
        cy=$(printf '%s' "$geometry" | sed -n 's/.*cy=\([0-9]*\).*/\1/p')
        window_y=$(driver window | tr ' ' '\n' | sed -n 's/^y=//p')
        [ -n "$window_y" ] || {
            echo "cannot read the window origin"
            return 1
        }
        from_y=$((cy - window_y))
        to_y=$((from_y + 60))
        printf 'window_y=%s cy=%s from=%s to=%s\n' "$window_y" "$cy" "$from_y" "$to_y" \
            >"$host_dir/drag-geometry.txt"

        driver drag --from "60,$from_y" --to "60,$to_y" --steps 8 \
            >"$host_dir/drag.txt" 2>&1 || {
            echo "cannot drag the divider"
            return 1
        }
        sleep 1
        driver ax --json --depth 22 >"$host_dir/ax-after.json" 2>&1 || {
            echo "cannot read the AX tree after the drag"
            return 1
        }
    }
    assert() {
        local after before before_agents after_agents
        after=$(python3 "$ROOT/Scripts/sidebar-heading-tops.py" "$host_dir/ax-after.json") \
            || after="missing"
        before=$(cat "$host_dir/before.txt")
        before_agents=$(printf '%s' "$before" | sed -n 's/.*agents_y=\([0-9]*\).*/\1/p')
        after_agents=$(printf '%s' "$after" | cut -d' ' -f2)
        check "dragging the divider moved the agents pane down" \
            "$([ -n "$after_agents" ] && [ "$after_agents" != "missing" ] \
                && [ "$after_agents" -gt "$before_agents" ] && echo 0 || echo 1)" \
            "before=[$before] after=[$after] (agents_y must grow)"
    }
}

# The two sidebar panes scroll independently (issue #116).
#
# Upstream keeps a separate `workspace_scroll` and `agent_scroll`
# (`src/client/shell/render.rs:239-240`, `state.rs:885-886`), so a long spaces list
# must not drag the agents pane out of view.
#
# Measured as "the sidebar column contains two scrolling areas". A single shared
# `ScrollView` can only ever produce one, so the count separates the two designs
# without synthesising a wheel event — which this backend cannot do, because the app
# runs as an accessory and synthetic scrolls need it frontmost.
#
# The rects are printed with the count so a *third* area (a stray list somewhere in
# the sidebar) is visible rather than silently tolerated by a `>= 2` test.
case_sidebar_independent_scroll() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        driver ax --json --depth 22 >"$host_dir/ax.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
    }
    assert() {
        python3 "$ROOT/Scripts/sidebar-scroll-areas.py" "$host_dir/ax.json" \
            >"$host_dir/areas.txt" 2>&1 || true
        local line
        line=$(cat "$host_dir/areas.txt")
        check "the sidebar has one scrolling area per pane" \
            "$(printf '%s' "$line" | grep -qcE '^areas=2 ' && echo 0 || echo 1)" \
            "$line"
        local stacked
        if python3 "$ROOT/Scripts/sidebar-areas-stacked.py" "$host_dir/areas.txt" \
            >"$host_dir/stacked.txt" 2>&1; then
            stacked=0
        else
            stacked=1
        fi
        check "the two scrolling areas are stacked vertically" "$stacked" \
            "$(cat "$host_dir/stacked.txt")"
    }
}

# A config the daemon cannot parse lights the footer dot (issue #121).
#
# Upstream marks its footer launcher when `update_available ||
# integration_updates_available` (`global_menu.rs:9-11`); a config diagnostic is this
# client's addition, because the daemon silently ignoring its own config is not
# visible anywhere in the sidebar otherwise.
#
# Driven by a real bad `config.toml`, not a stubbed snapshot: the diagnostic has to
# come from the daemon for this to be a product statement rather than a
# self-fulfilling one.
case_sidebar_footer_attention() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        # A parse error, written before the daemon starts (see `daemon_config`).
        driver ax --json --depth 22 >"$host_dir/ax.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
    }
    assert() {
        # Two claims, each of which can fail alone:
        #
        # 1. the dot is in the AX tree,
        # 2. the dot's *reason* is the config diagnostic. Without this a dot raised by
        #    an update would satisfy the case for the wrong reason — which is exactly
        #    what happened on the first run: the dot was there, the fixture's bad TOML
        #    was not the cause, and only the reason line told them apart.
        # The dot lives inside the `menu` Menu, and SwiftUI does not expose a Menu's
        # label subviews as separate AX elements — the container's identifier wins and
        # the `Circle` inside is invisible to AX. So the dot's *existence* is read from
        # the reason it logs (below), and this only checks the launcher it sits in.
        local launcher
        launcher=$(python3 "$ROOT/Scripts/sidebar-footer-controls.py" \
            "$host_dir/ax.json" 2>/dev/null) || launcher="missing"
        check "the footer has the menu launcher the dot sits in" \
            "$(printf '%s' "$launcher" | grep -qc 'menu=1' && echo 0 || echo 1)" \
            "$launcher"

        local reason
        reason=$(grep -a "sidebar footer attention: " "$host_dir/kraal.log" 2>/dev/null \
            | tail -1)
        check "the dot is about the config diagnostic" \
            "$(printf '%s' "$reason" | grep -qc "sidebar footer attention: config: " \
                && echo 0 || echo 1)" \
            "${reason:-no reason logged}"
    }
}

# A config the daemon rejects, so `config_diagnostic` is set.
case_sidebar_footer_attention_config() {
    write_config <<'TOML'
[ui
this is not valid toml at all = =
TOML
}

# The sidebar collapses to a narrow indexed strip, and expands again (issue #119).
#
# Upstream's collapsed sidebar is 4 columns of `"<n> <glyph>"` rows with the
# workspaces above the agents (`config.rs:403-408`, `sidebar.rs:47-175`). The claim
# that has to hold in a window, rather than in the arithmetic, is that the sidebar's
# width changes and both lists are still represented.
#
# Width is the assertion because everything else follows from it: the strip only
# exists at a narrow width, so a collapse that changes nothing visible fails here.
case_sidebar_collapse() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        driver ax --json --depth 22 >"$host_dir/ax-before.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
        local width
        width=$(python3 "$ROOT/Scripts/sidebar-width.py" "$host_dir/ax-before.json") || {
            echo "cannot measure the sidebar"
            return 1
        }
        # The collapsed state is persisted, so a previous run of this case leaves the
        # app starting collapsed and the press would *expand* it. Press until the
        # sidebar is wide, which makes the starting state explicit instead of assumed.
        while [ "$width" -lt 100 ]; do
            driver press --id "sidebar.collapse.toggle" >/dev/null 2>&1 || break
            sleep 1
            driver ax --json --depth 22 >"$host_dir/ax-before.json" 2>&1 || break
            width=$(python3 "$ROOT/Scripts/sidebar-width.py" "$host_dir/ax-before.json") \
                || break
        done
        printf '%s\n' "$width" >"$host_dir/before.txt"

        # The collapse control is a button with an identifier, so it is pressed rather
        # than clicked at a guessed coordinate — `AXPress` also works while the app
        # is an accessory, which clicking would not.
        driver press --id "sidebar.collapse.toggle" >"$host_dir/press.txt" 2>&1 || {
            echo "cannot press the collapse control"
            return 1
        }
        sleep 1
        driver ax --json --depth 22 >"$host_dir/ax-after.json" 2>&1 || {
            echo "cannot read the AX tree after collapsing"
            return 1
        }
    }
    assert() {
        local before after
        before=$(cat "$host_dir/before.txt")
        after=$(python3 "$ROOT/Scripts/sidebar-width.py" "$host_dir/ax-after.json") \
            || after="missing"
        check "collapsing narrowed the sidebar" \
            "$([ "$after" != "missing" ] && [ "$after" -lt "$before" ] && echo 0 || echo 1)" \
            "before=${before}pt after=${after}pt"

        # And the strip is the width the layout code claims, not merely narrower.
        check "the collapsed sidebar is one narrow strip" \
            "$([ "$after" != "missing" ] && [ "$after" -le 60 ] && echo 0 || echo 1)" \
            "after=${after}pt (upstream's compact mode is 4 columns)"
    }
}


# The agents header prints the current ordering, and clicking it switches (issue #120).
#
# Upstream prints `"grouped"` / `"priority"` on the heading's right edge and treats
# that text as the toggle (`agent_sidebar.rs:100-145`, `mouse.rs:2025-2032`). The
# mode therefore has to be *readable* — a control that only opens a menu leaves the
# active ordering invisible until you open it.
#
# Two claims: the label says which mode is on, and pressing it changes that.
case_sidebar_agent_sort() {
    requires() { echo ax; }
    fixture() {
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        ensure_sidebar_expanded || {
            echo "cannot expand the sidebar"
            return 1
        }
        driver ax --json --depth 22 >"$host_dir/ax-before.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
        driver press --id "sidebar.agents.sort" >"$host_dir/press.txt" 2>&1 || {
            echo "cannot press the sort label"
            return 1
        }
        sleep 1
        driver ax --json --depth 22 >"$host_dir/ax-after.json" 2>&1 || {
            echo "cannot read the AX tree after pressing"
            return 1
        }
    }
    assert() {
        local before after
        before=$(python3 "$ROOT/Scripts/sidebar-sort-label.py" "$host_dir/ax-before.json") \
            || before="missing"
        after=$(python3 "$ROOT/Scripts/sidebar-sort-label.py" "$host_dir/ax-after.json") \
            || after="missing"

        # Both modes are named, not just "not the other one": a label that is blank
        # in one state leaves the user guessing which ordering they are looking at.
        check "the header names one of the two orderings" \
            "$(printf '%s' "$before" | grep -qcE '^(grouped|priority)$' && echo 0 || echo 1)" \
            "before=[$before]"
        check "pressing the label switches the ordering" \
            "$([ "$before" != "$after" ] && printf '%s' "$after" \
                | grep -qcE '^(grouped|priority)$' && echo 0 || echo 1)" \
            "before=[$before] after=[$after]"
        # And the switch is the two-way one upstream has, not a third state.
        check "the two orderings alternate" \
            "$( { [ "$before" = "grouped" ] && [ "$after" = "priority" ]; } \
                || { [ "$before" = "priority" ] && [ "$after" = "grouped" ]; } \
                && echo 0 || echo 1)" \
            "before=[$before] after=[$after]"
    }
}


# The footer has `+ new` and `● menu`, both visible (issue #121).
#
# Upstream's footer is exactly two controls (`sidebar.rs:379-431`): `" new"` for a
# new workspace, and a `"menu"` launcher that gains a leading dot when something
# needs attention. Both are words on screen, not icons behind a right-click — the
# footer is the one row that is always present.
#
# `new` is verified by its *effect* (a workspace appears), because "a button exists"
# is satisfied by a button that does nothing.
case_sidebar_footer_controls() {
    requires() { echo ax; }
    fixture() {
        ensure_sidebar_expanded || return 1
        [ "$(pane_count)" -ge 1 ] || herdr workspace create >/dev/null 2>&1 || return 1
        return 0
    }
    action() {
        driver ax --json --depth 22 >"$host_dir/ax-before.json" 2>&1 || {
            echo "cannot read the AX tree"
            return 1
        }
        herdr workspace list >"$host_dir/ws-before.json" 2>/dev/null || true
        # A press failure is recorded rather than aborting: when the footer is
        # misplaced the control can end up outside the window, and aborting would
        # report "cannot press" while hiding the geometric evidence the case exists
        # to produce.
        driver press --id "sidebar.footer.new" >"$host_dir/press.txt" 2>&1 || true
        sleep 2
        herdr workspace list >"$host_dir/ws-after.json" 2>/dev/null || true
    }
    assert() {
        local before after
        before=$(python3 "$ROOT/Scripts/sidebar-footer-controls.py" \
            "$host_dir/ax-before.json" 2>/dev/null) || before="missing"
        check "the footer has both new and menu" \
            "$(printf '%s' "$before" | grep -qc 'new=1 menu=1' && echo 0 || echo 1)" \
            "$before"

        # `new` must actually create a workspace: the identifier being present only
        # proves the button was built.
        local count_before count_after
        count_before=$(python3 "$ROOT/Scripts/herdr-workspace-count.py" \
            "$host_dir/ws-before.json" 2>/dev/null) || count_before=0
        count_after=$(python3 "$ROOT/Scripts/herdr-workspace-count.py" \
            "$host_dir/ws-after.json" 2>/dev/null) || count_after=0
        check "new created a workspace" \
            "$([ "$count_after" -gt "$count_before" ] && echo 0 || echo 1)" \
            "workspaces ${count_before} -> ${count_after}"

        # The controls belong to the spaces pane, not to the sidebar's bottom edge:
        # upstream puts them at `workspace_area.bottom() - 1`
        # (`sidebar.rs:379-381`). Measured against the divider, because both
        # placements look reasonable until you see which side of it the row is on.
        local placed
        if python3 "$ROOT/Scripts/sidebar-footer-above-divider.py" \
            "$host_dir/ax-before.json" >"$host_dir/footer-place.txt" 2>&1; then
            placed=0
        else
            placed=1
        fi
        check "the footer sits inside the spaces pane, above the divider" "$placed" \
            "$(cat "$host_dir/footer-place.txt")"
    }
}


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
