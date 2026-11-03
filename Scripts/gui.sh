#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# Three-layer GUI gate for the herdr-core client (#235).
#
#   ./Scripts/gui.sh list              # the cases and what each one asserts
#   ./Scripts/gui.sh probe             # can this host/VM drive a window at all?
#   ./Scripts/gui.sh run [case ...]    # default: every case
#   ./Scripts/gui.sh verify            # build Kraal.app, then run every case
#
# Every assertion carries the layer it reads:
#
#   client   `kraal ls` / `kraal status`   — what the window's model says
#   core     `hc get --json`               — what the core recorded
#   pixels   `KraalGUIDriver` shot/diff/ax — what is actually on screen
#
# One layer agreeing is not a pass. A split can rewrite the tree while the core
# never starts a second terminal; a drag can move pixels while nothing is saved;
# `AXPress` returning success means "dispatched", not "the feature worked". So a
# case passes only when its client, core and pixel claims all hold, and every
# assertion prints what it looked at (`docs/DEBUGGING.md` §1, §8).
#
# Exit codes mirror KraalGUIDriver's, because an agent reads them:
#
#   0  every assertion passed
#   1  the product is wrong  → the failing assertion names what to fix
#   2  the rig is wrong      → VM missing, app did not launch, TCC, no activation
#
# `docs/DEBUGGING.md` §2 is the reason the split exists: reporting an environment
# failure as a product failure sends someone off to "fix" code that is fine, and
# a gate that cannot be believed is worse than no gate.
#
# Isolation is not optional (AGENTS.md §0.1). Each case gets its own root under
# /tmp with its own core session, XDG dirs, control socket, view, keys and a
# *copy* of Kraal.app, so a kill can never reach the window the person is using.
# The default backend is the Tart VM; `local` needs KRAAL_GUI_ALLOW_HOST=1
# because it takes the pointer and the keyboard of whoever is at this machine.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

BACKEND="${KRAAL_GUI_BACKEND:-vm}"
VM="${KRAAL_GUI_VM:-kraal-agent}"
ALLOW_HOST="${KRAAL_GUI_ALLOW_HOST:-0}"

ARTIFACT_ROOT="$ROOT/artifacts/gui"
HOST_APP="$ROOT/build/Kraal.app"
ALL_CASES="split-right close-pane resize seen"

# jq is the only JSON reader this gate needs; python cannot be assumed on the VM
# side of the fence and the script must run the same way in both places.
JQ=""
for candidate in /opt/homebrew/bin/jq /usr/local/bin/jq "$(command -v jq 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then JQ="$candidate"; break; fi
done

die() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 2
}
say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok() { printf '\033[32mok:\033[0m %s\n' "$*"; }
bad() { printf '\033[31mFAIL:\033[0m %s\n' "$*"; }

