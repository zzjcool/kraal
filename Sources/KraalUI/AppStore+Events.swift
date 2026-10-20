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

    func handleSnapshot(_ snapshot: ClientShellSnapshot) {
        kraalLog("snapshot: ws=\(snapshot.workspaces.count) tabs=\(snapshot.tabs.count) "
            + "panes=\(snapshot.panes.count) agents=\(snapshot.agents.count)")
        // A newer boot id invalidates every surface we hold.
        let bootChanged = self.snapshot?.bootId != snapshot.bootId
        let focusedTabChanged = self.snapshot?.focusedTabId != snapshot.focusedTabId
        self.snapshot = snapshot
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
