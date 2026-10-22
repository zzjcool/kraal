#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 zzjcool
#
# Performance probe: measures the two hot paths that dominate a frame, using the
# real protocol code from a **release** build.
#
#   ./Scripts/bench.sh              # both paths, default sizes
#   ./Scripts/bench.sh render       # renderer only
#   ./Scripts/bench.sh patch        # patch-application only
#   ./Scripts/bench.sh --json       # machine-readable, for comparing runs
#
# Why this exists: `swift test` proves behaviour, not cost. Every performance
# claim in issues #49/#50 was produced this way, because two of the first four
# numbers were wrong in opposite directions:
#
#   1. A benchmark whose result is not consumed gets **deleted by the optimiser**.
#      An early run reported 0.3 us for a render measured at 1500 us elsewhere —
#      the loop had been folded away entirely. Every measurement here adds its
#      output length to a global that escapes, so nothing can be proven dead.
#
#   2. `[CellData](repeating:count:)` does not produce a realistic frame. All
#      cells share one `String` instance, so retain/release behaves differently
#      from a decoded frame where every cell owns its string. The numbers moved
#      by 3x between the two shapes. Frames here are built cell by cell.
#
# Both traps are written down in docs/PERFORMANCE.md §2.
#
# The harness compiles a small Swift program against the release static library.
# It deliberately does not live in the test target: running it under `swift test`
# would link a debug build and measure nothing useful.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

SWIFT=/usr/bin/swift
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MODE="${1:-all}"
[ "$MODE" = "--json" ] && MODE=all
JSON=0
for arg in "$@"; do [ "$arg" = "--json" ] && JSON=1; done