usage() {
    sed -n '5,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- binaries

# SwiftPM writes products to .build/out for Xcode-backed toolchains and to
# .build/<config> otherwise; both spellings have been live in this repo.
resolve_bin() {
    local name="$1" dir
    for dir in "$ROOT/.build/out/Products/Debug" "$ROOT/.build/debug"; do
        if [ -x "$dir/$name" ]; then printf '%s' "$dir/$name"; return 0; fi
    done
    return 1
}

HOST_DRIVER="$(resolve_bin KraalGUIDriver || true)"
HOST_CLI="$(resolve_bin kraal || true)"
HOST_HC="$(command -v hc 2>/dev/null || true)"

# The `hc` a person has on PATH is often a symlink (`~/.local/bin/hc ->
# herdr-core`). `tar` stores the *link* when given a link name, so pushing that
# path puts a dangling symlink in the guest and the following `chmod +x hc`
# fails on a file that does not exist there. Resolve first; BSD `readlink` has no
# `-f`, so the chain is walked here rather than pulling in python.
resolve_real() {
    local path="$1" target
    while [ -L "$path" ]; do
        target=$(readlink "$path")
        case "$target" in
        /*) path="$target" ;;
        *) path="$(cd "$(dirname "$path")" && pwd)/$target" ;;
        esac
    done
    printf '%s' "$path"
}

HOST_HC_REAL=""
if [ -n "$HOST_HC" ]; then HOST_HC_REAL="$(resolve_real "$HOST_HC")"; fi

# ---------------------------------------------------------------- safety rails

# Backends are a safety boundary, not a preference. `local` posts synthetic
# events at whatever window is on this machine.
require_backend() {
    case "$BACKEND" in
    vm) return 0 ;;
    local)
        if [ "$ALLOW_HOST" != "1" ]; then
            die "KRAAL_GUI_BACKEND=local drives this machine's desktop (synthetic
    clicks, drags and keystrokes land in whatever is frontmost). Set
    KRAAL_GUI_ALLOW_HOST=1 only when nobody is using the machine, or leave the
    default KRAAL_GUI_BACKEND=vm."
        fi
        ;;
    *) die "unknown KRAAL_GUI_BACKEND='$BACKEND' (expected vm or local)" ;;
    esac
}

# Refuses to run against a stale bundle.
#
# `build-app.sh` has to be re-run after every app change, and forgetting it makes
# an A/B green for the wrong reason: the bundle still holds the *old* code, so
# the injected regression never ships and the case that should go red passes.
# Measured in this repo during #55 — the A/B stayed green until the bundle was
# rebuilt. A timestamp comparison costs nothing and turns a silent false pass
# into one line naming the command to run.
check_app_fresh() {
    [ -d "$HOST_APP" ] || die "no build/Kraal.app; run: ./Scripts/build-app.sh"
    local newest
    newest=$(find "$ROOT/Sources" -name '*.swift' -newer "$HOST_APP" -print -quit 2>/dev/null)
    if [ -n "$newest" ]; then
        die "build/Kraal.app is older than $newest
    run: ./Scripts/build-app.sh"
    fi
}

# `build-app.sh` builds KraalMac only, so a driver edit used to be invisible: the
# previously built binary was pushed and an A/B on driver code went green because
# the change never reached the VM (measured during #92). Rebuild when any driver
# source is newer than the binary; a no-op build is about a second.
ensure_driver() {
    local newest=""
    if [ -n "$HOST_DRIVER" ] && [ -x "$HOST_DRIVER" ]; then
        newest=$(find "$ROOT/Sources/KraalGUIDriver" -name '*.swift' -newer "$HOST_DRIVER" -print -quit 2>/dev/null)
        [ -n "$newest" ] || return 0
    fi
    local swift=/usr/bin/swift
    [ -x "$swift" ] || swift="$(command -v swift 2>/dev/null || true)"
    [ -n "$swift" ] || die "no swift toolchain to build KraalGUIDriver"
    say "building KraalGUIDriver"
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        "$swift" build --product KraalGUIDriver >>"$RUN_LOG" 2>&1 \
        || { tail -20 "$RUN_LOG"; die "swift build --product KraalGUIDriver failed"; }
    HOST_DRIVER="$(resolve_bin KraalGUIDriver || true)"
    [ -n "$HOST_DRIVER" ] || die "KraalGUIDriver was built but no binary turned up"
}

require_jq() {
    [ -n "$JQ" ] || die "jq not found (install it, or put it in /opt/homebrew/bin)"
}

require_tools() {
    require_jq
    [ -n "$HOST_DRIVER" ] && [ -x "$HOST_DRIVER" ] \
        || die "no KraalGUIDriver; run: swift build --product KraalGUIDriver"
    [ -n "$HOST_CLI" ] && [ -x "$HOST_CLI" ] \
        || die "no kraal CLI; run: swift build --product kraal"
    [ -n "$HOST_HC_REAL" ] && [ -f "$HOST_HC_REAL" ] \
        || die "no hc on PATH (the core CLI is how the core layer is read)"
}

# A GUI run must never touch the core or the window somebody is using. Three
# different mistakes have happened here already — a default session, a socket
# under $HOME, an app path outside the scratch root — so all three are tripwires
# rather than assumptions.
guard_isolation() {
    case "${SESSION:-}" in
    "" | default) die "refusing HC_SESSION='${SESSION:-}': a gate must never use the default core" ;;
    esac
    case "$SCR" in
    "$RUN_ROOT"/*) ;;
    *) die "scratch root $SCR is outside $RUN_ROOT" ;;
    esac
    case "$CTL" in
    "$HOME"/* | /tmp/kraal-mine/*) die "refusing to use the developer's control socket ($CTL)" ;;
    esac
    case "$STATE$CONFIG" in
    *"$HOME/Library/State"* | *"$HOME/.config"*) die "refusing to use the real config/state dir ($STATE $CONFIG)" ;;
    esac
    # macOS sun_path is 103 bytes and truncation fails at bind time, deep inside
    # the app, looking like a product bug (docs/DEBUGGING.md §10).
    if [ "${#HC_SOCKET}" -ge 100 ] || [ "${#CTL}" -ge 100 ]; then
        die "socket path too long for sun_path(103): $HC_SOCKET / $CTL"
    fi
}

# ---------------------------------------------------------------- backend plumbing

vm_reachable() {
    tart exec "$VM" /usr/bin/true >/dev/null 2>&1
}

# Brings the VM up if it exists but is stopped. Creating a VM is
# `Scripts/vm-bootstrap.sh`'s job (it needs tens of GB and TCC grants); this only
# refuses with the command that would fix it.
vm_up() {
    if ! tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM"; then
        ENV_WHY="no VM named '$VM' (create it: ./Scripts/vm-bootstrap.sh)"
        return 1
    fi
    if vm_reachable; then return 0; fi
    say "booting $VM (headless)"
    nohup tart run --no-graphics "$VM" >>"$RUN_LOG" 2>&1 &
    local deadline=$((SECONDS + 180))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if vm_reachable; then ok "vm up"; return 0; fi
        sleep 2
    done
    ENV_WHY="VM '$VM' never became reachable in 180s (log: $RUN_LOG)"
    return 1
}

# Push one tar stream into the guest. `-i` is mandatory: without it stdio is not
# wired up and the guest writes a zero-byte file. The guest `cd`s rather than
# using `tar -C`, because `-C` through `tart exec` has silently extracted into the
# wrong directory before (docs/AUTOMATION.md §2).
push_tar() {
    local dir="$1" dest="$2" pre="$3" post="$4"
    shift 4
    tar -czf - -C "$dir" "$@" \
        | tart exec -i "$VM" /bin/bash -lc "cd $dest && $pre && tar -xzf - && $post"
}

# Deploys once per run, not per case: the 17 MB bundle is copied inside the guest
# for each case, so every case still owns a path under its own scratch root (and
# a kill by path can only ever match that copy).
vm_deploy() {
    say "deploying to $VM"
    tart exec "$VM" /bin/mkdir -p "$RUN_ROOT/bin" "$RUN_ROOT/app" >/dev/null 2>&1 \
        || { ENV_WHY="cannot create $RUN_ROOT in $VM"; return 1; }
    push_tar "$ROOT/build" "$RUN_ROOT/app" "/bin/rm -rf Kraal.app" "true" Kraal.app \
        || { ENV_WHY="failed to push Kraal.app into $VM"; return 1; }
    push_tar "$(dirname "$HOST_DRIVER")" "$RUN_ROOT/bin" "true" "chmod +x KraalGUIDriver kraal" \
        KraalGUIDriver kraal \
        || { ENV_WHY="failed to push KraalGUIDriver/kraal into $VM"; return 1; }
    # Pushed under its real name, then renamed: the guest always has
    # `$RUN_ROOT/bin/hc`, whatever the host's binary is called.
    local hc_name
    hc_name=$(basename "$HOST_HC_REAL")
    push_tar "$(dirname "$HOST_HC_REAL")" "$RUN_ROOT/bin" "true" \
        "chmod +x $hc_name; if [ $hc_name != hc ]; then mv -f $hc_name hc; fi" \
        "$hc_name" \
        || { ENV_WHY="failed to push hc into $VM"; return 1; }
    # The bundle is ad-hoc signed on the host; the quarantine attribute would make
    # Gatekeeper refuse it inside the guest.
    tart exec "$VM" /bin/bash -lc \
        "xattr -dr com.apple.quarantine $RUN_ROOT/app/Kraal.app 2>/dev/null; true" >/dev/null 2>&1
    ok "deployed app + driver + kraal + hc"
}

# Copies whatever the case produced back to the host. Missing files are not an
# error: not every case produces every artifact.
collect_case() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec -i "$VM" /bin/bash -lc "cd $SCR/out 2>/dev/null && tar -czf - . 2>/dev/null" \
            | tar -xzf - -C "$HOST_OUT" 2>/dev/null || true
        tart exec "$VM" /bin/bash -lc "cat ~/Library/Logs/Kraal-$SESSION.log 2>/dev/null" \
            >"$HOST_OUT/app-runtime.log" 2>/dev/null || true
    else
        cp "$HOME/Library/Logs/Kraal-$SESSION.log" "$HOST_OUT/app-runtime.log" 2>/dev/null || true
    fi
    return 0
}

# ---------------------------------------------------------------- in-sandbox commands

# Every command below runs in the case's environment: the guest for `vm`, this
# machine for `local`. Arguments are passed as argv, never re-quoted through a
# guest shell — `tart exec` takes argv directly and `/usr/bin/env` carries the
# environment, which is why a `printf` with backslashes survives intact.
cli() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /usr/bin/env KRAAL_CONTROL_SOCKET="$CTL" "$GUEST_BIN/kraal" "$@"
    else
        env KRAAL_CONTROL_SOCKET="$CTL" "$HOST_CLI" "$@"
    fi
}

hc_cli() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /usr/bin/env HC_SESSION="$SESSION" XDG_STATE_HOME="$STATE" \
            XDG_CONFIG_HOME="$CONFIG" "$GUEST_BIN/hc" "$@"
    else
        env HC_SESSION="$SESSION" XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$CONFIG" \
            "$HOST_HC" "$@"
    fi
}

driver() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" "$GUEST_BIN/KraalGUIDriver" "$@"
    else
        "$HOST_DRIVER" "$@"
    fi
}

# ---------------------------------------------------------------- small helpers

# 0/1 for `check`'s third argument, without the `&& echo 0 || echo 1` dance that
# reads like a shell puzzle in every assertion.
bool() { if "$@"; then printf '0'; else printf '1'; fi; }

# Integer, as bash arithmetic reads it. A leading minus is allowed because a
# window's screen origin can be negative; anything else that is not all digits is
# refused, so `[ "$x" -lt "$y" ]` never sees "3px" and errors mid-case.
is_int() {
    case "${1:-}" in
    '' | - | *[!0-9-]*) return 1 ;;
    esac
    case "${1#-}" in
    '' | *-*) return 1 ;;
    esac
    return 0
}

# One value out of a saved JSON artifact. Extra arguments go to jq (`--arg k v`),
# so a filter can name the ids it wants without the caller building a shell
# string that contains quotes.
field() {
    local file="$1" filter="$2"
    shift 2
    "$JQ" -r "$@" "$filter" "$file" 2>/dev/null | head -1
}

# One `key=value` field out of a line of text (`pid=… windowNumber=… x=…`).
text_field() {
    sed -n "s/.*[[:space:]]$2=\([-0-9]*\).*/\1/p" "$1" 2>/dev/null | head -1
}

# Polls a predicate. Everything in this gate is asynchronous (core events, layout
# saves, AX layout), so a fixed sleep either flakes or wastes seconds.
wait_until() {
    local timeout="$1" what="$2"
    shift 2
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    printf '  (timed out after %ss waiting for %s)\n' "$timeout" "$what"
    return 1
}

# ---------------------------------------------------------------- assertions

ASSERT_FILE=""
FAILS=0
ERR=""

# Records one assertion and prints it. `detail` is printed on success too: a gate
# that cannot say what it verified is indistinguishable from one that always
# passes (docs/DEBUGGING.md §8).
record() {
    local layer="$1" what="$2" status="$3" detail="${4:-}"
    if [ "$status" = "pass" ]; then
        printf '  \033[32mPASS\033[0m [%s] %s%s\n' "$layer" "$what" "${detail:+  ($detail)}"
    else
        FAILS=$((FAILS + 1))
        printf '  \033[31mFAIL\033[0m [%s] %s%s\n' "$layer" "$what" "${detail:+  ($detail)}"
    fi
    "$JQ" -nc --arg layer "$layer" --arg what "$what" --arg status "$status" \
        --arg detail "$detail" \
        '{layer:$layer,status:$status,what:$what,detail:$detail}' >>"$ASSERT_FILE"
}

check() { # layer what status detail
    if [ "$3" -eq 0 ]; then
        record "$1" "$2" pass "${4:-}"
    else
        record "$1" "$2" FAIL "${4:-}"
    fi
}

# The rig failed, not the product. The first reason wins: later steps would only
# describe the consequences.
harness_fail() {
    if [ -z "${ERR:-}" ]; then ERR="$1"; fi
    printf '  \033[31mHARNESS\033[0m %s\n' "$1"
}

# Field-level readers for the core record. A missing record is reported in the
# value itself so the failing assertion says what happened instead of going blank.
hc_snapshot() {
    local t="$1"
    hc_cli get "$t" --json >"$HOST_OUT/hc-$t.json" 2>"$HOST_OUT/hc-$t.err"
}

hc_val() {
    hc_cli get "$1" --json 2>/dev/null | "$JQ" -r "$2" 2>/dev/null | head -1
}

# ---------------------------------------------------------------- core + app lifecycle

pred_hc_socket() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /bin/test -S "$HC_SOCKET"
    else
        [ -S "$HC_SOCKET" ]
    fi
}

