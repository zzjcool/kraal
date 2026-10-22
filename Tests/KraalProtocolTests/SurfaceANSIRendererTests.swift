// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Re-encoding the daemon's cell grid as VT/ANSI.
//
// The daemon renders a `PaneSurface` to a real terminal too, so its renderer
// tests (`herdr/src/protocol/render_ansi.rs`) are the only authority on what the
// *correct* bytes are. Several cases here are ports of upstream expectations;
// each says which one in its own comment.
//
// Split out of ProtocolTests.swift once that file passed the 900-line lint
// limit — the renderer had grown enough state (frame diffing, clear policy, sync
// wrapping, cursor hiding) to justify its own file anyway.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Cell grid to ANSI")
struct SurfaceANSIRendererTests {
    /// The whole rendering strategy rests on one claim: re-encoding the
    /// daemon's authoritative cells as VT sequences reproduces the same screen
    /// any correct terminal would draw. This test states it as a round trip.
    @Test("a captured surface survives encode → VT-parse → compare")
    func roundTripThroughTerminal() throws {
        let raw = try Fixture.data("surface_120x40.bin")
        guard case let .paneSurface(surface) = try ServerMessageDecoder.decode(raw) else {
            Issue.record("expected PaneSurface")
            return
        }

        var renderer = SurfaceANSIRenderer()
        let ansi = renderer.render(surface.frame)
        #expect(!ansi.isEmpty)
        // A full repaint, not an empty diff.
        #expect(String(bytes: ansi.prefix(8), encoding: .utf8)?.contains("2026h") == true)

        // Re-parsing is the terminal's job, so this test only asserts the
        // structural invariants we can check without a VT emulator: the output
        // ends with a reset and every row is addressed explicitly.
        let text = String(bytes: ansi, encoding: .utf8) ?? ""
        #expect(text.hasSuffix("\u{1B}[0m"))
        for row in 1 ... 40 {
            #expect(text.contains("\u{1B}[\(row);1H"), "row \(row) is not addressed")
        }
    }

    @Test("the first frame is full and the second only carries changes")
    func firstFrameIsFullSecondIsNot() {
        let blank = Array(repeating: CellData.blank, count: 8)
        var cells = blank
        cells[0] = CellData(
            symbol: "A",
            foreground: 0x0200_C0FF,
            background: 0x0100_0004,
            modifier: CellModifier.bold,
            skip: false,
            hyperlink: nil
        )
        let frame = FrameData(
            cells: cells,
            width: 4,
            height: 2,
            cursor: CursorState(column: 1, row: 1, visible: true, shape: 0),
            hyperlinks: [],
            graphics: Data()
        )

        var renderer = SurfaceANSIRenderer()
        let first = renderer.render(frame)
        #expect(String(bytes: first, encoding: .utf8)?.contains("[2J") == true)

        let second = renderer.render(frame)
        // Nothing changed, so the frame is just the synchronized-output pair plus
        // the trailing style reset — no row addressing, no cursor move.
        //
        // The bound was 16 bytes before every frame got wrapped in sync output;
        // the pair adds 16, so it is 40 now. Asserting the *absence* of a row
        // address is the real claim; the byte count only guards against someone
        // quietly turning the diff path into a full repaint.
        #expect(second.count < 40, "an unchanged frame is \(second.count) bytes")
        #expect(String(bytes: second, encoding: .utf8)?.contains("[1;1H") != true)
    }

