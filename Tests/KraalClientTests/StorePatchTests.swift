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

// MARK: - Fixtures (shared by the suites below)

/// A store holding one 80x20 surface at `revision`, projection 3.
@MainActor
func makeStore(at revision: UInt64) throws -> AppStore {
    let store = AppStore()
    // A snapshot is only needed so `handleSurface`'s projection fence has a
    // revision to compare against.
    store.handleSnapshot(try snapshot(revision: 3))
    store.handleSurface(try surface(revision: revision))
    return store
}

@MainActor
func applyOneCell(
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
    cursor: CursorState? = nil,
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
    writer.writeOptional(cursor) { writer, cursor in
        writer.writeVarint(UInt64(cursor.column))
        writer.writeVarint(UInt64(cursor.row))
        writer.writeBool(cursor.visible)
        writer.writeVarint(UInt64(cursor.shape))
    }
    guard case let .paneSurfacePatch(patch) =
        try ServerMessageDecoder.decode(Data(writer.bytes))
    else {
        throw FixtureError.wrongMessage("expected a patch")
    }
    return patch
}

func surface(revision: UInt64) throws -> PaneSurfaceFrame {
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

func snapshot(revision: UInt64) throws -> ClientShellSnapshot {
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
    /// common and sent by the daemon, while `validateGrid()`'s strict reading calls
    /// it out of bounds. Both entry points therefore agree on the opposite rule —
    /// clamp, do not refuse (`pendingWrapPatchCursorClamped` is the patch half).
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
}

// MARK: - issue #50 review: refusals vs divergences, and the latch

/// `handleSurfacePatch`'s recovery rule, tested separately from the patch path.
///
/// The subject here is not "did the patch apply" but "what does the store do
/// about a refusal". The two used to be the same answer — any rejection asked for
/// a fresh surface — which turned a *systematic* refusal (a popup on screen, every
/// patch refused, up to 60/s) into a re-projection amplifier, and left the latch
/// armed on requests that were never sent.
@Suite("Patch refusal handling (issue #50 review)")
struct PatchRefusalTests {
    /// While a popup owns the screen the daemon composes a different projection, so
    /// *every* patch is refused — once per frame, up to 60 times a second.
    ///
    /// That was always true (`popup == nil` has been in the guard since the parent
    /// commit). What was new is the reaction: the catch in `handleSurfacePatch`
    /// asked for a fresh surface on *any* rejection, so one popup open for a minute
    /// became 3600 rounds of two commands, each answered with the same refusal.
    ///
    /// A/B: fold `patchPopupOpen` back into `patchIdentity` and this goes red with
    /// "a popup caused 1 resyncs per frame".
    @Test("a patch refused because a popup is open does not ask for a resync")
    @MainActor
    func popupRefusalDoesNotResync() throws {
        let store = try makeStore(at: 1)
        var withPopup = try #require(store.surface)
        withPopup.popup = ClientShellPopupSurface(
            terminalId: "popup-1",
            title: "menu",
            width: nil,
            height: nil,
            frame: withPopup.frame,
            mouseReporting: false,
            sgrPixelMouse: false,
            pixelWidth: 0,
            pixelHeight: 0
        )
        store.handleSurface(withPopup)
        #expect(store.surface?.popup != nil, "the fixture never put a popup on screen")
        let requestsBefore = store.surfaceResyncRequests

        let newPatch = try patch(base: 1, row: 0, column: 0, symbol: "P")
        for _ in 0 ..< 5 {
            store.handleSurfacePatch(newPatch)
        }

        // The patch really was refused — otherwise the rest passes for the wrong
        // reason (an applied patch also does not resync).
        #expect(store.surface?.frame.buffer[0].symbol != "P",
                "the patch was applied, so this test never exercised the refusal")
        #expect(store.lastError?.contains("patch rejected") == true,
                Comment(rawValue: "a refused patch must still be visible: "
                    + "\(store.lastError ?? "nil")"))
        #expect(store.surfaceResyncRequests == requestsBefore,
                Comment(rawValue: "a popup caused "
                    + "\(store.surfaceResyncRequests - requestsBefore) resyncs; a popup "
                    + "cannot be fixed by re-projecting, so this floods the connection "
                    + "and changes nothing"))
    }

    /// The other half of the classification: a genuine divergence still asks.
    /// Without this, "never resync" would pass the test above.
    @Test("a patch rejected for a revision gap still asks for a resync")
    @MainActor
    func identityRefusalStillResyncs() throws {
        let store = try makeStore(at: 5)
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))
        #expect(store.surfaceResyncRequests == 1,
                "a diverged baseline stopped asking for a fresh surface")
    }

    /// The classification itself, exhaustively — so a new `SurfaceError` case has to
    /// be decided rather than inheriting "recoverable" by default.
    @Test("only a divergence counts as recoverable by a resync")
    func rejectionClassification() {
        let recoverable: [SurfaceError] = [.patchIdentity, .patchBeforeBaseline]
        let refused: [SurfaceError] = [
            .patchPopupOpen,
            .patchRowBounds,
            .patchRowOverlap(row: 3),
            .patchGeometry(paneId: "w1:p1"),
            .cellCount(expected: 4, actual: 2),
            .hyperlinkIndex(index: 3, count: 0),
            .cursorBounds(column: 80, row: 0, width: 80, height: 20),
            .bootIdMismatch(expected: "a", actual: "b"),
            .unexpectedValidationFailure("x"),
        ]
        for error in recoverable {
            #expect(AppStore.patchRejectionIsRecoverable(error),
                    Comment(rawValue: "\(error) is a divergence: only a fresh surface fixes it"))
        }
        for error in refused {
            #expect(!AppStore.patchRejectionIsRecoverable(error),
                    Comment(rawValue: "\(error) must not trigger a re-projection: resending "
                        + "the whole surface returns the same frame and the same refusal"))
        }
        #expect(!AppStore.patchRejectionIsRecoverable(FixtureError.wrongMessage("x")))
    }

    /// `column == width` is the pending-wrap state, and a patch is no less likely to
    /// carry it than a whole surface is.
    ///
    /// The two entry points used to disagree: `handleSurface` clamped it and adopted
    /// the frame, `validatePatch` refused it as `patchCursorBounds` and the patch was
    /// thrown away. Same state, opposite verdicts — and the refusal was the one that
    /// could not be recovered from, because the next patch carries the same cursor.
    ///
    /// A/B: reinstate the `patchCursorBounds` rejection and all five assertions fail.
    @Test("a patch carrying a pending-wrap cursor is clamped, not refused")
    @MainActor
    func pendingWrapPatchCursorClamped() throws {
        let store = try makeStore(at: 1)
        let width = try #require(store.surface?.frame.width)
        let height = try #require(store.surface?.frame.height)
        let cursor = CursorState(column: width, row: height &- 1, visible: true, shape: 0)

        store.handleSurfacePatch(try patch(
            base: 1, row: 0, column: 0, symbol: "W", cursor: cursor))

        #expect(store.surface?.surfaceRevision == 2,
                Comment(rawValue: "a pending-wrap cursor caused the whole patch to be "
                    + "dropped: every patch the terminal sends while parked there would be "
                    + "dropped"))
        #expect(store.surface?.frame.buffer[0].symbol == "W",
                "the patch was refused, so the cells never landed")
        #expect(store.lastError == nil,
                Comment(rawValue: "the patch applied but reported: \(store.lastError ?? "nil")"))
        // Clamped exactly the way the arrival path clamps it.
        #expect(store.surface?.frame.cursor?.column == width &- 1)
        #expect(store.surface?.frame.cursor?.row == height &- 1)
        #expect(store.surface?.frame.cursor?.visible == true)
    }

    /// A **hidden** cursor out of bounds is clamped too, not stored as it arrived.
    ///
    /// It used to survive: the rejection only looked at `cursor.visible`, so
    /// `column: 60000, visible: false` landed in the frame as-is and the patch
    /// reported APPLIED. `clampCursor`'s own note says hidden cursors are clamped
    /// because a later `visible` flip would otherwise paint at a position that does
    /// not exist — this is the patch-path test for that.
    @Test("a patch's hidden out-of-bounds cursor is clamped, not stored")
    @MainActor
    func hiddenOutOfBoundsPatchCursorClamped() throws {
        let store = try makeStore(at: 1)
        let width = try #require(store.surface?.frame.width)
        let height = try #require(store.surface?.frame.height)
        let cursor = CursorState(column: 60000, row: 60000, visible: false, shape: 0)

        store.handleSurfacePatch(try patch(
            base: 1, row: 0, column: 0, symbol: "H", cursor: cursor))

        #expect(store.surface?.surfaceRevision == 2, "the patch was refused")
        let stored = try #require(store.surface?.frame.cursor)
        #expect(stored.visible == false, "the hidden flag was lost in the clamp")
        #expect(stored.column == width &- 1,
                Comment(rawValue: "a hidden cursor was stored at column \(stored.column) in "
                    + "a \(width)-wide grid; a later visible flip would paint off-screen"))
        #expect(stored.row == height &- 1)
    }

    /// A grid with no cells has no legal cursor position, so a cursor on it is
    /// dropped rather than clamped into a trap.
    ///
    /// `clampCursor` used to `return` early on `width == 0 || height == 0`, which
    /// left the cursor exactly as it arrived — out of bounds — and the arrival check
    /// then refused the frame (`surface rejected: cursor (0, 0) outside 80x0`). A
    /// 0-row frame is degenerate but it is not corrupt, and refusing it strands the
    /// screen.
    ///
    /// A/B: restore the early return and this goes red on both assertions.
    @Test("a zero-height frame is adopted with its cursor dropped")
    @MainActor
    func zeroHeightFrameAdopted() throws {
        let store = try makeStore(at: 1)
        var empty = try #require(store.surface)
        empty.surfaceRevision = 4
        empty.frame.buffer = CellBuffer([], width: 80)
        empty.frame.width = 80
        empty.frame.height = 0
        empty.frame.cursor = CursorState(column: 0, row: 0, visible: true, shape: 0)

        // By the strict rule the cursor really is out of bounds — otherwise the test
        // would pass for the wrong reason.
        #expect(throws: SurfaceError.self) { try empty.frame.validateGrid() }

        store.handleSurface(empty)

        #expect(store.surface?.surfaceRevision == 4,
                Comment(rawValue: "a 0-row frame was refused for its cursor: "
                    + "\(store.lastError ?? "nil")"))
        #expect(store.surface?.frame.cursor == nil,
                Comment(rawValue: "a cursor was kept for a grid that has no cells: it can "
                    + "only be painted at a position that does not exist"))
    }

    // MARK: - The latch

    /// The latch must be released by a *refused* answer too, not only by an adopted
    /// one.
    ///
    /// The resync asks for a fresh surface; if that surface then fails arrival
    /// validation (a cell count that disagrees with the grid, say), the latch used to
    /// stay set forever. Every later rejection took the "already requested" path, so
    /// the store never asked again and the screen stayed on the diverged baseline for
    /// the life of the connection.
    ///
    /// A/B: drop the `surfaceResyncLatched = false` in the reject branch and this
    /// goes red with "only 1 resyncs: the second divergence is stranded".
    @Test("a rejected resync answer releases the latch")
    @MainActor
    func refusedResyncAnswerReleasesLatch() throws {
        let store = try makeStore(at: 5)
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))
        #expect(store.surfaceResyncRequests == 1)
        #expect(store.surfaceResyncLatched == true, "the first rejection did not latch")

        // The re-projected surface arrives corrupt.
        var broken = try #require(store.surface)
        broken.surfaceRevision = 6
        broken.frame.buffer = CellBuffer(Array(repeating: .blank, count: 3), width: 3)
        broken.frame.width = 3
        broken.frame.height = 2
        store.handleSurface(broken)
        #expect(store.lastError?.contains("surface rejected") == true,
                Comment(rawValue: "the corrupt surface was not refused: "
                    + "\(store.lastError ?? "nil")"))
        #expect(store.surfaceResyncLatched == false,
                Comment(rawValue: "the latch survived a refused answer, so it can never be "
                    + "released by anything except a frame that is already valid"))

        // And the next divergence can ask again — the assertion that fails without
        // the release above.
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "H"))
        #expect(store.surfaceResyncRequests == 2,
                Comment(rawValue: "only \(store.surfaceResyncRequests) resyncs: the second "
                    + "divergence is stranded because the latch never came off"))
    }

    /// A resync that was *dropped* must release the latch.
    ///
    /// `reprojectSurface` returns early while another toggle is in flight — a tab
    /// switch or a split, neither of which knows about this resync. `resyncSurface`
    /// latches on the *intent*, so a request that never went out used to leave the
    /// latch armed for a round trip that does not exist; the next legitimate
    /// rejection then took the "already requested" path and the store never asked
    /// again.
    ///
    /// A/B: replace the `if await !self.reprojectSurface()` block with a bare
    /// `await self.reprojectSurface()` and this goes red.
    @Test("a resync dropped by an in-flight re-projection releases the latch")
    @MainActor
    func droppedResyncReleasesLatch() async throws {
        let store = try makeStore(at: 5)
        // A connection that claims the method, so `resyncSurface` takes the
        // re-projection branch rather than the reconnect one.
        store.welcome = try welcomeFixture(methods: ["client_shell.surface.set"])
        store.reprojectInFlight = true           // an unrelated toggle is running

        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))
        #expect(store.surfaceResyncRequests == 1, "the first rejection did not even try")

        // Let the fire-and-forget task run: it finds the toggle in flight, gives up,
        // and has to hand the latch back.
        for _ in 0 ..< 40 where store.surfaceResyncLatched {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(store.surfaceResyncLatched == false,
                Comment(rawValue: "the latch stayed armed on a request that was never "
                    + "sent; the next divergence would be swallowed as 'already requested'"))
    }

    /// A new handshake invalidates the latch: it belongs to the connection that set
    /// it, and that connection is gone.
    @Test("a new welcome releases the resync latch")
    @MainActor
    func welcomeReleasesLatch() throws {
        let store = try makeStore(at: 5)
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))
        #expect(store.surfaceResyncLatched == true)

        store.handleWelcome(try welcomeFixture(methods: ["client_shell.surface.set"]))
        #expect(store.surfaceResyncLatched == false,
                "the latch crossed a handshake, so the new connection cannot ask")
    }

    /// The same for a machine switch: `selectEndpoint` drops `surface`, so any
    /// latched resync was about a frame that is no longer on screen.
    @Test("switching machines releases the resync latch")
    @MainActor
    func machineSwitchReleasesLatch() throws {
        let store = try makeStore(at: 5)
        store.handleSurfacePatch(try patch(base: 1, row: 0, column: 0, symbol: "G"))
        #expect(store.surfaceResyncLatched == true)

        let other = EndpointState(id: .ssh(id: "host-b"), label: "B", settings: .local)
        store.selectEndpoint(other)
        #expect(store.surfaceResyncLatched == false,
                "the latch followed the store to another machine, which never asked")
    }
}

/// The welcome only has a decoding initialiser, so fixtures build it from JSON the
/// way the connection does.
private func welcomeFixture(methods: [String]) throws -> EndpointServerWelcome {
    let list = methods.map { "\"\($0)\"" }.joined(separator: ",")
    let json = """
    {"generation":1,"server_version":"0.9.5",
     "snapshot_codec":"shell.snapshot.v1","surface_codec":"shell.surface.v1",
     "input_codec":"shell.input.v1","blob_codec":"blob.v1",
     "methods":[\(list)],"capabilities":[]}
    """
    return try JSONDecoder().decode(EndpointServerWelcome.self, from: Data(json.utf8))
}