pred_ctl_socket() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /bin/test -S "$CTL"
    else
        [ -S "$CTL" ]
    fi
}

# The window is usable only once the core handshake finished *and* the layout was
# loaded: `space.new` refuses while `layoutLoaded` is empty, and a case that
# starts too early reports a product error for its own impatience.
pred_status_ready() {
    cli status 2>/dev/null | "$JQ" -e \
        '(.status == "ready") and (.connected == true)
         and (([.documents[]? | select(.loaded == true)] | length) >= 1)' >/dev/null
}

start_core() {
    if ! hc_cli server start >"$HOST_OUT/core-start.json" 2>"$HOST_OUT/core-start.err"; then
        harness_fail "hc server start failed in session $SESSION: $(tail -c 300 "$HOST_OUT/core-start.err")"
        return 1
    fi
    if ! pred_hc_socket; then
        wait_until 30 "the core socket" pred_hc_socket \
            || { harness_fail "core socket $HC_SOCKET never appeared"; return 1; }
    fi
    return 0
}

stop_core() {
    hc_cli server stop >/dev/null 2>&1 || true
    return 0
}

# Per-case scratch: its own dirs, its own app copy, its own sockets.
case_scratch() {
    guard_isolation
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /bin/bash -lc \
            "rm -rf $SCR && /bin/mkdir -p $SCR/state $SCR/config $SCR/out \
             && /bin/cp -R $RUN_ROOT/app/Kraal.app $SCR/Kraal.app" >/dev/null 2>&1 \
            || { harness_fail "could not prepare the guest scratch dir $SCR"; return 1; }
    else
        rm -rf "$SCR"
        mkdir -p "$STATE" "$CONFIG" "$HOST_OUT" 2>/dev/null \
            || { harness_fail "could not prepare the scratch dir $SCR"; return 1; }
        cp -R "$HOST_APP" "$APP" 2>/dev/null \
            || { harness_fail "could not copy $HOST_APP to $APP"; return 1; }
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    fi
    return 0
}

# `seen` and `resize` need a frontmost app: activation is the thing under test in
# one, and the drag in the other only lands in a frontmost window. The other two
# stay `.accessory` so they never take the pointer.
case_background() {
    case "$CASE" in
    resize | seen) printf '0' ;;
    *) printf '1' ;;
    esac
}

launch_app() {
    local bg
    bg="$(case_background)"
    APP_PID=""
    # `open -n --env` starts a *new* instance through LaunchServices and returns
    # immediately. The earlier `nohup … &` form left the guest shell alive as the
    # app's parent; a later `tart exec` could then wait on that session and look
    # like "kraal status never became ready". `-n` also prevents LaunchServices
    # from raising another Kraal (a parallel run on the same VM).
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /usr/bin/open -a "$APP" -n \
            --env KRAAL_HC_SOCKET="$HC_SOCKET" \
            --env KRAAL_HC_VIEW="$VIEW" \
            --env KRAAL_CONTROL_SOCKET="$CTL" \
            --env KRAAL_KEYS="$KEYS" \
            --env KRAAL_DEV_SESSION="$SESSION" \
            --env KRAAL_DEV_BACKGROUND="$bg" \
            -o "$OUT/app.log" --stderr "$OUT/app.log" \
            >/dev/null 2>&1 || true
    else
        open -a "$APP" -n \
            --env KRAAL_HC_SOCKET="$HC_SOCKET" \
            --env KRAAL_HC_VIEW="$VIEW" \
            --env KRAAL_CONTROL_SOCKET="$CTL" \
            --env KRAAL_KEYS="$KEYS" \
            --env KRAAL_DEV_SESSION="$SESSION" \
            --env KRAAL_DEV_BACKGROUND="$bg" \
            -o "$OUT/app.log" --stderr "$OUT/app.log" \
            >/dev/null 2>&1 || true
    fi
    # `open` does not return the pid, and the bundle name is shared with every
    # other Kraal on the machine; the scratch path is the unique handle.
    local _
    for _ in $(seq 1 40); do
        if [ "$BACKEND" = "vm" ]; then
            APP_PID=$(tart exec "$VM" /usr/bin/pgrep -f "$APP/Contents/MacOS/KraalMac-bin" 2>/dev/null | head -1)
        else
            APP_PID=$(pgrep -f "$APP/Contents/MacOS/KraalMac-bin" 2>/dev/null | head -1)
        fi
        [ -n "$APP_PID" ] && break
        sleep 0.25
    done
    if [ -z "$APP_PID" ]; then
        harness_fail "could not start $APP/Contents/MacOS/KraalMac-bin (log: $OUT/app.log)"
        return 1
    fi
    return 0
}

# The driver can target a pid (`--client`), so another Kraal on the same VM is
# not a reason to refuse: it is only a reason never to let the driver choose.
check_our_client() {
    local deadline=$((SECONDS + 20)) json=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        json=$(driver clients --json 2>/dev/null) || json=""
        if [ -n "$json" ] && printf '%s' "$json" | "$JQ" -e --argjson want "$APP_PID" \
            '[.clients[]? | select(.pid == $want)] | length == 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    json=$(driver clients --json 2>/dev/null) || json=""
    if [ -z "$json" ]; then
        harness_fail "no Kraal instance registered with the driver (launched pid $APP_PID, log: $OUT/app.log)"
    else
        harness_fail "the driver never listed our pid $APP_PID (saw $(printf '%s' "$json" | "$JQ" -r '.clients | map("\(.pid)") | join(",")' 2>/dev/null)); a parallel run may still be alive"
    fi
    return 1
}

pred_app_gone() {
    if [ "$BACKEND" = "vm" ]; then
        ! tart exec "$VM" /bin/ps -p "$APP_PID" >/dev/null 2>&1
    else
        ! ps -p "$APP_PID" >/dev/null 2>&1
    fi
}

# Kills only what this case started: the pid it launched, matched by the scratch
# app path. Never `pkill -f KraalMac` — that pattern also matches the developer's
# app and every other run on the machine (docs/AUTOMATION.md §9).
stop_app() {
    if [ -n "${APP_PID:-}" ]; then
        if [ "$BACKEND" = "vm" ]; then
            tart exec "$VM" /bin/kill -TERM "$APP_PID" >/dev/null 2>&1 || true
        else
            kill -TERM "$APP_PID" 2>/dev/null || true
        fi
        if ! wait_until 15 "the app (pid $APP_PID) to exit" pred_app_gone; then
            if [ "$BACKEND" = "vm" ]; then
                tart exec "$VM" /bin/kill -KILL "$APP_PID" >/dev/null 2>&1 || true
            else
                kill -KILL "$APP_PID" 2>/dev/null || true
            fi
        fi
    fi
    # Also sweep anything else started from *this case's* bundle: `open -a` can
    # start a second instance, and such a stray would fail the next case's
    # one-client check for a reason that has nothing to do with the product. The
    # pattern carries this case's unique scratch root, so it can only ever match
    # the copy this case made — never the developer's app.
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /usr/bin/pkill -f "$APP/Contents/MacOS/KraalMac-bin" >/dev/null 2>&1 || true
    else
        pkill -f "$APP/Contents/MacOS/KraalMac-bin" >/dev/null 2>&1 || true
    fi
    return 0
}

case_prepare() {
    case_scratch || return 1
    start_core || return 1
    launch_app || return 1
    wait_until 25 "the control socket" pred_ctl_socket \
        || { harness_fail "the app never created its control socket $CTL (log: $OUT/app.log)"; return 1; }
    if ! wait_until 30 "kraal status to become ready" pred_status_ready; then
        # Keep the last payload: "never became ready" without the actual status
        # is a harness failure that hides its own cause.
        cli status >"$HOST_OUT/status-timeout.json" 2>&1 || true
        harness_fail "kraal status never became ready (last: $(head -c 300 "$HOST_OUT/status-timeout.json" 2>/dev/null | tr '\n' ' '); log: $OUT/app.log)"
        return 1
    fi
    check_our_client || return 1
    return 0
}

