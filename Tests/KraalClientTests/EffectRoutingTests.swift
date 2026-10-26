// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  EffectRoutingTests.swift
//  KraalClientTests
//
//  Which machine's effects reach the desktop, and the one exception.
//
//  Clipboard, window title and bell belong to the machine on screen: applying a
//  background machine's would overwrite what the visible one put there. A notification is
//  the opposite — "an agent on the *other* machine is blocked waiting for you" is exactly
//  the case worth interrupting for, and dropping it made the multi-machine setup silent
//  (#140).
//
//  So `handleEffectEvent` skips `isActive` for notifications and honours it for
//  everything else. Getting that backwards is silent in both directions: either no
//  notification ever appears for a second machine, or a background machine's bell rings
//  and its title wins.
//
//  The machine label travels **with** the effect rather than being read when the desktop
//  drains the queue: by then the user may have switched machines, and `[alpha-b]` would
//  name the wrong one.
//

import Foundation
import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalUI

@Suite("Effect routing")
@MainActor
struct EffectRoutingTests {
    private func store(machineCount: Int = 2) -> (AppStore, EndpointState) {
        let store = AppStore(target: .local)
        var endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        for index in 1 ..< machineCount {
            endpoints.append(EndpointState(
                id: .ssh(id: "m\(index)"), label: "alpha-b", settings: .local
            ))
        }
        store.endpoints = endpoints
        store.activeEndpointID = .local
        return (store, endpoints[0])
    }

    private func notification() -> SemanticNotification {
        SemanticNotification(
            kind: .needsAttention,
            title: "agent blocked",
            body: "waiting for you",
            sound: nil,
            agent: "claude",
            workspaceId: "w1",
            tabId: "w1:t1",
            paneId: "w1:p1"
        )
    }

    /// A background machine's notification must still reach the desktop.
    @Test("a background machine's notification reaches the desktop")
    func backgroundNotificationPasses() {
        let (store, localEndpoint) = store()
        var delivered: [TerminalEffects] = []
        store.onEffectsChanged = { delivered.append($0) }

        let remote = store.endpoints[1]
        store.handleEffectEvent(.notification(notification()), from: remote, isActive: false)

        #expect(!delivered.isEmpty,
                "a background machine's notification was dropped, so a blocked agent there is silent")
        #expect(delivered.last?.notification != nil)
    }

    /// And the label is captured at that moment, not read later.
    @Test("the machine label travels with the notification")
    func machineLabelTravels() {
        let (store, _) = store()
        var delivered: [TerminalEffects] = []
        store.onEffectsChanged = { delivered.append($0) }

        let remote = store.endpoints[1]
        store.handleEffectEvent(.notification(notification()), from: remote, isActive: false)

        #expect(delivered.last?.notificationMachine == "alpha-b",
                "the machine was not named with the notification")
    }

    /// With only one machine there is nothing to disambiguate, so no label is added.
    @Test("a single machine adds no label")
    func singleMachineHasNoLabel() {
        let (store, localEndpoint) = store(machineCount: 1)
        var delivered: [TerminalEffects] = []
        store.onEffectsChanged = { delivered.append($0) }

        store.handleEffectEvent(.notification(notification()), from: localEndpoint, isActive: true)
        #expect(delivered.last?.notificationMachine == nil,
                "a lone machine still labelled its notifications")
    }

    /// A background machine's bell must not ring here.
    @Test("a background machine's bell does not ring")
    func backgroundBellIsDropped() {
        let (store, _) = store()
        var delivered: [TerminalEffects] = []
        store.onEffectsChanged = { delivered.append($0) }

        let remote = store.endpoints[1]
        store.handleEffectEvent(.bell(count: 1), from: remote, isActive: false)
        #expect(delivered.isEmpty, "a background machine rang this window's bell")
    }

    /// A background machine's window title must not win.
    @Test("a background machine's title does not apply")
    func backgroundTitleIsDropped() {
        let (store, _) = store()
        var delivered: [TerminalEffects] = []
        store.onEffectsChanged = { delivered.append($0) }

        let remote = store.endpoints[1]
        store.handleEffectEvent(.windowTitle("remote title"), from: remote, isActive: false)
        #expect(delivered.isEmpty, "a background machine's title won over the visible one's")
    }

    /// The foreground machine's effects do apply.
    @Test("the foreground machine's effects apply")
    func foregroundEffectsApply() {
        let (store, localEndpoint) = store()
        var delivered: [TerminalEffects] = []
        store.onEffectsChanged = { delivered.append($0) }

        store.handleEffectEvent(.bell(count: 1), from: localEndpoint, isActive: true)
        #expect(!delivered.isEmpty, "the visible machine's own bell was dropped")
    }

    /// Draining clears the queue, so the same effect cannot be delivered twice.
    @Test("a drained effect is not delivered again")
    func drainClears() {
        let (store, localEndpoint) = store()
        var delivered: [TerminalEffects] = []
        store.onEffectsChanged = { delivered.append($0) }

        store.handleEffectEvent(.bell(count: 1), from: localEndpoint, isActive: true)
        let first = delivered.count
        store.drainEffects()
        #expect(delivered.count == first, "draining an empty queue delivered something")
    }
}
