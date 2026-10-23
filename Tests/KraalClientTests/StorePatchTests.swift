// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// issue #50, the store half: what `handleSurfacePatch` must keep doing now that
// the cells underneath it are cheap to copy.
//
// Three things could break silently here and none of them would fail a cell-level
// assertion:
//
//   1. the two guards the issue said must stay (boot id, projection revision),
//   2. recovery — a rejected patch means our baseline diverged, and the screen
//      cannot repair itself by waiting for the next patch, and
//   3. recovery not becoming a stampede — a diverged baseline rejects *every*
//      patch, so the request for a fresh surface has to be latched.
//
// There is also a fourth, narrower thing below: `patchIsObserved` pins the
// copy-assign implementation detail. It is not an argument about storage shape —
// see its own note.
//
// On (2): `@Observable` is driven by writes to the tracked property; whether an
// assignment is "a write" is invisible to a test that only reads the value
// afterwards. `withObservationTracking` observes what a real view would.

import Foundation
import Observation
import Testing

@testable import KraalProtocol
@testable import KraalUI

private enum FixtureError: Error { case wrongMessage(String) }

/// The fields a rejection test varies; everything else is the well-formed default.
private struct Deviation {
    var boot = "boot-1"
    var projection: UInt64 = 3
    var next: UInt64?

    static let none = Deviation()
}

