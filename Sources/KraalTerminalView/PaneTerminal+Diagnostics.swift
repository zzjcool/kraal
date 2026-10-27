// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import GhosttyTerminal
import KraalProtocol
import KraalUI

/// Diagnostics for a frame that does not fit the grid Ghostty derived.
///
/// Kept out of `PaneTerminal.swift` only because that file is at its length
/// budget; the reasoning for what is logged lives with the code below.
extension PaneTerminalModel {
    /// Records a grid that disagrees with the frame the daemon sent.
    ///
    /// `ghostty=WxH` alone cannot say *why* it disagreed: "one row short" is what a
    /// view half a point too small produces (Ghostty floors `pixels / cellPixels`,
    /// so it drops the partial row), and it is also what a stale grid shows before
    /// it has re-measured. Those need opposite fixes, and only the pixel numbers
    /// distinguish them — so they are logged next to the rows. `cell=0x0` means
    /// `surfaceSize` carried no usable metric, which is a third case.
    func logGridMismatch(
        grid: TerminalGridMetrics,
        frame: FrameData,
        surface: PaneSurfaceFrame
    ) {
        let all = surface.panes.map {
            "\($0.paneId)=\($0.innerRect.width)x\($0.innerRect.height)"
        }
        let cellHeight = grid.cellHeightPixels
        let measured = "\(grid.widthPixels)x\(grid.heightPixels)px"
            + " cell=\(grid.cellWidthPixels)x\(cellHeight)"
            + " fits=\(cellHeight > 0 ? Int(grid.heightPixels / cellHeight) : -1)"
        kraalLog("grid mismatch: pane=\(paneId) ghostty=\(grid.columns)x\(grid.rows) "
            + "frame=\(frame.width)x\(frame.height) "
            + "\(measured) "
            + "surface=\(surface.frame.width)x\(surface.frame.height) "
            + "panes=[\(all.joined(separator: " "))]")
    }

    /// Records that a parked frame was thrown away because its grid never matched.
    ///
    /// This is the difference between "the band went away on its own" and "the band
    /// was never repainted". A park lives 12 attempts x 80 ms; when it expires, the
    /// frame that would have covered the missing row is gone and only a later daemon
    /// revision repaints it — which on a still screen can be seconds. The user
    /// reports exactly that ("it fixes itself after a while"), so without this line
    /// the two causes are indistinguishable from the outside.
    func logParkExpired(paneId: String, frame: FrameData, grid: TerminalGridMetrics?) {
        let gridText = grid.map { "\($0.columns)x\($0.rows)" } ?? "nil"
        kraalLog("park expired: pane=\(paneId) frame=\(frame.width)x\(frame.height) "
            + "grid=\(gridText) after=\(Self.pendingRetryAttempts)")
    }

    /// Whether a parked frame can be written to a grid of this size.
    ///
    /// Equal is the ordinary case. A grid *larger* than the frame is also safe:
    /// every cell the frame has a coordinate for lands where it belongs, and the
    /// rows beyond it cannot be addressed anyway. Only a grid too *small* would
    /// wrap the rows that do not fit, so that one keeps waiting.
    ///
    /// Requiring exact equality here was a real defect rather than a conservative
    /// choice. Ghostty derives its grid from the NSView's `bounds`, which SwiftUI
    /// applies one layout pass after the frame that asked for it — so while a
    /// window is dragged the two stay one pass apart and equality never holds.
    /// The park then aged out after `pendingRetryAttempts`, and the row the
    /// mismatch left blank survived until the program next printed. Measured on
    /// a live session: at `17:19:26.473` Ghostty still reported the `26.318`
    /// layout (29 rows) while the frame was the `26.471` one (30 rows).
    static func parkedFrameFits(
        frameWidth: Int, frameHeight: Int,
        gridColumns: UInt16, gridRows: UInt16
    ) -> Bool {
        gridColumns >= frameWidth && gridRows >= frameHeight
    }

    /// Re-runs `apply` for the most recent surface once the terminal's grid has
    /// moved.
    ///
    /// This is the other half of "do not paint at a grid that does not match".
    /// Ghostty measures its grid from the NSView's `bounds`, and SwiftUI applies a
    /// new layout one pass after the frame that caused it — so `apply` routinely
    /// runs against the *previous* size and declines to paint. Something has to
    /// paint once the view has caught up, and this is that something: it re-applies
    /// the same surface against the grid that now exists.
    ///
    /// Without it, refusing to paint at a stale grid would leave the pane blank
    /// until the program next produced output.
    func reapplyAfterGridViewMoved() {
        guard let surface = lastSurface else { return }
        apply(surface: surface)
    }

    func reportCellMetrics() {
        guard let grid = state.surfaceSize,
              grid.cellWidthPixels > 0,
              grid.cellHeightPixels > 0 else { return }
        onCellMetrics?(CGSize(
            width: CGFloat(grid.cellWidthPixels),
            height: CGFloat(grid.cellHeightPixels)
        ))
    }
}