# ---------------------------------------------------------------- case helpers

# `kraal do` with the harness/product split the contract asks for: exit 2 is the
# environment (no window, usage), exit 1 is the product saying no.
do_action() {
    local file="$1" action="$2"
    shift 2
    local status=0
    cli "do" "$action" "$@" >"$HOST_OUT/$file" 2>"$HOST_OUT/$file.err" || status=$?
    if [ "$status" -eq 2 ]; then
        harness_fail "kraal do $action exited 2 (no window / usage): $(head -c 300 "$HOST_OUT/$file.err")"
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        record client "kraal do $action succeeds" FAIL \
            "exit $status: $(field "$HOST_OUT/$file" '.error // empty') $(head -c 200 "$HOST_OUT/$file.err")"
        return 1
    fi
    return 0
}

save_cli_state() {
    cli ls >"$HOST_OUT/ls.json" 2>"$HOST_OUT/ls.err" || { harness_fail "kraal ls failed: $(head -c 200 "$HOST_OUT/ls.err")"; return 1; }
    cli status >"$HOST_OUT/status.json" 2>"$HOST_OUT/status.err" || { harness_fail "kraal status failed: $(head -c 200 "$HOST_OUT/status.err")"; return 1; }
    return 0
}

# One id out of an action reply. A missing id makes the case unrunnable, and a
# duplicated 4-line check per id is where one eventually gets forgotten.
need_id() { # VARNAME file filter what
    local value
    value=$(field "$2" "$3")
    if [ -z "$value" ]; then
        harness_fail "$4 is missing from $(head -c 200 "$2")"
        return 1
    fi
    printf -v "$1" '%s' "$value"
}

# The tab under test: the first tab of the space `space.new` just made.
ls_field() { # file filter extra-jq-args...
    local file="$1" filter="$2"
    shift 2
    "$JQ" -r --arg sid "$SPACE" "$@" "(.spaces[]? | select(.id == \$sid) | .tabs[0]) as \$tab | \$tab | $filter" \
        "$file" 2>/dev/null | head -1
}

# One OSC 7501 agent turn: `working`, then `done`, then wait for the core's turn
# counter. `hc send` pastes the printf and presses Enter, so the word reaches the
# core exactly like one coming from a real agent harness.
hc_osc() {
    local t="$1" word="$2"
    hc_cli send "$t" "printf '\033]7501;state=${word}\033\\\\'" >"$HOST_OUT/osc-$word.json" 2>"$HOST_OUT/osc-$word.err"
}

pred_turn() {
    local turn
    turn=$(hc_val "$WANT_T" '.turn')
    is_int "$turn" && [ "$turn" = "$WANT_TURN" ]
}

pred_seen() {
    local seen
    seen=$(hc_val "$WANT_T" '.labels["herdr.seen"]')
    [ "$seen" = "$WANT_SEEN" ]
}

pred_active() {
    cli status 2>/dev/null | "$JQ" -e --argjson want "$WANT_ACTIVE" '.active == $want' >/dev/null
}

osc_turn() { # terminal expected-turn
    local t="$1" want="$2"
    WANT_T="$t"
    WANT_TURN="$want"
    if ! hc_osc "$t" working; then
        harness_fail "hc send (working) into $t failed: $(head -c 200 "$HOST_OUT/osc-working.err")"
        return 1
    fi
    sleep 0.3
    if ! hc_osc "$t" "done"; then
        harness_fail "hc send (done) into $t failed: $(head -c 200 "$HOST_OUT/osc-done.err")"
        return 1
    fi
    if ! wait_until 20 "the core's turn counter to reach $want" pred_turn; then
        harness_fail "the core never recorded turn $want on $t (turn=$(hc_val "$t" '.turn'), status=$(hc_val "$t" '.status.state'))"
        return 1
    fi
    return 0
}

# `open -a` is what a person clicking the Dock icon does; LaunchServices activates
# the already-running instance of the same bundle instead of starting a second one.
activate_app() {
    # LaunchServices raises an already-running instance by bundle path, which is
    # what a Dock click does; `activate --client` then confirms the pid (and
    # catches the case where another instance of the same bundle was raised).
    # Neither failure is fatal here: the case waits on `status.active` and
    # reports harness if the window really never came back.
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /usr/bin/open -a "$APP" >/dev/null 2>&1 || true
    else
        open -a "$APP" >/dev/null 2>&1 || true
    fi
    driver activate --client "$APP_PID" >/dev/null 2>&1 || true
    return 0
}

# Anything that is not this window takes the front. Finder is the cheapest such
# app in the guest; the `open -b` fallback exists because osascript needs an
# Apple-Events grant that an unattended guest may not have.
deactivate_app() {
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /usr/bin/osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 \
            || tart exec "$VM" /usr/bin/open -b com.apple.finder >/dev/null 2>&1
    else
        osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 \
            || open -b com.apple.finder >/dev/null 2>&1
    fi
    return 0
}

# ---------------------------------------------------------------- cases

# split-right
#
# Two layers must agree. A split that only rewrites the model leaves the core with
# one terminal; a split that only starts a terminal leaves the tree flat. The
# injection this case exists for claims success without touching the model, so both
# the tree shape and the core's two live records are asserted.
run_case_split_right() {
    local terminal1 pane2 terminal2 tree_type blocks terms focus_pane status_focus want_terms
    do_action space-new.json space.new --name gui-split || return 1
    need_id SPACE "$HOST_OUT/space-new.json" '.space // ""' "the space id" || return 1
    need_id terminal1 "$HOST_OUT/space-new.json" '.terminal // ""' "the terminal id" || return 1
    record client "space.new reports the space it created" pass "space=$SPACE terminal=$terminal1"

    do_action split.json pane.split --direction right || return 1
    need_id terminal2 "$HOST_OUT/split.json" '.terminal // ""' "the new terminal id" || return 1
    pane2=$(field "$HOST_OUT/split.json" '.pane // ""')
    record client "pane.split reports the pane and terminal it made" pass "pane=$pane2 terminal=$terminal2"
    check client "the split started a second terminal, not the same one" \
        "$(bool test "$terminal1" != "$terminal2")" "terminals: $terminal1, $terminal2"

    save_cli_state || return 1

    tree_type=$(ls_field "$HOST_OUT/ls.json" '.tree.type // "missing"')
    blocks=$(ls_field "$HOST_OUT/ls.json" '[.tree.children[]? | select(.type == "block")] | length')
    terms=$(ls_field "$HOST_OUT/ls.json" '[.tree.children[]? | .content.terminal] | sort | join(",")')
    want_terms=$(printf '%s\n%s\n' "$terminal1" "$terminal2" | sort | tr '\n' ',' | sed 's/,$//')
    check client "the tab's tree is a row" "$(bool test "$tree_type" = row)" "tree.type=$tree_type"
    check client "the row has exactly two block children" "$(bool test "$blocks" = 2)" "blocks=$blocks"
    check client "the two blocks are the terminals the actions reported" \
        "$(bool test "$terms" = "$want_terms")" "tree=$terms expected=$want_terms"

    focus_pane=$(ls_field "$HOST_OUT/ls.json" '.focused // "missing"')
    status_focus=$(field "$HOST_OUT/status.json" '.focused_pane // "missing"')
    check client "the tab's focused pane is the new pane" \
        "$(bool test "$focus_pane" = "$pane2")" "tab.focused=$focus_pane want=$pane2"
    check client "kraal status agrees on the focused pane" \
        "$(bool test "$status_focus" = "$pane2")" "status.focused_pane=$status_focus want=$pane2"

    local state1 state2 space_label tab_label tab_id want_tab_id
    hc_snapshot "$terminal1"
    hc_snapshot "$terminal2"
    state1=$(field "$HOST_OUT/hc-$terminal1.json" '.state // "missing"')
    state2=$(field "$HOST_OUT/hc-$terminal2.json" '.state // "missing"')
    check core "the first terminal is live in the core" "$(bool test "$state1" = live)" "state=$state1"
    check core "the second terminal is live in the core" "$(bool test "$state2" = live)" "state=$state2"

    tab_id=$(ls_field "$HOST_OUT/ls.json" '.id // ""')
    want_tab_id=$(field "$HOST_OUT/space-new.json" '.tab // ""')
    space_label=$(field "$HOST_OUT/hc-$terminal1.json" '.labels["herdr.space"] // ""')
    tab_label=$(field "$HOST_OUT/hc-$terminal1.json" '.labels["herdr.tab"] // ""')
    check core "the first terminal carries the space.new labels" \
        "$(bool test "$space_label" = "$SPACE" -a "$tab_label" = "$want_tab_id")" \
        "herdr.space=$space_label herdr.tab=$tab_label want=$SPACE/$want_tab_id"
    space_label=$(field "$HOST_OUT/hc-$terminal2.json" '.labels["herdr.space"] // ""')
    tab_label=$(field "$HOST_OUT/hc-$terminal2.json" '.labels["herdr.tab"] // ""')
    check core "the second terminal carries the same labels" \
        "$(bool test "$space_label" = "$SPACE" -a "$tab_label" = "$want_tab_id")" \
        "herdr.space=$space_label herdr.tab=$tab_label want=$SPACE/$want_tab_id"
    check client "the tab under the tree is the tab space.new reported" \
        "$(bool test "$tab_id" = "$want_tab_id")" "ls=$tab_id want=$want_tab_id"
    return 0
}

