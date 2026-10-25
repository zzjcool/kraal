// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AppStore+Sidebar.swift
//  KraalUI
//
//  The sidebar's user-adjustable settings.
//
//  Split out of `AppStore.swift` because that file sits on `type_body_length`:
//  the store is already at its line budget, and a preference with a `didSet`
//  writes back to disk, which does not belong in the middle of the connection
//  plumbing.
//

import Foundation
import KraalProtocol

extension AppStore {

    /// How the agents pane orders its rows.
    ///
    /// Persisted locally (`SidebarPreferences`), mirroring upstream's
    /// `ClientChromePreferences.agent_panel_sort` (`preferences.rs:29`) — the
    /// ordering is a client preference, not something the daemon knows about.
    public var agentPanelSort: AgentPanelSort {
        get { storedAgentPanelSort }
        set {
            guard newValue != storedAgentPanelSort else { return }
            storedAgentPanelSort = newValue
            SidebarPreferences.storeAgentSort(newValue)
        }
    }

    /// Stamp a machine's changed agents, then adopt its snapshot.
    ///
    /// Both halves in one call so a caller cannot replace the snapshot without
    /// recording the change — the ordering would then be silently stale, which looks
    /// like the sort "sometimes" being wrong.
    func adoptSnapshot(
        _ snapshot: ClientShellSnapshot,
        for endpoint: EndpointState
    ) {
        agentRecency.observe(
            endpointID: endpoint.id.storageKey,
            snapshot: snapshot,
            previous: endpoint.snapshot
        )
        endpoint.snapshot = snapshot
    }
}
