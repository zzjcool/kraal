// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  CopyModeController.swift
//  Kraal
//
//  Owns the live copy-mode state for one window and turns key presses into calls.
//
//  ## Why a local monitor and not `keyDown`
//
//  The pane's first responder is Ghostty's `NSView`, which consumes key events
//  before any SwiftUI view sees them — that is correct for a terminal, and it is
//  why this app has no `keyDown` override anywhere. A mode that needs *bare* keys
//  (no modifier) therefore cannot be a responder-chain feature. `NSEvent`'s local
//  monitor catches the event on its way to the responder chain, and while the mode
//  is active it swallows it. When the mode is off the monitor returns the event
//  untouched, so nothing about normal typing changes.
//
//  ## Why the state is not in `AppStore`
//
//  Copy mode is per-window and per-pane: the cursor, the anchor and the visible
//  bar all belong to the thing the user is looking at. `AppStore` is the daemon
//  connection, shared and not window-shaped. Keeping the mode here also means the
//  store never has to know a UI mode exists.
//

import AppKit
import KraalUI

/// The live copy-mode session, if any.
@MainActor
final class CopyModeController {
    private weak var store: AppStore?
    private weak var window: NSWindow?
    private var monitor: Any?

    /// The current session, or `nil` when the mode is off.
    ///
    /// Read by the view that draws the mode bar, so it is `@Published`-like in
    /// spirit — but this class is not observable; the owner redraws by asking for
    /// `snapshotForDisplay` after every change.
    private(set) var state: CopyModeState?
    private(set) var bounds: CopyModeBounds = CopyModeBounds(viewportTop: 0, viewportRows: 1)
    /// What the status bar shows. The controller owns the publishing because the
    /// status bar is a SwiftUI view and this class is AppKit-shaped.
    let banner = CopyModeBanner()

    init(store: AppStore) {
        self.store = store
    }

    var isActive: Bool { state != nil }

