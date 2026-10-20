#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# Runs every gate the repo has: build, tests, lint. This is the same set the
# README documents, so CI and a local check cannot drift apart.
#
#   ./Scripts/verify.sh          # build + test + lint
#   ./Scripts/verify.sh --fast   # skip the app bundle

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
check() {
    if [ "$1" -ne 0 ]; then
        printf '\033[31mFAILED: %s\033[0m\n' "$2"
        FAILED=1
    else
        printf '\033[32mok: %s\033[0m\n' "$2"
    fi
}

section "build (all targets)"
swift build 2>&1 | tail -3
check "${PIPESTATUS[0]}" "swift build"

section "tests"
swift test 2>&1 | grep -E "✔ Test run|✘|error:" | tail -8
check "${PIPESTATUS[0]}" "swift test"

# Scratch files go under a per-user directory. A fixed /tmp name collides across
# users (and with leftovers from a root debug run), and the failed redirect then
# surfaces as a lint or bundle failure instead of a permission problem.
SCRATCH="${TMPDIR:-/tmp}/kraal-verify-$(id -u)"
mkdir -p "$SCRATCH"

section "lint"
# pi-lens installs SwiftLint outside the default PATH.
export PATH="$HOME/.pi-lens/bin:$PATH"
if command -v swiftlint >/dev/null 2>&1; then
    swiftlint --quiet --reporter json Sources Tests > "${SCRATCH}/lint.json" 2>/dev/null
    VIOLATIONS=$(LINT_JSON="${SCRATCH}/lint.json" python3 - <<'PY'
import json
import os
try:
    raw = open(os.environ['LINT_JSON']).read()
    start = raw.find('[')
    data = json.loads(raw[start:raw.rindex(']') + 1]) if start >= 0 else []
    print(len(data))
except Exception:
    print('0')
PY
)
    if [ "$VIOLATIONS" -eq 0 ]; then
        check 0 "swiftlint ($VIOLATIONS violations)"
    else
        swiftlint --quiet Sources Tests
        check 1 "swiftlint ($VIOLATIONS violations)"
    fi
else
    printf 'swiftlint not installed; skipping\n'
fi

if [ "${1:-}" != "--fast" ]; then
    section "app bundle"
    ./Scripts/build-app.sh > "$SCRATCH/app-build.log" 2>&1
    TAIL=$?
    tail -2 "$SCRATCH/app-build.log"
    check "$TAIL" "Kraal.app"
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
    printf '\033[31mverify: FAILED\033[0m\n'
    exit 1
fi
printf '\033[32mverify: all green\033[0m\n'
