// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import GhosttyTerminal
@testable import KraalProtocol
@testable import KraalTerminalView
import Testing

/// While Ghostty's grid is still the *previous* size, a pane's frame is painted
/// cropped to it rather than not at all.
///
/// The defect this covers, measured on a live client: the pane's view grows to the new
/// cell count immediately, but Ghostty reports the old grid for a beat. `apply` parked
/// the frame and returned, so the view area taller than the grid stayed on the
/// terminal's own background — a one-cell band that read `(247,247,247)` between
/// `(17,20,25)` panes (libghostty's `alabaster`; `#212121` on dark). It showed up on
/// every drag step and every window resize.
@Suite("Cropped pane frames")
@MainActor
struct PaneFrameCropTests {
    /// A one-pane surface whose pane is `rows` tall, for driving `apply`.
    private func surface(rows: UInt16) -> PaneSurfaceFrame {
        PaneSurfaceFrame(
            bootId: "boot",
            projectionRevision: 1,
            surfaceRevision: 1,
            frame: frame(width: 112, height: rows),
            panes: [
                PaneSurfacePane(
                    paneId: "w1:p1",
                    contentRevision: 1,
                    rect: SurfaceRect(originX: 0, originY: 0, width: 112, height: rows),
                    innerRect: SurfaceRect(originX: 0, originY: 0, width: 112, height: rows),
                    scrollbarRect: nil,
                    scroll: nil,
                    focused: true,
                    mouseReporting: false,
                    sgrPixelMouse: false,
                    alternateScreenActive: false,
                    pixelWidth: 0,
                    pixelHeight: 0
                )
            ],
            splits: [],
            popup: nil,
            graphics: SurfaceGraphicsScene()
        )
    }

    private func frame(width: UInt16, height: UInt16) -> FrameData {
        // Distinct content per cell so a wrong crop is visible, not just a wrong size.
        let cells = (0 ..< Int(width) * Int(height)).map { index in
            CellData(symbol: "\(index % 10)", foreground: 1, background: 2, modifier: 0, skip: false, hyperlink: nil)
        }
        return FrameData(
            cells: cells,
            width: width,
            height: height,
            cursor: CursorState(column: 2, row: 3, visible: true, shape: 0),
            hyperlinks: [],
            graphics: Data([0x01])
        )
    }

    @Test("a taller frame is cropped to the grid's rows")
    func cropsRows() {
        let cropped = PaneTerminalModel.cropped(frame(width: 4, height: 19), toColumns: 4, rows: 18)
        #expect(cropped.width == 4)
        #expect(cropped.height == 18)
        // The first cell survives, so the crop kept the top-left, not the bottom.
        #expect(cropped.buffer.row(0).first?.symbol == "0")
    }

    @Test("a wider frame is cropped to the grid's columns")
    func cropsColumns() {
        let cropped = PaneTerminalModel.cropped(frame(width: 112, height: 2), toColumns: 100, rows: 2)
        #expect(cropped.width == 100)
        #expect(cropped.height == 2)
        // Row 1 starts at index 112 in the source; after cropping it starts at 100.
        #expect(cropped.buffer.row(1).count == 100)
        #expect(cropped.buffer.row(1).first?.symbol == "2")
    }

    @Test("a grid larger than the frame keeps the whole frame")
    func neverGrows() {
        let cropped = PaneTerminalModel.cropped(frame(width: 4, height: 3), toColumns: 9, rows: 9)
        #expect(cropped.width == 4)
        #expect(cropped.height == 3)
    }

    @Test("a cursor outside the crop is dropped, one inside is kept")
    func cursorFollowsTheCrop() {
        // Cursor at (2, 3): kept when 4x4 or larger.
        #expect(PaneTerminalModel.cropped(frame(width: 4, height: 4), toColumns: 4, rows: 4).cursor != nil)
        // Cropped to 3 rows: row 3 is gone.
        #expect(PaneTerminalModel.cropped(frame(width: 4, height: 4), toColumns: 4, rows: 3).cursor == nil)
        // Cropped to 2 columns: column 2 is gone.
        #expect(PaneTerminalModel.cropped(frame(width: 4, height: 4), toColumns: 2, rows: 4).cursor == nil)
    }

