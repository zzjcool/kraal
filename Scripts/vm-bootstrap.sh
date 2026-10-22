#!/bin/bash
# Creates or verifies the kraal-agent VM. Idempotent.
set -uo pipefail
VM="${KRAAL_GUI_VM:-kraal-agent}"
BASE_IMAGE="${KRAAL_GUI_BASE_IMAGE:-ghcr.nju.edu.cn/cirruslabs/macos-tahoe-base:latest}"
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }
say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok() { printf '\033[32mok:\033[0m %s\n' "$*"; }

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
        tart exec "$VM" /bin/bash -lc '
DB="/Library/Application Support/com.apple.TCC/TCC.db"
AGENT=$(ls -d /opt/homebrew/Cellar/tart-guest-agent/*/bin/tart-guest-agent 2>/dev/null | head -1)
[ -n "$AGENT" ] || { echo "tart-guest-agent not found in the guest"; exit 1; }
for svc in kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceScreenCapture; do
    sqlite3 "$DB" "insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) values ("$svc", "$AGENT", 1, 2, 0, 1, NULL, NULL, 0, "UNUSED", NULL, 0, strftime("%s","now"))" || echo "  $svc failed"
done
killall tccd 2>/dev/null || true
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

say "next steps"
echo "  ./Scripts/build-app.sh      # build the app on the host (VM has no Xcode)"
echo "  ./Scripts/gui.sh probe      # deploy + verify"
echo "  ./Scripts/gui.sh run        # all cases"