BUILD="$ROOT/.build/release"
[ -f "$BUILD/libKraalProtocol.a" ] || {
    echo "no release build; building (needed for honest numbers)..." >&2
    $SWIFT build -c release >&2 || exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/bench.swift" <<'SWIFT'
import Foundation
import KraalProtocol

// Escapes: the optimiser must not be able to prove these are unused.
nonisolated(unsafe) var sink: UInt64 = 0

/// A frame shaped like a decoded one: every cell owns its own `String`.
///
/// `[CellData](repeating:count:)` would share one instance and produce numbers
/// that do not match production (see the header of Scripts/bench.sh).
func decodedFrame(_ width: UInt16, _ height: UInt16, seed: UInt32 = 0) -> FrameData {
    var cells = [CellData]()
    cells.reserveCapacity(Int(width) * Int(height))
    for index in 0 ..< Int(width) * Int(height) {
        let symbol = String(UnicodeScalar(UInt8(97 + (index + Int(seed)) % 26)))
        cells.append(CellData(
            symbol: symbol,
            foreground: UInt32(index % 8),
            background: 0x1E1E1E,
            modifier: 0,
            skip: false,
            hyperlink: nil
        ))
    }
    return FrameData(
        cells: cells,
        width: width,
        height: height,
        cursor: CursorState(column: 0, row: 0, visible: true, shape: 0),
        hyperlinks: [],
        graphics: Data()
    )
}

/// Measures a renderer fed **alternating** frames through one instance.
///
/// Alternating is not cosmetic. With one renderer and one unchanging input, the
/// optimiser can prove the repeated `render` calls are identical, keep one, and
/// the loop measures nothing at all: an early version of this script reported
/// 0.36 us for work that takes 1547 us. Feeding two frames in turn makes the
/// renderer's diff state change every call, so no call can be elided.
func measureRendering(
    _ label: String,
    iterations: Int,
    first: FrameData,
    second: FrameData
) {
    var renderer = SurfaceANSIRenderer()
    _ = renderer.render(first)
    for iteration in 0 ..< max(3, iterations / 10) {
        sink &+= UInt64(renderer.render(iteration % 2 == 0 ? second : first).count)
    }
    let start = DispatchTime.now().uptimeNanoseconds
    for iteration in 0 ..< iterations {
        sink &+= UInt64(renderer.render(iteration % 2 == 0 ? second : first).count)
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
    let micros = elapsed / Double(iterations) / 1000.0
    let padded = label.padding(toLength: 46, withPad: " ", startingAt: 0)
    print(String(format: "%@ %9.2f us  %8.0f fps", padded, micros, 1_000_000.0 / micros))
}

func measure(_ label: String, iterations: Int, _ body: () -> Void) {
    for _ in 0 ..< max(3, iterations / 10) { body() }
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0 ..< iterations { body() }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
    let micros = elapsed / Double(iterations) / 1000.0
    let padded = label.padding(toLength: 46, withPad: " ", startingAt: 0)
    print(String(format: "%@ %9.2f us  %8.0f fps", padded, micros, 1_000_000.0 / micros))
}

let sizes: [(String, UInt16, UInt16)] = [
    ("80x24", 80, 24),
    ("200x50", 200, 50),
    ("300x80", 300, 80),
]

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"

if mode == "all" || mode == "render" {
    print("=== render: VT encoding (SurfaceANSIRenderer) ===")
    // First frame: a pane appearing. Full repaint, nothing to diff against.
    print("-- first frame (pane appears) --")
    for (label, width, height) in sizes {
        let frame = decodedFrame(width, height)
        measure("\(label) first frame", iterations: 400) {
            var renderer = SurfaceANSIRenderer()
            sink &+= UInt64(renderer.render(frame).count)
        }
    }
    // Typing: one cell changes, one row is repainted. Alternating between the
    // two frames is what stops the optimiser (see measureRendering).
    print("-- one cell changed (typing) --")
    for (label, width, height) in sizes {
        let frame = decodedFrame(width, height)
        var changed = frame
        changed.cells[0] = CellData(
            symbol: "Z", foreground: 1, background: 2,
            modifier: 0, skip: false, hyperlink: nil
        )
        measureRendering("\(label) 1 cell changed", iterations: 3000,
                         first: frame, second: changed)
    }
    // Worst case: every row differs (tail -f, htop, full-screen scroll).
    print("-- every row changed (scroll / tail -f) --")
    for (label, width, height) in sizes {
        let first = decodedFrame(width, height)
        let second = decodedFrame(width, height, seed: 1)
        measureRendering("\(label) every row changed", iterations: 800,
                         first: first, second: second)
    }
    // A frame that genuinely repeats (a polling snapshot): the renderer sees the
    // same content twice, which the daemon does send, so this case is real.
    print("-- identical frame repeated (redundant snapshot) --")
    for (label, width, height) in sizes {
        let frame = decodedFrame(width, height)
        measureRendering("\(label) no-op diff", iterations: 3000,
                         first: frame, second: frame)
    }
}

if mode == "all" || mode == "patch" {
    print("")
    print("=== patch: handleSurfacePatch's copy-mutate-assign (AppStore+Events) ===")
    print("-- cost of applying one patch, regardless of how few cells it carries --")
    for (label, width, height) in sizes {
        nonisolated(unsafe) var stored = decodedFrame(width, height)
        let iterations = 3000
        for _ in 0 ..< 300 {
            var copy = stored
            copy.cells[0].foreground = 1
            stored = copy
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< iterations {
            var copy = stored
            copy.cells[0].foreground = 1
            stored = copy
            sink &+= UInt64(copy.cells.count)
        }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start)
            / Double(iterations) / 1000.0
        // 4 panes at 60 patches/s is the multi-pane case issues #50 measured.
        let perFrame = micros * 60 * 4 / 1000.0
        let padded = label.padding(toLength: 46, withPad: " ", startingAt: 0)
        print(String(format: "%@ %9.2f us  %5.2f ms/frame at 60fps x 4 panes (%.0f%% of 16.7ms)",
                     padded, micros, perFrame, perFrame / 16.7 * 100))
    }
    print("-- frame.validate() runs on every patch --")
    for (label, width, height) in sizes {
        let frame = decodedFrame(width, height)
        measure("\(label) validate()", iterations: 3000) {
            try? frame.validate()
            sink &+= 1
        }
    }
}

print("")
print("(checksum \(sink) — printed so no measurement can be optimised away)")
SWIFT

echo "compiling probe against $BUILD ..." >&2
/usr/bin/swiftc -O -o "$WORK/bench" "$WORK/bench.swift" \
    -I "$BUILD" -L "$BUILD" -lKraalProtocol 2>&1 | grep -E "error" && exit 1

if [ "$JSON" -eq 1 ]; then
    # Convert "<label> <us> us <fps> fps" into JSON lines with awk: sed cannot
    # reliably split the right-aligned numeric columns (the us field carries a
    # decimal point and the label carries trailing spaces).
    # "<label...>   <us> us   <fps> fps" -> JSON. The numeric columns are the
    # last four fields (us, "us", fps, "fps"), so the label is everything before
    # them; sed cannot do this reliably because the label carries trailing spaces.
    "$WORK/bench" "$MODE" | awk '
        $NF == "fps" {
            fps = $(NF-1)
            us  = $(NF-3)
            label = ""
            for (i = 1; i <= NF-4; i++) label = label (i > 1 ? " " : "") $i
            gsub(/"/, "", label)
            printf "{\"label\":\"%s\",\"us\":%s,\"fps\":%s}\n", label, us, fps
        }'
else
    "$WORK/bench" "$MODE"
fi
