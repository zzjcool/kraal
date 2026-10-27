// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for window-resize repainting.
//
// The bug: dragging a window changed the grid the daemon rendered at, the view
// was handed the new surface, and the pane stayed frozen at the old size. Two
// separate causes, both covered here.
//
//  1. A reconnect — which is how this client changes surface size — restarts the
//     daemon's `surfaceRevision` counter at 1. Keying the repaint trigger on that
//     revision alone means a resize that lands on a revision already on screen
//     produces no change at all.
//  2. The frame carrying the new size arrives while Ghostty still reports the
//     *old* grid. The old code dropped that frame and relied on a later
//     revision to repaint, but revisions only advance when the program prints, so
//     a still screen stayed wrong forever.
//
// These tests exercise the decision functions rather than the SwiftUI view, since
// the view cannot be driven without a window.

import CoreGraphics
import Foundation
import Testing

import KraalProtocol
import KraalUI
@testable import KraalTerminalView

@Suite("Resize repaint")
struct ResizeRepaintTests {
    /// A frame whose grid changed must repaint even when the content revision did
    /// not. This is the split-to-full-width case and the resize case alike.
    @Test("grid change alone forces a repaint")
    func gridChangeForcesRepaint() {
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: (width: 119, height: 40),
            currentGrid: (width: 111, height: 35)
        )
        #expect(needs)
    }

    /// Both dimensions narrow on a shrink and both widen on a grow; a check that
    /// only compared columns would miss a pure vertical resize.
    @Test("rows-only change still forces a repaint")
    func rowChangeForcesRepaint() {
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: (width: 111, height: 40),
            currentGrid: (width: 111, height: 35)
        )
        #expect(needs)
    }

    /// The same grid with the same revision is the hot path: patches stream in
    /// constantly, and repainting the whole frame each time would defeat the
    /// delta renderer.
    @Test("unchanged grid and revision skips the repaint")
    func unchangedGridSkipsRepaint() {
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: (width: 111, height: 35),
            currentGrid: (width: 111, height: 35)
        )
        #expect(!needs)
    }

    /// The first frame of a pane has no previous grid and must always paint.
    @Test("first frame always repaints")
    func firstFrameRepaints() {
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: nil,
            currentGrid: (width: 111, height: 35)
        )
        #expect(needs)
    }

    /// A resize reconnects, and the new projection renumbers from 1. Treating that
    /// as a restarted delta stream is what makes `apply` wipe the screen and take
    /// the frame whole instead of patching a baseline that no longer exists.
    @Test("revision going backwards is a restarted stream")
    func revisionRestartIsDetected() {
        #expect(SurfaceGeometry.deltaStreamRestarted(previousRevision: 3, incomingRevision: 1))
    }

    /// Monotonic revisions inside one projection must not be mistaken for a
    /// restart, or every patch would trigger a full clear.
    @Test("increasing revision is not a restart")
    func increasingRevisionIsNotRestart() {
        #expect(!SurfaceGeometry.deltaStreamRestarted(previousRevision: 1, incomingRevision: 2))
    }

    /// The specific sequence the bug produced: a pane that had reached revision 3
    /// reconnects, and the first surface of the new connection is revision 1. The
    /// revision differs here, but the *grid* is what has to drive the repaint,
    /// because a second resize can bring the revision back to a value already
    /// painted.
    @Test("resize after reconnect repaints on grid, not revision")
    func resizeAfterReconnectUsesGrid() {
        // Before the resize: rendered at 119x40, revision 3.
        var lastPaintedGrid: (width: Int, height: Int)? = (width: 119, height: 40)
        let lastRevision = 3

        // After the resize: the daemon re-rendered at 111x35 and renumbered to 1.
        let incomingRevision = 1
        let newGrid = (width: 111, height: 35)

        let revisionChanged = incomingRevision != lastRevision
        #expect(revisionChanged, "the reconnect itself renumbers")

        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: revisionChanged,
            previousGrid: lastPaintedGrid,
            currentGrid: newGrid
        )
        #expect(needs)

        // And the same decision with the revision coincidentally equal, which is
        // the case a revision-only trigger silently dropped.
        let sameRevision = 3
        let stillNeeds = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: sameRevision != lastRevision,
            previousGrid: lastPaintedGrid,
            currentGrid: newGrid
        )
        #expect(stillNeeds, "grid change must repaint even when the revision matches")

        lastPaintedGrid = newGrid
        #expect(lastPaintedGrid?.width == 111)
    }

    /// Scrolling changes the cells without touching the revision or the grid.
    ///
    /// This is the case that made the scrollbar move while the terminal picture
    /// stayed frozen: `pane.scroll` renders a different viewport into `cells`, but
    /// it is a view operation and never bumps `content_seq`, so `contentRevision`
    /// came back identical and the grid did not change either. Both cheap reasons
    /// for a repaint said no, and the frame — which *did* differ — was dropped.
    ///
    /// Measured in the VM before the fix:
    /// `probe: rev=66 last=66 sameCells=false off=30/166`.
    @Test("scrolling repaints even though the revision and grid are unchanged")
    func scrollRepaints() {
        let grid = (width: 98, height: 35)
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: grid,
            currentGrid: grid,
            cellsDiffer: true
        )
        #expect(needs, "the viewport moved, so the cells must be painted")

        // And the same inputs without a cell change stay a no-op: this is a cursor
        // blink or a repeated frame, and repainting it would waste the whole grid.
        let quiet = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: grid,
            currentGrid: grid,
            cellsDiffer: false
        )
        #expect(!quiet)
    }

    /// `cellsDiffer` must not be consulted when a cheap reason already decided.
    ///
    /// Comparing every cell is the expensive part of the decision, and a frame that
    /// prints something determines the answer without it. Proven by passing a
    /// closure that fails the test if it ever runs.
    @Test("a repaint decided by the revision never compares cells")
    func revisionShortCircuitsCellComparison() {
        var compared = false
        let needs = SurfaceGeometry.needsRepaint(
            contentRevisionChanged: true,
            previousGrid: (width: 98, height: 35),
            currentGrid: (width: 98, height: 35),
            cellsDiffer: {
                compared = true
                return true
            }()
        )
        #expect(needs)
        #expect(!compared, "the cell comparison is the expensive fallback, not a default")
    }

    /// Cells are computed from the pane's point size, so a bigger pane must ask
    /// for more cells. This is what makes the resize visible to the daemon.
    @Test("a larger pane area asks for more cells")
    func largerAreaAsksForMoreCells() {
        let cell = CGSize(width: 17, height: 37)
        let small = SurfaceGeometry.cells(for: CGSize(width: 943, height: 647), cellSize: cell, scale: 2)
        let large = SurfaceGeometry.cells(for: CGSize(width: 1400, height: 900), cellSize: cell, scale: 2)
        #expect(large.cols > small.cols)
        #expect(large.rows > small.rows)
    }

    /// A grid negotiated against one cell size must not survive a cell-size
    /// change just because the container grew to fit it.
    ///
    /// This is the feedback loop that left panes running past the right edge of
    /// the window. Launch negotiates the first grid against fallback metrics
    /// (15.6x34pt); when Ghostty reports the real ones (17x37pt) the same 128
    /// columns are suddenly wider than the window. The panes overflow, the
    /// container is measured as the overflowed width, and measuring that width
    /// asks for those same 128 columns — the container confirming its own size
    /// back to itself, so nothing ever pulls it back.
    ///
    /// The numbers below are from a real run: a 1004pt window, fallback metrics
    /// giving 128 columns, and the inflated 1088pt width those columns measure.
    @Test("a grid too wide for the window is not confirmed by the overflow it caused")
    func overwideGridConvergesInsteadOfHolding() {
        let fallback = CGSize(width: 15.6, height: 34)
        let real = CGSize(width: 17, height: 37)
        let windowWidth: CGFloat = 1004

        let first = SurfaceGeometry.cells(
            for: CGSize(width: windowWidth, height: 742),
            cellSize: fallback,
            scale: 2
        )
        #expect(first.cols == 128)

        // What those 128 columns measure at the real cell size: wider than the
        // window, which is the overflow the container used to report back.
        let overflowedWidth = CGFloat(first.cols) * real.width / 2
        #expect(overflowedWidth > windowWidth)

        // Negotiating against the honest window width must come back down.
        let corrected = SurfaceGeometry.cells(
            for: CGSize(width: windowWidth, height: 742),
            cellSize: real,
            scale: 2
        )
        #expect(corrected.cols == 118)
        #expect(corrected.cols < first.cols)

        // And the corrected grid has to actually fit, or the loop comes back.
        #expect(CGFloat(corrected.cols) * real.width / 2 <= windowWidth)
    }

    /// Rounding down is deliberate: asking for one column more than fits is what
    /// makes every row wrap, which is the failure this geometry exists to avoid.
    @Test("cells round down so the grid always fits")
    func cellsRoundDown() {
        // 100 pt * 2 = 200 device px / 17 px per cell = 11.76 -> 11 columns.
        let size = SurfaceGeometry.cells(
            for: CGSize(width: 100, height: 100),
            cellSize: CGSize(width: 17, height: 37),
            scale: 2
        )
        #expect(size.cols == 11)
        // 200 / 37 = 5.4 -> 5 rows.
        #expect(size.rows == 5)
    }
}

