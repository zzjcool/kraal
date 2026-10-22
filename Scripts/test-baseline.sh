#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# Runs the whole suite except the tests ported from the three reference projects
# that are *known* to disagree with this client today.
#
# Why this exists: `swift test` is deliberately red. `docs/PORTED-TESTS.md`
# lists the tests that came from herdr / herdr-gpui / rootshell and encode
# behaviour this client does not have yet (named-colour SGR, halfwidth kana
# width, OSC 8, u8-as-varint in host themes, generation-vs-error in the
# handshake, snapshot revision fences, …). Each one is a real difference worth
# fixing, but until it is fixed nothing else can use `swift test` as a gate.
#
# This script is the gate: everything *outside* that list must stay green, so a
# genuine regression is still caught. `--compare` reports tracked reds that now
# pass (or vanished), so fixing one is noticed instead of silently staying on the
# skip list.
#
#   ./Scripts/test-baseline.sh            # assert no regressions
#   ./Scripts/test-baseline.sh --list     # print the tracked reds
#   ./Scripts/test-baseline.sh --compare  # which tracked reds now pass
#
# The identifiers are `Target.Suite/testFunction`, which is what `swift test
# --skip` matches (it filters on the symbol, not the human-readable @Test
# title). Get them from `swift test --list-tests`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Same toolchain handling as verify.sh: `swift test` needs XCTest.framework,
# which only ships with Xcode. Run directly against the CLT toolchain and the
# failure reads "unable to resolve module dependency: 'XCTest'" — a missing
# toolchain that looks like a broken test.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SWIFT=/usr/bin/swift
[ -x "$SWIFT" ] || SWIFT=swift

REDS=(
    # ANSI re-encoding — herdr/src/protocol/render_ansi.rs
    "KraalProtocolTests.TerminalColorEncodingTests/namedForeground()"
    "KraalProtocolTests.TerminalColorEncodingTests/namedBackground()"
    "KraalProtocolTests.TerminalColorEncodingTests/curlyUnderline()"
    "KraalProtocolTests.WideGlyphTests/halfwidthVoicedKana()"
    "KraalProtocolTests.ANSICursorAndHyperlinkTests/osc8()"
    "KraalProtocolTests.ANSICursorAndHyperlinkTests/cursorShape()"
    "KraalProtocolTests.ANSICursorAndHyperlinkTests/hiddenCursorParked()"
    # missingCursorHides / synchronizedOutputOnDiffs / sizeChangeDoesNotClear were
    # on this list until issue #2 landed on main (diff frames wrapped in
    # synchronized output, resize no longer clears scrollback). `--compare` is
    # what surfaced them; they now guard again instead of being skipped.
    # Wire shape — herdr-gpui herdr-protocol/tests/host_theme.rs
    # hostThemeLayout / wideColorBytes / fullPalette used to be here: issue #4
    # fixed the u8-as-varint encoding (BincodeWriter.writeU8), so they guard now.
    # Frozen upstream fixture — endpoint.rs serde defaults
    # helloDecodes used to be here: issue #10 gave EndpointClientHello a custom
    # init(from:) with the nine serde defaults, so it guards now.
    # Payload hygiene — compatibility.rs / render_ansi.rs:1882
    # trailingBytes / overlappingRows used to be here: issue #7 made the decoder
    # consume the payload exactly and made validatePatch reject row overlap.
    # Handshake — version_mismatch.rs / framing.rs / rootshell version floor
    "KraalClientTests.CompatibilityPortTests/generationBeatsError()"
    "KraalClientTests.CompatibilityPortTests/olderDaemon()"
    "KraalClientTests.CompatibilityPortTests/versionFloor()"
    # gridLimit used to be here: issue #8 added the per-axis and total-cell
    # ceiling to resizeSurface (SurfaceGeometry.isAcceptableGrid).
    # Snapshot fences — session_state.rs / rootshell snapshot validation
    # revisionRegression / duplicatePaneIDs used to be here: issue #6 added
    # snapshotIsCurrent (boot-aware revision fence) and decode-time id checks.
    # Drag arithmetic — rootshell TmuxDividerResizeTests:66
    # nonFiniteDrag used to be here: issue #8 refuses a non-finite drag delta
    # before it can reach the ratio.
    # Split request shape — rootshell HerdrProtocolTests:29
    # ratioRequestShape used to be here: issue #8 sends the tab id (and omits it,
    # rather than blank, when there is no snapshot yet).
    # Backoff reporting — herdr supervisor.rs:1132
    # backoffIsBounded used to be here: issue #9 made scheduleEndpointRetry the
    # single source of the delay, so the countdown now matches the sleep.
)

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${REDS[@]}"
    exit 0
fi

if [ "${1:-}" = "--compare" ]; then
    available=$("$SWIFT" test --list-tests 2>/dev/null || true)
    for red in "${REDS[@]}"; do
        if ! printf '%s\n' "$available" | grep -qxF "$red"; then
            printf 'gone:       %s\n' "$red"
            continue
        fi
        if "$SWIFT" test --filter "$red" 2>&1 | grep -q '✔ Test "'; then
            printf 'now green:  %s\n' "$red"
        fi
    done
    exit 0
fi

SKIP_ARGS=()
for red in "${REDS[@]}"; do
    SKIP_ARGS+=(--skip "${red%()}")
done

"$SWIFT" test "${SKIP_ARGS[@]}"
