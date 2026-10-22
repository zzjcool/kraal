// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AppStore+CopyMode.swift
//  Kraal
//
//  Glue between the copy-mode state machine and the daemon.
//
//  Everything decision-shaped lives in `CopyMode.swift` and is tested there; this
//  file only spends round trips and applies answers. That split is deliberate — the
//  interesting bugs are "the cursor was clamped wrong" and "the range was reversed",
//  and neither needs a daemon to reproduce.
//
//  ## The daemon owns two things the client cannot compute
//
//  - **Word boundaries.** `pane.copy_motion` answers "where does the next word
//    start" from the pane's text. The client has only the visible screen, and not
//    even that in a form it can index by text offset.
//  - **The text itself.** `pane.selection.read` extracts a range. This is the whole
//    reason copy mode exists in this client: the pane's scrollback lives in the
//    daemon, so history is unreachable from the local terminal.
//

import AppKit
import Foundation
import KraalProtocol

/// What the copy mode needs from a pane to start.
///
/// Named rather than a tuple: three unlabelled members of two types is the kind of
/// thing that gets destructured in the wrong order once and stays wrong.
public struct CopyModeEntry: Equatable, Sendable {
    /// Where the cursor starts, already clamped into `bounds`.
    public var cursor: CopyModeCursor
    /// The visible rows, in the daemon's text space.
    public var bounds: CopyModeBounds
    /// Rows of text the pane holds, history included.
    public var totalRows: Int
}

public extension AppStore {
    /// Surfaces a message the user should see, from outside the store's module.
    ///
    /// `lastError` is `internal(set)` on purpose — the store's own requests are the
    /// only thing that should normally write it, so a failure cannot be manufactured
    /// by a view. This is the one case that needs it: copy mode lives in the app
    /// target (it needs AppKit key events), and "nothing to copy" is not a failed
    /// request, so it has no `call` to attach itself to.
    func reportCopyModeMessage(_ message: String) {
        lastError = message
    }

    /// Whether the daemon serves the copy-mode methods at all.
    ///
    /// Checked before offering the menu item: an older daemon would answer with a
    /// refusal, which surfaces as an error banner for a feature that simply is not
    /// there. The method list is the contract — see `supportsSurfaceInterest`.
    var supportsCopyMode: Bool {
        guard let methods = welcome?.methods else { return false }
        return methods.contains("pane.selection.read") && methods.contains("pane.copy_motion")
    }

    /// Where the copy-mode cursor should start, and the bounds it may move in.
    ///
    /// The starting point is the terminal's own cursor when that cursor belongs to
    /// this pane and is on screen — the user is already looking there. Otherwise it
    /// is the bottom-left of the viewport, which is where a shell prompt usually is.
    ///
    /// Rows are converted from screen space to the daemon's text space, where row 0
    /// is the first line the pane ever printed. That conversion is the whole reason
    /// this is not just "pass the cursor through": a selection made one screenful up
    /// would read the right *shape* of text from the wrong place, and the wrong text
    /// still copies fine.
    /// The viewport bounds alone, for refreshing mid-session.
    ///
    /// Separate from `copyModeEntry` because the controller needs this on every
    /// keypress (the viewport moves under the mode) while the entry point is only
    /// needed once.
    func copyModeBounds(for paneId: String) -> CopyModeBounds? {
        guard let surface,
              let pane = surface.panes.first(where: { $0.paneId == paneId }) else { return nil }
        let scroll = pane.scroll
        let maxOffset = scroll?.maxOffsetFromBottom ?? 0
        let offset = scroll?.offsetFromBottom ?? 0
        return CopyModeBounds(
            viewportTop: Int(maxOffset > offset ? maxOffset - offset : 0),
            // The daemon's own count when it sent one: `innerRect.height` is the
            // client's idea of the same thing, and the two can differ by a
            // reserved row, which would silently shift every clamp by one.
            viewportRows: max(Int(scroll?.viewportRows ?? UInt64(pane.innerRect.height)), 1)
        )
    }