@Suite("Patch path at the store (issue #50)")
struct StorePatchTests {
    /// A one-cell patch must land, advance the revision, and leave every other
    /// row on screen untouched.
    @Test("a patch lands and touches only its row")
    @MainActor
    func patchLands() throws {
        let store = try makeStore(at: 1)
        let before = try #require(store.surface?.frame)
        try applyOneCell(to: store, row: 7, column: 3, base: 1)

        let after = try #require(store.surface?.frame)
        #expect(store.surface?.surfaceRevision == 2)
        #expect(after.buffer[7 * 80 + 3].symbol == "X")
        for row in 0 ..< 20 where row != 7 {
            #expect(after.buffer.row(row) == before.buffer.row(row),
                    Comment(rawValue: "row \(row) changed although no patch touched it"))
        }
    }

    /// The issue's hard requirement: both guards stay. A patch for another boot is
    /// dropped; a patch for another projection (i.e. another tab) is dropped.
    @Test("the boot-id and projection guards still drop foreign patches")
    @MainActor
    func guardsHold() throws {
        let store = try makeStore(at: 1)
        let baseline = try #require(store.surface)

        // Foreign boot id.
        store.handleSurfacePatch(try patch(
            base: 1, row: 0, column: 0, symbol: "B",
            deviation: Deviation(boot: "boot-other")))
        #expect(store.surface?.surfaceRevision == 1, "a patch from another boot was applied")

        // Foreign projection.
        store.handleSurfacePatch(try patch(
            base: 1, row: 0, column: 0, symbol: "P",
            deviation: Deviation(projection: 9)))
        #expect(store.surface?.surfaceRevision == 1, "a patch from another projection was applied")

        // And the baseline cell is still the one the surface carried.
        #expect(store.surface?.frame.buffer[0] == baseline.frame.buffer[0])
    }

    /// Pins the copy-assign implementation detail of `handleSurfacePatch`.
    ///
    /// A view body reads `store.surface?.surfaceRevision`; if a patch stopped
    /// assigning the tracked property, the view would never be invalidated. This
    /// test keeps the patch path assigning rather than mutating through a reference
    /// held elsewhere.
    ///
    /// **What it does not prove**: that a `final class` storage would be invisible
    /// to `@Observable`. It would not be. A nested-class mutation reached through
    /// `surface?.apply(...)` still goes through the tracked property's `_modify`
    /// accessor, which fires `willSet`/`didSet`, so SwiftUI is notified either way.
    /// The reason that storage was rejected is the write-through into
    /// `renderer.previous` (see `PatchCopyOnWriteTests.publishedCopyIsIndependent`),
    /// not observation.
    @Test("a patch invalidates an observer of store.surface")
    @MainActor
    func patchIsObserved() throws {
        let store = try makeStore(at: 1)

        // Observe the same thing `GhosttyPaneView.onChange(of:)` observes.
        nonisolated(unsafe) var invalidated = false
        nonisolated(unsafe) var seenRevision: UInt64?
        withObservationTracking {
            seenRevision = store.surface?.surfaceRevision
        } onChange: {
            invalidated = true
        }
        #expect(!invalidated, "reading the surface must not itself fire a change")

        try applyOneCell(to: store, row: 2, column: 0, base: 1)
        #expect(invalidated, Comment(rawValue: "a patch did not invalidate the observer of "
            + "store.surface: SwiftUI would never redraw the pane"))
        #expect(seenRevision == 1, Comment(rawValue: "the observed value was \(seenRevision as Any)"))
    }

    /// Requirement (3): a rejected patch must not leave the screen stranded on a
    /// diverged baseline. The comment in `handleSurfacePatch` has always said this;
    /// before this change the code only recorded an error, so the daemon kept
    /// patching a baseline we could no longer follow and the pane stayed frozen
    /// until something else happened to re-project.
    @Test("a rejected patch asks the daemon for a fresh surface")
    @MainActor
    func rejectionResyncs() throws {
        let store = try makeStore(at: 5)
        // A gap: base 1 while the store is at revision 5. `apply` refuses it.
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))

        #expect(store.surface?.surfaceRevision == 5, "the frame was disturbed by a rejected patch")
        #expect(store.lastError?.contains("patch rejected") == true,
                "a rejected patch was silent: \(store.lastError ?? "nil")")
        // The recovery itself. Asserted on the store's own counter rather than on a
        // connection: the request is asynchronous and this store has no daemon, but
        // *that a resync was requested* is precisely the decision the old code did
        // not make — it recorded the error and left the screen on the bad baseline.
        #expect(store.surfaceResyncRequests == 1,
                Comment(rawValue: "a rejected patch made no attempt to recover a baseline: "
                    + "the screen is stranded on a diverged frame"))
    }

    /// A surface that fails validation is refused on arrival, with a reason. This
    /// is where the full cell scan lives now — the patch path no longer repeats it,
    /// so it has to be here, once per frame, and it has to be visible when it fires.
    @Test("an invalid surface is refused on arrival with a reason")
    @MainActor
    func invalidSurfaceRejected() throws {
        let store = try makeStore(at: 1)
        let good = try #require(store.surface)

        // Same revision and boot, but the cells no longer match the grid.
        var broken = good
        broken.surfaceRevision = 9
        broken.frame.buffer = CellBuffer(Array(repeating: .blank, count: 3), width: 3)
        broken.frame.width = 3
        broken.frame.height = 2          // 6 cells declared, 3 present
        store.handleSurface(broken)

        #expect(store.surface?.surfaceRevision == 1,
                "a frame with a cell count that disagrees with its grid was adopted")
        #expect(store.lastError?.contains("surface rejected") == true,
                "the rejection was silent: \(store.lastError ?? "nil")")
    }

    /// A cursor parked past the last column is **not** a corrupt frame.
    ///
    /// Terminal pending-wrap state is `cursor.column == width`: the cursor sits
    /// one past the last cell until the next character wraps it. It is legal,
    /// common and sent by the daemon; `validateGrid()` calls it out of bounds
    /// because the *patch* path must refuse a daemon that moves the cursor
    /// outside the grid.
    ///
    /// Refusing the whole frame for it is the failure this test exists for: a
    /// surface that is dropped is never adopted (`self.surface` stays nil at
    /// startup, i.e. black, or keeps the previous tab's cells forever) and the
    /// only symptom is a tab-bar icon. The renderer already clamps the host
    /// cursor it paints, so the frame is adopted with the cursor clamped.
    ///
    /// The other half of the arrival check — a cell count that disagrees with the
    /// grid is still **refused** — is `invalidSurfaceRejected` below. Clamping the
    /// cursor must not have turned the check into a rubber stamp.
    @Test("a pending-wrap cursor is adopted, not rejected")
    @MainActor
    func pendingWrapCursorAdopted() throws {
        let store = try makeStore(at: 1)
        let good = try #require(store.surface)
        #expect(store.lastError == nil)

        var wrapped = good
        wrapped.surfaceRevision = 7
        var cursor = try #require(wrapped.frame.cursor)
        cursor.column = wrapped.frame.width      // == width, the pending-wrap state
        cursor.row = wrapped.frame.height &- 1
        wrapped.frame.cursor = cursor

        // The old code refused this frame here; assert it is genuinely out of
        // bounds by the strict rule, or the test would pass for the wrong reason.
        #expect(throws: SurfaceError.self) { try wrapped.frame.validateGrid() }

        store.handleSurface(wrapped)

        #expect(store.surface?.surfaceRevision == 7,
                Comment(rawValue: "a pending-wrap cursor caused the whole frame to be dropped: "
                    + "the screen would freeze on the previous frame with only a tab-bar icon"))
        #expect(store.lastError == nil,
                Comment(rawValue: "the frame was adopted but still reported an error: "
                    + "\(store.lastError ?? "nil")"))
        // Adopted with the cursor pulled back into the grid, so the rest of the
        // client (pane cropping, debug output) agrees with what is painted.
        #expect(store.surface?.frame.cursor?.column == wrapped.frame.width &- 1)
        #expect(store.surface?.frame.cursor?.row == wrapped.frame.height &- 1)
        #expect(store.surface?.frame.cursor?.visible == true)
    }

    /// The latch. Once a resync has been requested, a diverged baseline keeps
    /// rejecting patches — up to 60/s — and each one used to send another round
    /// of two commands: the in-flight guard cleared as soon as the request
    /// finished, long before the fresh surface landed, and the reconnect branch
    /// had no guard at all while resetting the backoff every time.
    @Test("repeated rejections request exactly one resync")
    @MainActor
    func repeatedRejectionsCoalesce() throws {
        let store = try makeStore(at: 5)
        for _ in 0 ..< 5 {
            store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))
        }
        #expect(store.surfaceResyncRequests == 1,
                Comment(rawValue: "\(store.surfaceResyncRequests) resyncs were requested for "
                    + "5 rejected patches; a diverged baseline would send one round of two "
                    + "commands per frame"))
    }

    /// The latch must not be permanent: a fresh surface is what pays it off, and
    /// the next divergence has to be able to ask again or the screen strands on
    /// the second failure.
    @Test("adopting a fresh surface resets the resync latch")
    @MainActor
    func latchResetsOnFreshSurface() throws {
        let store = try makeStore(at: 5)
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))
        #expect(store.surfaceResyncRequests == 1)

        // The re-projected surface lands.
        store.handleSurface(try surface(revision: 6))
        #expect(store.surfaceResyncLatched == false, "the latch survived a fresh surface")

        // It diverges again later: the store must be able to ask a second time.
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "H"))
        #expect(store.surfaceResyncRequests == 2,
                Comment(rawValue: "only \(store.surfaceResyncRequests) resyncs: the latch "
                    + "never reset, so a second divergence cannot recover"))
    }

    // MARK: - Fixtures

    /// A store holding one 80x20 surface at `revision`, projection 3.
    @MainActor
    private func makeStore(at revision: UInt64) throws -> AppStore {
        let store = AppStore()
        // A snapshot is only needed so `handleSurface`'s projection fence has a
        // revision to compare against.
        store.handleSnapshot(try snapshot(revision: 3))
        store.handleSurface(try surface(revision: revision))
        return store
    }

    @MainActor
    private func applyOneCell(
        to store: AppStore,
        row: UInt16,
        column: UInt16,
        base: UInt64
    ) throws {
        store.handleSurfacePatch(try patch(base: base, row: row, column: column, symbol: "X"))
    }

    /// One patch at one cell. `deviation` carries the fields a rejection test
    /// needs to vary; the rest are the well-formed defaults.
    private func patch(
        base: UInt64,
        row: UInt16,
        column: UInt16,
        symbol: String,
        deviation: Deviation = .none
    ) throws -> PaneSurfacePatch {
        var writer = BincodeWriter()
        writer.writeVarint(19)                       // PaneSurfacePatch
        writer.writeString(deviation.boot)
        writer.writeVarint(deviation.projection)
        writer.writeVarint(base)
        writer.writeVarint(deviation.next ?? base &+ 1)
        writer.writeVarint(1)                        // one row
        writer.writeVarint(UInt64(column))
        writer.writeVarint(UInt64(row))
        writer.writeArray([symbol]) { writer, text in
            writer.writeString(text)
            writer.writeVarint(1)                    // foreground
            writer.writeVarint(2)                    // background
            writer.writeVarint(0)                    // modifier
            writer.writeBool(false)                  // skip
            writer.writeBool(false)                  // no hyperlink
        }
        writer.writeVarint(0)                        // panes
        writer.writeBool(false)                      // cursor: None
        guard case let .paneSurfacePatch(patch) =
            try ServerMessageDecoder.decode(Data(writer.bytes))
        else {
            throw FixtureError.wrongMessage("expected a patch")
        }
        return patch
    }

    private func surface(revision: UInt64) throws -> PaneSurfaceFrame {
        var writer = BincodeWriter()
        writer.writeVarint(13)                       // PaneSurface
        writer.writeString("boot-1")
        writer.writeVarint(3)                        // projectionRevision
        writer.writeVarint(revision)
        writer.writeArray(Array(0 ..< 80 * 20)) { writer, index in
            writer.writeString(String(UnicodeScalar(UInt8(97 + index % 26))))
            writer.writeVarint(UInt64(index % 8))
            writer.writeVarint(0x1E1E1E)
            writer.writeVarint(0)
            writer.writeBool(false)
            writer.writeBool(false)
        }
        writer.writeVarint(80)
        writer.writeVarint(20)
        writer.writeBool(true)                       // cursor: Some
        writer.writeVarint(0)
        writer.writeVarint(0)
        writer.writeBool(true)
        writer.writeVarint(0)
        writer.writeVarint(0)                        // hyperlinks
        writer.writeVarint(0)                        // graphics bytes
        writer.writeVarint(0)                        // panes
        writer.writeVarint(0)                        // splits
        writer.writeBool(false)                      // popup
        writer.writeVarint(0)                        // graphics assets
        writer.writeVarint(0)                        // graphics placements
        writer.writeVarint(0)                        // graphics retained
        guard case let .paneSurface(surface) =
            try ServerMessageDecoder.decode(Data(writer.bytes))
        else {
            throw FixtureError.wrongMessage("expected a surface")
        }
        return surface
    }

    private func snapshot(revision: UInt64) throws -> ClientShellSnapshot {
        let json = """
        {
          "boot_id": "boot-1", "revision": \(revision),
          "update_install_command": "", "worktree_directory": "",
          "tab_bar_right": [], "tab_bar_right_separator": " ", "agent_order": [],
          "workspaces": [{"workspace_id": "w1", "active_tab_id": "w1:t1",
            "new_workspace_cwd": "/", "number": 1, "label": "repo",
            "custom_label": false, "tokens": [], "focused": true,
            "agent_status": "working"}],
          "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "number": 1,
            "label": "main", "custom_label": false, "zoomed": false,
            "focused": true, "agent_status": "working"}],
          "panes": [{"pane_id": "w1:p1", "workspace_id": "w1",
            "tab_id": "w1:t1", "focused": true}],
          "agents": [], "commands": []
        }
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }
}