# close-pane
#
# Closing is two facts: the tree loses the pane, and the core *finishes* the
# terminal instead of forgetting it. The injection skips `killCascade`, so the
# tree goes clean while the core keeps a live terminal — which is exactly why the
# second half is not optional.
run_case_close_pane() {
    local pane1 terminal1 pane2 terminal2 tree_type blocks focused status_focus
    local closed_state closed_reason remaining_state terms
    do_action space-new.json space.new --name gui-close || return 1
    need_id SPACE "$HOST_OUT/space-new.json" '.space // ""' "the space id" || return 1
    need_id terminal1 "$HOST_OUT/space-new.json" '.terminal // ""' "the terminal id" || return 1
    pane1=$(field "$HOST_OUT/space-new.json" '.pane // ""')

    do_action split.json pane.split --direction right || return 1
    need_id terminal2 "$HOST_OUT/split.json" '.terminal // ""' "the new terminal id" || return 1
    pane2=$(field "$HOST_OUT/split.json" '.pane // ""')
    # Focus is the new pane, so `pane.close` without an argument closes it.
    local focus_now
    focus_now=$(cli status 2>/dev/null | "$JQ" -r '.focused_pane // ""' 2>/dev/null)
    if [ "$focus_now" != "$pane2" ]; then
        harness_fail "focus is $focus_now, not the pane the split made ($pane2); pane.close would close the wrong pane"
        return 1
    fi

    do_action close.json pane.close || return 1
    WANT_T="$terminal2"
    WANT_STATE=finished
    if ! wait_until 15 "the closed terminal to finish in the core" pred_hc_state; then
        # The close action succeeded (the tree lost the pane) but the terminal is
        # still live: that is the product leaving a process behind, not a rig
        # problem, so it must be exit 1 with a red core assertion.
        record core "the closed terminal finished" FAIL \
            "state=$(hc_val "$terminal2" '.state') reason=$(hc_val "$terminal2" '.reason')"
        return 1
    fi

    save_cli_state || return 1
    tree_type=$(ls_field "$HOST_OUT/ls.json" '.tree.type // "missing"')
    # The model keeps the row wrapper when its last sibling goes; what matters is
    # that exactly one pane block is left (the closed one is not a second leaf).
    blocks=$(ls_field "$HOST_OUT/ls.json" '[.tree | .. | objects | select(.type == "block")] | length')
    terms=$(ls_field "$HOST_OUT/ls.json" '[.terminals[]? | .terminal] | sort | join(",")')
    focused=$(ls_field "$HOST_OUT/ls.json" '.focused // "missing"')
    status_focus=$(field "$HOST_OUT/status.json" '.focused_pane // "missing"')
    check client "the tab has exactly one pane block after the close" \
        "$(bool test "$blocks" = 1)" "tree.type=$tree_type blocks=$blocks"
    check client "the closed terminal is gone from the tab" \
        "$(bool test "$terms" = "$terminal1")" "terminals=$terms want=$terminal1"
    check client "the remaining pane has focus" \
        "$(bool test "$focused" = "$pane1" -a "$status_focus" = "$pane1")" \
        "tab.focused=$focused status.focused_pane=$status_focus want=$pane1"

    hc_snapshot "$terminal2"
    hc_snapshot "$terminal1"
    closed_state=$(field "$HOST_OUT/hc-$terminal2.json" '.state // "missing"')
    closed_reason=$(field "$HOST_OUT/hc-$terminal2.json" '.reason // "missing"')
    remaining_state=$(field "$HOST_OUT/hc-$terminal1.json" '.state // "missing"')
    check core "the closed terminal finished" "$(bool test "$closed_state" = finished)" \
        "state=$closed_state reason=$closed_reason"
    check core "the closed terminal was killed, not lost" \
        "$(bool test "$closed_reason" = killed)" "reason=$closed_reason"
    check core "the remaining terminal is still live" \
        "$(bool test "$remaining_state" = live)" "state=$remaining_state"
    return 0
}

