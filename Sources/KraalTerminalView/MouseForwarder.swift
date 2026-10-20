// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Forwards mouse events to the daemon.
//
// Ghostty's view owns the mouse for its own selection and scrolling, so events are
// observed with a local monitor rather than intercepted: the terminal behaves
// exactly as it would standalone, and when the program inside the pane has asked
// for mouse reporting the same event is additionally sent to the daemon.
//
// Pane hit-testing uses the geometry the daemon already gave us — the pane whose
// `innerRect` contains the cell under the cursor — so this stays correct for any
// split arrangement without duplicating the layout math.

import AppKit
import KraalProtocol
import KraalUI
import SwiftUI

/// One pane's own context menu, and the clipboard actions it needs.
///
/// Ghostty's terminal view owns right-click: it either offers its Copy item over a
/// selection or forwards the press to the program in the pane. It has no menu for
/// the pane itself, so the pane's actions (
/// split, zoom, rename, close, focus, paste) are unreachable from the one place a
/// user is most likely to right-click. This provides them.
@MainActor
public protocol PaneContextMenuProviding: AnyObject {
    /// Raises the pane menu at the pointer. `event` is the right-click being
    /// handled, so the menu opens where the user clicked.
    func showPaneContextMenu(for paneId: String, event: NSEvent)
    /// Whether the pane's terminal currently has a text selection, which is what
    /// makes Copy meaningful.
    func paneHasSelection(_ paneId: String) -> Bool
    /// Runs Ghostty's `copy_to_clipboard` binding for the pane.
    func copySelection(in paneId: String)
}

@MainActor
public final class MouseForwarder {
    private weak var window: NSWindow?
    private var monitors: [Any] = []
    private let store: AppStore
    /// Supplies the pane context menu and the clipboard actions behind it.
    /// Held weakly because the app delegate owns the window and the forwarder,
    /// and neither should keep the other alive.
    private weak var paneActions: (any PaneContextMenuProviding)?

    public init(store: AppStore, paneActions: (any PaneContextMenuProviding)? = nil) {
        self.store = store
        self.paneActions = paneActions
    }

    public func attach(to window: NSWindow) {
        detach()
        self.window = window

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }

        for mask in [
            NSEvent.EventTypeMask.leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .mouseMoved,
            .scrollWheel,
        ] {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) {
                monitors.append(monitor)
            }
        }
    }

    public func detach() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        window = nil
    }

    deinit {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Routing

    /// Routes one event. Returns true when the event was consumed and must not be
    /// delivered to the view underneath — a right-click that raised the pane menu
    /// is such a case: the menu has taken the gesture, and letting Ghostty also
    /// forward it to the program would act on one click twice.
    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        guard let location = paneLocation(for: event) else { return false }

        // Right-click is both a menu gesture and an input event, and which one it
        // is depends on the program. A pane that enabled mouse reporting is
        // using the right button itself (TUIs do), so the menu would steal a
        // click the program is waiting for; those panes get the event and no
        // menu. Every other pane has no use for the button, and without a menu
        // the click does nothing at all — which is the state this fixes.
        if event.type == .rightMouseDown, paneShowsMenu(location.paneId) {
            let paneId = location.paneId
            let actions = paneActions
            // Raised on the next runloop turn rather than here: a menu runs a
            // modal event loop of its own, and starting one from inside event
            // dispatch (before the view has seen the event) wedges the app.
            // Consuming the event first is what makes this safe — by the time the
            // menu opens, this click is already finished.
            DispatchQueue.main.async {
                actions?.showPaneContextMenu(for: paneId, event: event)
            }
            return true
        }

        let kind = mouseKind(for: event)
        let modifiers = MouseModifiers.bits(from: event.modifierFlags)
        let lines = event.type == .scrollWheel
            ? PaneMouse.scrollLines(from: event.scrollingDeltaY)
            : 0

        // Only panes that asked for mouse reporting get the event; the terminal
        // view has already handled it locally either way.
        guard let kind else { return false }
        store.sendMouse(
            kind,
            at: location.point,
            in: location.size,
            paneId: location.paneId,
            modifiers: modifiers,
            lines: lines
        )
        return false
    }

    /// Whether the program in `paneId` asked to receive mouse buttons itself.
    ///
    /// Read from the daemon's geometry rather than from Ghostty: the daemon is
    /// what decoded the program's escape sequences, and `sendMouse` already
    /// gates on this same flag, so the two decisions cannot disagree.
    private func paneShowsMenu(_ paneId: String) -> Bool {
        KraalUI.PaneContextRouting.shouldShowPaneMenu(
            programReportsMouse: store.paneGeometry(for: paneId)?.mouseReporting == true
        )
    }

    private struct PaneLocation {
        let paneId: String
        let point: CGPoint
        let size: CGSize
    }

    /// Maps a window point to the pane under it, using the rectangles the pane
    /// views reported for themselves.
    ///
    /// Measuring the views beats recomputing the layout from chrome heights: the
    /// sidebar can be collapsed, the tab bar can grow, and hard-coded offsets
    /// would silently drift out of sync with them.
    private func paneLocation(for event: NSEvent) -> PaneLocation? {
        guard let contentView = window?.contentView else { return nil }
        // `locationInWindow` is in window coordinates, which include the title
        // bar; the reported frames are relative to the content view. Converting
        // against the content view rather than using the window point directly is
        // what keeps the two in the same space.
        let inView = contentView.convert(event.locationInWindow, from: nil)
        // AppKit's origin is bottom-left; the surface grid counts from the top.
        let topDown = CGPoint(
            x: inView.x,
            y: contentView.bounds.height - inView.y
        )

        for (paneId, rect) in store.paneViewFrames where rect.contains(topDown) {
            return PaneLocation(
                paneId: paneId,
                point: CGPoint(x: topDown.x - rect.minX, y: topDown.y - rect.minY),
                size: rect.size
            )
        }
        return nil
    }

    private func mouseKind(for event: NSEvent) -> ClientMouseKind? {
        switch event.type {
        case .leftMouseDown: return .press(.left)
        case .leftMouseUp: return .release(.left)
        case .rightMouseDown: return .press(.right)
        case .rightMouseUp: return .release(.right)
        case .otherMouseDown: return .press(.middle)
        case .otherMouseUp: return .release(.middle)
        case .leftMouseDragged: return .drag(.left)
        case .rightMouseDragged: return .drag(.right)
        case .otherMouseDragged: return .drag(.middle)
        case .mouseMoved: return .moved
        case .scrollWheel:
            let delta = event.scrollingDeltaY
            if delta > 0 { return .scrollUp }
            if delta < 0 { return .scrollDown }
            return nil
        default:
            return nil
        }
    }
}
