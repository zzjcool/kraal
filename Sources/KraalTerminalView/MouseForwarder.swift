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

    /// Points banked per pane between whole-row scrolls.
    private var scrollAccumulators: [String: PaneMouse.ScrollAccumulator] = [:]
    /// Same idea as `scrollAccumulators`, for panes whose program owns the wheel.
    /// Kept separate on purpose: the two paths take different units to the daemon,
    /// and sharing a remainder between them would let one path spend the other's.
    private var otherScrollAccumulators: [String: PaneMouse.ScrollAccumulator] = [:]

    /// Where the last left/right press landed, per pane, so a drag can be told from
    /// pointer jitter.
    ///
    /// macOS emits `leftMouseDragged` for a movement of a single point, which a
    /// trackpad produces on almost every click. Forwarding those to a program makes
    /// a click arrive as press → drag → drag → release, and a TUI that requires a
    /// clean press/release pair then treats the click as a drag and ignores it — the
    /// "clicking the TUI does nothing" half of issue #95. The threshold is one cell,
    /// which is also the smallest movement a program could meaningfully respond to.
    private var pressOrigins: [String: CGPoint] = [:]

    /// The pane whose context menu a consumed `rightMouseDown` just raised.
    ///
    /// The menu opens on the next runloop turn, which is *after* the matching
    /// `rightMouseUp` has been dispatched. AppKit's menu tracking reads the mouse
    /// as already released and closes the menu the instant it appears — the click
    /// looks like it did nothing. Swallowing the paired up keeps a button the
    /// pointer is no longer holding.
    private var menuRaisedFor: String?

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
            menuRaisedFor = paneId
            DispatchQueue.main.async {
                actions?.showPaneContextMenu(for: paneId, event: event)
            }
            return true
        }

        // The up that pairs with a menu-raising down has to be consumed too.
        // The menu does not open until the next runloop turn, so without this the
        // up is already dispatched when AppKit starts tracking: it sees a released
        // button and closes the menu as it appears, which is why a right-click
        // looked like it did nothing at all. Cleared on every press as well, so a
        // lost up (app switched away mid-click) cannot leak into the next one.
        if event.type == .rightMouseUp {
            let raised = menuRaisedFor
            menuRaisedFor = nil
            if KraalUI.PaneContextRouting.consumesRightUp(menuRaisedForPane: raised) {
                return true
            }
        }

        // A program that reports the mouse owns its own scrolling (a TUI's pager,
        // a file list); the wheel belongs to it, not to the pane's history. Every
        // other pane scrolls the daemon's scrollback instead — Ghostty has none
        // to scroll, because the renderer paints a fixed screen with absolute
        // cursor addressing and never emits a newline.
        if event.type == .scrollWheel, !paneReportsMouse(location.paneId) {
            scrollDaemonBacklog(for: event, location: location)
            return false
        }

        let kind = mouseKind(for: event)
        // A click is press → release. macOS also sends `leftMouseDragged` for a
        // one-point wobble, and a program that tracks drags then sees a drag where
        // the user saw a click. Dropping movement below a cell keeps the click a
        // click; anything larger is a real drag and goes through.
        if let kind, case .drag = kind, let origin = pressOrigins[location.paneId] {
            let cell = min(location.size.width, location.size.height) / 40
            if !PaneMouse.PressTracking(cellSize: cell)
                .isDrag(from: origin, to: location.point) {
                return false
            }
        }
        if let kind {
            switch kind {
            case .press: pressOrigins[location.paneId] = location.point
            case .release: pressOrigins.removeValue(forKey: location.paneId)
            default: break
            }
        }
        let modifiers = MouseModifiers.bits(from: event.modifierFlags)
        // TUI panes get a wheel *event*, not a line count — the protocol carries
        // `lines` but a program implementing SGR mouse input turns one event into
        // one scroll step regardless. So a trackpad's per-frame deltas must be
        // accumulated exactly as they are for the daemon-scrollback path, or the
        // program scrolls one notch per frame and a flick flies past everything
        // (issue #95). `nil` means "not a whole notch yet" and the event is dropped.
        var lines: UInt16 = 0
        if event.type == .scrollWheel {
            lines = tuiScrollNotch(for: event, paneId: location.paneId, viewSize: location.size)
            if lines == 0 { return false }
        }

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

    /// Scrolls the pane's own history by `pane.scroll`.
    ///
    /// `pane.scroll` takes an absolute `offset_from_bottom`, not a delta, so
    /// something has to remember where the viewport is. That "something" is
    /// `PaneScrollQueue`, not this function: a trackpad emits one event per frame,
    /// and computing a target here meant every event in a flick read the same
    /// stale snapshot, so they overwrote each other and roughly one in four was
    /// refused for `endpoint_busy` and dropped (issue #94).
    private func scrollDaemonBacklog(for event: NSEvent, location: PaneLocation) {
        let paneId = location.paneId
        guard let metrics = store.paneGeometry(for: paneId)?.scroll else {
            // No metrics yet: the daemon has not reported this pane's history, so
            // there is nothing to steer towards.
            return
        }
        let lines = scrollLines(for: event, paneId: paneId, viewSize: location.size)
        // No `shouldSend` filter here: a gesture that clamps at the end of the
        // history still has to reach the queue, because its accumulated movement is
        // what the *next* request will carry. Filtering per event is what made a
        // flick lose its first few notches.
        store.scrollPaneBy(
            paneId: paneId,
            lines: lines,
            current: metrics.offsetFromBottom,
            maxOffset: metrics.maxOffsetFromBottom
        )
    }

    /// Whole lines for one scroll event, carrying the sub-line remainder.
    ///
    /// A wheel with detents already reports whole notches, so its delta is a line
    /// count; a trackpad reports points and has to be banked until it covers a
    /// cell. Treating them the same either loses the wheel or floods the trackpad.
    private func scrollLines(for event: NSEvent, paneId: String, viewSize: CGSize) -> Int {
        let delta = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            scrollAccumulators[paneId]?.reset()
            return delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        }
        guard let rows = store.paneGeometry(for: paneId)?.innerRect.height, rows > 0 else {
            return 0
        }
        // Cell height in points: `scrollingDeltaY` is points for a precise device,
        // and the ratio of the view's height to its row count is scale-free.
        let cellHeight = viewSize.height / CGFloat(rows)
        var accumulator = scrollAccumulators[paneId]
            ?? PaneMouse.ScrollAccumulator(cellHeight: cellHeight)
        let lines = accumulator.lines(for: delta)
        scrollAccumulators[paneId] = accumulator
        return lines
    }

    /// Whole wheel notches for a pane whose program handles the mouse itself.
    ///
    /// Returns 0 while the accumulated movement is below one notch, so the caller
    /// drops the event instead of sending a wheel report the program will treat as
    /// a full step. A mouse wheel with detents reports whole notches already and
    /// bypasses the accumulator; a trackpad reports points, and sending one report
    /// per frame made a TUI scroll roughly six times faster than the hand moved
    /// (measured against `herdr-gpui`, which has the same behaviour for the same
    /// reason).
    ///
    /// The accumulator is per pane, like the one for the daemon scrollback path, so
    /// two TUIs scrolling at once keep their own remainders.
    private func tuiScrollNotch(
        for event: NSEvent, paneId: String, viewSize: CGSize
    ) -> UInt16 {
        let delta = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            otherScrollAccumulators[paneId]?.reset()
            // One report per notch is what the program expects; a wheel that
            // reports several notches in one event keeps its magnitude.
            let notches = Int(abs(delta).rounded())
            guard notches > 0 else { return 0 }
            return UInt16(min(max(notches, 1), 20))
        }
        guard let rows = store.paneGeometry(for: paneId)?.innerRect.height, rows > 0 else {
            return 0
        }
        let cellHeight = viewSize.height / CGFloat(rows)
        var accumulator = otherScrollAccumulators[paneId]
            ?? PaneMouse.ScrollAccumulator(cellHeight: cellHeight)
        let lines = accumulator.lines(for: delta)
        otherScrollAccumulators[paneId] = accumulator
        guard lines != 0 else { return 0 }
        return UInt16(min(abs(lines), 20))
    }

    /// Whether the program in this pane asked to receive mouse events itself.
    private func paneReportsMouse(_ paneId: String) -> Bool {
        store.paneGeometry(for: paneId)?.mouseReporting == true
    }

    /// Whether the program in `paneId` asked to receive mouse buttons itself.
    ///
    /// Read from the daemon's geometry rather than from Ghostty: the daemon is
    /// what decoded the program's escape sequences, and `sendMouse` already
    /// gates on this same flag, so the two decisions cannot disagree.
    ///
    /// `rightClickPassthrough` comes from the snapshot rather than the surface:
    /// it is a per-pane setting the daemon persists, not something the terminal
    /// stream reports. Before this was passed in, the setting had no effect and
    /// a pane with `right_click = "pane"` still opened Kraal's menu.
    private func paneShowsMenu(_ paneId: String) -> Bool {
        // Mouse reporting is deliberately not consulted: it is how a TUI asks for
        // the pointer, not a claim on the right button. Only an explicit per-pane
        // `right_click = "pane"` hands the button over (see `ownsRightClick`).
        KraalUI.PaneContextRouting.shouldShowPaneMenu(
            rightClickPassthrough: store.rightClickPassthrough(paneId: paneId)
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
        // `convert(_:from:)` already answers in the content view's own space, so
        // the only question left is which way that space points. It is **flipped**
        // here — the content view is an `NSHostingView`, whose `isFlipped` is true —
        // so `inView.y` counts from the top and needs no further inversion.
        //
        // This used to be `contentHeight - inView.y` on the strength of "AppKit's
        // origin is bottom-left". That is true of an ordinary `NSView` and false of
        // this one, and the cost was a second inversion: a wheel event over the top
        // pane was routed to the bottom one, every time. Measured on the developer's
        // own window (issue #88):
        //
        //     DIAG88 FLIP isFlipped=true windowY=1679 inViewY=850
        //                  contentH=2530 sum=2530
        //
        // `windowY + inViewY == contentHeight` exactly, which is what "already
        // top-down" looks like; subtracting turned 850 into 1680 and moved the hit
        // to the other pane. The pane frames this is compared against are written by
        // `PaneFrameMath.rect`, which produces top-down rects — so the reader and the
        // writer disagreed about which end y is measured from. Now they agree.
        let topDown = KraalUI.PaneFrameMath.contentPoint(
            inView,
            contentHeight: contentView.bounds.height,
            isFlipped: contentView.isFlipped
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
