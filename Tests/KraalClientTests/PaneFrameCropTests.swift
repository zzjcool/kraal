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
    @Test("a mismatched grid paints nothing and parks the frame")
    func applyDeclinesToPaintUnderMismatch() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        // The pane's view has 19 rows; Ghostty is still reporting 18.
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 18,
            widthPixels: 1904, heightPixels: 666,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        let before = model.paintCount
        model.apply(surface: surface(rows: 19))
        #expect(model.paintCount == before,
                "a mismatch painted the intersection; the rows past it keep the old layout")
        // The full frame is parked, so the grid catching up repaints it all.
        #expect(model.parkedFrame?.height == 19)
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
        #expect(model.paintCount == 0)

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
        #expect(resetsBefore >= 1, "the first frame has nothing to diff against")

        // Now a frame whose height the grid has not caught up with. Same width.
        model.apply(surface: surface(rows: 19))
        #expect(!model.needsCleanRepaint,
                "a height mismatch marked the screen dirty; every later paint then erases it")

        // A width mismatch is the opposite: the baseline really is untrustworthy.
        model.gridOverride = TerminalGridMetrics(
            columns: 120, rows: 19,
            widthPixels: 2040, heightPixels: 703,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        model.apply(surface: surface(rows: 19))
        #expect(model.needsCleanRepaint,
                "a width mismatch left the old baseline in place")
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
        #expect(model.screenResetCount == 1, "the first frame has no baseline to trust")

        // Same grid, same boot, new projection: repaint, not erase.
        var reprojected = surface(rows: 19)
        reprojected.projectionRevision = 2
        reprojected.surfaceRevision = 2
        model.apply(surface: reprojected)
        #expect(model.screenResetCount == 1,
                "a projection change with an unchanged width must not erase the screen")
    }

}
