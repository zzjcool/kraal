// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  EffectRoutingTests.swift
//  KraalClientTests
//
//  Which machine's desktop-side effects are allowed through.
//
//  Clipboard and window title are suppressed for a machine that is not on screen:
//  otherwise a background machine's copy would replace yours and its title would
//  rewrite the window. Notifications are the exception — "an agent on the *other*
//  machine is blocked waiting for you" is the whole point of watching several
//  machines, and the same blanket suppression made that case silent.
//
//  These run against `handleEffectEvent` rather than the applier: the applier's work
//  is AppKit (`UNUserNotificationCenter`, `NSPasteboard`), which cannot be asserted
//  headlessly. The decision is what can be, and the decision is what was wrong.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalUI

@Suite("Effect routing")
@MainActor
struct EffectRoutingTests {
    /// A store with one local machine selected. `AppStore()` starts empty, so the
    /// endpoints have to be supplied the way the app's startup does.
    private func store() -> (AppStore, EndpointState) {
        let store = AppStore(target: .local)
        let endpoint = EndpointState(id: .local, label: "Local", settings: .local)
        store.endpoints = [endpoint]
        store.activeEndpointID = .local
        return (store, endpoint)
    }

    /// The batch the desktop would have received.
    private func drained(from store: AppStore) -> TerminalEffects? {
        var seen: TerminalEffects?
        store.onEffectsChanged = { seen = $0 }
        return seen
    }

    @Test("a bell from a background machine does not ring")
    func backgroundBellSuppressed() {
        let (store, endpoint) = self.store()
        var seen: TerminalEffects?
        store.onEffectsChanged = { seen = $0 }
        store.handleEffectEvent(.bell(count: 1), from: endpoint, isActive: false)
        #expect(seen == nil, "a background machine's bell reached the desktop")
    }

    @Test("a notification from a background machine still gets through")
    func backgroundNotificationDelivered() {
        let (store, endpoint) = self.store()
        var seen: TerminalEffects?
        store.onEffectsChanged = { seen = $0 }
        let notification = SemanticNotification(
            kind: .needsAttention,
            title: "agent needs attention"
        )
        store.handleEffectEvent(.notification(notification), from: endpoint, isActive: false)
        #expect(seen?.notification == notification,
                "the notification was dropped because its machine was not on screen")
    }

    /// A background machine that is the *only* machine is still "not active" while
    /// another one is selected, and that is exactly when the notice matters.
    @Test("a notification carries the machine label when several machines exist")
    func notificationCarriesMachineLabel() {
        let (store, endpoint) = self.store()
        var seen: TerminalEffects?
        store.onEffectsChanged = { seen = $0 }
        // Two machines, so a label is needed to tell them apart. The store starts with
        // one; a second entry makes the label meaningful.
        store.endpoints.append(EndpointState(
            id: .ssh(id: "alpha-b"),
            label: "alpha-b",
            settings: .local
        ))
        let notification = SemanticNotification(kind: .finished, title: "done")
        store.handleEffectEvent(.notification(notification), from: endpoint, isActive: false)
        #expect(seen?.notificationMachine == endpoint.label,
                "the notice did not say which machine it was about")
    }

    /// With a single machine the label is noise: every notice is about the one
    /// machine the user is looking at.
    @Test("a single-machine notification has no label")
    func singleMachineHasNoLabel() {
        let (store, endpoint) = self.store()
        var seen: TerminalEffects?
        store.onEffectsChanged = { seen = $0 }
        let notification = SemanticNotification(kind: .finished, title: "done")
        store.handleEffectEvent(.notification(notification), from: endpoint, isActive: true)
        #expect(seen?.notificationMachine == nil)
    }

    @Test("an active machine still delivers its bell")
    func activeBellDelivered() {
        let (store, endpoint) = self.store()
        var seen: TerminalEffects?
        store.onEffectsChanged = { seen = $0 }
        store.handleEffectEvent(.bell(count: 1), from: endpoint, isActive: true)
        #expect(seen?.bells == 1)
    }
}

/// The notifier's own decision, which is not about AppKit.
///
/// `post` needs `UNUserNotificationCenter`, so the *post* is not asserted here; the
/// availability decision is, because getting it wrong is invisible: a build without a
/// bundle identifier must report `unavailable` rather than crash or silently pretend
/// to have posted.
@Suite("System notifier")
@MainActor
struct SystemNotifierTests {
    /// `swift test` runs in an xctest host, which has a bundle identifier of its own.
    /// The check exists for the opposite case — a bare executable — and this pins that
    /// it is answered from the bundle rather than hard-coded either way.
    @Test("availability follows the bundle identifier")
    func availabilityFollowsBundle() {
        let hasBundle = Bundle.main.bundleIdentifier != nil
        #expect(SystemNotifier.isAvailable == hasBundle)
    }

    /// Outside a bundle the answer must be `unavailable`, and asking must not throw or
    /// trap. This is the path that keeps `swift test` from standing up a notification
    /// centre.
    @Test("posting outside a bundle reports unavailable")
    func postingOutsideBundleIsUnavailable() async {
        guard !SystemNotifier.isAvailable else { return }
        let notifier = SystemNotifier()
        let outcome = await notifier.post(
            SemanticNotification(kind: .finished, title: "t"),
            machine: nil
        )
        #expect(outcome == .unavailable)
    }
}
