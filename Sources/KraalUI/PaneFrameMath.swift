// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import CoreGraphics

/// The arithmetic behind a pane's hit-testing rectangle.
///
/// Kept apart from the reporter because getting it wrong is silent: the mouse
/// monitor simply stops matching panes, with no error anywhere. Two concrete
/// mistakes it guards against are stacking the pane offset twice (once in the
/// SwiftUI host, once in the conversion) and leaving the origin at the bottom
/// while the surface grid counts from the top.
public enum PaneFrameMath {
    /// Rounds a point size up to a whole device pixel.
    ///
    /// Ghostty derives its grid by floor-dividing the view's pixel size by the
    /// cell's pixel size, so a pane measuring a fraction of a pixel under
    /// `cells * cellSize` silently loses a whole row and column — and every cell
    /// drawn in that pane, along with the cursor and the selection, lands one
    /// cell off. Since the loss is identical in every pane it reads as a global
    /// misalignment rather than a sizing bug.
    public static func pixelSnapped(
        _ points: CGFloat,
        scale: CGFloat = SurfaceGeometry.backingScale
    ) -> CGFloat {
        (points * scale).rounded(.up) / scale
    }
    /// A point in the content view's own space, converted to this app's pane
    /// coordinate space (top-left origin), given whether that view is flipped.
    ///
    /// Exists because the inverse of this was wrong for months in a way nobody
    /// could see from the outside: a wheel event over the top pane scrolled the
    /// bottom one, 100% of the time (issue #88). The content view is an
    /// `NSHostingView`, whose `isFlipped` is `true`, so `convert(_:from:)` already
    /// answers top-down — and the reader subtracted from `bounds.height` anyway,
    /// inverting a point that was already inverted.
    ///
    /// Kept as a function of `isFlipped` rather than hard-coded to `true`, because
    /// a future container (or a test) can legitimately be either, and the branch is
    /// the thing worth stating: *flipped means no arithmetic*.
    public static func contentPoint(
        _ point: CGPoint, contentHeight: CGFloat, isFlipped: Bool
    ) -> CGPoint {
        isFlipped ? point : CGPoint(x: point.x, y: contentHeight - point.y)
    }

    /// A pane's rectangle in content-view coordinates, top-left origin.
    ///
    /// `container` is in AppKit coordinates (origin bottom-left) and `pane` is in
    /// SwiftUI coordinates *inside* that container (origin top-left). Mixing the
    /// two was the bug: `contentHeight - (container.minY + pane.maxY)` subtracts a
    /// top-down pane offset from a bottom-up container offset, so the result is
    /// wrong by an amount that depends on where the container sits — every pane
    /// in the window shifted by the same constant, which reads as a global offset
    /// rather than a per-pane one. The old tests missed it because they put the
    /// container at y = 0, where the two conventions happen to coincide.
    ///
    /// The fix is to convert the container to top-down first, then add the pane's
    /// own top-down offset. Both operands are then measured from the same edge.
    /// Whether a reported rectangle is usable for hit testing.
    ///
    /// A pane view reports its own frame, and SwiftUI reports `0x0` while it is
    /// tearing a view down or before it has been laid out. Storing that would replace
    /// a good rectangle with an empty one, and `CGRect.contains` never matches an
    /// empty rect — so every click in that pane would afterwards be handed to Ghostty
    /// instead of raising the pane menu (issue: right-click on an SSH pane produced
    /// the system Copy/AutoFill menu).
    public static func isUsableForHitTesting(_ rect: CGRect) -> Bool {
        rect.width > 0 && rect.height > 0
    }

    /// `isFlipped` says whether the container rectangle already counts from the top.
    ///
    /// Measured 2026-10-30: the content view here is an `NSHostingView`, whose
    /// `isFlipped` is `true`, so `contentView.convert(bounds, from: self)` already answers
    /// top-down — and subtracting from `contentHeight` inverted it a *second* time. Every
    /// pane's hit rectangle came out 46 pt too high on a split window, which meant the
    /// y this app hands the daemon for `pane.mouse` was 46 pt too large: a TUI was told
    /// the pointer was on row 3 when it was on row 1, and the bottom of a pane stopped
    /// responding to clicks at all. This is the same double inversion as issue #88, still
    /// present one function over.
    public static func rect(
        container: CGRect,
        pane: CGRect,
        contentHeight: CGFloat,
        isFlipped: Bool = false
    ) -> CGRect {
        let containerTop = isFlipped
            ? container.minY
            : contentHeight - (container.minY + container.height)
        return CGRect(
            x: container.minX + pane.minX,
            y: containerTop + pane.minY,
            width: pane.width,
            height: pane.height
        )
    }
}
