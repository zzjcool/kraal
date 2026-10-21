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

    /// Pixels banked per pane between scroll notches. See
    /// `PaneMouse.ScrollAccumulator` for why the remainder has to be carried.
    private var scrollAccumulators: [String: PaneMouse.ScrollAccumulator] = [:]

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

        let modifiers = MouseModifiers.bits(from: event.modifierFlags)

        // A trackpad delivers dozens of scroll events per gesture, each only a
        // pixel or two. Sending all of them makes the program scroll once per
        // event and the view races ahead of the fingers; banking the pixels per
        // pane and emitting only whole cells matches Ghostty's own feel.
        if event.type == .scrollWheel {
            let notches = scrollNotches(for: event, paneId: location.paneId, viewSize: location.size)
            // Zero: the gesture has not covered a cell yet, or there is nothing
            // to measure against. Both mean send nothing; the remainder waits.
            guard notches != 0 else { return false }
            store.sendMouse(
                notches > 0 ? .scrollUp : .scrollDown,
                at: location.point,
                in: location.size,
                paneId: location.paneId,
                modifiers: modifiers,
                lines: UInt16(min(abs(notches), 20))
            )
            return false
        }

        // Only panes that asked for mouse reporting get the event; the terminal
        // view has already handled it locally either way.
        guard let kind = mouseKind(for: event) else { return false }
        store.sendMouse(
            kind,
            at: location.point,
            in: location.size,
            paneId: location.paneId,
            modifiers: modifiers,
            lines: 0
        )
        return false
    }

    /// Whole-cell notches for one scroll event, or nil when the accumulator has
    /// not yet covered a cell (or the pane has no geometry to measure against).
    ///
    /// Whole-cell notches for one scroll event, signed so positive scrolls up.
    ///
    /// Zero means the gesture has not yet covered a cell and nothing should be
    /// sent; the pixels stay banked in the accumulator for the next event.
    /// Whole-cell notches for one scroll event, signed so positive scrolls up.
    ///
    /// A wheel with detents already reports whole notches, so its delta is used
    /// as-is; a trackpad reports points, which have to be banked until they
    /// cover a cell. Treating the two the same either loses the wheel (it takes
    /// a dozen clicks to move a row) or floods the trackpad path.
    private func scrollNotches(for event: NSEvent, paneId: String, viewSize: CGSize) -> Int {
        let delta = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            // Not points — a wheel notch count. One event, one notch.
            scrollAccumulators[paneId]?.reset()
            return delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        }
        guard let geometry = store.paneGeometry(for: paneId), geometry.innerRect.height > 0 else {
            return 0
        }
        // Height of one cell in **points**, because that is the unit
        // `scrollingDeltaY` uses for a precise device. Derived from the view
        // rather than from `pixelHeight`: the daemon reports pixels, and mixing
        // the two would halve the speed on a 2x display. `viewSize` is points
        // and `innerRect.height` is rows, so the ratio is scale-free.
        let cellHeight = viewSize.height / CGFloat(geometry.innerRect.height)
        var accumulator = scrollAccumulators[paneId]
            ?? PaneMouse.ScrollAccumulator(cellHeight: cellHeight)
        // Trackpads emit momentum events after the fingers lift. They still
        // carry real distance, so they go through the same bank.
        let notches = accumulator.notches(for: delta)
        scrollAccumulators[paneId] = accumulator
        return notches
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
