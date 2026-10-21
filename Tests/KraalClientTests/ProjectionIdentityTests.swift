// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for panes that came back scrambled after switching machines.
//
// The report: switching between two machines (or two worktrees) left the panes
// showing cells from the other one — stacked, repeated, cut by the split bars.
//
// The cause was that nothing in the repaint decision could see a machine switch.
// `apply(surface:)` decided "nothing to do" from two things: the pane's
// `contentRevision` and its grid. Both are wrong for this:
//
//   * `contentRevision` keeps climbing across the whole daemon session and is
//     not reset by a re-projection, so the value a pane has on machine B can be
//     the same one it had on machine A.
//   * the grid is *identical* by design: two machines name their first
//     workspace's first pane `w1:p1`, split it the same way, and hand over the
//     same 118x12 rect.
//
// So the switch arrived with every number unchanged, `apply` returned early, and
// the previous machine's picture stayed on screen. The renderer's baseline was
// also still the old machine's, so the next delta was painted on top of it —
// which is where the stacked, half-erased text came from.
//
// `bootId` is the one field that differs: the daemon stamps it at boot and two
// machines never share one.

import Testing

@testable import KraalUI

@Suite("Projection identity")
struct ProjectionIdentityTests {
    private func identity(
        _ bootId: String = "1-1792504918586040568",
        _ revision: UInt64 = 3
    ) -> SurfaceGeometry.ProjectionIdentity {
        SurfaceGeometry.ProjectionIdentity(bootId: bootId, revision: revision)
    }

    /// The case the bug was made of: same revision number, different machine.
    ///
    /// Two daemons count their projections independently, so both can be sitting
    /// on revision 3. Everything else the client compares — pane id, inner rect,
    /// content revision — can match too. If this returns false the pane keeps the
    /// other machine's cells.
    @Test("the same revision on a different machine is a different projection")
    func differentBootIsDifferentProjection() {
        #expect(SurfaceGeometry.projectionChanged(
            previous: identity("1-1792504918586040568", 3),
            current: identity("3495920-1791970698559926386", 3)
        ))
    }

    /// A daemon re-projecting onto another tab keeps its boot id and moves the
    /// revision. That is the workspace-switch case.
    @Test("a re-projection on the same machine is a different projection")
    func differentRevisionIsDifferentProjection() {
        #expect(SurfaceGeometry.projectionChanged(
            previous: identity("1-1792504918586040568", 3),
            current: identity("1-1792504918586040568", 4)
        ))
    }

    /// The common case must stay cheap: a new frame inside one projection is
    /// handled by the revision and grid checks, not by wiping the screen.
    @Test("the same projection is not a change")
    func sameProjectionIsUnchanged() {
        #expect(!SurfaceGeometry.projectionChanged(
            previous: identity("1-1792504918586040568", 3),
            current: identity("1-1792504918586040568", 3)
        ))
    }

    /// The first frame a pane ever sees has nothing to compare against, and
    /// treating it as unchanged would leave it blank.
    @Test("the first frame is always a change")
    func firstFrameIsAChange() {
        #expect(SurfaceGeometry.projectionChanged(
            previous: nil,
            current: identity()
        ))
    }
}