@Suite("Resize stays on the live connection")
@MainActor
struct LiveResizeTests {
    /// The bug this pins down: `surfaceSize` had a `didSet` that scheduled a
    /// reconnect. A window drag changes the grid every frame, so the client spent
    /// the whole gesture re-handshaking and the panes never followed the window.
    /// Resizing is now a `client_shell_resize` on the existing connection, so the
    /// phase must not move at all.
    ///
    /// Asserted as "unchanged" rather than "still `.live`" because `phase` has an
    /// internal setter; moving it is the failure either way.
    @Test("changing the grid does not move the connection phase")
    func resizeDoesNotMovePhase() {
        let store = AppStore()
        let phaseBefore = store.phase

        store.surfaceSize = ClientSurfaceSize(cols: 100, rows: 30)

        #expect(store.phase == phaseBefore, "phase moved to \(store.phase)")
        #expect(store.lastError == nil)
    }

    /// A resize is not a failure, so it must not raise the error the UI renders.
    @Test("resizing does not report an error")
    func resizeDoesNotReportError() {
        let store = AppStore()
        let phaseBefore = store.phase

        store.resizeSurface(cols: 80, rows: 24)

        #expect(store.lastError == nil)
        #expect(store.phase == phaseBefore)
        #expect(store.surfaceSize == ClientSurfaceSize(cols: 80, rows: 24))
    }

