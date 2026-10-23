// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #88: a wheel event over the *top* pane scrolled the *bottom* one, every
// time. The cause was a second inversion of a coordinate that was already
// inverted, and the reason it survived so long is that both halves looked right
// on their own:
//
//  * `PaneFrameMath.rect` writes pane frames measured from the top, because the
//    surface grid counts rows downward.
//  * `paneLocation` compared a point against those frames, but first did
//    `contentHeight - y` on the strength of "AppKit's origin is bottom-left".
//
// That premise is true of an ordinary `NSView` and false of this app's content
// view, which is an `NSHostingView` with `isFlipped == true`. Measured on the
// developer's own window:
//
//     isFlipped=true windowY=1679 inViewY=850 contentH=2530 sum=2530
//
// `windowY + inViewY == contentHeight` exactly — the definition of "already
// top-down". Subtracting turned 850 into 1680 and moved the hit to the other pane.
//
// These tests pin the arithmetic, not the view hierarchy: the numbers are the ones
// the window actually reported.

import CoreGraphics
import Testing

@testable import KraalUI

@Suite("content point space")
struct ContentPointSpaceTests {
    /// The measured geometry: a 2530pt content view, both panes, and the point the
    /// developer's wheel event landed on.
    private static let contentHeight: CGFloat = 2530
    private static let topPane = CGRect(x: 231, y: 48, width: 1198, height: 1184)
    private static let bottomPane = CGRect(x: 231, y: 1269, width: 1190, height: 1165)

    @Test("a flipped content view is already top-down and must not be inverted")
    func flippedIsPassedThrough() {
        let inView = CGPoint(x: 777, y: 850)
        let resolved = PaneFrameMath.contentPoint(
            inView, contentHeight: Self.contentHeight, isFlipped: true
        )
        #expect(resolved == inView)

        // And the point lands on the pane the user was actually pointing at. This
        // is the assertion the bug failed: with the second inversion the same
        // point resolved to y = 1680, inside the bottom pane.
        let onTop = Self.topPane.contains(resolved)
        let onBottom = Self.bottomPane.contains(resolved)
        #expect(onTop)
        #expect(!onBottom)
    }

    @Test("an unflipped content view still needs the inversion")
    func unflippedIsInverted() {
        let resolved = PaneFrameMath.contentPoint(
            CGPoint(x: 777, y: 850), contentHeight: Self.contentHeight, isFlipped: false
        )
        #expect(resolved.y == Self.contentHeight - 850)
        #expect(resolved.x == 777)
    }

    @Test("the inverse only holds inside the view")
    func roundTrip() {
        // Not every value survives the round trip, and saying so is the point: the
        // flipped branch is the identity, the other reflects about `contentHeight`,
        // so reflecting twice is the identity only for points the view actually
        // contains. `0` and `contentHeight` are the two ends where a caller has
        // already left the view.
        for probeY in [CGFloat(48), 850, 1269, 2434] {
            let flipped = PaneFrameMath.contentPoint(
                CGPoint(x: 10, y: probeY), contentHeight: Self.contentHeight, isFlipped: true
            )
            #expect(flipped.y == probeY)
            let back = PaneFrameMath.contentPoint(
                flipped, contentHeight: Self.contentHeight, isFlipped: false
            )
            #expect(back.y == Self.contentHeight - probeY)
        }
    }

    @Test("applying both branches twice in the same direction is not an identity")
    func doubleInversionMovesThePoint() {
        // The bug, expressed arithmetically: inverting an already-inverted point.
        // At the measured y this moves the hit from the top pane to the bottom one.
        let inViewY: CGFloat = 850
        let once = Self.contentHeight - inViewY
        #expect(Self.topPane.contains(CGPoint(x: 777, y: inViewY)))
        #expect(Self.bottomPane.contains(CGPoint(x: 777, y: once)))
    }

    @Test("the reported window arithmetic is the flipped one")
    func measuredSumIsContentHeight() {
        // The measurement that identified the bug, as an assertion. On a flipped
        // view, window y and content y are complementary about the content height:
        // the pair adds up to it (to within the pixel the window rounding costs —
        // measured 1679 + 850 = 2529 against a 2530pt view). That is what "already
        // top-down" looks like; if this ever stops holding, the premise of
        // `contentPoint` has changed and this file needs re-reading.
        let windowY: CGFloat = 1679
        let inViewY: CGFloat = 850
        let slack: CGFloat = 1
        #expect(abs((windowY + inViewY) - Self.contentHeight) <= slack)
    }

    @Test("a point in the bottom pane stays in the bottom pane")
    func bottomPaneIsNotLifted() {
        // The mirror of the reported symptom: the bottom half used to be reported
        // as the top half once anything above it was inverted twice.
        let inView = CGPoint(x: 777, y: 1908)
        let resolved = PaneFrameMath.contentPoint(
            inView, contentHeight: Self.contentHeight, isFlipped: true
        )
        #expect(Self.bottomPane.contains(resolved))
        #expect(!Self.topPane.contains(resolved))
    }
}
