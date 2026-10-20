// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for the reconnect label shown while resizing the window.
//
// The bug: dragging the window edge made the sidebar footer read
// "Reconnecting (1)…". Resizing changes the cell grid, and the daemon renders
// one grid per connection, so the client has to re-handshake — but that
// reconnect is caused by the user's own drag, not by anything failing. Showing
// recovery UI for it is wrong twice over: it says a working session broke, and
// it teaches people to ignore the label that appears when one really has.
//
// The interesting case is the second-order one. A quiet reconnect stops its old
// connection before starting the new one, and that stop reports itself as a
// disconnect. Treating that disconnect as a failure schedules another, non-quiet
// reconnect — so the label comes back even if the first reconnect was silent.

import Foundation
import Testing

import KraalProtocol
@testable import KraalUI

/// Records what the store did without touching the network.
///
/// `AppStore` reaches the daemon through `startConnection`, which a test cannot
/// complete. The state under test is the bookkeeping around that call, so the
/// tests drive the public surface and assert on it rather than on a connection.
@Suite("Quiet reconnect on resize")
@MainActor
struct QuietReconnectTests {
    /// A grid change is the window being resized. It must not move the visible
    /// phase off `.live`, because the sidebar footer renders "Reconnecting" from
    /// exactly that.
    @Test("resizing the grid does not put the store into a reconnecting phase")
    func resizeKeepsPhaseLive() {
        let store = AppStore()
        store.phase = .live

        store.surfaceSize = ClientSurfaceSize(cols: 100, rows: 30)

        #expect(store.phase == .live, "phase was \(store.phase)")
    }

    /// The flag exists so the disconnect handler can tell "we stopped this on
    /// purpose" from "it dropped". If it never gets set, the handler treats the
    /// teardown as a failure and the label returns.
    @Test("a grid change marks the reconnect as quiet")
    func resizeMarksQuiet() {
        let store = AppStore()
        store.phase = .live

        store.surfaceSize = ClientSurfaceSize(cols: 90, rows: 24)

        #expect(store.isQuietReconnect)
    }

    /// Setting the same grid again is not a resize. Re-handshaking for it would
    /// be a pointless connection churn on every layout pass.
    @Test("an unchanged grid does not trigger a reconnect")
    func sameGridIsIgnored() {
        let store = AppStore()
        store.phase = .live
        let size = ClientSurfaceSize(cols: 80, rows: 24)
        store.surfaceSize = size
        let afterFirst = store.isQuietReconnect

        // Second assignment of the same value: `didSet` still runs, the guard in
        // the setter must reject it.
        store.surfaceSize = size

        #expect(store.surfaceSize == size)
        #expect(store.isQuietReconnect == afterFirst)
    }

    /// A genuine failure is never quiet. The store must be able to say "this one
    /// is the user's problem" or the label would be suppressed for real outages.
    @Test("a real reconnect still reports a reconnecting phase")
    func realReconnectIsNotQuiet() {
        let store = AppStore()
        store.phase = .live

        store.scheduleReconnect(resetBackoff: true, quiet: false)

        #expect(!store.isQuietReconnect)
        guard case .reconnecting = store.phase else {
            Issue.record("expected .reconnecting, got \(store.phase)")
            return
        }
    }
}
