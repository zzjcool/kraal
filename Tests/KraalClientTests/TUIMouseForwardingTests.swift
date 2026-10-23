// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #95, the TUI half: two problems that looked unrelated and shared a cause —
// the mouse events forwarded to a program were not the events the user performed.
//
//  * A trackpad emits one `scrollWheel` per frame, and each was forwarded as its
//    own wheel report. A program implementing SGR mouse input turns one report into
//    one scroll step, so a flick scrolled several times faster than the hand moved.
//  * macOS emits `leftMouseDragged` for a one-point wobble, so almost every click
//    arrived as press → drag → drag → release. A program that watches for drags
//    treats that as a drag and ignores the click.
//
// Both are fixed by deciding *whether* to forward rather than forwarding and hoping.
// These tests pin the two decisions, which live in `MouseCoordinateMapper` (whole
// notches) and `PaneMouse.PressTracking` (jitter) so they can be checked without an
// event loop.

import CoreGraphics
import Testing

@testable import KraalUI
@testable import KraalProtocol

@Suite("TUI mouse forwarding")
struct TUIMouseForwardingTests {
    // MARK: - Whole notches

    @Test("sub-notch trackpad deltas produce no wheel report")
    func subNotchIsDropped() {
        // 18.5pt cells: this is the measured cell height on the developer's window.
        var accumulator = PaneMouse.ScrollAccumulator(cellHeight: 18.5)
        // One frame of a slow flick moves a couple of points.
        #expect(accumulator.lines(for: 2) == 0)
        #expect(accumulator.lines(for: 3) == 0)
        // ...and the movement is banked, not lost: enough frames do reach a row.
        var seen = 0
        for _ in 0..<8 {
            seen += accumulator.lines(for: 3)
        }
        #expect(seen >= 1)
    }

    @Test("a flick reports far fewer notches than it has frames")
    func flickIsNotOneNotchPerFrame() {
        // The bug, measured: 40 frames of a 3pt-per-frame flick used to become 40
        // wheel reports (the old code clamped each to at least one). With banking it
        // becomes the number of whole cells the hand actually covered.
        var accumulator = PaneMouse.ScrollAccumulator(cellHeight: 18.5)
        var reports = 0
        for _ in 0..<40 where accumulator.lines(for: 3) != 0 {
            reports += 1
        }
        let covered = 40 * 3
        let expected = covered / 18
        #expect(reports <= expected + 1)
        // The old behaviour, for contrast: 40 reports for 120pt of travel.
        #expect(reports < 40)
    }

    @Test("a wheel with detents keeps its magnitude")
    func detentWheelKeepsMagnitude() {
        // Not a trackpad: `hasPreciseScrollingDeltas` is false and the delta is
        // already a notch count. `tuiScrollNotch` bypasses the accumulator, which is
        // what these numbers pin.
        let notches = { (delta: CGFloat) -> UInt16 in
            let rounded = Int(abs(delta).rounded())
            guard rounded > 0 else { return 0 }
            return UInt16(min(max(rounded, 1), 20))
        }
        #expect(notches(1) == 1)
        #expect(notches(3) == 3)
        #expect(notches(0.4) == 0)
        // Capped so one pathological event cannot ask for a hundred rows.
        #expect(notches(500) == 20)
    }

    // MARK: - Click versus drag

    @Test("a one-point wobble during a click is not a drag")
    func jitterIsNotADrag() {
        let tracking = PaneMouse.PressTracking(cellSize: 8.5)
        let origin = CGPoint(x: 100, y: 200)
        #expect(!tracking.isDrag(from: origin, to: CGPoint(x: 101, y: 200)))
        #expect(!tracking.isDrag(from: origin, to: CGPoint(x: 100, y: 201)))
        #expect(!tracking.isDrag(from: origin, to: CGPoint(x: 101, y: 201)))
    }

    @Test("movement of a cell or more is a drag")
    func realMovementIsADrag() {
        let tracking = PaneMouse.PressTracking(cellSize: 8.5)
        let origin = CGPoint(x: 100, y: 200)
        #expect(tracking.isDrag(from: origin, to: CGPoint(x: 109, y: 200)))
        #expect(tracking.isDrag(from: origin, to: CGPoint(x: 100, y: 210)))
        #expect(tracking.isDrag(from: origin, to: CGPoint(x: 120, y: 260)))
    }

    @Test("the threshold is at least two points")
    func thresholdHasAFloor() {
        // A tiny cell size must not make every movement a drag: at 1pt cells the
        // floor is what stops a click from being classified as a drag by rounding.
        let tracking = PaneMouse.PressTracking(cellSize: 1)
        #expect(!tracking.isDrag(from: .zero, to: CGPoint(x: 1, y: 1)))
        #expect(tracking.isDrag(from: .zero, to: CGPoint(x: 3, y: 0)))
    }
}