    func copyModeEntry(for paneId: String) -> CopyModeEntry? {
        guard let surface,
              let pane = surface.panes.first(where: { $0.paneId == paneId }),
              // One implementation of the bounds, shared with the per-keypress
              // refresh: two copies of `max - offset` is how the clamp and the
              // entry point would end up a row apart.
              let bounds = copyModeBounds(for: paneId)
        else { return nil }

        var cursor = CopyModeCursor(row: bounds.viewportBottom, column: 0)
        if let frameCursor = surface.frame.cursor,
           frameCursor.visible,
           // The surface's cursor is in whole-surface cells; a pane only owns part
           // of that grid, so an on-screen cursor can still belong to a neighbour.
           frameCursor.column >= pane.innerRect.originX,
           frameCursor.column < pane.innerRect.originX &+ pane.innerRect.width,
           frameCursor.row >= pane.innerRect.originY,
           frameCursor.row < pane.innerRect.originY &+ pane.innerRect.height {
            cursor = CopyModeCursor(
                row: bounds.viewportTop + Int(frameCursor.row - pane.innerRect.originY),
                column: Int(frameCursor.column - pane.innerRect.originX)
            )
        }

        // Every row the pane can show, history included — the same sum the
        // scrollbar uses for its thumb proportions.
        let totalRows = Int(
            min(
                (pane.scroll?.maxOffsetFromBottom ?? 0) &+ UInt64(bounds.viewportRows),
                UInt64(Int.max)
            )
        )
        return CopyModeEntry(
            cursor: CopyModeState.clamp(cursor, bounds: bounds),
            bounds: bounds,
            totalRows: totalRows
        )
    }

    /// Sends a motion and delivers the answer back on the main actor.
    ///
    /// The answer is in the daemon's text space and can be outside the viewport
    /// (the daemon does not know what the client is showing), so the caller has to
    /// clamp — `applyMotionTarget` does.
    func requestCopyMotion(
        paneId: String,
        from cursor: CopyModeCursor,
        motion: CopyModeMotion,
        contentRevision: UInt64,
        completion: @escaping @MainActor (CopyModeCursor?) -> Void
    ) {
        var params: [String: Any] = [
            "pane_id": paneId,
            "cursor": ["row": cursor.row, "col": cursor.column],
            "motion": motion.rawValue
        ]
        // Sent so the daemon can refuse with `stale_content` if the pane's text
        // moved between reading the cursor and asking for the next word position.
        // Omitting it would make a race produce a cursor pointing into text that no
        // longer exists there.
        params["content_revision"] = contentRevision

        Task { @MainActor in
            guard let result = await callReturningResult("pane.copy_motion", params),
                  let target = result["cursor"] as? [String: Any],
                  let row = target["row"] as? Int,
                  let column = target["col"] as? Int else {
                completion(nil)
                return
            }
            completion(CopyModeCursor(row: row, column: column))
        }
    }

    /// Reads a range and puts the text on the clipboard.
    ///
    /// Pasting into the clipboard happens here rather than through Ghostty's
    /// `copy_to_clipboard`: that binding copies the *local surface's* selection,
    /// which is a different thing (one screenful, chosen by the mouse). The text
    /// this returns came from the daemon's history and has never existed locally.
    func copySelection(
        paneId: String,
        from start: CopyModeCursor,
        to end: CopyModeCursor,
        contentRevision: UInt64,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        // Columns are clamped to the pane's own width. This is not defensive
        // padding — it is the fix for a measured failure: the linewise sentinel
        // (`CopyModeCursor.lineEndColumn`) asks for column 65535, and the daemon
        // answers `selection_unavailable` because a range that runs past the last
        // column of the pane extracts nothing at all. Probing end columns against a
        // 118-column pane: 117 returned the line, 200 and 65535 returned nothing.
        //
        // Trimmed from the pane's *inner* rect, because `PaneTextPoint.col` is
        // pane-relative: column 0 is the pane's first column, not the surface's.
        let paneColumns = surface?.panes.first { $0.paneId == paneId }
            .map { Int($0.innerRect.width) } ?? 0
        // A `nil` here means "the width is unknown and this is the end-of-line
        // sentinel", which is the one combination known to be refused. Saying so is
        // better than sending a request that cannot work.
        guard let anchorColumn = CopyModeColumn.clamped(start.column, paneColumns: paneColumns),
              let cursorColumn = CopyModeColumn.clamped(end.column, paneColumns: paneColumns)
        else {
            kraalLog("copymode: pane width unknown, refusing to send a sentinel column")
            reportCopyModeMessage("Pane size unknown — try again")
            completion(false)
            return
        }
        var params: [String: Any] = [
            "pane_id": paneId,
            "anchor": ["row": start.row, "col": anchorColumn],
            "cursor": ["row": end.row, "col": cursorColumn]
        ]
        params["content_revision"] = contentRevision

        Task { @MainActor in
            guard let result = await callReturningResult("pane.selection.read", params),
                  let text = result["text"] as? String,
                  !text.isEmpty else {
                // An empty selection is not an error the daemon reports; it just
                // returns nothing. Treat it as failure so the caller keeps the mode
                // open instead of silently leaving with an unchanged clipboard.
                kraalLog("copymode: selection read returned no text for \(paneId)")
                completion(false)
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            kraalLog("copymode: copied \(text.count) chars from \(paneId)")
            completion(true)
        }
    }
}
