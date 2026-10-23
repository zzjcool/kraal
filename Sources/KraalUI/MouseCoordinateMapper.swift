// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Mouse input.
//
// Ghostty renders the pane but cannot tell whether the program inside wants
// mouse events: its terminal state comes from the cell grid we feed it, which
// carries no mouse-mode information. The daemon does know, and reports it per
// pane as `PaneSurfacePane.mouseReporting` / `sgrPixelMouse`. So mouse events are
// translated here — window point → cell coordinate → semantic event — and the
// decision to forward at all is made by `AppStore` from that flag.
//
// Coordinates are pane-relative cells, which is what `ClientMousePosition.cell`
// expects; a pane's `innerRect` origin is subtracted so a right-hand split never
// reports absolute tab coordinates.

import AppKit
import KraalProtocol
import SwiftUI

/// Converts a view-space point into a pane-relative cell coordinate.
public struct MouseCoordinateMapper: Sendable {
    public var innerRect: SurfaceRect
    public var viewSize: CGSize
    public var gridWidth: UInt16
    public var gridHeight: UInt16

    public init(
        innerRect: SurfaceRect,
        viewSize: CGSize,
        gridWidth: UInt16,
        gridHeight: UInt16
    ) {
        self.innerRect = innerRect
        self.viewSize = viewSize
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
    }

    /// Cell offset inside the pane, clamped to its content area.
    public func cell(for point: CGPoint) -> (column: UInt16, row: UInt16) {
        let columns = max(Int(innerRect.width), 1)
        let rows = max(Int(innerRect.height), 1)
        let cellWidth = viewSize.width / CGFloat(columns)
        let cellHeight = viewSize.height / CGFloat(rows)
        let column = Int(point.x / max(cellWidth, 1))
        let row = Int(point.y / max(cellHeight, 1))
        return (
            UInt16(min(max(column, 0), columns - 1)),
            UInt16(min(max(row, 0), rows - 1))
        )
    }

    /// Pixel offset inside the pane, for `sgrPixelMouse` panes.
    public func pixels(for point: CGPoint) -> (x: UInt32, y: UInt32) {
        (
            UInt32(max(min(point.x, viewSize.width), 0)),
            UInt32(max(min(point.y, viewSize.height), 0))
        )
    }
}

/// Which modifier bits the wire wants for the current event.
public enum MouseModifiers {
    public static func bits(from flags: NSEvent.ModifierFlags) -> UInt8 {
        var result: UInt8 = 0
        if flags.contains(.shift) { result |= InputModifiers.shift.rawValue }
        if flags.contains(.control) { result |= InputModifiers.control.rawValue }
        if flags.contains(.option) { result |= InputModifiers.alt.rawValue }
        if flags.contains(.command) { result |= InputModifiers.super.rawValue }
        return result
    }
}

/// Translates AppKit mouse events for one pane into semantic events.
///
/// Not main-actor isolated: these are pure coordinate conversions over value
/// types, and keeping them isolation-free lets the geometry be unit tested.
public enum PaneMouse {
    public static func position(
        for point: CGPoint,
        mapper: MouseCoordinateMapper,
        precision: Bool
    ) -> ClientMousePosition {
        let cell = mapper.cell(for: point)
        guard precision else {
            return .cell(column: cell.column, row: cell.row)
        }
        let pixels = mapper.pixels(for: point)
        return .pixels(
            pixelX: pixels.x,
            pixelY: pixels.y,
            column: cell.column,
            row: cell.row
        )
    }

    /// Scroll amount as whole lines, keeping the sub-line remainder out of the
    /// wire: the protocol counts lines.
    public static func scrollLines(from delta: CGFloat) -> UInt16 {
        UInt16(max(1, min(Int(abs(delta).rounded()), 20)))
    }

    /// Where a scroll gesture should move the pane's viewport.
    ///
    /// The pane's scrollback lives in the daemon, not in Ghostty: the renderer
    /// paints a fixed screen with absolute cursor addressing and never emits a
    /// newline, so the local terminal never accumulates history to scroll through
    /// (measured — see `docs/DEBUGGING.md`). A wheel event therefore has to become
    /// a `pane.scroll` request carrying an absolute offset, not a mouse report.
    public enum ScrollTarget {
        /// The offset to ask the daemon for, clamped to what exists.
        ///
        /// `offsetFromBottom` is where the viewport is now, `lines` is how far the
        /// gesture moved (positive scrolls up). Clamping matters: overshooting the
        /// top would make the daemon jump to the end of its history, so a fast
        /// flick past the start would land somewhere unrelated.
        public static func offset(
            current: UInt64,
            lines: Int,
            maxOffset: UInt64
        ) -> UInt64 {
            let moved = Int64(current) + Int64(lines)
            guard moved > 0 else { return 0 }
            return min(UInt64(moved), maxOffset)
        }

        /// Whether a scroll is worth sending at all.
        ///
        /// A pane with one screenful of output has no history, and asking the
        /// daemon to stay at offset 0 is a round trip that changes nothing.
        public static func shouldSend(current: UInt64, lines: Int, maxOffset: UInt64) -> Bool {
            guard maxOffset > 0, lines != 0 else { return false }
            return offset(current: current, lines: lines, maxOffset: maxOffset) != current
        }
    }

    /// Whether a pointer movement is a drag or just the wobble inside a click.
    ///
    /// macOS emits `leftMouseDragged` for a movement of a single point, and a
    /// trackpad produces one on almost every click. Forwarding those made a click
    /// arrive at the program as press → drag → drag → release, which a TUI reads as
    /// a drag and ignores — the "clicking the TUI does nothing" half of issue #95.
    ///
    /// Pure so the threshold can be tested without an event loop; the caller keeps
    /// the per-pane origin.
    public struct PressTracking: Sendable {
        /// One cell's smaller dimension, in points. A third of a cell is still a
        /// wobble; a whole cell is deliberate.
        public let threshold: CGFloat

        public init(cellSize: CGFloat) {
            // A floor of two points: at tiny cell sizes rounding would otherwise
            // classify a stationary click as a drag.
            threshold = max(cellSize, 2)
        }

        /// True when the pointer moved far enough from where the button went down.
        public func isDrag(from origin: CGPoint, to point: CGPoint) -> Bool {
            hypot(point.x - origin.x, point.y - origin.y) >= threshold
        }
    }

    /// Turns a stream of trackpad deltas into whole lines to scroll.
    ///
    /// A trackpad emits one event per frame, each a point or two, so rounding
    /// every event up to a line makes a three-line flick scroll thirty — the
    /// complaint that started this. The remainder is carried instead, the way
    /// Ghostty's own `pending_scroll_y` does for its local scrollback.
    public struct ScrollAccumulator: Sendable {
        private var pending: CGFloat = 0
        /// Height of one cell in points; the divisor that makes pixels into rows.
        public let cellHeight: CGFloat

        public init(cellHeight: CGFloat) {
            self.cellHeight = max(cellHeight, 1)
        }

        /// Signed whole lines covered by this delta; zero means "not yet a row".
        public mutating func lines(for delta: CGFloat) -> Int {
            guard delta.isFinite, delta != 0 else { return 0 }
            pending += delta
            // Toward zero so a partial row keeps its sign instead of being lost.
            let whole = (pending / cellHeight).rounded(.towardZero)
            guard whole != 0 else { return 0 }
            pending -= whole * cellHeight
            return Int(whole)
        }

        public mutating func reset() {
            pending = 0
        }
    }
}
