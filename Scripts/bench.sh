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
# Both traps are written down in docs/PERFORMANCE.md — §1 ("没被消费的结果会被删掉")
# for the optimiser deleting the work, §2 ("合成数据要和真实数据同形") for the
# repeating-cell frame.
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
# Rebuild when the library is missing **or older than the sources it was built
# from**. The missing-only check meant a stale release library was silently
# reused: adding a type or changing a signature made the probe fail to compile
# (or worse, link against old code) while the script reported nothing but a
# compile error from the probe itself.
if [ ! -f "$BUILD/libKraalProtocol.a" ] \
    || [ -n "$(find "$ROOT/Sources" -name '*.swift' -newer "$BUILD/libKraalProtocol.a" -print -quit)" ]; then
    echo "release build is missing or stale; building (needed for honest numbers)..." >&2
    $SWIFT build -c release >&2 || exit 1
fi

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

// Machine-readable mode. Set by `Scripts/bench.sh --json`.
//
// The shell used to post-process stdout with awk (`$NF == "fps"`), which only
// matched the render rows: every patch measurement ends with
// `(2% of 16.7ms)` instead, so the core number of issue #50 was invisible to
// `--json` (it printed the three `validate()` rows and nothing else). Emitting
// the JSON here, where the label and the fields are both in hand, removes that
// whole class of bug -- no column counting, no trailing-text matching.
let jsonMode = ProcessInfo.processInfo.environment["KRAAL_BENCH_JSON"] == "1"

/// A section header, suppressed in JSON mode (it is not a measurement).
func header(_ line: String) {
    guard !jsonMode else { return }
    print(line)
}

/// One measurement.
///
/// - Parameters:
///   - fps: set for per-frame costs (rendering).
///   - perFrameMs / budgetPercent: set for per-patch costs (60fps x 4 panes).
func emit(
    _ label: String,
    us: Double,
    fps: Double? = nil,
    perFrameMs: Double? = nil,
    budgetPercent: Double? = nil
) {
    if jsonMode {
        var fields = ["\"label\":\"\(label)\"", String(format: "\"us\":%.3f", us)]
        if let fps { fields.append(String(format: "\"fps\":%.0f", fps)) }
        if let perFrameMs { fields.append(String(format: "\"ms_per_frame\":%.3f", perFrameMs)) }
        if let budgetPercent {
            fields.append(String(format: "\"percent_of_budget\":%.0f", budgetPercent))
        }
        print("{" + fields.joined(separator: ",") + "}")
        return
    }
    let padded = label.padding(toLength: 46, withPad: " ", startingAt: 0)
    if let fps {
        print(String(format: "%@ %9.2f us  %8.0f fps", padded, us, fps))
    } else if let perFrameMs, let budgetPercent {
        print(String(format: "%@ %9.2f us  %5.2f ms/frame at 60fps x 4 panes (%.0f%% of 16.7ms)",
                     padded, us, perFrameMs, budgetPercent))
    } else {
        print(String(format: "%@ %9.2f us", padded, us))
    }
}

/// Measures a renderer fed **alternating** frames through one instance.
///
/// Alternating is not cosmetic. With one renderer and one unchanging input, the
/// optimiser can prove the repeated `render` calls are identical, keep one, and
/// the loop measures nothing at all: an early version of this script reported
/// 0.36 us for work that takes 1547 us. Feeding two frames in turn makes the
/// renderer's diff state change every call, so no call can be elided.
/// Times one render, refusing to measure a case that cannot measure anything.
///
/// Issue #54: passing the *same* `FrameData` value as both arguments makes the
/// row diff short-circuit on shared storage, so a full scan reported 0.29 us
/// instead of 87 us -- 263x too fast. The separate self-check that was added for
/// it rebuilt its own two frames, so it passed even while the measurement used
/// one value for both (verified by injecting the regression: the self-check still
/// said "no, ok" and the run exited 0).
///
/// Checking inside the measurement is the point: it tests the frames the timing
/// actually consumes, not a pair reconstructed beside them.
func measureRendering(
    _ label: String,
    iterations: Int,
    first: FrameData,
    second: FrameData
) {
    // Row 0's storage, not an equality check: cells live in one array per row
    // (issue #50), and per row is exactly the granularity at which storage must
    // differ for the renderer's row diff to do any work.
    if first.buffer.sharesRow(0, with: second.buffer) {
        FileHandle.standardError.write(Data("""
        bench refuses to measure "\(label)": both frames share row storage, so the
        diff short-circuits and the number is meaningless (issue #54). Decode each
        frame separately.

        """.utf8))
        exit(1)
    }
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
    emit(label, us: micros, fps: 1_000_000.0 / micros)
}

func measure(_ label: String, iterations: Int, _ body: () -> Void) {
    for _ in 0 ..< max(3, iterations / 10) { body() }
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0 ..< iterations { body() }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
    let micros = elapsed / Double(iterations) / 1000.0
    emit(label, us: micros, fps: 1_000_000.0 / micros)
}

