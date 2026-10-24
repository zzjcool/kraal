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
        // A handshake is a new connection, so any latched resync belonged to the
        // old one. Left set, a rejection on this connection would take the
        // "already requested" path and never ask — the surface would stay diverged
        // for the life of the connection. `clearResyncLatch` also resets the
        // release budget for the same reason: the new connection's first question
        // is a new question.
        clearResyncLatch()
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
        let revisionAdvanced = if let previous, previous.bootId == snapshot.bootId {
            snapshot.revision > previous.revision
        } else {
            false
        }
        self.snapshot = snapshot
        // Reconcile the focus belief with the daemon's own answer (issue #55).
        // A snapshot naming a different pane means this client's belief is stale and
        // the next keystroke must re-send; a snapshot naming the same pane is
        // silence about an in-flight request and must change nothing.
        focusConfirmation.observe(focusedPaneId: snapshot.focusedPaneId)
        // The selected machine's own group reads from the main snapshot; keep its
        // catalog entry in step so switching away and back does not show the rows
        // from before the last snapshot arrived.
        syncActiveEndpointSnapshot()
        // A snapshot is the second way a latched resync's answer arrives.
        //
        // The latch means "a fresh surface is on its way". Its answer is a surface
        // on a *new* projection, and a new projection is announced two ways: the
        // re-projected frame itself (handled in `handleSurface`'s stale-projection
        // branch, which drops it because the snapshot has not caught up yet), and
        // this snapshot, which is what makes that frame current. Either can win the
        // race, so both have to end the wait — otherwise a resync whose answer
        // arrives as snapshot-then-frame leaves the latch armed forever, and every
        // later divergence takes the "already requested" path.
        //
        // **Not a per-frame trigger.** A snapshot is not a streamed frame: they
        // arrive on focus/geometry/config changes, a handful per tab switch. The
        // bound in `releaseResyncLatch` caps the damage a burst can do even so,
        // which is what keeps a fast tab-switcher from becoming H1's failure mode
        // mirrored (one resync per frame).
        //
        // `focusedTabChanged` is included because that is a projection change by
        // definition — the context the latched request was about is gone.
        if revisionAdvanced || focusedTabChanged || bootChanged {
            releaseResyncLatch("snapshot moved the projection"
                + " (revision \(previous?.revision ?? 0) -> \(snapshot.revision))")
        }
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
            // And no pane of the old daemon is focused in the new one, so the local
            // focus belief has to go with it (issue #55): keeping it would skip the
            // first focus after a reconnect.
            focusConfirmation.invalidate()
            // The baseline this latch was waiting on no longer exists, so nothing is
            // pending any more: settle the latch and its budget.
            clearResyncLatch()
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
            //
            // A dropped frame can be the answer a latched resync is waiting for. The
            // daemon restarts `surfaceRevision` when it begins a fresh projection
            // (that is why `SurfaceGeometry.deltaStreamRestarted` exists), and a
            // re-projection is exactly such a beginning — so the answer can arrive
            // with a *lower* number inside the projection we are still on, land in
            // this branch, and be dropped. Nothing else will ever arrive for that
            // request, so the wait has to end here.
            noteDroppedResyncAnswer(held: current, incoming: surface)
            return
        }
        if let snapshot, surface.projectionRevision != snapshot.revision {
            // The daemon is streaming a projection for a tab we are no longer
            // focused on. It is authoritative for that tab, not for ours.
            kraalLog("surface: stale projection \(surface.projectionRevision) "
                + "!= revision \(snapshot.revision), ignored")
            // This is the *usual* landing point of a resync's answer, not an
            // exotic one: `reprojectSurface` toggles `client_shell.surface.set`,
            // the daemon bumps its projection revision, and the re-projected
            // surface can arrive before the snapshot that would make it current.
            // Left alone, the latch stayed armed for the life of the connection.
            noteDroppedResyncAnswer(held: self.surface, incoming: surface)
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
        // Validate the whole frame here, once, where the cells are new.
        //
        // This is the other half of the patch path's speedup (issue #50).
        // `PaneSurfaceFrame.apply` no longer re-scans every cell for a hyperlink
        // index, because a patch cannot add hyperlinks and so cannot invalidate the
        // rows it does not touch — but that argument only holds if *something*
        // checked the baseline. Nothing did: `FrameData.validate()` was reachable
        // only from the patch path, so the scan that ran on every patch was also
        // the only scan that ever ran. Moving it here keeps the same total
        // coverage (every frame validated exactly once) at 1/60th the frequency.
        //
        // The cursor is clamped *before* the check, not rejected by it. A terminal
        // parked in its pending-wrap state reports `column == width`, which is
        // legal and common, and `validateGrid()` calls that out of bounds. Refusing
        // the frame for it would drop the whole screen — nothing else adopts a
        // surface, so `self.surface` would stay nil (black) or keep the previous
        // tab's cells forever, with only a tab-bar icon to show for it. The
        // renderer already clamps the host cursor it paints
        // (`SurfaceANSIRenderer.resolveHostCursor`), so clamping here just makes
        // the stored value agree with what is drawn.
        var incoming = surface
        incoming.frame.clampCursor()
        if let error = incoming.frame.firstValidationError() {
            // Refuse the frame rather than paint a grid we cannot trust: a cell
            // whose hyperlink index is out of range makes `linkURI` return nil and
            // silently drops the link, and a count that disagrees with the grid
            // means every row after the first is offset.
            lastError = "surface rejected: \(error)"
            kraalLog("surface: rejected, \(error)")
            // The latch has to come off here, or it is permanent.
            //
            // It is set when a resync is requested and cleared only by a surface
            // being adopted — and this branch is precisely the one where the
            // resync's answer gets refused. Left set, every later rejection would
            // take the "already requested" path below and never ask again: the
            // screen strands on the diverged baseline with no path back short of
            // a reconnect.
            clearResyncLatch()
            return
        }
        let previousPanes = Set(self.surface?.panes.map(\.paneId) ?? [])
        self.surface = incoming
        surfaceIsStale = false
        // The baseline is whole again: whatever triggered the re-projection (or
        // the reconnect) has been paid for, so a later rejection may ask again —
        // and the release budget that caps the weaker "projection moved" evidence
        // starts over with it.
        clearResyncLatch()
        let paneIds = Set(incoming.panes.map(\.paneId))
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
            // A rejected patch comes in two flavours, and only one of them is
            // recoverable by asking for a fresh surface.
            //
            //   diverged — `patchIdentity` / `patchBeforeBaseline`. Our baseline
            //     is not the daemon's any more, and no number of further patches
            //     will make it so. A rejection is not self-healing; the whole
            //     surface has to be re-sent.
            //
            //   refused  — everything else. The frame is fine; the daemon sent
            //     something this client will not apply (a popup owns the screen, a
            //     row is out of bounds, a hyperlink index dangles). Re-projecting
            //     returns the same screen and the same refusal, 60 times a second,
            //     so the only honest response is to record it.
            //
            // The popup case is the one that made this distinction necessary: it
            // used to be reported as `patchIdentity`, so every popup on screen
            // turned into a full re-projection per frame.
            lastError = "surface patch rejected: \(error)"
            guard Self.patchRejectionIsRecoverable(error) else {
                // Claim the frame number, cells untouched.
                //
                // A refusal leaves the frame unapplied, and it used to leave the
                // revision behind too — but the daemon has committed that frame,
                // so the *next* patch carries `base = N+1` while this client still
                // says N. The identity guard then fires, `patchIdentity` is a
                // recoverable rejection, and the store asks for a whole new
                // surface for a refusal that is going to repeat verbatim. That is
                // how "systematic refusal, no resync" became "refusal, divergence,
                // refusal, divergence": the classification flipped every other
                // frame instead of holding.
                //
                // Claiming the number is also the honest reading of the protocol:
                // the daemon's baseline moved, and this client has now *decided*
                // not to follow that frame's cells, rather than having fallen
                // behind it. Cells stay exactly as they were — a refusal must not
                // paint the content it refused.
                //
                // Note this is the first place where a rejection has a side
                // effect at all: the old wording ("a refusal changes nothing")
                // is now wrong, and the three decisions a revision feeds are
                // re-checked against an advanced-revision/unchanged-cells frame —
                // `PaneTerminalModel.apply(surface:)` (keyed on the pane's
                // `contentRevision`, grid and cells, so it repaints nothing and
                // misses nothing), `SurfaceANSIRenderer.changedRows` (only runs
                // when a render happens, and untouched rows are shared buffers),
                // `SurfaceGeometry.needsRepaint` (returns false — correct, there is
                // nothing to paint). What it does cost is one crop per pane and one
                // popup repaint per claimed frame; see the notes at
                // `KraalMacMain.popupView` and `PaneLayoutView`'s layout log.
                //
                // Every refusal reaches here only *after* the identity guard in
                // `validatePatch` has passed, so `base` is this client's revision by
                // construction — hence the unconditional assignment. If a future
                // error case were thrown before the guard, the frame number would
                // jump; `@testable` tests would see that immediately as a lost
                // patch, which is why no defensive `if` is used to hide it.
                if let held = surface {
                    var claimed = held
                    claimed.surfaceRevision = patch.surfaceRevision
                    surface = claimed
                }
                kraalLog("surface: patch refused (\(error)), not asking for a resync")
                return
            }
            if surfaceResyncLatched {
                // A fresh surface is already on its way; asking again per rejected
                // frame would be 60 rounds of commands a second. Logged, not sent.
                kraalLog("surface: patch rejected (\(error)), resync already requested")
            } else {
                kraalLog("surface: patch rejected (\(error)), requesting a fresh surface")
                resyncSurface()
            }
        }
    }

    /// Clears the "we already asked for a fresh surface" latch **and** the release
    /// budget.
    ///
    /// Used only where the question the latch asked is *settled*: a surface was
    /// adopted, a surface was refused on arrival, a handshake replaced the
    /// connection, the machine changed, the store disconnected, or the request was
    /// never sent. In all of those the next rejection is a new question, so the
    /// budget starts over.
    ///
    /// One place for it because the latch has several release points now, and a
    /// release path that forgot the budget would silently let a diverged baseline
    /// ask once per frame (see ``surfaceResyncLatchReleases``).
    func clearResyncLatch() {
        surfaceResyncLatched = false
        surfaceResyncLatchReleases = 0
    }

    /// Ends the latch on *weaker* evidence, under a budget.
    ///
    /// The latch means "a fresh surface is on its way", and several events can show
    /// that wait is over without a surface being adopted: a surface arrived and was
    /// dropped (``noteDroppedResyncAnswer``), or a snapshot revealed the projection was
    /// renumbered. Both used to leave the latch armed for the life of the connection.
    ///
    /// **Bounded**, and deliberately not via ``clearResyncLatch()``: while a resync is
    /// in flight the client sits on projection P and the daemon streams P+1 (that is
    /// what a re-projection *is*), so every subsequent frame is evidence that the
    /// wait should end. Releasing unbounded on that evidence would convert a stuck
    /// latch into one resync per frame — the bug this classification exists to
    /// prevent, mirrored. ``resyncLatchReleaseLimit`` releases per settled baseline;
    /// after that the latch stays armed and later rejections take the "already
    /// requested" path until a surface is adopted, a handshake lands, or the store
    /// disconnects.
    ///
    /// No worse than before, by construction: the pre-fix behaviour was one resync
    /// then a permanently armed latch, so the cap can only add attempts, never
    /// remove one.
    ///
    /// - Parameter reason: logged; also what the tests key their message on.
    /// - Returns: whether the latch actually came off.
    @discardableResult
    func releaseResyncLatch(_ reason: String) -> Bool {
        guard surfaceResyncLatched else { return false }
        guard surfaceResyncLatchReleases < Self.resyncLatchReleaseLimit else {
            // The evidence has stopped being new. Keeps a daemon that renumbers on
            // every frame from turning this into a flood.
            return false
        }
        surfaceResyncLatched = false
        surfaceResyncLatchReleases += 1
        kraalLog("surface: resync latch released (\(reason))")
        return true
    }

    /// Ends the latch on *weaker* evidence: a surface arrived and was **dropped**
    /// rather than adopted.
    ///
    /// The latch means "a fresh surface is on its way". A dropped surface is not a
    /// duplicate of a streamed patch — surfaces only arrive on re-projection — so a
    /// dropped one is evidence that the re-projection happened and its result is not
    /// something this client will adopt. The frame that *is* the answer will never be
    /// re-sent, so leaving the latch armed here means never asking again.
    ///
    /// Both of `handleSurface`'s early returns use this, because both are reachable
    /// by a resync's answer:
    ///
    ///   stale projection — the daemon bumped its revision and the frame beat the
    ///     snapshot that would make it current. This is the common one.
    ///   older revision — the daemon restarted `surfaceRevision` for the new
    ///     projection (that is exactly why `SurfaceGeometry.deltaStreamRestarted`
    ///     exists) and the numbered-from-1 answer is lower than what is on screen.
    ///
    /// Deliberately does not try to distinguish "the answer" from "an unrelated late
    /// frame": both are one-off events, the bound in ``releaseResyncLatch`` caps the
    /// cost of being wrong, and requiring a `projectionRevision` change instead
    /// silently missed the second case above.
    ///
    /// - Parameters:
    ///   - held: the frame still on screen, or `nil` when there is none.
    ///   - incoming: the frame that is about to be dropped.
    func noteDroppedResyncAnswer(held: PaneSurfaceFrame?, incoming: PaneSurfaceFrame) {
        guard surfaceResyncLatched else { return }
        // A frame from another daemon is not an answer about this one.
        if let held, held.bootId != incoming.bootId { return }
        releaseResyncLatch("a dropped surface answered it (projection "
            + "\(incoming.projectionRevision), revision \(incoming.surfaceRevision) "
            + "not adopted)")
    }

    /// Whether asking for a fresh surface could plausibly fix this rejection.
    ///
    /// A pure function so the rule is readable in one place and testable without
    /// a daemon. Everything not listed is a *refusal*: the daemon's frame is
    /// intact and re-sending it changes nothing.
    nonisolated static func patchRejectionIsRecoverable(_ error: any Error) -> Bool {
        guard let surfaceError = error as? SurfaceError else { return false }
        return switch surfaceError {
        case .patchIdentity, .patchBeforeBaseline:
            true
        case .patchPopupOpen, .patchRowBounds, .patchRowOverlap, .patchGeometry,
             .cellCount, .hyperlinkIndex, .cursorBounds, .bootIdMismatch,
             .unexpectedValidationFailure:
            false
        }
    }

    /// Asks the daemon to re-project the tab we are showing.
    ///
    /// Toggling `client_shell.surface.set` off and on is the only lever the
    /// protocol offers; a daemon that does not serve that method cannot be asked,
    /// so the handshake is redone instead (which re-projects as a side effect).
    ///
    /// **Latched**: the first request sets `surfaceResyncLatched`, and nothing is
    /// requested again until the question is settled. Settled means a fresh surface
    /// was adopted or refused in ``handleSurface``, a handshake/machine switch/
    /// disconnect replaced the context, or the projection demonstrably moved while we
    /// waited (``releaseResyncLatch``, bounded). An in-flight flag cannot do this — it
    /// would clear as soon as the request finished, long before the fresh surface
    /// landed, and a diverged baseline (every patch rejected) would re-arm it
    /// immediately.
    ///
    /// The reconnect branch is the one that used to be worst: with
    /// `resetBackoff: true` every rejection zeroed `reconnectAttempt` and tore the
    /// endpoint down. The latch now guards it the same way.
    ///
    /// This is what `resyncPending` in ``handleSurface`` does for the "daemon
    /// cannot re-project" case, extended to cover the whole patch-rejection round
    /// trip; the two flags stay separate because they answer different questions.
    func resyncSurface() {
        guard !surfaceResyncLatched else { return }
        surfaceResyncLatched = true
        surfaceResyncRequests += 1
        Task { [weak self] in
            guard let self else { return }
            if supportsSurfaceInterest {
                // `reprojectSurface` gives up when a toggle is already in flight.
                // That is not a reason to keep the latch: the in-flight request
                // was for some *earlier* reason (a tab switch, a split) and
                // finishes long before our fresh surface would arrive. Keeping the
                // latch armed on a request that was never sent swallows the next
                // legitimate one.
                if await !self.reprojectSurface() {
                    kraalLog("surface: resync skipped (a re-projection was already in "
                        + "flight); releasing the latch so the next rejection can ask")
                    // Not `releaseResyncLatch`: the request was never sent, so this
                    // must give the latch back whole — including the budget, or a
                    // burst of dropped requests would eat it.
                    self.clearResyncLatch()
                }
            } else {
                scheduleReconnect(resetBackoff: true)
            }
        }
    }
}
