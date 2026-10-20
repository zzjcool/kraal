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