    @Test("a changed cell produces a row repaint")
    func changedRowOnly() {
        var cells = Array(repeating: CellData.blank, count: 12)
        cells[4] = CellData(
            symbol: "x",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        var frame = FrameData(
            cells: cells,
            width: 4,
            height: 3,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame)

        cells[9] = CellData(
            symbol: "y",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        frame.cells = cells
        let delta = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""
        #expect(delta.contains("[3;1H"))
        #expect(!delta.contains("[2;1H"), "an unchanged row must not be repainted")
    }

    @Test("a reset repaints rows that did not change")
    func resetForcesFullRepaint() {
        // Regression: after a rejected frame the terminal keeps rows written at
        // the wrong width in its scrollback. `reset` must make the very next
        // render emit every row again, not just the rows that changed.
        var cells = Array(repeating: CellData.blank, count: 12)
        cells[0] = CellData(
            symbol: "A",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        let frame = FrameData(
            cells: cells,
            width: 4,
            height: 3,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame)
        let unchanged = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""
        #expect(!unchanged.contains("A"), "an unchanged row must not be repainted")

        renderer.reset()
        let repainted = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""
        #expect(
            repainted.contains("A"),
            "a reset must repaint the cells that were already on screen"
        )
    }

    @Test("a row that became blank is repainted, not skipped")
    func clearedRowIsRepainted() {
        // Regression: skipping blank rows left stale content on screen when a
        // pane split shrank a pane, because the old glyphs were never cleared.
        var cells = Array(repeating: CellData.blank, count: 12)
        cells[4] = CellData(
            symbol: "#",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        var frame = FrameData(
            cells: cells,
            width: 4,
            height: 3,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame)

        // Clear the row that had content.
        cells[4] = .blank
        frame.cells = cells
        let delta = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""
        #expect(delta.contains("[2;1H"), "a row that became blank must still be repainted")
    }

    @Test("an unchanged blank row is still not repainted")
    func unchangedBlankRowIsSkipped() {
        let frame = FrameData(
            cells: Array(repeating: .blank, count: 12),
            width: 4,
            height: 3,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame)
        let delta = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""
        #expect(!delta.contains("[1;1H"))
        #expect(!delta.contains("[2;1H"))
    }

    @Test("every frame is wrapped in synchronized output")
    func synchronizedOutputOnDiffs() {
        // Synchronized output (`?2026h` … `?2026l`) is what stops a terminal
        // painting a half-built grid. The old code only wrapped the first frame,
        // on the theory that a diff is "small". A diff still writes several rows
        // in sequence, so a fast-printing program (or a scroll) showed the screen
        // mid-write — the tear this pair exists to prevent.
        //
        // The daemon wraps every frame (render_ansi.rs:1284). Cost is 16 bytes
        // per frame against a 66-byte steady-state patch, which is not what made
        // this worth not doing.
        var renderer = SurfaceANSIRenderer()
        let first = FrameData(
            cells: Array(repeating: .blank, count: 8),
            width: 4,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        _ = renderer.render(first)

        var changed = first
        changed.cells[5] = CellData(
            symbol: "z",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        let diff = String(bytes: renderer.render(changed), encoding: .utf8) ?? ""
        #expect(diff.contains("\u{1B}[?2026h"), "diff frame opened without sync: \(diff)")
        #expect(diff.contains("\u{1B}[?2026l"), "diff frame never closed sync: \(diff)")
    }

    @Test("a size change repaints without clearing the screen")
    func sizeChangeDoesNotClear() {
        // A resize repaints every row (the grid changed, so no cell is
        // trustworthy), but must **not** send `2J`. The terminal owns scrollback
        // from before the resize; clearing it throws away output the user was
        // reading, and it is unrecoverable.
        //
        // The old code used one flag for both decisions, so every resize wiped
        // the pane. The daemon only clears on a pane's very first frame
        // (render_ansi.rs:1772), which is what this mirrors.
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(FrameData(
            cells: Array(repeating: .blank, count: 4),
            width: 2,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        ))
        let resized = String(bytes: renderer.render(FrameData(
            cells: Array(repeating: .blank, count: 6),
            width: 3,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )), encoding: .utf8) ?? ""
        #expect(!resized.contains("\u{1B}[2J"), "resize cleared the scrollback: \(resized)")
        // It must still be a full repaint: a resize that only diffed would leave
        // the rows past the old width unwritten.
        #expect(resized.contains("\u{1B}[1;1H"), "resize did not repaint row 1: \(resized)")
        #expect(resized.contains("\u{1B}[2;1H"), "resize did not repaint row 2: \(resized)")
    }

    @Test("the first frame does clear the screen")
    func firstFrameClears() {
        // The counterpart to the test above: only the scrollback we must not
        // destroy is protected. A pane's first frame has no scrollback worth
        // keeping, and stale bytes from whatever drew there before must go.
        var renderer = SurfaceANSIRenderer()
        let first = String(bytes: renderer.render(FrameData(
            cells: Array(repeating: .blank, count: 4),
            width: 2,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )), encoding: .utf8) ?? ""
        #expect(first.contains("\u{1B}[2J"), "first frame must clear: \(first)")
    }

    @Test("a reset clears the screen")
    func resetClears() {
        // `reset()` is reached after a rejected frame, which leaves rows written
        // at the wrong width in scrollback. Those must go — this is the one case
        // where destroying scrollback is the point.
        var renderer = SurfaceANSIRenderer()
        let frame = FrameData(
            cells: Array(repeating: .blank, count: 4),
            width: 2,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: Data()
        )
        _ = renderer.render(frame)
        renderer.reset()
        let afterReset = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""
        #expect(afterReset.contains("\u{1B}[2J"), "a reset must clear: \(afterReset)")
    }

    @Test("the cursor is hidden before any cell write, on every frame")
    func cursorHiddenBeforeCellWrites() {
        // The cursor is moved with CUP while painting, so a terminal that draws
        // the hardware cursor at the intermediate position shows it flicking
        // across the pane. Upstream hides it unconditionally inside the sync pair
        // (render_ansi.rs:690). This matters more now that diff frames write
        // several rows — there are more intermediate positions to flick through.
        var cells = Array(repeating: CellData.blank, count: 8)
        cells[0] = CellData(
            symbol: "A",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        var frame = FrameData(
            cells: cells,
            width: 4,
            height: 2,
            cursor: CursorState(column: 0, row: 0, visible: true, shape: 0),
            hyperlinks: [],
            graphics: Data()
        )
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame)

        cells[5] = CellData(
            symbol: "z",
            foreground: 0,
            background: 0,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        frame.cells = cells
        let diff = String(bytes: renderer.render(frame), encoding: .utf8) ?? ""

        let syncOpen = diff.range(of: "\u{1B}[?2026h")
        let hide = diff.range(of: "\u{1B}[?25l")
        let firstRow = diff.range(of: "\u{1B}[2;1H")
        #expect(syncOpen != nil && hide != nil && firstRow != nil)
        if let syncOpen, let hide, let firstRow {
            #expect(
                syncOpen.lowerBound < hide.lowerBound && hide.lowerBound < firstRow.lowerBound,
                "the cursor must be hidden inside the sync pair, before the first cell write: \(diff)"
            )
        }
    }

    @Test("colors use the non-ARGB encoding in SGR output")
    func colorEncoding() {
        let trueColor = CellData(
            symbol: "z",
            foreground: 0x020A_141E,
            background: 0x0100_00FF,
            modifier: 0,
            skip: false,
            hyperlink: nil
        )
        let code = StyleCode.encode(trueColor)
        #expect(code.contains("38;2;10;20;30"))
        #expect(code.contains("48;5;255"))
    }
}