# resize
#
# Three layers. The drag has to reach the window (pixels change), the layout has to
# be saved (document version rises), and the app has to forward the new geometry to
# the core (cols move). Dropping the RESIZE forwarder is the injection: pixels and
# the document look right while the core still believes the old sizes.
run_case_resize() {
    local terminal1 terminal2
    local left_before right_before left_after right_after rows_before rows_after
    local version_before version_after sum_before sum_after delta
    local div_sel div_count div_x div_y div_w div_h win_x win_y win_w win_h
    local cx cy bx by bw bh rect diff_out mismatch

    do_action space-new.json space.new --name gui-resize || return 1
    need_id SPACE "$HOST_OUT/space-new.json" '.space // ""' "the space id" || return 1
    need_id terminal1 "$HOST_OUT/space-new.json" '.terminal // ""' "the terminal id" || return 1

    do_action split.json pane.split --direction right || return 1
    need_id terminal2 "$HOST_OUT/split.json" '.terminal // ""' "the new terminal id" || return 1

    # Both terminals have to be live and sized before "before" means anything.
    WANT_T="$terminal1"
    WANT_STATE=live
    wait_until 20 "the left terminal to be live" pred_hc_state \
        || { harness_fail "the left terminal never went live"; return 1; }
    WANT_T="$terminal2"
    wait_until 20 "the right terminal to be live" pred_hc_state \
        || { harness_fail "the right terminal never went live"; return 1; }
    wait_cols_settled "$terminal1" "$terminal2" \
        || { harness_fail "the panes' cols never settled (left=$(hc_val "$terminal1" '.cols') right=$(hc_val "$terminal2" '.cols'))"; return 1; }

    left_before=$(hc_val "$terminal1" '.cols')
    right_before=$(hc_val "$terminal2" '.cols')
    rows_before=$(hc_val "$terminal1" '.rows')
    version_before=$(cli status 2>/dev/null | "$JQ" -r '.documents[0].version // empty' 2>/dev/null)
    if ! is_int "$left_before" || ! is_int "$right_before" || ! is_int "$version_before"; then
        harness_fail "could not read the sizes/version before the drag (cols=$left_before/$right_before version=$version_before)"
        return 1
    fi

    driver ax --json --client "$APP_PID" >"$HOST_OUT/ax.json" 2>"$HOST_OUT/ax.err" \
        || { harness_fail "KraalGUIDriver ax failed: $(head -c 200 "$HOST_OUT/ax.err")"; return 1; }
    driver window --client "$APP_PID" >"$HOST_OUT/window.txt" 2>"$HOST_OUT/window.err" \
        || { harness_fail "KraalGUIDriver window failed: $(head -c 200 "$HOST_OUT/window.err")"; return 1; }

    # The divider is the only thing in the window describing pane geometry, so the
    # drag point and the pixel band both come from its AX frame instead of from
    # guesses about the sidebar and the tab bar.
    div_sel='[.nodes[] | select(.desc == "Resize panes")]'
    div_count=$(field "$HOST_OUT/ax.json" "$div_sel | length")
    check pixels "exactly one 'Resize panes' handle is exposed" \
        "$(bool test "$div_count" = 1)" "handles=$div_count"
    if [ "$div_count" != 1 ]; then
        harness_fail "cannot drag: expected 1 AX divider, found $div_count"
        return 1
    fi
    div_x=$(field "$HOST_OUT/ax.json" "$div_sel | .[0].frame.x // 0")
    div_y=$(field "$HOST_OUT/ax.json" "$div_sel | .[0].frame.y // 0")
    div_w=$(field "$HOST_OUT/ax.json" "$div_sel | .[0].frame.w // 0")
    div_h=$(field "$HOST_OUT/ax.json" "$div_sel | .[0].frame.h // 0")
    win_x=$(text_field "$HOST_OUT/window.txt" x)
    win_y=$(text_field "$HOST_OUT/window.txt" y)
    win_w=$(text_field "$HOST_OUT/window.txt" w)
    win_h=$(text_field "$HOST_OUT/window.txt" h)
    if ! is_int "$div_w" || ! is_int "$div_h" || ! is_int "$win_x" || ! is_int "$win_y" \
        || ! is_int "$win_w" || ! is_int "$win_h"; then
        harness_fail "could not read geometry (divider=$div_x,$div_y ${div_w}x${div_h} window=$win_x,$win_y ${win_w}x${win_h})"
        return 1
    fi
    # AX frames are in screen points; `drag --from/--to` and `diff --rect` are in
    # window-relative points.
    cx=$((div_x + div_w / 2 - win_x))
    cy=$((div_y + div_h / 2 - win_y))

    driver shot --client "$APP_PID" -o "$OUT/shot-before.png" >"$HOST_OUT/shot-before.txt" 2>&1 \
        || { harness_fail "screenshot before the drag failed: $(head -c 200 "$HOST_OUT/shot-before.txt")"; return 1; }
    driver drag --client "$APP_PID" --from "$cx,$cy" --to "$((cx - 60)),$cy" --steps 10 >"$HOST_OUT/drag.txt" 2>&1 \
        || { harness_fail "KraalGUIDriver drag failed: $(head -c 300 "$HOST_OUT/drag.txt")"; return 1; }

    WANT_T="$terminal1"
    WANT_COLS="$left_before"
    wait_until 15 "the left pane's cols to change in the core" pred_cols_shrank \
        || printf '  (the core never reported a narrower left pane; asserting what it did report)\n'
    driver shot --client "$APP_PID" -o "$OUT/shot-after.png" >"$HOST_OUT/shot-after.txt" 2>&1 \
        || { harness_fail "screenshot after the drag failed: $(head -c 200 "$HOST_OUT/shot-after.txt")"; return 1; }

    left_after=$(hc_val "$terminal1" '.cols')
    right_after=$(hc_val "$terminal2" '.cols')
    rows_after=$(hc_val "$terminal1" '.rows')
    version_after=$(cli status 2>/dev/null | "$JQ" -r '.documents[0].version // empty' 2>/dev/null)
    if ! is_int "$left_after" || ! is_int "$right_after" || ! is_int "$version_after"; then
        harness_fail "could not read the sizes/version after the drag (cols=$left_after/$right_after version=$version_after)"
        return 1
    fi
    printf '  sizes: left %s->%s cols, right %s->%s cols, rows %s->%s, doc version %s->%s\n' \
        "$left_before" "$left_after" "$right_before" "$right_after" \
        "$rows_before" "$rows_after" "$version_before" "$version_after"

    check client "the document version rose, so the new weights were saved" \
        "$(bool test "$version_after" -gt "$version_before")" \
        "version $version_before -> $version_after"
    check core "the left pane got narrower" "$(bool test "$left_after" -lt "$left_before")" \
        "cols $left_before -> $left_after"
    check core "the right pane got wider" "$(bool test "$right_after" -gt "$right_before")" \
        "cols $right_before -> $right_after"
    check core "the row count did not change" "$(bool test "$rows_after" = "$rows_before")" \
        "rows $rows_before -> $rows_after"
    sum_before=$((left_before + right_before))
    sum_after=$((left_after + right_after))
    delta=$((sum_after - sum_before))
    if [ "$delta" -lt 0 ]; then delta=$((-delta)); fi
    check core "the total width stayed constant (±2 cols)" "$(bool test "$delta" -le 2)" \
        "sum $sum_before -> $sum_after"

    # The band is the pane area around the divider: x is right of the sidebar
    # because the divider is, and y is the divider's own height, which starts below
    # the tab bar. Clamped to the window so `diff` cannot silently measure a
    # shrunken rect (it refuses clamped rects as a harness error anyway).
    bx=$((cx - 120))
    if [ "$bx" -lt 0 ]; then bx=0; fi
    by=$((div_y - win_y))
    if [ "$by" -lt 0 ]; then by=0; fi
    bw=240
    if [ $((bx + bw)) -gt "$win_w" ]; then bw=$((win_w - bx)); fi
    bh=$div_h
    if [ $((by + bh)) -gt "$win_h" ]; then bh=$((win_h - by)); fi
    if [ "$bw" -le 0 ] || [ "$bh" -le 0 ]; then
        harness_fail "pixel band is empty (rect $bx $by $bw $bh in ${win_w}x${win_h})"
        return 1
    fi
    rect="$bx $by $bw $bh"
    diff_out=$(driver diff --a "$OUT/shot-before.png" --b "$OUT/shot-after.png" --rect "$rect" 2>&1) \
        || { harness_fail "KraalGUIDriver diff failed: $(head -c 300 "$diff_out")"; return 1; }
    printf '%s\n' "$diff_out" >"$HOST_OUT/diff.txt"
    mismatch=$(printf '%s' "$diff_out" | sed -n 's/.*mismatch=\([0-9]*\).*/\1/p')
    check pixels "the pane band changed after the drag" \
        "$(bool test "${mismatch:-0}" -gt 0)" "rect=$rect $diff_out"
    return 0
}

# seen
#
# The window may only mark a turn as seen while it is the active app, and the mark
# only ever rises. Three turns plus one manual label prove all three rules; the
# injection drops the `appActive` guard, which turn 2 catches because the label
# must not move while the window is in the background.
run_case_seen() {
    local terminal active agent turn seen label_now
    do_action space-new.json space.new --name gui-seen || return 1
    need_id SPACE "$HOST_OUT/space-new.json" '.space // ""' "the space id" || return 1
    need_id terminal "$HOST_OUT/space-new.json" '.terminal // ""' "the terminal id" || return 1
    WANT_T="$terminal"

    WANT_ACTIVE=true
    if ! wait_until 25 "kraal status.active to become true" pred_active; then
        harness_fail "kraal status.active never became true — either activation is unavailable in this environment (no Aqua frontmost, no permission) or the app never published NSApp.isActive"
        return 1
    fi

    osc_turn "$terminal" 1 || return 1
    check core "the first turn was recorded" "$(bool test "$(hc_val "$terminal" '.turn')" = 1)" \
        "turn=$(hc_val "$terminal" '.turn')"

    WANT_SEEN=1
    if ! wait_until 20 "herdr.seen to reach 1" pred_seen; then
        record core "the active window marked turn 1 as seen" FAIL \
            "turn=$(hc_val "$terminal" '.turn') herdr.seen=$(hc_val "$terminal" '.labels["herdr.seen"]')"
        return 1
    fi

    cli status >"$HOST_OUT/status-active.json" 2>/dev/null \
        || { harness_fail "kraal status failed"; return 1; }
    active=$(field "$HOST_OUT/status-active.json" 'if .active then "true" else "false" end')
    agent=$(field "$HOST_OUT/status-active.json" '.agent // ""')
    check client "status.active is true while the window is frontmost" \
        "$(bool test "$active" = true)" "active=$active"
    check client "status.agent is the terminal the turn ran in" \
        "$(bool test "$agent" = "$terminal")" "agent=$agent terminal=$terminal"
    check core "the active window marked turn 1 as seen" \
        "$(bool test "$(hc_val "$terminal" '.labels["herdr.seen"]')" = 1)" \
        "herdr.seen=$(hc_val "$terminal" '.labels["herdr.seen"]')"

    deactivate_app
    WANT_ACTIVE=false
    if ! wait_until 25 "kraal status.active to become false" pred_active; then
        harness_fail "kraal status.active stayed true after another app was activated (cannot test the inactive rule here)"
        return 1
    fi
    record client "the window is no longer the active app" pass "active=false"

    osc_turn "$terminal" 2 || return 1
    # The window writes herdr.seen from a task after the event; the pause is what
    # gives a build that lost the `appActive` guard the chance to be wrong.
    sleep 2
    turn=$(hc_val "$terminal" '.turn')
    seen=$(hc_val "$terminal" '.labels["herdr.seen"]')
    check core "the second turn was recorded" "$(bool test "$turn" = 2)" "turn=$turn"
    check core "an inactive window writes no herdr.seen" "$(bool test "$seen" = 1)" \
        "herdr.seen=$seen (turn $turn ran while the window was in the background)"

    activate_app || { harness_fail "could not activate $APP"; return 1; }
    WANT_ACTIVE=true
    if ! wait_until 25 "the window to become active again" pred_active; then
        harness_fail "kraal status.active did not return to true after activating $APP"
        return 1
    fi
    WANT_SEEN=2
    if ! wait_until 25 "herdr.seen to advance to 2" pred_seen; then
        record core "the reactivated window caught up to turn 2" FAIL \
            "herdr.seen=$(hc_val "$terminal" '.labels["herdr.seen"]') turn=$(hc_val "$terminal" '.turn')"
        return 1
    fi
    check core "the reactivated window caught up to turn 2" \
        "$(bool test "$(hc_val "$terminal" '.labels["herdr.seen"]')" = 2)" \
        "herdr.seen=$(hc_val "$terminal" '.labels["herdr.seen"]')"

    if ! hc_cli label "$terminal" herdr.seen=9 >"$HOST_OUT/hc-label.json" 2>"$HOST_OUT/hc-label.err"; then
        harness_fail "hc label herdr.seen=9 failed: $(head -c 200 "$HOST_OUT/hc-label.err")"
        return 1
    fi
    # The window reads the label from the terminal record, so the next turn must
    # only be counted after the core reports it, otherwise the assertion would be
    # measuring a stale label.
    WANT_SEEN=9
    if ! wait_until 15 "the core to report herdr.seen=9" pred_seen; then
        harness_fail "hc label did not stick (herdr.seen=$(hc_val "$terminal" '.labels["herdr.seen"]'))"
        return 1
    fi
    sleep 1

    osc_turn "$terminal" 3 || return 1
    sleep 2
    turn=$(hc_val "$terminal" '.turn')
    label_now=$(hc_val "$terminal" '.labels["herdr.seen"]')
    check core "the third turn was recorded" "$(bool test "$turn" = 3)" "turn=$turn"
    check core "herdr.seen only ever rises: a manual 9 is left alone" \
        "$(bool test "$label_now" = 9)" "herdr.seen=$label_now (turn $turn)"
    return 0
}

