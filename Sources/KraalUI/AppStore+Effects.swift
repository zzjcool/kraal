// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AppStore+Effects.swift
//  KraalUI
//
//  Where a pane's desktop-side requests are routed and folded.
//
//  Split out of `AppStore+Endpoints.swift` when that file passed swiftlint's
//  900-line limit. The split is along a real seam: everything here is about what a
//  pane wants the *desktop* to do (clipboard, window title, bell, notification),
//  which is a different question from what a connection does with a snapshot.
//
//  `private` became internal for the move. That is the cost of the split; these are
//  not part of the store's public surface and are not called from outside.
//

import Foundation
import KraalClient
import KraalProtocol

extension AppStore {
    func handleEffectEvent(
        _ event: ConnectionEvent,
        from endpoint: EndpointState,
        isActive: Bool
    ) {
        // Notifications ignore `isActive` on purpose. Clipboard and window title must
        // not be applied for a machine that is not on screen — they would overwrite
        // what the visible machine put there. A notification is the opposite: "an
        // agent on the *other* machine is blocked waiting for you" is exactly the case
        // worth interrupting for, and dropping it made the multi-machine setup silent.
        if case let .notification(notification) = event {
            // The label travels with the effect rather than being read at post time:
            // by the time the desktop drains the queue the user may have switched
            // machines, and `[alpha-b]` would then name the wrong one.
            pendingEffects.notification = notification
            pendingEffects.notificationMachine = endpoints.count > 1
                ? endpoint.label
                : nil
            drainEffects()
            return
        }
        guard isActive else { return }
        switch event {
        case .clipboard, .windowTitle, .bell:
            applyEffects(event)
        default:
            break
        }
    }

    /// Records the daemon's `ClientShellKeyboardReportAll` for one machine.
    ///
    /// Connection level, matching the daemon: the message carries no pane id — it
    /// reports the mode of whichever program is focused now
    /// (`server/headless/render.rs:211-214`). Kept per machine so switching
    /// machines restores each side's answer instead of leaking one machine's
    /// keyboard mode into the other's panes.
    ///
    /// Split out of `applyEndpointEvent` rather than inlined: that switch is one
    /// branch per event and adding two pushed it past the complexity limit.
    func applyKeyboardReportAll(
        _ enabled: Bool,
        from endpoint: EndpointState,
        isActive: Bool
    ) {
        endpoint.keyboardReportAll = enabled
        kraalLog("endpoint \(endpoint.label): keyboard report-all \(enabled)")
        if isActive { keyboardReportAll = enabled }
    }

    /// Folds one effect-carrying event into `pendingEffects` and lets the
    /// desktop act on the result.
    ///
    /// Only the foreground machine's events reach here. A background machine
    /// keeps its snapshot and status up to date, but its bells must not ring in
    /// this window and its clipboard must not overwrite yours: selection is what
    /// decides whose terminal you are looking at.
    func applyEffects(_ event: ConnectionEvent) {
        pendingEffects = TerminalEffectsReducer.reduce(
            pendingEffects,
            event: event,
            fallbackTitle: activeEndpoint?.label ?? "Kraal",
            sessionSuffix: DevSession.windowTitleSuffix(name: DevSession.name)
        )
        drainEffects()
    }
}
