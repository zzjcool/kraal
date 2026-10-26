// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  CopyModeBoundsTests.swift
//  KraalClientTests
//
//  `AppStore.copyModeBounds` / `copyModeEntry`: where copy mode's viewport starts.
//
//  `CopyModeTests` already covers the pure cursor algebra (75 assertions). What was
//  untested is the store-level step that feeds it, and that step has two traps its own
//  comments call out:
//
//  * **`viewportRows` must prefer the daemon's count.** `innerRect.height` is the
//    client's idea of the same number and the two can differ by a reserved row, which
//    shifts every clamp by one.
//  * **`copyModeEntry` must share `copyModeBounds`.** Two copies of `max - offset` is
//    how the entry point and the per-keypress refresh end up a row apart.
//
//  A one-row difference is invisible in a screenshot and only shows up as "k stopped one
//  line early", which is why it is pinned rather than left to inspection.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Copy mode bounds")
@MainActor
struct CopyModeBoundsTests {
    private func pane(
        id: String = "w1:p1",
        innerHeight: UInt16 = 20,
        scroll: PaneSurfaceScrollMetrics? = nil
    ) -> PaneSurfacePane {
        PaneSurfacePane(
            paneId: id,
            contentRevision: 1,
            rect: SurfaceRect(originX: 0, originY: 0, width: 80, height: innerHeight),
            innerRect: SurfaceRect(originX: 0, originY: 0, width: 80, height: innerHeight),
            scrollbarRect: nil,
            scroll: scroll,
            focused: true,
            mouseReporting: false,
            sgrPixelMouse: false,
            alternateScreenActive: false,
            pixelWidth: 0,
            pixelHeight: 0
        )
    }

    private func store(
        panes: [PaneSurfacePane],
        cursor: CursorState? = nil
    ) -> AppStore {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        store.surface = PaneSurfaceFrame(
            bootId: "boot",
            projectionRevision: 1,
            surfaceRevision: 1,
            frame: FrameData(
                cells: Array(repeating: .blank, count: 80 * 20),
                width: 80, height: 20,
                cursor: cursor, hyperlinks: [], graphics: Data()
            ),
            panes: panes, splits: [], popup: nil,
            graphics: SurfaceGraphicsScene()
        )
        return store
    }

    // MARK: - The daemon's row count wins

