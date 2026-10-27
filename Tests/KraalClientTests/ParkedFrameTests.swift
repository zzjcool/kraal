// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for the pane that opened blank.
//
// The bug: launching the app showed an empty terminal. Switching to another tab
// and back made the content appear. That looked like a rendering fault, but it
// was a scheduling one.
//
// `PaneTerminalModel.apply(surface:)` refuses to paint a frame whose grid does
// not match Ghostty's current grid — writing it anyway would wrap every row at
// the wrong width and push the overflow into scrollback. In that case the frame
// is parked in `pendingFrame` and the method returns. The parked frame was only
// ever painted again from `onChange(of: model.state.surfaceSize)`, i.e. on a
// *subsequent* grid change.
//
// Launch produces a burst of grid changes while the window settles (109x36 →
// 119x40 → 127x43 → 117x40). The frame that arrived with the last of them was
// parked, and because the grid then stopped changing, no `onChange` ever fired
// again. The frame sat in `pendingFrame` forever. Switching tabs rebuilt the
// view, `onAppear` ran once more against a grid that now matched, and the
// content appeared — which is exactly the symptom the user described.
//
// The fix is `schedulePendingRetry()`: parking a frame now also starts a bounded
// retry chain, so the park has a wakeup that does not depend on someone else
// producing another grid change.

import CoreGraphics
import Testing

import GhosttyTerminal

@testable import KraalTerminalView

@Suite("Parked frame retry")
@MainActor
struct ParkedFrameRetryTests {
    /// The retry window has to outlast the settling burst but stay short enough
    /// that a genuinely stuck pane is not holding a frame indefinitely.
    ///
    /// Pinned because it is the whole fix: too few attempts and the last grid
    /// change still loses its frame, too many and a pane whose grid never matches
    /// keeps repainting into the wrong width.
    @Test("the retry budget spans the window-settling burst")
    func retryBudgetCoversSettling() {
        // 12 attempts at 80 ms is about a second, which is how long the launch
        // grid burst takes in the logs (109→119→127→117 over ~300 ms) plus
        // slack for a slow first attach.
        #expect(PaneTerminalModel.pendingRetryAttempts == 12)
        #expect(PaneTerminalModel.pendingRetryIntervalMilliseconds == 80)
        let span = Double(PaneTerminalModel.pendingRetryAttempts)
            * Double(PaneTerminalModel.pendingRetryIntervalMilliseconds)
        #expect(span >= 800, "retry window too short to outlast the settling burst")
        #expect(span <= 2000, "retry window long enough to fight a real mismatch")
    }

    /// A frame is only paintable when the grid agrees with it. This is the
    /// predicate `flushPendingFrame` guards on, and the reason a parked frame
    /// must not be written early.
    @Test("a frame is paintable only at its own grid")
    func paintableOnlyAtMatchingGrid() {
        #expect(PaneTerminalModel.gridMatches(
            frameWidth: 117, frameHeight: 40,
            gridColumns: 117, gridRows: 40
        ))
        #expect(!PaneTerminalModel.gridMatches(
            frameWidth: 117, frameHeight: 40,
            gridColumns: 127, gridRows: 43
        ))
    }

    /// The rule `flushPendingFrame` uses: **exact**, and the live trace that says
    /// why it cannot be "at least".
    ///
    /// A previous revision allowed a grid larger than the frame, reasoning that a
    /// frame whose cells all land on real coordinates cannot be wrong and that
    /// waiting was only costing latency. Both halves of that are wrong, and a real
    /// session shows it:
    ///
    /// ```
    /// [18:00:09.786] grid mismatch: pane=wB:p16 ghostty=126x14 frame=126x13
    /// ```
    ///
    /// The pane's view was 13 rows (240.5 pt); Ghostty still reported 14. `14 >= 13`
    /// let a 13-row frame be written into a 14-row screen. The last row kept
    /// whatever the previous layout left there — the band at the bottom of the pane
    /// that would not go away — and because `frameGrid` was then set to the frame,
    /// nothing repainted it. Wait instead: one more layout pass and the grid
    /// arrives at 13, at which point the frame is exact.
    @Test("a parked frame paints only at the exact grid it was composed for")
    func parkedFramePaintsOnlyAtExactGrid() {
        // The ordinary case.
        #expect(PaneTerminalModel.parkedFrameFits(
            frameWidth: 124, frameHeight: 30, gridColumns: 124, gridRows: 30
        ))
        // The live failure. One row more must keep waiting, not paint.
        #expect(!PaneTerminalModel.parkedFrameFits(
            frameWidth: 126, frameHeight: 13, gridColumns: 126, gridRows: 14
        ))
        #expect(!PaneTerminalModel.parkedFrameFits(
            frameWidth: 124, frameHeight: 30, gridColumns: 124, gridRows: 31
        ))
        // Too small: every row would wrap.
        #expect(!PaneTerminalModel.parkedFrameFits(
            frameWidth: 124, frameHeight: 30, gridColumns: 124, gridRows: 29
        ))
        #expect(!PaneTerminalModel.parkedFrameFits(
            frameWidth: 124, frameHeight: 30, gridColumns: 123, gridRows: 30
        ))
    }

    /// The grid has to be re-derived from the view, because the reported one can
    /// freeze.
    ///
    /// The live numbers this is written against: a pane settled at `832.5 pt` with a
    /// `37 px` cell, so exactly 45 rows, while `surfaceSize` still said 36 and never
    /// moved again. `apply` refused every frame that needed 45, and the pane kept the
    /// rows the last good paint left behind.
    @Test("a view's own pixels decide the grid, not the last reported size")
    func gridDerivedFromViewPixels() {
        let cell = TerminalGridMetrics(
            columns: 126, rows: 36,
            widthPixels: 2142, heightPixels: 1332,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        // 832.5 pt at 2x is 1665 px, and 1665 / 37 is 45 exactly.
        let settled = PaneTerminalModel.grid(
            forViewPixelsWide: 2142, high: 1665, cell: cell
        )
        #expect(settled?.columns == 126)
        #expect(settled?.rows == 45,
                "the view is 45 rows tall; reporting 36 is what left the pane blank")

        // A view too small for one cell is unusable, not a zero-size grid.
        #expect(PaneTerminalModel.grid(
            forViewPixelsWide: 2142, high: 10, cell: cell
        ) == nil)
        // Degenerate cell metrics are what the caller must not divide by.
        let empty = TerminalGridMetrics(
            columns: 0, rows: 0, widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 0, cellHeightPixels: 0
        )
        #expect(PaneTerminalModel.grid(
            forViewPixelsWide: 2142, high: 1665, cell: empty
        ) == nil)
    }

}