    /// `resizeSurface` is the only writer, and it must not re-send a grid the
    /// daemon is already rendering: that would re-render a whole surface for
    /// nothing, on every layout pass.
    @Test("an unchanged grid is a no-op")
    func unchangedGridIsIgnored() {
        let store = AppStore()
        store.resizeSurface(cols: 80, rows: 24)
        let settled = store.surfaceSize

        store.resizeSurface(cols: 80, rows: 24)

        #expect(store.surfaceSize == settled)
    }

    /// Degenerate sizes must never reach the daemon: a zero-column surface is not
    /// something it can render.
    @Test("a zero grid is rejected")
    func zeroGridRejected() {
        let store = AppStore()
        let before = store.surfaceSize

        store.resizeSurface(cols: 0, rows: 24)
        store.resizeSurface(cols: 80, rows: 0)

        #expect(store.surfaceSize == before)
    }
}

@Suite("Screen reset scope")
struct ScreenResetScopeTests {
    /// Frames that differ only in the cursor are not a reason to erase anything.
    ///
    /// This is the flicker: pressing Return drops the cursor one row, the frames
    /// compare unequal, and the pane used to be cleared and fully repainted. The
    /// cells never changed, so a reset would do nothing but show a blank screen
    /// for a moment.
    @Test("a cursor-only move does not need a screen reset")
    func cursorOnlyMoveNeedsNoReset() {
        let needs = SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 111, height: 35),
            currentGrid: (width: 111, height: 35)
        )

        #expect(!needs)
    }

    /// New text inside an unchanged grid is a delta, not a reset. Every frame that
    /// prints anything differs from the last, so treating "cells differ" as a
    /// reason to erase would reset on every keystroke.
    @Test("changed cells in an unchanged grid do not need a screen reset")
    func cellsChangeNeedsNoReset() {
        let needs = SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 80, height: 24),
            currentGrid: (width: 80, height: 24)
        )

        #expect(!needs)
    }

    /// A **width** change must reset: rows written at the old width are still in
    /// the scrollback, and an incremental repaint only revisits rows that changed.
    @Test("a width change does need a screen reset")
    func widthChangeNeedsReset() {
        #expect(SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 119, height: 40),
            currentGrid: (width: 111, height: 35)
        ))
        // Same height, so a check that compared rows alone would miss it.
        #expect(SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 119, height: 40),
            currentGrid: (width: 111, height: 40)
        ))
    }

    /// A **height**-only change must not reset, and the renderer must still clear
    /// the rows the frame no longer covers.
    ///
    /// This is the drag path. A vertical divider produces one-row height changes at
    /// mouse speed, and treating each as a reset meant `2J 3J H` plus a full
    /// rewrite: measured on a live drag, 1139 of 1195 paints took that path at ~6 KB
    /// of ANSI each, up to 97 in a second. Correctness has to survive dropping the
    /// reset, so the clear is asserted here rather than assumed.
    @Test("a height-only change does not reset, but clears the rows it lost")
    func heightChangeClearsWithoutReset() {
        #expect(!SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 111, height: 40),
            currentGrid: (width: 111, height: 35)
        ))

        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(Self.blankFrame(columns: 8, rows: 40), clearingFirst: true)
        let bytes = renderer.render(Self.blankFrame(columns: 8, rows: 35), clearingFirst: false)
        let text = String(bytes: bytes, encoding: .utf8) ?? ""

        // Rows 36..40 are the ones that used to be content and are now nothing.
        // `0J` from the first row past the new height erases to the end of screen,
        // which covers all of them without a full-screen erase.
        #expect(text.contains("\u{1B}[36;1H"), "the rows below the new height were not cleared")
        #expect(text.contains("\u{1B}[0J"), "the clear was not an erase-to-end")
        #expect(!text.contains("\u{1B}[2J"), "a full-screen erase is what the drag could not afford")
        #expect(!text.contains("\u{1B}[3J"), "the scrollback must not be thrown away for a resize")
    }

    /// A restarted delta stream refers to a baseline that no longer exists, so it
    /// must reset even at the same grid.
    @Test("a restarted delta stream needs a screen reset")
    func restartedStreamNeedsReset() {
        #expect(SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: true,
            previousGrid: (width: 111, height: 35),
            currentGrid: (width: 111, height: 35)
        ))
    }

    /// Until a frame has been painted there is nothing incremental to paint onto.
    @Test("the first frame needs a screen reset")
    func firstFrameNeedsReset() {
        #expect(SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: nil,
            currentGrid: (width: 111, height: 35)
        ))
    }

    /// A refused patch now advances `surfaceRevision` while the cells stay put
    /// (issue #50 review). Every repaint decision must treat that frame as
    /// "nothing to paint" — not as a missed frame and not as a reset.
    ///
    /// The three decisions that a revision feeds, asserted together because they
    /// have to agree: `PaneTerminalModel.apply(surface:)` keys on the pane's own
    /// `contentRevision`, the grid and the cells (never the surface revision); the
    /// renderer's `changedRows` only runs when a render happens at all; and
    /// `needsRepaint` returns false. The cost that *is* real is one crop per pane and
    /// one popup repaint per claimed frame — those are re-run because the surface
    /// value changed, and they draw nothing new. Recorded here so a later change to
    /// any of the three cannot quietly turn a claimed revision into a repaint.
    @Test("an advanced surface revision with unchanged cells repaints nothing")
    func claimedRevisionPaintsNothing() {
        let grid = (width: 98, height: 35)
        // The pane's own contentRevision did not move: a refused patch carried no
        // new cells, so the daemon did not bump it either.
        #expect(!SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: grid,
            currentGrid: grid,
            cellsDiffer: false
        ), "a claimed revision made the pane repaint")

        // The projection cannot have changed: a refused patch never crosses one
        // (`handleSurfacePatch` drops foreign-projection patches before this point).
        // Explicitly typed rather than `.init(...)`: the parameter is optional, and a
        // discarded `Optional` context would make this assert against `nil` (which
        // `projectionChanged` treats as "first frame ever", i.e. always changed).
        let sameProjection = SurfaceGeometry.ProjectionIdentity(bootId: "boot-1", revision: 3)
        #expect(!SurfaceGeometry.projectionChanged(
            previous: sameProjection,
            current: sameProjection
        ), "a claimed revision was mistaken for a new projection")

        // And it is not a restarted delta stream, so nothing may wipe the screen.
        #expect(!SurfaceGeometry.deltaStreamRestarted(previousRevision: 7, incomingRevision: 7))
        #expect(!SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: grid,
            currentGrid: grid
        ), "a claimed revision triggered a screen reset")
    }

    /// The guard has to hold for the exact shape of a Return press: same grid,
    /// cursor one row lower. Pinned as a pair because the two answers together are
    /// what the fix is — reset only when the grid moves, and never when only the
    /// cursor does.
    @Test("a Return press is a cursor move, not a screen reset")
    func returnPressIsNotAReset() {
        let grid = (width: 111, height: 35)

        #expect(!SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: grid,
            currentGrid: grid
        ))
    }
    /// A frame of blank cells, sized exactly. Enough to drive the renderer: the
    /// assertions are about which escape sequences come out, not the glyphs.
    static func blankFrame(columns: UInt16, rows: UInt16) -> FrameData {
        let count = Int(columns) * Int(rows)
        let buffer = CellBuffer(Array(repeating: .blank, count: count), width: Int(columns))
        return FrameData(buffer: buffer, width: columns, height: rows,
                         cursor: nil, hyperlinks: [], graphics: Data())
    }

    /// Re-painting a parked frame must not erase the screen unless the width moved.
    ///
    /// This decision shipped broken: the caller cleared `frameGrid` and then asked
    /// whether it was nil, so the answer was always yes and every parked repaint was
    /// a full-screen erase. It read fine and every test passed, because nothing
    /// called it — the live log is what caught it, still showing 509 of 565 paints
    /// with `erase=1` while the surface width never left 126.
    @Test("a parked repaint erases only when the width moved")
    func parkedRepaintErasesOnlyOnWidthChange() {
        let wide = Self.blankFrame(columns: 126, rows: 26)
        let tall = Self.blankFrame(columns: 126, rows: 30)

        // Height-only: the rows are still at the right columns, so no erase.
        #expect(!PaneTerminalModel.widthMoved(from: wide, to: tall),
                "a height change erased the screen; that is the whole drag cost")
        // Width: every row reflows, so the screen has to go.
        #expect(PaneTerminalModel.widthMoved(
            from: Self.blankFrame(columns: 120, rows: 26),
            to: wide
        ))
        // No baseline at all: nothing on screen is trustworthy.
        #expect(PaneTerminalModel.widthMoved(from: nil, to: wide))
    }

    /// A grid change must reissue the cells even when the frame's own size is the
    /// same, and must **not** erase.
    ///
    /// The live failure: after a vertical drag settled, `paint:` logged `bytes=38`
    /// (cursor sequence, zero cells) every second for as long as it was observed.
    /// The pane's grid had moved, so the rows the cells belong to no longer matched
    /// what was on screen — but the frame was the same size as the previous one, so
    /// every row compared equal and nothing was written. The rows the pane stopped
    /// covering kept their old content: the blank area.
    @Test("a grid move reissues the cells without erasing")
    func gridMoveReissuesWithoutErase() {
        var renderer = SurfaceANSIRenderer()
        // Paint one frame at 20 rows.
        let first = renderer.render(Self.blankFrame(columns: 8, rows: 20), clearingFirst: true)
        #expect(!first.isEmpty)

        // Same 8x20 frame, but the grid moved, so the baseline is meaningless.
        let again = renderer.render(
            Self.blankFrame(columns: 8, rows: 20),
            clearingFirst: false,
            invalidateBaseline: true
        )
        let text = String(bytes: again, encoding: .utf8) ?? ""
        // Every row written again: `CSI <n>;1H` for each.
        #expect(text.contains("\u{1B}[1;1H"), "row 1 was not reissued")
        #expect(text.contains("\u{1B}[20;1H"), "the last row was not reissued")
        // And without the erase, which a vertical drag cannot afford per mouse move.
        #expect(!text.contains("\u{1B}[2J"), "a grid move must not throw the screen away")
        #expect(!text.contains("\u{1B}[3J"), "a grid move must not throw the scrollback away")
    }

    /// `gridMoved` is the predicate that feeds it.
    @Test("gridMoved sees a grid change the renderer cannot")
    func gridMovedDetectsGridChange() {
        let frame = Self.blankFrame(columns: 8, rows: 20)
        #expect(PaneTerminalModel.gridMoved(from: nil, to: frame))
        #expect(!PaneTerminalModel.gridMoved(from: frame, to: frame))
        #expect(PaneTerminalModel.gridMoved(
            from: Self.blankFrame(columns: 8, rows: 21), to: frame
        ))
    }

    /// `layoutSettled(size:)` must be driven by the size SwiftUI actually handed
    /// the view, and must ignore the no-op case.
    ///
    /// The bug: the repaint was triggered only by `onChange(of:
    /// state.surfaceSize)`. That field is the one this whole workaround exists
    /// because it goes **stale** — so once it stopped moving, the repaint stopped
    /// firing, and a pane that shrank kept its old contents under a blank band.
    /// The trigger was gated on the very signal that fails.
    @Test("layoutSettled only reacts to a real size change")
    @MainActor
    func layoutSettledIgnoresRepeats() {
        let model = PaneTerminalModel(paneId: "wB:p14") { _ in }
        #expect(model.lastLaidOutSize == nil)
        model.layoutSettled(size: CGSize(width: 1071, height: 777))
        #expect(model.lastLaidOutSize == CGSize(width: 1071, height: 777))
        // A second identical layout is not a reason to repaint.
        model.layoutSettled(size: CGSize(width: 1071, height: 777))
        #expect(model.lastLaidOutSize == CGSize(width: 1071, height: 777))
        // A degenerate proposal must not become the new baseline.
        model.layoutSettled(size: .zero)
        #expect(model.lastLaidOutSize == CGSize(width: 1071, height: 777))
        // A real change does move it.
        model.layoutSettled(size: CGSize(width: 1071, height: 129.5))
        #expect(model.lastLaidOutSize == CGSize(width: 1071, height: 129.5))
    }

    /// The first grid negotiation must not run on the fallback cell estimate.
    ///
    /// Measured on a live start, before this guard existed:
    ///
    ///     19:41:43.131  geometry: 120x40 -> 137x54      (fallback 7.8x17)
    ///     19:41:43.217  layout: grid=137x54  rect=1164pt  (container is 1071)
    ///     19:41:43.268  layout: grid=126x50  rect=1071pt  (real 8.5x18.5)
    ///
    /// 137 columns at 8.5 pt is 1164.5 pt: 93.5 pt of pane outside the window, and
    /// every transition is a new projection, so both panes were wiped and repainted
    /// twice before anything was touched.
    @Test("the fallback cell size is wider than the real font, so it cannot size a surface")
    func fallbackWouldOverflowTheContainer() {
        let container = CGSize(width: 1071, height: 930)
        let fallback = SurfaceGeometry.cells(
            for: container, cellSize: SurfaceGeometry.fallbackCellSize, scale: 2
        )
        let real = SurfaceGeometry.cells(
            for: container, cellSize: CGSize(width: 17, height: 37), scale: 2
        )
        // The fallback asks for the same grid the live log showed: 137x54.
        #expect(fallback.cols == 137)
        #expect(real.cols == 126)
        // And that grid does not fit: 137 columns of the real font measure more
        // than the container, which is the pane-outside-the-window symptom.
        #expect(CGFloat(fallback.cols) * 8.5 > container.width)
        #expect(CGFloat(real.cols) * 8.5 <= container.width)
    }

    /// The negotiation must refuse to release a grid computed from the fallback.
    @Test("a surface is not sized from the fallback cell estimate")
    @MainActor
    func negotiationWaitsForAMeasurement() {
        let store = AppStore()
        #expect(!store.hasMeasuredCellSize, "a fresh store has only the fallback")
        #expect(store.terminalCellSize == SurfaceGeometry.fallbackCellSize)
        // The first real measurement flips it, and asks for a re-evaluation.
        store.updateCellMetrics(CGSize(width: 17, height: 37))
        #expect(store.hasMeasuredCellSize)
        #expect(store.needsGeometryReeval)
        // A measurement that happens to land within the threshold still counts,
        // because it is what unblocks the negotiator.
        let second = AppStore()
        second.updateCellMetrics(CGSize(width: 17.1, height: 37.1))
        #expect(second.hasMeasuredCellSize)
    }

    /// A new projection must rewrite every row without throwing the screen away.
    ///
    /// Measured on a live start, twice, with the width constant the whole time:
    ///
    ///     [19:46:12.725] erase why: wB:p16 projection=true restart=false \
    ///                    widthMoved=false clean=false
    ///
    /// Both panes erased and repainted 6 KB for a projection change that needed only
    /// the rows rewritten. Erasing also drops scrollback, which is the part a user
    /// notices.
    @Test("a projection change repaints every row and does not erase")
    func projectionChangeRepaintsWithoutErasing() {
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(Self.blankFrame(columns: 8, rows: 20), clearingFirst: true)
        // Same grid, different projection: baseline worthless, scrollback fine.
        let repaint = renderer.render(
            Self.blankFrame(columns: 8, rows: 20),
            clearingFirst: false,
            invalidateBaseline: true
        )
        let text = String(bytes: repaint, encoding: .utf8) ?? ""
        // Every row written again.
        #expect(text.contains("\u{1B}[1;1H"), "row 1 was not reissued")
        #expect(text.contains("\u{1B}[20;1H"), "the last row was not reissued")
        // And the screen — hence the scrollback — survives.
        #expect(!text.contains("\u{1B}[2J"), "a projection change must not erase")
        #expect(!text.contains("\u{1B}[3J"), "a projection change must not drop scrollback")
    }

}