    func attach(to window: NSWindow) {
        self.window = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Enters the mode for a pane, or reports why it could not.
    func enter(paneId: String) {
        guard let store else { return }
        guard store.supportsCopyMode else {
            // A daemon without these methods would answer with a refusal, which the
            // store turns into an error banner for a feature that is simply absent.
            store.reportCopyModeMessage("This daemon does not support copy mode")
            kraalLog("copymode: daemon lacks pane.selection.read")
            return
        }
        guard let entry = store.copyModeEntry(for: paneId) else {
            kraalLog("copymode: no geometry for \(paneId), cannot enter")
            return
        }
        let revision = store.surface?.panes
            .first { $0.paneId == paneId }?
            .contentRevision
        state = CopyModeState.entering(
            paneId: paneId,
            cursor: entry.cursor,
            bounds: entry.bounds,
            contentRevision: revision ?? 0,
            // Everything the pane can show, history included. Without this `G` had
            // nothing to jump to — and, worse, returned "not my key" so the letter
            // reached the pty. `PaneScrollbar` computes the same sum for the thumb's
            // proportions; both read it from the daemon's own metrics.
            totalRows: entry.totalRows
        )
        bounds = entry.bounds
        kraalLog("copymode: entered \(paneId) at "
            + "\(entry.cursor.row):\(entry.cursor.column) viewport=\(entry.bounds.viewportTop)")
        if let state { publish(state) }
    }

    func exit() {
        guard state != nil else { return }
        kraalLog("copymode: exited")
        state = nil
        banner.hide()
    }

    /// Handles one key event. Returns whether it was consumed.
    ///
    /// Synchronous decision, then a `Task` for anything that needs the daemon: the
    /// monitor must answer *now*, so it cannot await. Everything that can be
    /// decided locally already has been, inside `CopyModeState.handle`.
    private func handle(_ event: NSEvent) -> Bool {
        guard var current = state else { return false }
        // A popup owns the keyboard while it is open. Copy mode and a popup can both
        // be up at once (nothing closes one when the other opens), and the popup is
        // the thing the user is looking at, so it wins. Without this the copy-mode
        // monitor — which is registered first and swallows bare keys — would eat the
        // popup's input and the popup would look dead.
        if store?.hasPopup == true {
            kraalLog("copymode: leaving because a popup opened")
            exit()
            return false
        }
        // Re-read the viewport before every key. It moves under the mode — a wheel
        // scroll is not gated by copy mode, and `pane.scroll` can arrive from
        // anywhere — and the contract in `CopyModeState` is that the cursor is kept
        // inside the *visible* rows. Capturing the bounds once at entry made the
        // cursor stay at an absolute row that could scroll off screen, which is
        // exactly the failure the doc warns about: the right shape of text from the
        // wrong place still copies fine.
        if let fresh = store?.copyModeBounds(for: current.paneId) {
            bounds = fresh
            current.cursor = CopyModeState.clamp(current.cursor, bounds: fresh)
            // The viewport identity also feeds the bar's position display, so a
            // scroll has to redraw even when the key did not move the cursor.
            state = current
        }
        // Modifier combos are the menu bar's, not the mode's: ⌘C inside copy mode
        // should still be the system copy, and ⌘Q must quit. Only bare keys are ours.
        // A bitwise test rather than Set algebra: `ModifierFlags` is an OptionSet,
        // so "shares no bit with these" is exactly `isEmpty` on the intersection.
        let menuLike: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.isDisjoint(with: menuLike) else { return false }

        guard let key = CopyModeKeyEvent.from(
            characters: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        ) else { return false }

        let effect = current.handle(key, bounds: bounds)
        switch effect {
        case .none:
            // Not ours: let it through so an unrecognised key still reaches the
            // terminal, which is what makes the mode feel non-modal for stray keys.
            return false

        case .redraw:
            state = current
            publish(current)
            return true

        case .exit:
            // `handle` already cleared the selection for Escape; for `y` with no
            // selection it returns `.exit` without touching state.
            state = nil
            banner.hide()
            return true

        case let .requestMotion(motion):
            state = current
            publish(current)
            requestMotion(motion, from: current)
            return true

        case let .copy(rowStart, columnStart, rowEnd, columnEnd):
            state = current
            publish(current)
            copy(
                from: CopyModeCursor(row: rowStart, column: columnStart),
                to: CopyModeCursor(row: rowEnd, column: columnEnd)
            )
            return true
        }
    }

    /// Pushes the displayable part of the state to the banner.
    private func publish(_ current: CopyModeState) {
        // Logged on every change: the state machine is unit-tested, but "did this
        // keystroke actually reach the monitor" is a wiring question that only the
        // running app can answer, and the GUI case asserts on this line.
        kraalLog("copymode: cursor=\(current.cursor.row):\(current.cursor.column) "
            + "selecting=\(current.isSelecting) "
            + "viewport=\(bounds.viewportTop)...\(bounds.viewportBottom)")
        banner.show(
            cursor: current.cursor,
            selecting: current.isSelecting,
            viewportTop: bounds.viewportTop,
            viewportRows: bounds.viewportRows
        )
    }

    private func requestMotion(_ motion: CopyModeMotion, from current: CopyModeState) {
        guard let store else { return }
        store.requestCopyMotion(
            paneId: current.paneId,
            from: current.cursor,
            motion: motion,
            contentRevision: current.contentRevision
        ) { [weak self] target in
            guard let self, var live = self.state, live.paneId == current.paneId else { return }
            guard let target else {
                kraalLog("copymode: motion \(motion.rawValue) had no answer")
                return
            }
            live.applyMotionTarget(target, bounds: self.bounds)
            self.state = live
            self.publish(live)
        }
    }

    private func copy(from start: CopyModeCursor, to end: CopyModeCursor) {
        guard let store, let current = state else { return }
        store.copySelection(
            paneId: current.paneId,
            from: start,
            to: end,
            contentRevision: current.contentRevision
        ) { [weak self] copied in
            guard let self else { return }
            // Leave either way once the attempt is over: a mode that stays open
            // after `y` looks like the copy did not happen.
            self.exit()
            if !copied {
                self.store?.reportCopyModeMessage("Nothing to copy")
            }
        }
    }
}
