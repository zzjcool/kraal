#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# The old Herdr 1 ported tests are gone, so the baseline is now a plain
# `swift test`. The script stays as the single command verify.sh calls, and as
# the place to put a temporary skip list if a future migration needs one.
#
#   ./Scripts/test-baseline.sh
#   ./Scripts/test-baseline.sh --list
#   ./Scripts/test-baseline.sh --compare

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SWIFT=/usr/bin/swift
[ -x "$SWIFT" ] || SWIFT=swift

case "${1:-}" in
    --list)
        echo "no tracked red tests"
        exit 0
        ;;
    --compare)
        echo "no tracked red tests"
        exit 0
        ;;
esac

exec "$SWIFT" test "$@"
