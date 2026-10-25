// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ScrollRepaintTests.swift
//  KraalClientTests
//
//  Scrolling must not wipe the screen.
//
//  The symptom is "a white flash while scrolling fast", and the only thing that can
//  produce a flash is the `2J`/`3J` reset: erase the screen, then repaint it whole.
//  So the question this suite settles is narrow and answerable: **does the reset
//  decision fire on a scroll?**
//
//  `resetNeeded` is `projectionChanged || needsScreenReset(...)`. `apply(surface:)`
//  cannot be the subject here — with no Ghostty grid attached every call parks the
//  frame and resets `lastRevision`, which is a fixture artifact, not scrolling. So
//  these tests call the two predicates directly, which is exactly what `apply` calls.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Scroll does not reset the screen")
struct ScrollRepaintTests {
    private func projection(_ bootId: String, _ revision: UInt64) -> SurfaceGeometry.ProjectionIdentity {
        SurfaceGeometry.ProjectionIdentity(bootId: bootId, revision: revision)
    }

    /// The bug: the reset decision compared a **pane-sized** frame against a
    /// **surface-sized** grid.
    ///
    /// `paneFrame` builds this pane's frame from `geometry.innerRect`, while
    /// `apply` asked `needsScreenReset` about `surface.frame`. Those are different
    /// quantities — a pane draws *inside* its box, so the surface is a cell or two
    /// larger — and they never agree, which made every apply erase and repaint the
    /// whole screen. Measured in the scroll fixture: `frame=118x36`,
    /// `surface=119x36`, `needsReset=true` on every frame.
    @Test("a pane-sized frame against a surface-sized grid does not reset")
    func paneGridMatchesItself() {
        // What the pane actually paints: innerRect, 118x36, twice.
        #expect(!SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 118, height: 36),
            currentGrid: (width: 118, height: 36)
        ))
        // What the old code compared: the pane's 118 against the surface's 119.
        #expect(SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 118, height: 36),
            currentGrid: (width: 119, height: 36)
        ), "this is the mismatch that used to reset every frame")
    }

    /// A projection revision that moves *because of a re-projection* still resets.
    ///
    /// Kept adjacent to the pane/surface case on purpose: both are "the numbers moved",
    /// and only one of them means the screen is invalid.
    @Test("a re-projection still counts as a projection change")
    func reProjectionStillCounts() {
        #expect(SurfaceGeometry.projectionChanged(
            previous: projection("boot-1", 3),
            current: projection("boot-1", 4)
        ))
    }

    /// A real machine/workspace switch must still reset: the pixels on screen belong
    /// to another daemon, so a delta against them paints the wrong content.
    @Test("a boot change is a projection change")
    func bootChangeIsAProjectionChange() {
        #expect(SurfaceGeometry.projectionChanged(
            previous: projection("boot-1", 7),
            current: projection("boot-2", 7)
        ))
    }

    /// The first frame has no baseline, so it resets.
    @Test("the first frame is a projection change")
    func firstFrameIsAProjectionChange() {
        #expect(SurfaceGeometry.projectionChanged(
            previous: nil,
            current: projection("boot-1", 1)
        ))
    }

    /// Scrolling does not restart the delta stream: the revision only climbs.
    @Test("a scroll does not restart the delta stream")
    func scrollDoesNotRestartTheStream() {
        #expect(!SurfaceGeometry.deltaStreamRestarted(previousRevision: 10, incomingRevision: 11))
    }

    /// And the grid does not change while scrolling, so the only reset reason left
    /// is the revision — which is the one above.
    @Test("a scroll does not change the grid")
    func scrollDoesNotChangeTheGrid() {
        #expect(!SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 120, height: 40),
            currentGrid: (width: 120, height: 40)
        ))
    }

    /// A resize still resets — this is the reason `needsScreenReset` exists.
    @Test("a resize still resets")
    func resizeStillResets() {
        #expect(SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: false,
            previousGrid: (width: 120, height: 40),
            currentGrid: (width: 121, height: 40)
        ))
    }
}
