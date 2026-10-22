// SPDX-License-Identifier: Apache-2.0
//
//  AppStore+Events.swift
//  Kraal
//
//  Reduction of connection events into store state.
//
//  Kept apart from the store's storage and actions because the tab/surface
//  interplay is the subtle part of this client: a daemon either re-projects on
//  request or never changes projection at all, and the two cases need different
//  responses to the same event.
//

import Foundation
import KraalClient
import KraalProtocol

extension AppStore {
    func handleWelcome(_ welcome: EndpointServerWelcome) {
        kraalLog("welcome: \(welcome.serverVersion) gen=\(welcome.generation)")
        self.welcome = welcome
        resyncPending = false
        if phase != .live {
            phase = .live
        }
        surfaceIsStale = false
    }

    /// Whether an incoming snapshot belongs to the projection we are already on.
    ///
    /// Revisions only ever increase within one boot. A smaller one means the
    /// stream was renumbered under us, and every surface is fenced on
    /// `projectionRevision == snapshot.revision` — so adopting the regression
    /// makes every live frame look stale at once and the screen freezes, with no
    /// later frame able to recover on its own.
    ///
    /// A different boot id is *not* a regression: the daemon restarted, so the
    /// counter legitimately starts over. That is why this compares boot ids
    /// first instead of just the revision.
    ///
    /// Split out as a pure function so the rule is testable without a daemon —
    /// the same reason `eventIsCurrent` is shaped this way.
    nonisolated static func snapshotIsCurrent(
        incomingRevision: UInt64,
        incomingBootId: String,
        currentRevision: UInt64?,
        currentBootId: String?
    ) -> Bool {
        guard let currentRevision, let currentBootId else { return true }
        guard incomingBootId == currentBootId else { return true }
        return incomingRevision >= currentRevision
    }

    func handleSnapshot(_ snapshot: ClientShellSnapshot) {
        let previous = self.snapshot
        guard Self.snapshotIsCurrent(
            incomingRevision: snapshot.revision,
            incomingBootId: snapshot.bootId,
            currentRevision: previous?.revision,
            currentBootId: previous?.bootId
        ) else {
            // Do not drop this silently: a frozen screen with no explanation is
            // the failure mode this fence exists to prevent.
            let message = "snapshot revision \(snapshot.revision) regressed below "
                + "\(previous?.revision ?? 0); keeping the newer projection"
            kraalLog(message)
            lastError = message
            return
        }
        // `commands` is logged with its popup ids because a popup can only be opened
        // by invoking one, and "the daemon registered no such command" is otherwise
        // indistinguishable from "the client cannot draw a popup". Both were true at
        // different points while this was built; this line tells them apart.
        let popupCommands = snapshot.commands.filter { $0.action == .popup }
        kraalLog("snapshot: ws=\(snapshot.workspaces.count) tabs=\(snapshot.tabs.count) "
            + "panes=\(snapshot.panes.count) agents=\(snapshot.agents.count) "
            + "commands=\(snapshot.commands.count) popup=\(popupCommands.count)"
            + (popupCommands.isEmpty ? "" : " ids=\(popupCommands.map(\.commandId).joined(separator: ","))"))
        // A newer boot id invalidates every surface we hold.
        let bootChanged = self.snapshot?.bootId != snapshot.bootId
        let focusedTabChanged = self.snapshot?.focusedTabId != snapshot.focusedTabId
        self.snapshot = snapshot
        // The selected machine's own group reads from the main snapshot; keep its
        // catalog entry in step so switching away and back does not show the rows
        // from before the last snapshot arrived.
        syncActiveEndpointSnapshot()
        guard bootChanged || focusedTabChanged else { return }
        // Keep the previous frame on screen while the daemon re-projects.
        //
        // Clearing it here is what produced the black flash on a tab switch: the
        // pane views are torn down, `PaneLayoutView` has nothing to draw but its
        // background, and the new projection lands tens of milliseconds later.
        // The old frame is stale in the sense that it shows another tab, but a
        // stale frame that is replaced ~30 ms later reads as a smooth switch,
        // while a blank rectangle reads as a crash. The new surface replaces it
        // wholesale in `handleSurface`.
        if bootChanged {
            // A new boot id means the old frame belongs to a dead daemon; there is
            // nothing meaningful to keep.
            surface = nil
        } else {
            kraalLog("snapshot: tab changed, holding previous frame until re-projection")
        }
        if supportsSurfaceInterest {
            // Claiming interest makes the daemon stream the new tab's projection.
            requestSurfaceInterest()
        } else {
            // No way to switch projections on a live connection, so the only way
            // to see the new focus is a new handshake.
            kraalLog("snapshot: tab changed and daemon lacks surface_interest, reconnecting")
            scheduleReconnect(resetBackoff: true)
        }
    }

    func handleSurface(_ surface: PaneSurfaceFrame) {
        if let current = self.surface,
           current.surfaceRevision > surface.surfaceRevision,
           current.bootId == surface.bootId,
           current.projectionRevision == surface.projectionRevision {
            // Only comparable within one projection: two projections number their
            // frames independently, so a held-over frame from the previous tab
            // must not veto the first frame of the new one.
            return
        }
        if let snapshot, surface.projectionRevision != snapshot.revision {
            // The daemon is streaming a projection for a tab we are no longer
            // focused on. It is authoritative for that tab, not for ours.
            kraalLog("surface: stale projection \(surface.projectionRevision) "
                + "!= revision \(snapshot.revision), ignored")
            if !supportsSurfaceInterest, !resyncPending {
                // Older daemons never re-project and never send another snapshot
                // when the focus moves, so staying connected means showing the
                // wrong tab forever. The guard keeps a still-stale surface from
                // restarting the reconnect on every frame.
                resyncPending = true
                kraalLog("surface: daemon cannot re-project, reconnecting")
                scheduleReconnect(resetBackoff: true)
            }
            return
        }
        kraalLog("surface: \(surface.frame.width)x\(surface.frame.height) "
            + "panes=\(surface.panes.map(\.paneId).joined(separator: ",")) "
            + "rev=\(surface.surfaceRevision)")
        let previousPanes = Set(self.surface?.panes.map(\.paneId) ?? [])
        self.surface = surface
        surfaceIsStale = false
        let paneIds = Set(surface.panes.map(\.paneId))
        if paneIds != previousPanes {
            onPaneSetChanged?(paneIds)
        }
    }

    func handleSurfacePatch(_ patch: PaneSurfacePatch) {
        guard var current = surface, current.bootId == patch.bootId else { return }
        guard patch.projectionRevision == current.projectionRevision else { return }
        do {
            try current.apply(patch)
            surface = current
        } catch {
            // A rejected patch means our baseline diverged; ask for a fresh
            // surface rather than showing a corrupt screen.
            lastError = "surface patch rejected: \(error)"
        }
    }
}