    /// The daemon's `viewportRows` must be used even when it disagrees with the
    /// client's `innerRect.height`.
    @Test("the daemon's viewport row count wins over innerRect")
    func daemonRowCountWins() throws {
        let scroll = PaneSurfaceScrollMetrics(
            offsetFromBottom: 0, maxOffsetFromBottom: 0, viewportRows: 18
        )
        let store = store(panes: [pane(innerHeight: 20, scroll: scroll)])
        let bounds = try #require(store.copyModeBounds(for: "w1:p1"))
        #expect(bounds.viewportRows == 18,
                "innerRect.height (20) was used instead of the daemon's 18; every clamp shifts by 2")
    }

    /// Without a daemon count the client's own geometry is the only answer.
    @Test("with no scroll metrics, innerRect supplies the rows")
    func innerRectIsTheFallback() throws {
        let store = store(panes: [pane(innerHeight: 20, scroll: nil)])
        let bounds = try #require(store.copyModeBounds(for: "w1:p1"))
        #expect(bounds.viewportRows == 20)
    }

    /// A zero height would make every clamp degenerate; the result is floored at 1.
    @Test("the row count is never zero")
    func rowsAreAtLeastOne() throws {
        let scroll = PaneSurfaceScrollMetrics(
            offsetFromBottom: 0, maxOffsetFromBottom: 0, viewportRows: 0
        )
        let store = store(panes: [pane(innerHeight: 0, scroll: scroll)])
        let bounds = try #require(store.copyModeBounds(for: "w1:p1"))
        #expect(bounds.viewportRows >= 1)
    }

    // MARK: - viewportTop

    /// Scrolled all the way up: the viewport starts at the top of the history.
    @Test("scrolled to the top puts the viewport at the oldest row")
    func scrolledToTop() throws {
        let scroll = PaneSurfaceScrollMetrics(
            offsetFromBottom: 100, maxOffsetFromBottom: 100, viewportRows: 20
        )
        let store = store(panes: [pane(scroll: scroll)])
        let bounds = try #require(store.copyModeBounds(for: "w1:p1"))
        #expect(bounds.viewportTop == 0)
        #expect(bounds.viewportBottom == 19)
    }

    /// Live tail: the viewport starts `max` rows into the history.
    @Test("at the bottom the viewport starts at the newest page")
    func scrolledToBottom() throws {
        let scroll = PaneSurfaceScrollMetrics(
            offsetFromBottom: 0, maxOffsetFromBottom: 100, viewportRows: 20
        )
        let store = store(panes: [pane(scroll: scroll)])
        let bounds = try #require(store.copyModeBounds(for: "w1:p1"))
        #expect(bounds.viewportTop == 100)
        #expect(bounds.viewportBottom == 119)
    }

    /// An offset larger than `max` (a stale scroll from another projection) must not
    /// produce a negative top: that would place the cursor outside the buffer.
    @Test("an over-large offset does not go negative")
    func overLargeOffsetClamps() throws {
        let scroll = PaneSurfaceScrollMetrics(
            offsetFromBottom: 500, maxOffsetFromBottom: 100, viewportRows: 20
        )
        let store = store(panes: [pane(scroll: scroll)])
        let bounds = try #require(store.copyModeBounds(for: "w1:p1"))
        #expect(bounds.viewportTop == 0, "viewportTop went negative")
    }

    // MARK: - Entry shares the bounds

    /// `copyModeEntry` must agree with `copyModeBounds`: a second copy of `max - offset`
    /// is how the two drift a row apart.
    @Test("entry uses the same bounds as the per-keypress refresh")
    func entrySharesBounds() throws {
        let scroll = PaneSurfaceScrollMetrics(
            offsetFromBottom: 30, maxOffsetFromBottom: 100, viewportRows: 20
        )
        let store = store(panes: [pane(scroll: scroll)])
        let bounds = try #require(store.copyModeBounds(for: "w1:p1"))
        let entry = try #require(store.copyModeEntry(for: "w1:p1"))

        #expect(entry.bounds.viewportTop == bounds.viewportTop)
        #expect(entry.bounds.viewportRows == bounds.viewportRows)
        #expect(entry.bounds.viewportBottom == bounds.viewportBottom)
        // The cursor starts inside the viewport, never above it.
        #expect(entry.cursor.row >= bounds.viewportTop)
        #expect(entry.cursor.row <= bounds.viewportBottom)
    }

    /// `totalRows` is history plus one viewport — the same sum the scrollbar uses for
    /// its thumb proportions.
    @Test("totalRows counts history and one viewport")
    func totalRowsCountsHistory() throws {
        let scroll = PaneSurfaceScrollMetrics(
            offsetFromBottom: 0, maxOffsetFromBottom: 100, viewportRows: 20
        )
        let store = store(panes: [pane(scroll: scroll)])
        let entry = try #require(store.copyModeEntry(for: "w1:p1"))
        #expect(entry.totalRows == 120)
    }

    // MARK: - Absent pane

    /// Asking about a pane the surface does not carry returns nil rather than a
    /// degenerate one-row viewport.
    @Test("an unknown pane has no bounds")
    func unknownPaneIsNil() {
        let store = store(panes: [pane(id: "w1:p1")])
        #expect(store.copyModeBounds(for: "w9:p9") == nil)
        #expect(store.copyModeEntry(for: "w9:p9") == nil)
    }

    /// No surface at all (before the first frame) is also nil, not a crash.
    @Test("no surface has no bounds")
    func noSurfaceIsNil() {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        #expect(store.copyModeBounds(for: "w1:p1") == nil)
    }
}
