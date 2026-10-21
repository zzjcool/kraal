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

    /// Turns a stream of trackpad deltas into wheel notches, the way Ghostty
    /// does it.
    ///
    /// A trackpad emits a scroll event per frame, not per notch: a light flick is
    /// dozens of events carrying 1–3 pixels each. Rounding every one of them up
    /// to a whole line turns 60 events of 2px into 60 lines when the gesture only
    /// moved three — the page tears past. Rounding down instead loses the gesture
    /// entirely.
    ///
    /// So the remainder is carried: pixels accumulate until they cover a cell,
    /// only then does a notch go out and the remainder stay behind for the next
    /// frame. That is `Surface.zig`'s `pending_scroll_y`, and matching it is what
    /// makes scrolling feel the same as it does in Ghostty standalone.
    ///
    /// `lines` cannot carry the amount here. For a pane that reports the mouse,
    /// the daemon ignores `lines` and emits exactly one wheel sequence per event
    /// (`pane_input.rs` → `apply_scroll` → `WheelRouting::MouseReport`), so a
    /// larger count would change nothing and only the *number* of events scrolls
    /// the program. Accumulating before sending is the only lever that works.
    public struct ScrollAccumulator: Sendable {
        /// Pixels moved but not yet converted into a notch.
        private var pending: CGFloat = 0
        /// Pixel height of one cell; the divisor that turns pixels into rows.
        public let cellHeight: CGFloat

        public init(cellHeight: CGFloat) {
            // A zero or negative height would divide to infinity and emit a notch
            // on every event, which is the bug this type exists to prevent.
            self.cellHeight = max(cellHeight, 1)
        }

        /// Feeds one event's delta and returns how many notches to send, signed
        /// the way a wheel is (positive = up).
        ///
        /// Returned as `Int` rather than `UInt16` because the sign is the
        /// direction; the caller turns it into a kind plus a count.
        public mutating func notches(for delta: CGFloat) -> Int {
            guard delta.isFinite, delta != 0 else { return 0 }
            pending += delta
            // Truncate toward zero so a partial cell keeps its sign and is not
            // thrown away: a slow drag downward must not be banked as upward.
            let whole = (pending / cellHeight).rounded(.towardZero)
            guard whole != 0 else { return 0 }
            pending -= whole * cellHeight
            return Int(whole)
        }

        /// Drops any banked remainder, for when the gesture ends or the pane
        /// changes: a leftover from one direction must not offset the next.
        public mutating func reset() {
            pending = 0
        }
    }
}
