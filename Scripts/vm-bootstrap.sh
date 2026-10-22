#!/bin/bash
# Creates or verifies the kraal-agent VM. Idempotent.
set -uo pipefail
VM="${KRAAL_GUI_VM:-kraal-agent}"
BASE_IMAGE="${KRAAL_GUI_BASE_IMAGE:-ghcr.nju.edu.cn/cirruslabs/macos-tahoe-base:latest}"
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }
say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok() { printf '\033[32mok:\033[0m %s\n' "$*"; }

provision() {
    say "checking tart"
    command -v tart >/dev/null || die "tart not installed (brew install cirruslabs/cli/tart)"
    tart --version

    say "checking vm $VM"
    if tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM"; then
        ok "vm exists"
    else
        say "cloning $VM from $BASE_IMAGE (this pulls tens of GB)"
        tart clone "$BASE_IMAGE" "$VM" || die "clone failed"
        tart set "$VM" --cpu 6 --memory 12288 || true
        ok "created"
    fi

    say "booting headless"
    if tart list 2>/dev/null | grep -qw running; then ok "already running"; else
        nohup tart run --no-graphics "$VM" >"${TMPDIR:-/tmp}/kraal-agent-vm-run.log" 2>&1 &
        for _ in $(seq 1 60); do
            tart exec "$VM" /bin/bash -lc 'echo ready' >/dev/null 2>&1 && break
            sleep 2
        done
    fi
    tart exec "$VM" /bin/bash -lc 'echo ready' >/dev/null 2>&1 || die "vm never became reachable"

    say "checking session type (must be Aqua)"
    SESSION=$(tart exec "$VM" /bin/bash -lc 'launchctl managername' 2>/dev/null | tr -d '\r\n')
    [ "$SESSION" = "Aqua" ] || die "session is '$SESSION', need Aqua — synthetic input will not reach apps"
    ok "Aqua"

    say "checking tart-guest-agent TCC grants"
    echo "  These need SIP disabled inside the guest. Without them, AXPress works but"
    echo "  synthetic events and screenshots are refused — and the failure looks like a"
    echo "  product bug ('clicked but nothing happened')."
    # shellcheck disable=SC2016  # $svc/\" expand in the guest, by design
    MISSING=$(tart exec "$VM" /bin/bash -lc '
    DB="/Library/Application Support/com.apple.TCC/TCC.db"
    for svc in kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceScreenCapture; do
        n=$(sqlite3 "$DB" "select count(*) from access where service=\"$svc\" and client like \"%tart-guest-agent\" and auth_value=2" 2>/dev/null || echo 0)
        [ "$n" -ge 1 ] || echo "$svc"
    done' 2>/dev/null | tr -d '\r')
    if [ -n "$MISSING" ]; then
        printf '\033[33mwarning:\033[0m missing grants:\n%s\n' "$MISSING"
        if [ "${1:-}" = "--fix-tcc" ]; then
            say "granting (requires SIP disabled in the guest)"
            # client_type 1 = absolute path; auth_value 2 = allowed; auth_reason 0 =
            # "no reason given", which is what a manual entry gets. Writing TCC.db
            # directly only works with SIP off — that is why the base image ships
            # with it disabled.
            # TCC.db is root:wheel 0644 — writing needs sudo even with SIP off.
            # The guest's admin account has passwordless sudo, so nothing prompts.
            tart exec "$VM" /bin/bash -lc '
    DB="/Library/Application Support/com.apple.TCC/TCC.db"
    AGENT=$(ls -d /opt/homebrew/Cellar/tart-guest-agent/*/bin/tart-guest-agent 2>/dev/null | head -1)
    [ -n "$AGENT" ] || { echo "tart-guest-agent not found in the guest"; exit 1; }
    for svc in kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceScreenCapture; do
        echo "insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) values ('"'"'$svc'"'"', '"'"'$AGENT'"'"', 1, 2, 0, 1, NULL, NULL, 0, '"'"'UNUSED'"'"', NULL, 0, strftime('"'"'%s'"'"','"'"'now'"'"'));" \
            | sudo sqlite3 "$DB" || echo "  $svc failed"
    done
    sudo killall tccd 2>/dev/null || true
    echo "granted; restarting the guest agent so it picks them up"
    launchctl kickstart -k system/com.apple.tart-guest-agent 2>/dev/null || true
    sleep 2
    echo done'
            ok "grants written — re-run without --fix-tcc to confirm"
        else
            echo "  fix with: ./Scripts/vm-bootstrap.sh --fix-tcc"
            echo "  (needs SIP disabled inside the guest; see docs/ENVIRONMENT.md §4.6)"
        fi
    else
        ok "all three granted"
    fi

}

# ---------------------------------------------------------------- dispatch
#
# `export` / `import` were previously appended after the provisioning steps, so
# running `vm-bootstrap.sh export` provisioned a VM and *then* exported it — the
# wrong order, and it printed the "next steps" block in the middle of a migration.
# Dispatch first; provisioning is one of the branches.

case "${1:-}" in
export | import)
    :  # handled below
    ;;
*)
    provision "$@"
    say "next steps"
    echo "  ./Scripts/build-app.sh      # build the app on the host (VM has no Xcode)"
    echo "  ./Scripts/gui.sh probe      # deploy + verify"
    echo "  ./Scripts/gui.sh run        # all cases"
    echo
    echo "  moving to another machine?"
    echo "    $0 export ~/kraal-agent.tvm     # ~22GB, ~32s (stops the VM first)"
    echo "    $0 import ~/kraal-agent.tvm     # on the new machine, ~17s"
    echo "  the image carries the TCC grants, SIP state and autologin — importing"
    echo "  is what makes a new machine work without re-provisioning."
    ;;
esac

# ---------------------------------------------------------------- migration
#
# Reached only when the first argument is `export` or `import`. Everything above
# is the "provision" path and returns before this point.

case "${1:-}" in
export)
    DEST="${2:-$VM.tvm}"
    say "stopping $VM (an export of a running VM is refused by tart)"
    tart stop "$VM" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        tart list 2>/dev/null | grep -q "running" || break
        sleep 1
    done
    say "exporting $VM -> $DEST"
    echo "  Expect ~22GB and ~30s for a 31GB VM (measured 2026-10-22)."
    tart export "$VM" "$DEST" || die "export failed"
    ok "exported: $DEST ($(du -h "$DEST" 2>/dev/null | cut -f1 | tr -d ' '))"
    echo
    echo "  Move that file to the new machine, then:"
    echo "    ./Scripts/vm-bootstrap.sh import $DEST"
    ;;
import)
    SRC="${2:-}"
    [ -n "$SRC" ] || die "usage: $0 import <file.tvm>"
    [ -f "$SRC" ] || die "no such file: $SRC"
    # Importing over an existing VM fails with tart's own message ("is running"),
    # which reads like a tart bug rather than "you already have one". Say what is
    # actually wrong and how to proceed.
    if tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM"; then
        die "$VM already exists — delete it first if you really mean to replace it:
    tart stop $VM && tart delete $VM
  or import under a different name: KRAAL_GUI_VM=${VM}-imported $0 import $SRC"
    fi
    say "importing $SRC -> $VM"
    echo "  Measured 2026-10-22: ~17s for a 22GB file."
    tart import "$SRC" "$VM" || die "import failed"
    ok "imported"
    echo
    echo "  Now run this script with no arguments to verify the three prerequisites."
    ;;
esac