let sizes: [(String, UInt16, UInt16)] = [
    ("80x24", 80, 24),
    ("200x50", 200, 50),
    ("300x80", 300, 80),
]

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"

if mode == "all" || mode == "render" {
    header("=== render: VT encoding (SurfaceANSIRenderer) ===")
    // First frame: a pane appearing. Full repaint, nothing to diff against.
    header("-- first frame (pane appears) --")
    for (label, width, height) in sizes {
        let frame = decodedFrame(width, height)
        measure("\(label) first frame", iterations: 400) {
            var renderer = SurfaceANSIRenderer()
            sink &+= UInt64(renderer.render(frame).count)
        }
    }
    // Typing: one cell changes, one row is repainted. Alternating between the
    // two frames is what stops the optimiser (see measureRendering).
    header("-- one cell changed (typing) --")
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
    header("-- every row changed (scroll / tail -f) --")
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
    header("-- identical frame repeated (redundant snapshot) --")
    for (label, width, height) in sizes {
        let first = decodedFrame(width, height)
        let second = decodedFrame(width, height)
        measureRendering("\(label) no-op diff", iterations: 800,
                         first: first, second: second)
    }
}

if mode == "all" || mode == "render" {
    header("")
    header("=== self-check: the two every-row frames must differ in style count ===")
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
        header("  \(label) styles: varied=\(varied) uniform=\(uniform): \(ok ? "ok" : "BROKEN")")
        if !ok {
            FileHandle.standardError.write(
                Data("bench self-check failed: uniform frame is not uniform for \(label)\n".utf8))
            exit(1)
        }
    }
}

// The storage check lives inside `measureRendering` rather than here. It used to
// sit here, rebuilding its own two frames -- which is why injecting the #54
// regression left it saying "no, ok" and the run exiting 0. A check that inspects
// a different pair than the one being timed cannot fail for the right reason.

if mode == "all" || mode == "patch" {
    header("")
    header("=== patch: PaneSurfaceFrame.apply, as AppStore.handleSurfacePatch drives it ===")
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
    // measures nothing (docs/PERFORMANCE.md §1, "没被消费的结果会被删掉").
    header("-- one patch, 1 cell, with a view holding a copy of the surface --")
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
        emit("\(label) 1-cell patch", us: micros,
             perFrameMs: perFrame, budgetPercent: perFrame / 16.7 * 100)
    }
    header("-- one patch carrying a whole row (a line echoed back) --")
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
        emit("\(label) whole-row patch", us: micros,
             perFrameMs: perFrame, budgetPercent: perFrame / 16.7 * 100)
    }
    header("-- frame.validate() (a full-surface arrival still runs the whole scan) --")
    for (label, width, height) in sizes {
        let frame = decodedFrame(width, height)
        measure("\(label) validate()", iterations: 3000) {
            try? frame.validate()
            sink &+= 1
        }
    }
    // The cost of `apply`'s atomicity: write into a local copy and publish once,
    // versus write straight into the stored value.
    //
    // This exists because the numbers this comment used to quote (`+0.069 us` at
    // 200x50 and friends) had no probe behind them, and an independent reviewer
    // measured a different order of magnitude. A claim about the *cost of a code
    // shape* needs a probe with both shapes in it, not an inference from the shape
    // that shipped — see docs/PERFORMANCE.md §3 ("拆到能单独归因").
    //
    // Deliberately measures the storage step only: `apply`'s validation is shared
    // by both shapes, so including it would dilute the difference being measured.
    // Both arms hold a second reference for the whole loop, for the same reason the
    // patch section does — with one reference alive the optimiser deletes the copy
    // and the atomic arm reports the in-place cost (§1).
    header("-- atomicity: copy-then-publish vs write-in-place, one 1-cell row write --")
    // The tall sizes are here on purpose: the doc this replaced claimed the cost
    // grows with *height* (+6.3% at 50 rows, +11% at 300, +13.6% at 1200), which is
    // a claim about the outer row array being relocated one extra time. Probing only
    // the 24/50/80-row sizes could not have found that.
    let atomicitySizes = sizes + [("200x300", 200, 300), ("200x1200", 200, 1200)]
    for (label, width, height) in atomicitySizes {
        for atomic in [true, false] {
            var frame = decodedFrame(width, height)
            var viewHolds = frame
            var cell = CellData(
                symbol: "x", foreground: 1, background: 2, modifier: 0,
                skip: false, hyperlink: nil
            )
            let iterations = 3000
            for _ in 0 ..< 300 {
                cell.foreground = 1
                if atomic {
                    var next = frame
                    next.buffer.write([cell], at: Int(width) + 1)
                    frame = next
                } else {
                    frame.buffer.write([cell], at: Int(width) + 1)
                }
                viewHolds = frame
            }
            let start = DispatchTime.now().uptimeNanoseconds
            for iteration in 0 ..< iterations {
                cell.foreground = UInt32(iteration % 8)
                if atomic {
                    var next = frame
                    next.buffer.write([cell], at: Int(width) + 1)
                    frame = next
                } else {
                    frame.buffer.write([cell], at: Int(width) + 1)
                }
                viewHolds = frame
                // Consume both references, or the copy is dead code (§1).
                sink &+= UInt64(frame.buffer[1].foreground)
                sink &+= UInt64(viewHolds.buffer[1].symbol.utf8.count)
            }
            let micros = Double(DispatchTime.now().uptimeNanoseconds - start)
                / Double(iterations) / 1000.0
            emit("\(label) \(atomic ? "copy-then-publish" : "write-in-place")",
                 us: micros, fps: 1_000_000.0 / micros)
        }
    }
}