# The core's `cols` for WAIT_T, as a predicate: the drag must reach the core.
pred_cols_shrank() {
    local cols
    cols=$(hc_val "$WANT_T" '.cols')
    is_int "$cols" && [ "$cols" -lt "$WANT_COLS" ]
}

# The panes' cols are whatever the app forwards after layout, so the first read
# after a split is the pre-layout default. Two identical reads are what makes
# "before the drag" mean something.
wait_cols_settled() {
    local t1="$1" t2="$2"
    local a1="" a2="" b1="" b2="" deadline
    deadline=$((SECONDS + 15))
    while [ "$SECONDS" -lt "$deadline" ]; do
        a1=$(hc_val "$t1" '.cols')
        a2=$(hc_val "$t2" '.cols')
        sleep 0.4
        b1=$(hc_val "$t1" '.cols')
        b2=$(hc_val "$t2" '.cols')
        if is_int "$a1" && is_int "$a2" && [ "$a1" = "$b1" ] && [ "$a2" = "$b2" ]; then
            return 0
        fi
    done
    return 1
}

pred_hc_state() {
    local state
    state=$(hc_val "$WANT_T" '.state')
    [ "$state" = "$WANT_STATE" ]
}

# ---------------------------------------------------------------- runner

# `summary.json` is the machine-readable half of a case: the exit code says
# something went wrong, this says which layer said so.
write_summary() {
    local status="$1" code="$2" ftype="$3" reason="$4" duration="$5"
    local assertions="[]"
    if [ "$status" != "error" ] && [ -s "$ASSERT_FILE" ]; then
        assertions=$("$JQ" -s . "$ASSERT_FILE")
    fi
    "$JQ" -n --arg case "$CASE" --arg backend "$BACKEND" --arg status "$status" \
        --argjson exitCode "$code" --arg failureType "$ftype" --arg reason "$reason" \
        --argjson durationMs "$duration" --argjson assertions "$assertions" \
        '{case:$case,backend:$backend,status:$status,exitCode:$exitCode,
          failureType:$failureType,reason:$reason,durationMs:$durationMs,
          assertions:$assertions}' >"$SUMMARY"
    cat "$SUMMARY"
}

run_case() {
    CASE="$1"
    CASE_INDEX="$2"
    CASE_DIR="$RUN_DIR/$CASE"
    SUMMARY="$CASE_DIR/summary.json"
    HOST_OUT="$CASE_DIR"
    ASSERT_FILE="$CASE_DIR/assertions.jsonl"
    SCR="$RUN_ROOT/c$CASE_INDEX"
    SESSION="g$CASE_INDEX-$$"
    STATE="$SCR/state"
    CONFIG="$SCR/config"
    CTL="$SCR/ctl.sock"
    VIEW="$SCR/view.json"
    KEYS="$SCR/keys.json"
    APP="$SCR/Kraal.app"
    HC_SOCKET="$STATE/herdr-core/$SESSION/$SESSION.sock"
    # `OUT` is where guest-side programs write; `HOST_OUT` is where this shell
    # writes. Under `vm` they are different machines.
    OUT="$HOST_OUT"
    if [ "$BACKEND" = "vm" ]; then OUT="$SCR/out"; fi
    APP_PID=""
    FAILS=0
    ERR=""

    mkdir -p "$CASE_DIR"
    : >"$ASSERT_FILE"
    say "case $CASE"

    local started finished duration body_code=0 prepared=1
    started=$(date +%s)
    if ! case_prepare >>"$HOST_OUT/stdout.log" 2>&1; then prepared=0; fi
    if [ "$prepared" -eq 1 ]; then
        "run_case_$(printf '%s' "$CASE" | tr '-' '_')" >>"$HOST_OUT/stdout.log" 2>&1
        body_code=$?
    else
        body_code=2
    fi
    stop_app >>"$HOST_OUT/stdout.log" 2>&1
    stop_core >>"$HOST_OUT/stdout.log" 2>&1
    collect_case >>"$HOST_OUT/stdout.log" 2>&1
    finished=$(date +%s)
    duration=$(((finished - started) * 1000))

    # Everything the case did is in the log; printing it here (and not through a
    # pipeline) keeps `record`'s bookkeeping in this shell.
    cat "$HOST_OUT/stdout.log"

    local status code ftype reason
    if [ -n "$ERR" ]; then
        status=error
        code=2
        ftype=harness
        reason="$ERR"
    elif [ "$FAILS" -gt 0 ]; then
        status=failed
        code=1
        ftype=assertion
        reason="$FAILS assertion(s) failed: $(field "$ASSERT_FILE" 'select(.status=="FAIL") | .what' 2>/dev/null | head -3 | tr '\n' ';')"
    elif [ "$body_code" -ne 0 ]; then
        status=error
        code=2
        ftype=harness
        reason="the case stopped with $body_code without recording a reason"
    else
        status=passed
        code=0
        ftype=none
        reason=""
    fi
    write_summary "$status" "$code" "$ftype" "$reason" "$duration"
    "$JQ" -nc --arg case "$CASE" --arg status "$status" --argjson exitCode "$code" \
        '{case:$case,status:$status,exitCode:$exitCode}' >>"$RUN_DIR/cases.jsonl"
    return "$code"
}

cmd_list() {
    cat <<'CASES'
split-right   space.new + pane.split right → tree row of two blocks (client), two live terminals with the space labels (core)
close-pane    pane.split right, pane.close → one pane block left (client), closed terminal finished/killed (core)
resize        drag the AX divider 60pt left → document version rose (client), cols moved and rows did not (core), pane band changed (pixels)
seen          three OSC 7501 turns around activation → status.active/agent (client), herdr.seen writes gated on activation and monotonic (core)
CASES
}

