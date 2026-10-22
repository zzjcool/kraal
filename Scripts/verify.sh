#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# Runs every gate the repo has: build, tests, lint. This is the same set the
# README documents, so CI and a local check cannot drift apart.
#
#   ./Scripts/verify.sh          # build + test + lint + app bundle + GUI
#   ./Scripts/verify.sh --fast   # skip the app bundle and the GUI gate
#
# KRAAL_SKIP_GUI=1 disables only the GUI gate (needs an unlocked screen for
# any case that posts synthetic events).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# `swift test` needs XCTest.framework, which only ships with Xcode. The default
# CommandLineTools toolchain fails with "unable to resolve module dependency:
# 'XCTest'" — and the failure looks like a broken test, not a missing toolchain.
# AGENTS.md §1 documents this; export it here so the gate works when run plainly.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# /usr/bin/swift honours DEVELOPER_DIR; a `swift` from Homebrew would not, and
# would silently pick its own toolchain instead.
SWIFT=/usr/bin/swift
[ -x "$SWIFT" ] || SWIFT=swift

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
"$SWIFT" build 2>&1 | tail -3
check "${PIPESTATUS[0]}" "swift build"

section "tests"
"$SWIFT" test 2>&1 | grep -E "✔ Test run|✘|error:" | tail -8
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
elif [ "${KRAAL_SKIP_LINT:-0}" = "1" ]; then
    printf 'swiftlint not installed; skipped because KRAAL_SKIP_LINT=1\n'
else
    # A silently skipped lint gate is worse than no gate: it reports green while
    # checking nothing, which is exactly the failure mode this repo keeps hitting.
    printf 'swiftlint not found on PATH\n'
    check 1 "swiftlint (not installed)"
fi

section "shell lint"
# The scripts are part of the product here: gui.sh is the GUI gate, so a broken
# gui.sh is a broken gate. shellcheck is not installed by default, same policy as
# swiftlint (missing tool = failure, not silence).
if command -v shellcheck >/dev/null 2>&1; then
    SHELL_BAD=0
    for f in Scripts/*.sh; do
        shellcheck -S warning "$f" || SHELL_BAD=1
    done
    check "$SHELL_BAD" "shellcheck ($(ls Scripts/*.sh | wc -l | tr -d ' ') scripts)"
elif [ "${KRAAL_SKIP_LINT:-0}" = "1" ]; then
    printf 'shellcheck not installed; skipped because KRAAL_SKIP_LINT=1\n'
else
    printf 'shellcheck not found on PATH\n'
    check 1 "shellcheck (not installed)"
fi

if [ "${1:-}" != "--fast" ]; then
    section "app bundle"
    ./Scripts/build-app.sh > "$SCRATCH/app-build.log" 2>&1
    TAIL=$?
    tail -2 "$SCRATCH/app-build.log"
    check "$TAIL" "Kraal.app"
fi

if [ "${1:-}" != "--fast" ] && [ "${KRAAL_SKIP_GUI:-0}" != "1" ]; then
    section "gui (real window, scratch daemon, vm backend)"
    # The GUI gate drives a real window, so it runs in the VM by default: a local
    # run takes the pointer and keyboard away from whoever is using the machine.
    # Set KRAAL_GUI_BACKEND=local to run it here (interactive use only).
    ./Scripts/gui.sh run > "$SCRATCH/gui.log" 2>&1
    TAIL=$?
    # Strip ANSI first: the ✓/✗ lines start with a colour escape, so anchoring the
    # pattern at ^ matched nothing and the gate printed a green line with no
    # evidence of what it actually checked.
    sed 's/\[[0-9;]*m//g' "$SCRATCH/gui.log" | grep -E '^(  ✓|  ✗|ok:|FAILED)' | tail -14
    check "$TAIL" "gui.sh run"
    if [ "$TAIL" -ne 0 ]; then
        printf '    full log: %s\n' "$SCRATCH/gui.log"
    fi
fi

printf '\n'
if [ "$FAILED" -ne 0 ]; then
    printf '\033[31mverify: FAILED\033[0m\n'
    exit 1
fi
printf '\033[32mverify: all green\033[0m\n'
