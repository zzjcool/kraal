// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  PaneFrameHitTestingTests.swift
//  KraalClientTests
//
//  A zero-size pane rectangle must never be stored.
//
//  The mouse monitor answers "which pane is under the pointer" with
//  `paneViewFrames.first { $0.value.contains(point) }`. `CGRect.contains` is false for
//  every point in an empty rect, so one `0x0` report permanently removes that pane
//  from hit testing — and the event is then handed to Ghostty, which raises its own
//  system menu instead of the pane menu.
//
//  Measured on a live session: one pane reported `1020x740` → `986x2423` → `0x0`, and
//  after the `0x0` a right-click produced the system Copy/AutoFill menu.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Pane frames are usable for hit testing")
struct PaneFrameHitTestingTests {
    @Test("a real rectangle is usable")
    func realRectangleIsUsable() {
        #expect(PaneFrameMath.isUsableForHitTesting(
            CGRect(x: 221, y: 71, width: 986, height: 2423)
        ))
    }

    /// The one that was measured: SwiftUI reporting a view being torn down.
    @Test("a zero rectangle is not usable")
    func zeroRectangleIsNotUsable() {
        #expect(!PaneFrameMath.isUsableForHitTesting(
            CGRect(x: 221, y: 71, width: 0, height: 0)
        ))
    }

    /// A collapsed axis alone is enough: a split divider dragged to the edge leaves
    /// one dimension at zero, and that pane is equally unhittable.
    @Test("a collapsed axis is not usable")
    func collapsedAxisIsNotUsable() {
        #expect(!PaneFrameMath.isUsableForHitTesting(
            CGRect(x: 0, y: 0, width: 500, height: 0)
        ))
        #expect(!PaneFrameMath.isUsableForHitTesting(
            CGRect(x: 0, y: 0, width: 0, height: 500)
        ))
    }

    /// The point of the guard: an empty rect swallows no hits at all, so keeping the
    /// last real one is what keeps the pane reachable.
    @Test("an empty rectangle matches nothing")
    func emptyRectangleMatchesNothing() {
        let empty = CGRect(x: 221, y: 71, width: 0, height: 0)
        #expect(!empty.contains(CGPoint(x: 221, y: 71)))
        #expect(!empty.contains(CGPoint(x: 700, y: 900)))
    }
}
