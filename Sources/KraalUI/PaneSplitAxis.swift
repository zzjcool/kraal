// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Split by axis rather than by view, so the drag arithmetic is testable without
// a window. Split out of `PaneLayoutView.swift`, which had grown past swiftlint's
// file length limit — the limit is what noticed that a pure value type was
// living inside a view.

import CoreGraphics
import KraalProtocol

/// Which way a split divider moves.
///
/// The daemon names a split after the divider *line*, and the drag axis is
/// perpendicular to that name. The two names therefore read backwards to anyone
/// thinking about where the panes go, and that is the whole bug this type exists
/// to make explicit:
///
/// * `.vertical` — a vertical line — leaves panes stacked top to bottom, which
///   the UI offers as "Split Down". The divider moves **up and down**.
/// * `.horizontal` — a horizontal line — leaves panes side by side, offered as
///   "Split Right". The divider moves **left and right**.
///
/// Verified against a live daemon: a `direction: down` split came back as
/// `.vertical` with a 120×2 hit rect in a 120×40 area (a wide, thin, horizontal
/// strip), and its `position` tracked the row axis.
public enum PaneSplitAxis: Sendable {
    /// The divider moves along Y; the resize cursor is the up-down arrows.
    case verticalDrag
    /// The divider moves along X; the resize cursor is the left-right arrows.
    case horizontalDrag

    public init(_ direction: PaneSurfaceSplitDirection) {
        switch direction {
        case .vertical: self = .verticalDrag
        case .horizontal: self = .horizontalDrag
        }
    }

    public var direction: PaneSurfaceSplitDirection {
        switch self {
        case .verticalDrag: .vertical
        case .horizontalDrag: .horizontal
        }
    }

    /// Converts a drag in points into the ratio the daemon expects.
    ///
    /// `DragGesture` reports **points**; the daemon's `position` and `area` are
    /// **cells**. Going straight from one to the other is the mistake that made the
    /// divider leap to an edge: the old conversion multiplied by
    /// `surface.height / grid.height`, and those are the same number by
    /// construction, so a 40-point drag counted as 40 rows — 0.89 of a 45-row
    /// surface, straight into the 0.9 clamp.
    ///
    /// Lives on the axis type because "which way does this move" and "in what unit"
    /// are the same question: each axis divides by the cell extent along itself.
    ///
    /// A zero cell size is possible (Ghostty reports 0 before its first frame), and
    /// must not divide by zero; treating one point as one cell is wrong but bounded,
    /// since the result is clamped anyway.
    public func ratio(
        position: UInt16,
        area: SurfaceRect,
        dragPoints: CGSize,
        cellSize: CGSize
    ) -> Double {
        let cellsWide = cellSize.width > 0 ? cellSize.width : 1
        let cellsHigh = cellSize.height > 0 ? cellSize.height : 1
        let translatedX = dragPoints.width / cellsWide
        let translatedY = dragPoints.height / cellsHigh
        // `.vertical` names a horizontal divider line between stacked panes, so it
        // moves along Y; `.horizontal` is a vertical line, so it moves along X.
        let base: Double
        let span: Double
        switch self {
        case .verticalDrag:
            base = Double(position) - Double(area.originY) + Double(translatedY)
            span = Double(max(area.height, 1))
        case .horizontalDrag:
            base = Double(position) - Double(area.originX) + Double(translatedX)
            span = Double(max(area.width, 1))
        }
        return min(max(base / span, 0.1), 0.9)
    }
}