// Graphics encoding cost (issue #105).
//
// The encoder runs on **every** frame a pane paints, so its steady-state cost has
// to be negligible next to the cell render. It diffs against what it already sent,
// which means the two cases that matter are far apart:
//
//   * first frame  — upload the image (base64 of the whole asset) + place it
//   * cache hit    — look up the image and the placement, emit nothing
//
// Measuring only the first would overstate the cost, and only the second would
// hide the upload entirely. Both are reported.
//
// A 200x50 pane with a 64x64 RGBA image is the shape a real pane has: the image is
// small relative to the screen, but its base64 form is 4/3 larger than its bytes.
if mode == "all" || mode == "graphics" {
    header("")
    header("=== graphics: SurfaceGraphicsScene -> kitty bytes (GraphicsEncoder) ===")
    let imageWidth: UInt32 = 64
    let imageHeight: UInt32 = 64
    // RGBA, so 4 bytes per pixel. Three images, so the cache has something to hold.
    let pixelBytes = 4
    let dataLen = UInt64(imageWidth * imageHeight * UInt32(pixelBytes))
    let graphicsKey = SurfaceGraphicsAssetKey(
        source: .terminal(target: .pane(paneId: "w1:p1"), imageId: 1),
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        format: .rgba,
        dataLen: dataLen,
        dataFingerprint: 0xFEED_FACE
    )
    let graphicsAsset = SurfaceGraphicsAsset(
        key: graphicsKey,
        data: Data(count: Int(dataLen))
    )
    let graphicsPlacement = SurfaceGraphicsPlacement(
        asset: graphicsKey,
        logicalPlacementId: 1,
        cellX: 2,
        cellY: 2,
        cols: 8,
        rows: 4,
        sourceX: 0,
        sourceY: 0,
        sourceWidth: 0,
        sourceHeight: 0,
        xOffset: 0,
        yOffset: 0,
        layer: 0,
        scrollbackOffset: 0
    )
    let graphicsScene = SurfaceGraphicsScene(
        assets: [graphicsAsset],
        placements: [graphicsPlacement]
    )

    // First frame: a fresh encoder every iteration, so nothing can be cached away.
    measure("graphics 64x64 rgba first frame", iterations: 2000) {
        var encoder = GraphicsEncoder()
        sink &+= UInt64(encoder.encode(scene: graphicsScene, scope: "w1:p1").count)
    }

    // Cache hit: one encoder, the same scene again. This is the frame a pane
    // actually paints while nothing changes — it must cost close to nothing.
    var graphicsEncoder = GraphicsEncoder()
    _ = graphicsEncoder.encode(scene: graphicsScene, scope: "w1:p1")
    measure("graphics 64x64 rgba cache hit", iterations: 20000) {
        sink &+= UInt64(graphicsEncoder.encode(scene: graphicsScene, scope: "w1:p1").count)
    }

    // The empty case: a pane with no images pays this on every frame.
    let emptyScene = SurfaceGraphicsScene()
    var emptyEncoder = GraphicsEncoder()
    measure("graphics empty scene", iterations: 20000) {
        sink &+= UInt64(emptyEncoder.encode(scene: emptyScene, scope: "w1:p1").count)
    }
}

// The checksum goes to stderr: it is the reason no measurement can be optimised
// away, not a measurement, and on stdout it would make `--json` unparseable.
FileHandle.standardError.write(
    Data("(checksum \(sink) — printed so no measurement can be optimised away)\n".utf8))
SWIFT

echo "compiling probe against $BUILD ..." >&2
/usr/bin/swiftc -O -o "$WORK/bench" "$WORK/bench.swift" \
    -I "$BUILD" -L "$BUILD" -lKraalProtocol 2>&1 | grep -E "error" && exit 1

# JSON mode is the probe's own, not a stdout filter here.
#
# It used to be awk on `$NF == "fps"`, which matched only the render rows: every
# patch row ends with `(2% of 16.7ms)`, so `--json` printed the three validate()
# rows and silently dropped the number issue #50 is about. The probe now emits
# the JSON itself, where the label and the fields are both in hand.
if [ "$JSON" -eq 1 ]; then
    KRAAL_BENCH_JSON=1 "$WORK/bench" "$MODE"
else
    "$WORK/bench" "$MODE"
fi
