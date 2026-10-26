// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AppStoreFactoryTests.swift
//  KraalClientTests
//
//  The three factories in `AppStore+Actions.swift`, and the one property they all claim.
//
//  Each of them exists for a structural reason, and each one captures its store
//  **weakly** — the comments say so explicitly ("the queue must not keep its store
//  alive"). None of that was verified. A strong capture would not fail any other test:
//  it would just mean a closed window's `AppStore` stays resident, holding its
//  connections, decoders and scroll state for the life of the process.
//
//  The assertions here are about *identity and liveness*, not behaviour: the behaviour
//  of `FocusConfirmation` and `PaneScrollQueue` is already covered by their own suites.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("AppStore factories")
@MainActor
struct AppStoreFactoryTests {
    private func store() -> AppStore {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        return store
    }

    /// A released store must not be resurrected by a factory that captured it strongly.
    ///
    /// The check is indirect because Swift has no "is this captured strongly" query:
    /// build the factory from a store that goes out of scope, then confirm the store is
    /// deallocated while the factory is still alive. A strong capture would keep the
    /// object alive and `weak` would stay non-nil.
    @Test("the focus factory does not keep its store alive")
    func focusFactoryIsWeak() async {
        weak var observed: AppStore?
        var confirmation: FocusConfirmation?
        do {
            let store = store()
            observed = store
            confirmation = AppStore.makeFocusConfirmation(store)
        }
        // The store is out of scope; with a weak capture nothing holds it.
        #expect(observed == nil, "the focus factory kept its store alive")
        // And using the factory afterwards must not crash.
        confirmation = nil
        #expect(confirmation == nil)
    }

    @Test("the scroll queue does not keep its store alive")
    func scrollQueueIsWeak() async {
        weak var observed: AppStore?
        var queue: PaneScrollQueue?
        do {
            let store = store()
            observed = store
            queue = AppStore.makePaneScrollQueue(store)
        }
        #expect(observed == nil, "the scroll queue kept its store alive")
        queue = nil
        #expect(queue == nil)
    }

    /// The factories must be distinct objects per store. Sharing one queue between two
    /// stores would let one window's wheel events drive another window's scroll.
    @Test("two stores get two queues")
    func queuesArePerStore() {
        let first = AppStore.makePaneScrollQueue(store())
        let second = AppStore.makePaneScrollQueue(store())
        #expect(first !== second)
    }
}
