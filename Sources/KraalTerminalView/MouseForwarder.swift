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

/// Installs a local mouse monitor for one window and routes events to panes.
@MainActor
public final class MouseForwarder {
    private weak var window: NSWindow?
    private var monitors: [Any] = []
    private let store: AppStore

    public init(store: AppStore) {
        self.store = store
    }

    public func attach(to window: NSWindow) {
        detach()
        self.window = window

        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handle(event)
            return event
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

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        guard let location = paneLocation(for: event) else { return }

        let kind = mouseKind(for: event)
        let modifiers = MouseModifiers.bits(from: event.modifierFlags)
        let lines = event.type == .scrollWheel
            ? PaneMouse.scrollLines(from: event.scrollingDeltaY)
            : 0

        // Only panes that asked for mouse reporting get the event; the terminal
        // view has already handled it locally either way.
        guard let kind else { return }
        store.sendMouse(
            kind,
            at: location.point,
            in: location.size,
            paneId: location.paneId,
            modifiers: modifiers,
            lines: lines
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
