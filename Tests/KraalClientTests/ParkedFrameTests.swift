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
}
