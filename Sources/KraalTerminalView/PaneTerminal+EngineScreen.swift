// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import GhosttyTerminal
import KraalUI

/// Rewriting the pane when the engine's screen really changes size.
///
/// See `EngineScreenReport` for the race. The rule is one line: **whenever the engine says
/// its screen changed, write the whole frame again.** A frame written before the change was
/// parsed against the old screen and may have been clamped onto its last row; one written
/// after is already right and is merely written twice. Nothing here tries to *predict* which
/// it was — the first attempt at that (laying frames out in the announced grid instead of the
/// view's) was measured to change nothing, because the announcement itself races the writes.
extension PaneTerminalModel {
    /// Asks the surface to announce its screen size, once per surface.
    ///
    /// Safe before the surface exists: the session queues the bytes and the engine reads them
    /// in front of the first frame.
    func requestEngineScreenIfNeeded() {
        guard !isPopup, !engineReportsRequested else { return }
        engineReportsRequested = true
        session.receive(EngineScreenReport.enableSequence)
    }

    /// The engine announced its screen. Runs on the main actor, in the order announced.
    func engineScreenDidChange(_ batch: [EngineScreenReport]) {
        guard let latest = batch.last else { return }
        let moved = Self.screenMoved(from: engineScreen, through: batch)
        engineScreen = latest
        guard moved else { return }
        kraalLog("engine screen: pane=\(paneId) \(latest.columns)x\(latest.rows)"
            + " announcements=\(batch.count)")
        // Everything on screen may have been rearranged by the resize, so what the renderer
        // believes is drawn is not known to be. Write the frame again, all of it.
        engineScreenMoved = true
        reapplyAfterGridViewMoved()
    }

    /// Whether the cell grid changed at any point across `batch`.
    ///
    /// Every announcement is compared with the one before it, not just the last with the
    /// first. A screen that went 34 -> 38 -> 34 rows ends where it began, yet a frame parsed
    /// while it was 38 tall was rearranged on the way back; looking only at the endpoints
    /// reads that as "nothing happened".
    nonisolated static func screenMoved(
        from known: EngineScreenReport?,
        through batch: [EngineScreenReport]
    ) -> Bool {
        var previous = known
        for report in batch {
            // The first announcement is a change too: no write has been checked against an
            // engine screen yet, so there is no baseline to trust.
            guard let before = previous, before.sameGrid(as: report) else { return true }
            previous = report
        }
        return false
    }

    /// Forgets what the engine said, because the surface that said it is gone.
    func forgetEngineScreen() {
        engineScreen = nil
        engineReportsRequested = false
        engineScreenMoved = false
    }

    /// Notices that Ghostty replaced its surface, which starts empty and unarmed.
    ///
    /// The surface is held weakly and compared as an object. An `ObjectIdentifier` is an
    /// address, and an address can be handed to a replacement once the original is freed;
    /// whether that ever happened here is not known, but nothing below depends on it being
    /// impossible. A replacement matters more now than it used to: the new engine has never
    /// been asked for its size, and without a fresh request the repaint above never fires.
    func noteSurfaceIdentity() {
        guard let live = state.surface else { return }
        if Self.surfaceWasReplaced(seenBefore: hasSeenSurface, previous: seenSurface, current: live) {
            kraalLog("surface replaced: pane=\(paneId) forgetting the painted frame")
            frameGrid = nil
            lastRevision = 0
            forgetEngineScreen()
        }
        seenSurface = live
        hasSeenSurface = true
    }
}
