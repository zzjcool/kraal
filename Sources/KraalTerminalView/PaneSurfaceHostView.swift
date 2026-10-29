// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import GhosttyTerminal

/// The terminal view a pane takes its size from.
///
/// Two things were wrong with reading the size anywhere else, and both produced the
/// same symptom — a band of libghostty's own background under a pane that had drawn its
/// rows correctly.
///
/// **One: SwiftUI's proposal is a pass ahead.** Measured on a settled drag, every entry
/// read `terminal == super1` while both trailed the allocation by one step:
///
///     allocated=148.0  terminal=74.0   super1=74.0
///     allocated=203.5  terminal=148.0  super1=148.0
///
/// **Two: `surfaceSize` is one pass behind `bounds` even here.** Measured:
///
///     settled: p14 size=148.0pt view=126x14 terminal=126x14
///
/// 148pt is 8 rows at 18.5pt, and 14 rows is 259pt — the *previous* layout. Both numbers
/// agreed only because both were reading the same stale field.
///
/// So `layout()` runs `fitToSize()` itself before reporting: after it, the surface's
/// grid describes these bounds rather than the ones before them.
///
/// (A third suspect — the engine's own `IOSurfaceLayer` keeping an old frame after a
/// resize — was tested with a real engine and ruled out: across 540 samples of a fast
/// resize, no sublayer ever disagreed with the view's bounds. The band was a write-ordering
/// problem; see `EngineScreenReport`.)
final class PaneSurfaceHostView: AppTerminalView {
    /// Called after the view's bounds settle **and** its grid matches them.
    var onSettledSize: ((CGSize) -> Void)?

    private var lastReported: CGSize?

    override var intrinsicContentSize: NSSize {
        // Never let AppKit invent a size: the pane's allocation is the only input.
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // Sub-point noise is not a resize. AppKit calls `layout()` for reasons that have
        // nothing to do with size (focus, appearance), and forwarding those would
        // repaint on every keystroke.
        if let last = lastReported,
           abs(last.width - size.width) <= 0.5, abs(last.height - size.height) <= 0.5 {
            return
        }
        lastReported = size
        // Re-fit now, then report: without the fit the grid read by the callback still
        // describes the previous bounds.
        fitToSize()
        onSettledSize?(size)
    }
}