# Every environment fact the gate depends on, printed as findings. Probe never
# runs a case: it answers "would `run` have a chance", so a red probe is not
# evidence about the product.
cmd_probe() {
    RUN_ID="$(date +%Y%m%d-%H%M%S)-probe"
    RUN_DIR="$ARTIFACT_ROOT/$RUN_ID"
    RUN_ROOT="/tmp/kg-$$-$RANDOM"
    RUN_LOG="$RUN_DIR/probe.log"
    mkdir -p "$RUN_DIR"
    GUEST_BIN="$RUN_ROOT/bin"
    local failed=0

    require_backend
    finding() { # ok|FAIL label detail
        if [ "$1" = "ok" ]; then
            printf '  \033[32mok\033[0m   %-12s %s\n' "$2" "$3"
        else
            failed=$((failed + 1))
            printf '  \033[31mFAIL\033[0m %-12s %s\n' "$2" "$3"
        fi
    }
    printf '\n\033[1m== probe (%s backend)\033[0m\n' "$BACKEND"

    if [ -n "$JQ" ]; then finding ok jq "$JQ ($("$JQ" --version 2>/dev/null))"; else finding FAIL jq "not found"; fi
    if [ -n "$HOST_HC" ]; then
        local hc_note="$HOST_HC"
        if [ "$HOST_HC_REAL" != "$HOST_HC" ]; then hc_note="$HOST_HC -> $HOST_HC_REAL"; fi
        finding ok hc "$hc_note ($("$HOST_HC" --version 2>/dev/null | awk '{print $2}'))"
    else
        finding FAIL hc "not on PATH"
    fi
    if [ -d "$HOST_APP" ]; then finding ok app "$HOST_APP"; else finding FAIL app "missing — run ./Scripts/build-app.sh"; fi
    if [ -d "$HOST_APP" ]; then
        local newest
        newest=$(find "$ROOT/Sources" -name '*.swift' -newer "$HOST_APP" -print -quit 2>/dev/null)
        if [ -n "$newest" ]; then
            finding FAIL fresh "build/Kraal.app is older than $newest — run ./Scripts/build-app.sh"
        else
            finding ok fresh "build/Kraal.app is newer than every source"
        fi
    fi
    if [ -n "$HOST_DRIVER" ]; then finding ok driver "$HOST_DRIVER"; else finding FAIL driver "missing — run: swift build --product KraalGUIDriver"; fi
    if [ -n "$HOST_CLI" ]; then finding ok cli "$HOST_CLI"; else finding FAIL cli "missing — run: swift build --product kraal"; fi

    if [ "$BACKEND" = "vm" ]; then
        if command -v tart >/dev/null 2>&1; then
            finding ok tart "$(tart --version 2>&1 | head -1)"
        else
            finding FAIL tart "not installed (brew install cirruslabs/cli/tart)"
        fi
        if vm_up; then
            finding ok vm "$VM reachable"
            tart exec "$VM" /bin/mkdir -p "$GUEST_BIN" >/dev/null 2>&1 || true
            if [ -n "$HOST_DRIVER" ]; then
                push_tar "$(dirname "$HOST_DRIVER")" "$GUEST_BIN" "true" "chmod +x KraalGUIDriver" KraalGUIDriver \
                    >/dev/null 2>&1 || finding FAIL deploy "could not push KraalGUIDriver into $VM"
            fi
            local session_out manager
            session_out=$(tart exec "$VM" /bin/bash -lc 'launchctl managername' 2>/dev/null | tr -d '\r')
            if [ "$session_out" = "Aqua" ]; then
                finding ok session "Aqua (synthetic input can land)"
            else
                finding FAIL session "'$session_out' — needs Aqua, see Scripts/vm-bootstrap.sh"
            fi
            if manager=$(tart exec "$VM" /usr/bin/env "$GUEST_BIN/KraalGUIDriver" probe 2>&1); then
                finding ok driver-probe "$(printf '%s' "$manager" | tr '\n' ' ')"
            else
                finding FAIL driver-probe "$(printf '%s' "$manager" | tr '\n' ' ')"
            fi
        else
            finding FAIL vm "$ENV_WHY"
        fi
    else
        if [ -n "$HOST_DRIVER" ]; then
            local probe_out
            if probe_out=$("$HOST_DRIVER" probe 2>&1); then
                finding ok driver-probe "$(printf '%s' "$probe_out" | tr '\n' ' ')"
            else
                finding FAIL driver-probe "$(printf '%s' "$probe_out" | tr '\n' ' ')"
            fi
        fi
    fi

    # Probe pushed a driver into the guest just to ask `KraalGUIDriver probe`;
    # take the scratch back out so repeated probes do not pile up in /tmp.
    if [ "$BACKEND" = "vm" ]; then
        tart exec "$VM" /bin/rm -rf "$RUN_ROOT" >/dev/null 2>&1 || true
    fi
    rmdir "$RUN_ROOT" 2>/dev/null || true

    printf '\n'
    if [ "$failed" -ne 0 ]; then
        bad "probe: $failed finding(s) failed"
        return 2
    fi
    ok "probe: ready — ./Scripts/gui.sh run"
    return 0
}

cmd_run() {
    local cases=() c
    if [ "$#" -gt 0 ]; then
        for c in "$@"; do cases[${#cases[@]}]="$c"; done
    else
        for c in $ALL_CASES; do cases[${#cases[@]}]="$c"; done
    fi
    for c in "${cases[@]}"; do
        case " $ALL_CASES " in
        *" $c "*) ;;
        *) die "no such case '$c' (see: $0 list)" ;;
        esac
    done

    require_backend
    require_jq
    check_app_fresh

    RUN_ID="$(date +%Y%m%d-%H%M%S)"
    RUN_DIR="$ARTIFACT_ROOT/$RUN_ID"
    RUN_ROOT="/tmp/kg-$$-$RANDOM"
    RUN_LOG="$RUN_DIR/run.log"
    GUEST_BIN="$RUN_ROOT/bin"
    mkdir -p "$RUN_DIR" "$RUN_ROOT"
    : >"$RUN_DIR/cases.jsonl"

    ensure_driver
    require_tools

    if [ "$BACKEND" = "vm" ]; then
        vm_up || die "$ENV_WHY"
        vm_deploy || die "$ENV_WHY"
    fi
    say "run $RUN_ID ($BACKEND backend, scratch $RUN_ROOT)"

    local index=0 code=0 failed=0
    for c in "${cases[@]}"; do
        code=0
        run_case "$c" "$index" || code=$?
        index=$((index + 1))
        # A product failure outranks an environment one: an agent that sees exit 1
        # looks at the product, which is the actionable thing when both happened.
        case "$code" in
        1) failed=1 ;;
        2) if [ "$failed" -ne 1 ]; then failed=2; fi ;;
        esac
    done

    local rows="[]"
    if [ -s "$RUN_DIR/cases.jsonl" ]; then
        rows=$("$JQ" -s . "$RUN_DIR/cases.jsonl")
    fi
    local run_status=passed
    if [ "$failed" -eq 1 ]; then run_status=failed; fi
    if [ "$failed" -eq 2 ]; then run_status=error; fi
    "$JQ" -n --arg runId "$RUN_ID" --arg backend "$BACKEND" --arg vm "$VM" \
        --arg status "$run_status" --argjson cases "$rows" \
        '{runId:$runId,backend:$backend,vm:$vm,status:$status,cases:$cases}' \
        >"$RUN_DIR/run.json"

    printf '\n\033[1m== run %s: %s \033[0m\n' "$RUN_ID" "$run_status"
    printf '  artifacts: %s\n' "$RUN_DIR"
    printf '  scratch:   %s\n' "$RUN_ROOT"
    if [ "$failed" -ne 0 ]; then
        bad "run $RUN_ID: exit $failed"
        return "$failed"
    fi
    # A green run has already collected its artifacts; the per-case app copies and
    # core state are only useful when something failed. Keeping them on failure is
    # deliberate (KRAAL_GUI_KEEP_SCRATCH=1 keeps them on green too).
    if [ "${KRAAL_GUI_KEEP_SCRATCH:-0}" != "1" ]; then
        rm -rf "$RUN_ROOT"
        if [ "$BACKEND" = "vm" ]; then
            tart exec "$VM" /bin/rm -rf "$RUN_ROOT" >/dev/null 2>&1 || true
        fi
    fi
    ok "run $RUN_ID: every assertion passed"
    return 0
}

cmd_verify() {
    RUN_LOG="${TMPDIR:-/tmp}/kraal-gui-verify-$$.log"
    say "building Kraal.app"
    if ! ./Scripts/build-app.sh >"$RUN_LOG" 2>&1; then
        tail -20 "$RUN_LOG"
        die "build-app.sh failed"
    fi
    ok "built build/Kraal.app"
    cmd_run "$@"
}

mkdir -p "$ARTIFACT_ROOT" 2>/dev/null || true
RUN_LOG="${TMPDIR:-/tmp}/kraal-gui-$$.log"

case "${1:-}" in
list) cmd_list ;;
probe) cmd_probe; exit $? ;;
run) shift; cmd_run "$@"; exit $? ;;
verify) shift; cmd_verify "$@"; exit $? ;;
*)
    usage
    exit 2
    ;;
esac