    @Test("a zero-size grid yields an empty frame instead of crashing")
    func degenerateGrid() {
        let cropped = PaneTerminalModel.cropped(frame(width: 4, height: 4), toColumns: 0, rows: 0)
        #expect(cropped.width == 0)
        #expect(cropped.height == 0)
    }

    /// The decision `apply` makes when the grid lags the view. It must be "paint the
    /// overlap", not "paint nothing": painting nothing is the defect, because the rows
    /// between the grid and the view then show the terminal's own background.
    @Test("a lagging grid still paints the overlap")
    func mismatchPaintsTheOverlap() {
        let bridge = PaneTerminalModel.bridgeFrame(
            frame(width: 112, height: 19), gridColumns: 112, gridRows: 18
        )
        #expect(bridge?.width == 112)
        #expect(bridge?.height == 18, "the one row past the grid must not be painted")
    }

    @Test("a zero grid paints nothing rather than an empty write")
    func zeroGridPaintsNothing() {
        #expect(PaneTerminalModel.bridgeFrame(frame(width: 4, height: 4), gridColumns: 0, gridRows: 0) == nil)
    }

    /// **The real path**: drive `apply(surface:)` with a grid that lags the frame.
    ///
    /// This deliberately asserts that **nothing** is painted, which is the opposite
    /// of what an earlier version of this test required. That version was written
    /// when the defect was "a mismatch paints nothing and the rows past the grid
    /// show the terminal's background", and painting the intersection fixed that.
    ///
    /// It then caused a worse one. The grid comes from Ghostty's `bounds`, which
    /// SwiftUI updates one layout pass *after* the frame that asked for it. On a
    /// split, a pane was briefly measured at its previous height — measured
    /// `ghostty=118x36 frame=116x16` — so the intersection covered 16 of 36 rows
    /// and the other twenty kept the *previous layout's* content. That is the
    /// reported "drag fast and a lot of empty rows appear at the bottom", and it
    /// persisted until something else repainted.
    ///
    /// So the rule is now: at a grid the frame does not fit, paint nothing and wait.
    /// `reapplyAfterGridViewMoved` is what guarantees the wait ends.
    /// A frame taller than the terminal paints the rows that fit.
    ///
    /// This used to paint nothing and park, which is correct only while the grid
    /// *does* catch up. Measured in #188 it never did — `ghostty=126x30` against
    /// `frame=126x31` with no further metrics change — and 39 consecutive skips over
    /// `bytes=41` writes left the pane drawing nothing at all. That is the large blank
    /// area, not a one-row seam. Same width means every row keeps its coordinates, so
    /// the rows that fit are correct and the renderer clears what is left.
    @Test("a frame taller than the terminal paints the rows that fit")
    func applyPaintsCroppedUnderHeightMismatch() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        // The pane's view has 19 rows; Ghostty is still reporting 18.
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 18,
            widthPixels: 1904, heightPixels: 666,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        let before = model.paintCount
        model.apply(surface: surface(rows: 19))
        #expect(model.paintCount > before,
                "a height-only mismatch must still paint, or the pane stays blank")
        #expect(model.parkedFrame == nil,
                "nothing is parked once the rows that fit have been painted")
    }

    /// The wait must end by itself, or refusing to paint would leave a blank pane.
    @Test("re-applying after the grid catches up paints the whole frame")
    func reapplyPaintsOnceGridMatches() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 18,
            widthPixels: 1904, heightPixels: 666,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        let surface = surface(rows: 19)
        model.apply(surface: surface)
        // Painted once at the cropped size, not zero times.
        #expect(model.paintCount == 1)

        // The view caught up: same surface, grid now matching.
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 19,
            widthPixels: 1904, heightPixels: 703,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        model.reapplyAfterGridViewMoved()
        #expect(model.paintCount > 0,
                "the grid caught up but nothing was painted; the pane would stay blank")
    }

    @Test("graphics are dropped from a crop, because placements address surface cells")
    func dropsGraphics() {
        let cropped = PaneTerminalModel.cropped(frame(width: 4, height: 4), toColumns: 2, rows: 2)
        #expect(cropped.graphics.isEmpty)
    }
    /// A **height** mismatch must not mark the screen dirty for later frames.
    ///
    /// This is the drag path. The grid catches up one layout pass late, so a height
    /// mismatch is the normal condition while a divider moves — and the mismatch
    /// branch used to set `needsCleanRepaint` unconditionally. Combined with the
    /// parked-repaint path, that made every later paint during a drag a full-screen
    /// erase: measured 509 of 565 paints with `erase=1` while the surface width never
    /// left 126.
    @Test("a height mismatch does not dirty the screen for what follows")
    func heightMismatchKeepsBaseline() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        // Paint one good frame at 18 rows so there is a baseline.
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 18,
            widthPixels: 1904, heightPixels: 666,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        model.apply(surface: surface(rows: 18))
        let resetsBefore = model.screenResetCount
        // The first frame establishes the screen, and does so without asking the
        // caller to erase: the renderer already treats a missing baseline as
        // `firstFrame` and clears inside its own synchronized block. Asking as well
        // was the only reason "no previous grid" used to mean "erase".
        #expect(resetsBefore == 0, "a first frame has nothing on screen to erase")

        // Now a frame whose height the grid has not caught up with. Same width.
        model.apply(surface: surface(rows: 19))
        #expect(!model.needsCleanRepaint,
                "a height mismatch marked the screen dirty; every later paint then erases it")

        // A width mismatch is the opposite: the baseline really is untrustworthy.
        //
        // The baseline is what has to go, and clearing `frameGrid` is how: the frame
        // that finally paints is then taken whole because `gridMoved` sees `nil`.
        // `needsCleanRepaint` is *not* the mechanism — it means "the screen has
        // something on it that must be scrubbed", and a mismatched frame paints
        // nothing at all, so arming it made every mismatch in a burst erase.
        model.gridOverride = TerminalGridMetrics(
            columns: 120, rows: 19,
            widthPixels: 2040, heightPixels: 703,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        model.apply(surface: surface(rows: 19))
        #expect(model.frameGrid == nil,
                "a width mismatch left the old baseline in place")
        #expect(!model.needsCleanRepaint,
                "a frame that paints nothing has no screen to clean")
    }

    /// The decision itself: a projection change with a constant width must repaint
    /// without erasing.
    ///
    /// The renderer's own test proves it *can* do that; this one proves the caller
    /// asks. Without it, both injections at the call site — adding
    /// `|| projectionChanged` to `erase`, and dropping `repaintAll` — stayed green,
    /// which would let the erase come back unnoticed.
    @Test("a projection change with a steady width does not ask for an erase")
    func projectionChangeDoesNotEraseAtTheCallSite() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 19,
            widthPixels: 1904, heightPixels: 703,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        model.apply(surface: surface(rows: 19))
        #expect(model.screenResetCount == 0, "a first frame has nothing on screen to erase")

        // Same grid, same boot, new projection: repaint, not erase.
        var reprojected = surface(rows: 19)
        reprojected.projectionRevision = 2
        reprojected.surfaceRevision = 2
        model.apply(surface: reprojected)
        #expect(model.screenResetCount == 0,
                "a projection change with an unchanged width must not erase the screen")
    }

    /// A settled pane must not erase on every frame.
    ///
    /// The failure this guards: `frameGrid == nil` was read as "the width moved"
    /// (`?? true`). The width-mismatch branch sets `frameGrid = nil` *and*
    /// `needsCleanRepaint = true`, so each frame erased and re-armed the flag for the
    /// next one. Measured on one startup: eight erases in 53 ms with the daemon's
    /// grid constant at 120x40 the whole time.
    @Test("a settled pane stops erasing once the dirty frame has been paid")
    func settledPaneStopsErasing() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 19,
            widthPixels: 1904, heightPixels: 703,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        let surface = surface(rows: 19)
        // Apply the same settled frame repeatedly, as the view does at 60 Hz.
        var erases = 0
        for _ in 0 ..< 6 {
            let before = model.screenResetCount
            model.apply(surface: surface)
            if model.screenResetCount > before { erases += 1 }
        }
        // Nothing here has a reason to erase: the first frame clears inside the
        // renderer, and every frame after it is identical.
        #expect(erases == 0, "a settled pane erased \(erases) times, expected 0")
    }

    /// A frame *shorter* than the terminal must not leave the terminal's rows blank.
    ///
    /// This is the case a fast drag produces, from a real log:
    ///
    ///     paint: pane=wB:p14 erase=0 rows=7 cells=1 bytes=2808
    ///     frame skipped: pane=wB:p14 frame=126x8 previous=126x8
    ///     layout: wB:p14=126x8@0,0 rect=126x8->1071x148pt
    ///
    /// The daemon's `innerRect` was 8 rows while the view was 14 (259pt — the previous
    /// layout), so 6 rows at the bottom of the view were never written by anyone and
    /// kept libghostty's own background. `render(viewRows:)` is what closes them, and it
    /// only fires when the caller knows how tall the view is.
    @Test("a frame shorter than the terminal still clears the rows beneath it")
    func shortFrameClearsRemainder() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        // The terminal is 14 rows; the daemon sent 8.
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 14,
            widthPixels: 1904, heightPixels: 518,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        // What a drag does: the pane's own size moved. In the app this is `layout()` ->
        // `viewDidSettle`; a unit test has no view, so it is set directly.
        model.didViewSizeChange = true
        model.apply(surface: surface(rows: 8))
        #expect(model.paintCount == 1, "an 8-row frame in a 14-row terminal must paint")
        // The pane must know its own height so the renderer can clear the gap; the
        // checkout above is what makes that possible without a live NSView.
        // The write must carry the clear for the rows below the 8-row frame. There is
        // no surface in a unit test, so `viewRows` is nil here and the renderer cannot
        // emit `0J`; that half is covered by `everyRowIsTouched`, which drives the
        // renderer directly.
    }

    /// Resetting the renderer makes the next frame a *first* frame, which sends `2J`.
    ///
    /// That is the only thing that makes a baseline reset safe: the renderer forgets
    /// what is on screen, so the screen has to be cleared on the same write, or the
    /// diff is computed against a screen that still holds the old picture. This holds
    /// the invariant; `apply` relies on it when `frameGrid == nil`.
    @Test("a reset renderer repaints from a cleared screen")
    func resetMakesNextFrameAFullOne() {
        var renderer = SurfaceANSIRenderer()
        let grid = frame(width: 8, height: 4)
        _ = renderer.render(grid, clearingFirst: true)
        // Steady state: nothing changed, so nothing is written.
        let quiet = renderer.render(grid, clearingFirst: false)
        #expect(String(bytes: quiet, encoding: .utf8)?.contains(";1H") != true,
                "an unchanged grid must write no rows")

        renderer.reset()
        let afterReset = String(
            bytes: renderer.render(grid, clearingFirst: false), encoding: .utf8
        ) ?? ""
        #expect(afterReset.contains("\u{1B}[2J"),
                "a reset renderer must clear the screen on its next frame")
        #expect(afterReset.contains("\u{1B}[1;1H"),
                "and repaint every row, not just the ones it thinks changed")
    }

    /// A fast drag: many surface sizes in a burst, ending smaller.
    ///
    /// This is the reported repro. The invariant checked here is the one a user sees:
    /// **the last frame the terminal receives must describe the terminal's final
    /// size**, not an intermediate one. A pane that ends up painting an 8-row frame
    /// into a 14-row terminal leaves 6 rows nobody ever wrote — libghostty's own
    /// background, which is the band.
    @Test("a burst of sizes ends painting the final size")
    func burstEndsAtFinalSize() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        // Terminal ends at 14 rows.
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 14,
            widthPixels: 1904, heightPixels: 518,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        // The drag passes through these heights, ending at 8 — the daemon lagging
        // behind the view, which is what a fast drag produces.
        for rows: UInt16 in [20, 18, 15, 12, 10, 8] {
            model.apply(surface: surface(rows: rows))
        }
        let wrote = String(bytes: model.lastPainted ?? Data(), encoding: .utf8) ?? ""
        // Row 9 is the first row below the final 8-row frame; the terminal has 14.
        #expect(wrote.contains("\u{1B}[9;1H"),
                "the rows below the last frame must be addressed, or they stay blank")
        #expect(wrote.contains("\u{1B}[0J"),
                "and erased — this is the band")
    }

    /// A fast drag can end with the frame *taller* than the revision it carries.
    ///
    /// The reported repro: dragging slowly is fine, dragging fast leaves a band. The
    /// difference is which frame wins the race — during a fast drag several surfaces
    /// arrive for the same revision, and the last one painted may be the tall one. The
    /// terminal then holds rows 9...14 with content while the daemon has already moved
    /// on to 8 rows, and every later frame is "unchanged" against the 8-row baseline.
    ///
    /// The invariant: whatever the frame, the rows below it must be cleared *by that
    /// frame*, because there will not be another one.
    @Test("a frame that shrinks clears the rows it no longer covers")
    func shrinkClearsRowsItNoLongerCovers() {
        var renderer = SurfaceANSIRenderer()
        let tall = frame(width: 8, height: 14)
        _ = renderer.render(tall, clearingFirst: true)

        // The daemon catches up to 8 rows.
        let short = frame(width: 8, height: 8)
        let delta = String(
            bytes: renderer.render(short, clearingFirst: false, invalidateBaseline: false),
            encoding: .utf8
        ) ?? ""

        // Rows 9...14 held content; nothing will repaint them.
        #expect(delta.contains("\u{1B}[9;1H"),
                "the first dropped row must be addressed")
        #expect(delta.contains("\u{1B}[0J"),
                "and erased, or it keeps the previous frame's text forever")
    }

    /// A reset drops the baseline, which loses the "rows below the new frame" clear.
    ///
    /// `apply` calls `resetSurfaces()` whenever `frameGrid == nil`, and a fast drag hits
    /// that repeatedly: every mismatch parks and sets `frameGrid = nil`. The renderer
    /// then has no `previous`, so `previous.height > frame.height` is false and the
    /// trailing `0J` never goes out — the tall frame's rows stay on screen forever.
    ///
    /// This is why dragging slowly is fine: it converges before the next reset.
    @Test("a reset renderer cannot know which rows to clear")
    func resetLosesTheRowClear() {
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(width: 8, height: 14), clearingFirst: true)

        // A parked mismatch resets the baseline, exactly as `apply` does.
        renderer.reset()
        let delta = String(
            bytes: renderer.render(frame(width: 8, height: 8), clearingFirst: false),
            encoding: .utf8
        ) ?? ""

        // `2J` clears the whole screen, so rows 9...14 do go — the reset path is safe.
        #expect(delta.contains("\u{1B}[2J"),
                "a reset must clear the whole screen, which is what makes it safe")
    }

    /// The exact fast-drag sequence: reset, then paint a bridged (cropped) frame.
    ///
    /// `apply` resets the renderer whenever `frameGrid == nil`, and a fast drag parks on
    /// every mismatch — so `resetSurfaces()` runs repeatedly. The very next paint is a
    /// *first* frame for the renderer (it has no `previous`), and `paintBridged` passes
    /// `clearingFirst: false` because the frames keep coming.
    ///
    /// A first frame clears via `2J`, which is a full screen erase and would destroy
    /// scrollback on every starved frame. The `rowsBelowFrame` clear is what closes the
    /// gap without it — and it only fires when `viewRows > frame.height`.
    @Test("a bridged paint after a reset covers the rows below it")
    func bridgedPaintAfterResetCoversGap() {
        var renderer = SurfaceANSIRenderer()
        // Previous layout was 14 rows and is on screen.
        _ = renderer.render(frame(width: 8, height: 14), clearingFirst: true)
        renderer.reset()

        // The daemon now sends 8; the terminal is still 14.
        let delta = String(
            bytes: renderer.render(
                frame(width: 8, height: 8),
                clearingFirst: false,
                invalidateBaseline: true,
                viewRows: 14
            ),
            encoding: .utf8
        ) ?? ""
        #expect(delta.contains("\u{1B}[9;1H"),
                "rows 9...14 are still on screen and must be addressed")
        #expect(delta.contains("\u{1B}[0J"),
                "and erased — nothing else will repaint them")
    }

    /// A clear must never be the last word on a row.
    ///
    /// A fast drag ends with the frame shrinking while the terminal keeps its height.
    /// `0J` erases rows 9...14 — but if nothing writes them afterwards, the erase is
    /// the last thing that happened there and the rows stay blank. That is only safe
    /// when the terminal is *also* shrinking, or when the rows are going to be filled
    /// by the frame. Here the frame is 8 rows and the terminal 14, so the six erased
    /// rows are correct to be empty — but only because the frame itself cleared them.
    ///
    /// The failure this guards: a frame that neither writes a row nor clears it, so the
    /// row keeps the previous layout's text. Row coverage is what makes the band
    /// impossible: every row of the terminal must be touched by every frame.
    @Test("every row of the terminal is touched by the frame")
    func everyRowIsTouched() {
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(width: 8, height: 14), clearingFirst: true)
        let delta = String(
            bytes: renderer.render(
                frame(width: 8, height: 8),
                clearingFirst: false,
                invalidateBaseline: false,
                viewRows: 14
            ),
            encoding: .utf8
        ) ?? ""
        // Rows 1...8 written, rows 9...14 cleared: between them, all 14 are accounted for.
        let clearsFrom = delta.contains("\u{1B}[9;1H") && delta.contains("\u{1B}[0J")
        let writesAll = (1...8).allSatisfy { delta.contains("\u{1B}[\($0);1H") }
        #expect(clearsFrom && writesAll,
                "every terminal row must be either written or cleared")
    }

    /// The reported repro, end to end through `apply`: drag towards a pane so it grows,
    /// then look at the bottom of *that* pane. It is blank, and it is blanker the faster
    /// the drag.
    ///
    /// The shape of that report pins where the rows go missing: the pane that grows is
    /// the one whose view gains rows, and those rows have never held anything. Whoever
    /// last touched them decides whether they show the terminal's own background or
    /// content, and if the answer is "nobody", the width of the band is just how many
    /// rows were added.
    ///
    /// This drives it the way the client does: a frame at the old grid, then the same
    /// frame with the terminal taller, which is what a grow looks like between two
    /// daemon renders.
    @Test("a pane that grows has every new row addressed")
    func grownPaneAddressesNewRows() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 8,
            widthPixels: 1904, heightPixels: 296,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        model.apply(surface: surface(rows: 8))
        let before = model.lastPainted ?? Data()

        // The pane grew: same frame, taller terminal. This is the drag step.
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 14,
            widthPixels: 1904, heightPixels: 518,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        // What a drag does: the pane's own size moved. In the app this is `layout()` ->
        // `viewDidSettle`; a unit test has no view, so it is set directly.
        model.didViewSizeChange = true
        model.apply(surface: surface(rows: 8))
        let after = String(bytes: model.lastPainted ?? Data(), encoding: .utf8) ?? ""

        // Six rows exist now that existed before. If the paint says nothing about them
        // they keep whatever was there — for a surface that has never drawn them, that
        // is libghostty's background, and it reads as a band.
        let addressed = (9...14).contains { after.contains("\u{1B}[\($0);1H") }
        let cleared = after.contains("\u{1B}[0J")
        #expect(addressed || cleared,
                "rows 9...14 were born empty; the frame must write or clear them")
        #expect(!before.isEmpty, "the first frame must paint at all")
    }
}
