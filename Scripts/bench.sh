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
# A third trap is shape, not code: a frame's *style count* changes the cost of
# rendering it by 7x once issue #49 was fixed. `decodedFrame` cycles colours so
# every cell starts a new style run (worst case); `uniformlyStyledFrame` is one
# style for the whole screen (what a real full-text pane looks like). Both are
# measured, and a self-check asserts they really do differ in style count -- if
# they silently converge, the pair stops measuring anything.
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

/// A frame whose cells all share one style, like a terminal full of plain text.
///
/// `decodedFrame` cycles `foreground` through 8 named colours, so *every* cell
/// differs from its neighbour in style. That is the worst case for the renderer
/// (and issue #49's root cause: `StyleCode.encode` used to run per cell and its
/// result was discarded). Real screens are mostly this shape instead -- one
/// colour, thousands of cells -- which is why both are measured.
func uniformlyStyledFrame(_ width: UInt16, _ height: UInt16, seed: UInt32 = 0) -> FrameData {
    var cells = [CellData]()
    cells.reserveCapacity(Int(width) * Int(height))
    for index in 0 ..< Int(width) * Int(height) {
        let symbol = String(UnicodeScalar(UInt8(97 + (index + Int(seed)) % 26)))
        cells.append(CellData(
            symbol: symbol,
            foreground: 3,
            background: 0x0100_0000,
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

/// A `width`×`height` surface (tag 13), built with the public wire writer.
///
/// Built from bytes rather than a struct initialiser so the patch section below
/// compiles against both sides of issue #50: `PaneSurfaceFrame.init` is internal,
/// the decoder is public. It is also the honest shape — production gets surfaces
/// from this decoder, and a frame assembled in a `for` loop is not the same
/// allocation pattern as a decoded one (see the header of this script).
func decodedSurface(_ width: UInt16, _ height: UInt16) -> PaneSurfaceFrame {
    let w = Int(width), h = Int(height)
    var writer = BincodeWriter()
    writer.writeVarint(13)
    writer.writeString("boot-a")
    writer.writeVarint(3)                        // projectionRevision
    writer.writeVarint(1)                        // surfaceRevision
    writer.writeArray(Array(0 ..< w * h)) { writer, index in
        let symbol = String(UnicodeScalar(UInt8(97 + index % 26)))
        writer.writeString(symbol)
        writer.writeVarint(UInt64(index % 8))    // foreground
        writer.writeVarint(0x1E1E1E)             // background
        writer.writeVarint(0)                    // modifier
        writer.writeBool(false)                  // skip
        writer.writeBool(false)                  // no hyperlink
    }
    writer.writeVarint(UInt64(w))
    writer.writeVarint(UInt64(h))
    writer.writeBool(true)                       // cursor: Some
    writer.writeVarint(0)                        // column
    writer.writeVarint(0)                        // row
    writer.writeBool(true)                       // visible
    writer.writeVarint(0)                        // shape
    writer.writeVarint(0)                        // hyperlinks
    writer.writeVarint(0)                        // graphics bytes
    writer.writeVarint(0)                        // panes
    writer.writeVarint(0)                        // splits
    writer.writeBool(false)                      // popup
    writer.writeVarint(0)                        // graphics assets
    writer.writeVarint(0)                        // graphics placements
    writer.writeVarint(0)                        // graphics retained
    guard case let .paneSurface(surface) = try! ServerMessageDecoder.decode(Data(writer.bytes)) else {
        fatalError("expected a surface")
    }
    return surface
}

/// A patch (tag 19) rewriting `cells` cells of `row`, based on revision 1.
func decodedPatch(_ width: UInt16, row: UInt16, cells: Int) -> PaneSurfacePatch {
    var writer = BincodeWriter()
    writer.writeVarint(19)
    writer.writeString("boot-a")
    writer.writeVarint(3)                        // projectionRevision
    writer.writeVarint(1)                        // baseSurfaceRevision
    writer.writeVarint(2)                        // surfaceRevision
    writer.writeVarint(1)                        // one row
    writer.writeVarint(0)                        // column
    writer.writeVarint(UInt64(row))
    writer.writeArray(Array(0 ..< min(cells, Int(width)))) { writer, index in
        writer.writeString(String(UnicodeScalar(UInt8(97 + index % 26))))
        writer.writeVarint(1)                    // foreground
        writer.writeVarint(2)                    // background
        writer.writeVarint(0)                    // modifier
        writer.writeBool(false)                  // skip
        writer.writeBool(false)                  // no hyperlink
    }
    writer.writeVarint(0)                        // panes
    writer.writeBool(false)                      // cursor: None
    guard case let .paneSurfacePatch(patch) = try! ServerMessageDecoder.decode(Data(writer.bytes)) else {
        fatalError("expected a patch")
    }
    return patch
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
        changed.buffer[0] = CellData(
            symbol: "Z", foreground: 1, background: 2,
            modifier: 0, skip: false, hyperlink: nil
        )
        measureRendering("\(label) 1 cell changed", iterations: 3000,
                         first: frame, second: changed)
    }
    // Worst case: every row differs (tail -f, htop, full-screen scroll).
    //
    // Measured twice, because issue #49's claim is precisely that these two must
    // *not* cost the same. `decodedFrame` cycles the foreground through 8 named
    // colours, so every cell starts a new style run and the encoder genuinely has
    // to run ~10000 times. `uniformlyStyledFrame` is one style across the screen,
    // where it has to run ~once. Before the fix the ratio was 1.08x -- i.e. the
    // encoder ran per cell and its result was thrown away.
    print("-- every row changed (scroll / tail -f) --")
    for (label, width, height) in sizes {
        let varied = decodedFrame(width, height)
        let variedNext = decodedFrame(width, height, seed: 1)
        measureRendering("\(label) every row changed", iterations: 800,
                         first: varied, second: variedNext)
        let uniform = uniformlyStyledFrame(width, height)
        let uniformNext = uniformlyStyledFrame(width, height, seed: 1)
        measureRendering("\(label) every row changed, uniform", iterations: 800,
                         first: uniform, second: uniformNext)
    }
    // A frame that genuinely repeats (a polling snapshot): the renderer sees the
    // same content twice, which the daemon does send, so this case is real.
    //
    // Two *separately decoded* frames, not the same value twice. A decoded frame
    // always gets fresh storage, and `Array` comparison short-circuits when two
    // values share a buffer -- passing one value as both arguments measured
    // 0.15 us instead of 60 us, a 400x understatement. See docs/PERFORMANCE.md.
    print("-- identical frame repeated (redundant snapshot) --")
    for (label, width, height) in sizes {
        let first = decodedFrame(width, height)
        let second = decodedFrame(width, height)
        measureRendering("\(label) no-op diff", iterations: 800,
                         first: first, second: second)
    }
}

if mode == "all" || mode == "render" {
    print("")
    print("=== self-check: the two every-row frames must differ in style count ===")
    // Issue #49's regression, as a self-check rather than a timing comparison.
    // Timing one run against another measures the machine; counting distinct
    // styles measures the probe. If these ever come out equal, the "uniform"
    // case stopped being uniform and the comparison above silently measures
    // nothing -- exactly the class of error that produced the 0.29 us no-op diff.
    for (label, width, height) in sizes {
        func distinctStyles(_ frame: FrameData) -> Int {
            Set((0 ..< frame.buffer.rowCount).flatMap { row in
                frame.buffer.row(row).map { "\($0.foreground),\($0.background),\($0.modifier)" }
            }).count
        }
        let varied = distinctStyles(decodedFrame(width, height))
        let uniform = distinctStyles(uniformlyStyledFrame(width, height))
        let ok = varied > 1 && uniform == 1
        print("  \(label) styles: varied=\(varied) uniform=\(uniform): \(ok ? "ok" : "BROKEN")")
        if !ok {
            FileHandle.standardError.write(
                Data("bench self-check failed: uniform frame is not uniform for \(label)\n".utf8))
            exit(1)
        }
    }
}

// `Array` comparison short-circuits when two values share a storage buffer, so
// passing one frame as both arguments to measureRendering makes a full row scan
// look 400x cheaper than it is. Check storage identity directly -- a ratio check
// on timings measures the probe, not the hazard.
if mode == "all" || mode == "render" {
    print("")
    print("=== self-check: no-op frames must not share storage ===")
    for (label, width, height) in sizes {
        let first = decodedFrame(width, height)
        let second = decodedFrame(width, height)
        // Row 0's storage, not an equality check: after issue #50 the cells live
        // in one array per row, and per row is exactly the granularity at which
        // storage must differ for the renderer's row diff to see a change.
        let sameBuffer = first.buffer.sharesRow(0, with: second.buffer)
        print("  \(label) first/second share buffer: \(sameBuffer ? "YES -> BROKEN" : "no, ok")")
        if sameBuffer {
            FileHandle.standardError.write(Data("bench self-check failed for \(label)\n".utf8))
            exit(1)
        }
    }
}

if mode == "all" || mode == "patch" {
    print("")
    print("=== patch: PaneSurfaceFrame.apply, as AppStore.handleSurfacePatch drives it ===")
    // Measured through the **public wire API** on purpose, twice over.
    //
    //  1. It is the real path: a patch is decoded from bytes exactly as the socket
    //     delivers it, applied to a decoded surface, and the result published by
    //     assignment, which is what `handleSurfacePatch` does. An earlier version
    //     of this section hand-rolled `copy.cells[0] = ...; stored = copy` on a
    //     bare array, which reproduced the symptom but not the code, so it could
    //     not have shown the fix (issue #50).
    //
    //  2. It touches no API that issue #50 added: surfaces and patches come in
    //     through the public decoders and go out through `apply`. That is what made
    //     the before/after comparison possible — the same section, byte for byte,
    //     compiled against a worktree at the parent commit and against this one.
    //     (The render section above cannot do that: it asks the storage directly.)
    //
    // The view's copy is what makes this honest: with no second reference alive
    // the optimiser can prove the published copy is unobservable and the loop
    // measures nothing (docs/PERFORMANCE.md §2).
    print("-- one patch, 1 cell, with a view holding a copy of the surface --")
    for (label, width, height) in sizes {
        var surface = decodedSurface(width, height)
        var viewHolds = surface
        var patch = decodedPatch(width, row: 1, cells: 1)
        let iterations = 3000
        for _ in 0 ..< 300 {
            patch.baseSurfaceRevision = surface.surfaceRevision
            patch.surfaceRevision = surface.surfaceRevision &+ 1
            var current = surface
            do { try current.apply(patch) } catch { fatalError("\(error)") }
            surface = current
            viewHolds = surface
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0 ..< iterations {
            patch.baseSurfaceRevision = surface.surfaceRevision
            patch.surfaceRevision = surface.surfaceRevision &+ 1
            patch.rows[0].cells[0].foreground = UInt32(iteration % 8)
            var current = surface
            do { try current.apply(patch) } catch { fatalError("\(error)") }
            surface = current
            viewHolds = surface
            sink &+= UInt64(viewHolds.frame.cell(column: Int(width) - 1, row: Int(height) - 1)?.foreground ?? 0)
        }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start)
            / Double(iterations) / 1000.0
        // 4 panes at 60 patches/s is the multi-pane case issue #50 measured.
        let perFrame = micros * 60 * 4 / 1000.0
        let padded = label.padding(toLength: 46, withPad: " ", startingAt: 0)
        print(String(format: "%@ %9.2f us  %5.2f ms/frame at 60fps x 4 panes (%.0f%% of 16.7ms)",
                     padded, micros, perFrame, perFrame / 16.7 * 100))
    }
    print("-- one patch carrying a whole row (a line echoed back) --")
    for (label, width, height) in sizes {
        var surface = decodedSurface(width, height)
        var viewHolds = surface
        var patch = decodedPatch(width, row: 1, cells: Int(width))
        let iterations = 3000
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0 ..< iterations {
            patch.baseSurfaceRevision = surface.surfaceRevision
            patch.surfaceRevision = surface.surfaceRevision &+ 1
            patch.rows[0].cells[0].foreground = UInt32(iteration % 8)
            var current = surface
            do { try current.apply(patch) } catch { fatalError("\(error)") }
            surface = current
            viewHolds = surface
            sink &+= UInt64(viewHolds.frame.cell(column: Int(width) - 1, row: Int(height) - 1)?.foreground ?? 0)
        }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start)
            / Double(iterations) / 1000.0
        let perFrame = micros * 60 * 4 / 1000.0
        let padded = label.padding(toLength: 46, withPad: " ", startingAt: 0)
        print(String(format: "%@ %9.2f us  %5.2f ms/frame at 60fps x 4 panes (%.0f%% of 16.7ms)",
                     padded, micros, perFrame, perFrame / 16.7 * 100))
    }
    print("-- frame.validate() (a full-surface arrival still runs the whole scan) --")
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
