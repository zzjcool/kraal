// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// macOS app entry point.
//
// The window is an `NSWindow` hosting the SwiftUI `RootView`. The pane renderer
// is injected here so the UI package stays free of the Ghostty xcframework, and
// so a headless build can swap in a stub.

import AppKit
import KraalClient
import KraalProtocol
import KraalTerminalView
import KraalUI
import SwiftUI

@MainActor
final class KraalAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let store = AppStore()
    private var mouseForwarder: MouseForwarder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        KraalLog.shared.rotate()
        kraalLog("launch: bundle=\(Bundle.main.bundleIdentifier ?? "none") bundlePath=\(Bundle.main.bundlePath)")
        kraalLog("launch: screens=\(NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | "))")

        let pool = PaneTerminalPool { [weak self] paneId, data in
            // Ghostty produced bytes for this pane (keys, paste, query replies).
            // They go back as semantic input on the same connection.
            kraalLog("input: pane=\(paneId) bytes=\(data.count) "
                + "raw=\(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
            Task { @MainActor in
                guard let self else { return }
                self.store.sendInput(data, to: paneId)
                self.store.focus(paneId: paneId)
            }
        }

        let root = RootView(store: store) { store, paneId, geometry in
            guard let surface = store.surface else {
                return AnyView(Color(nsColor: .textBackgroundColor))
            }
            let model = pool.model(for: paneId, size: store.surfaceSize)
            model.onCellMetrics = { [weak store] cellSize in
                guard let store else { return }
                Task { @MainActor in
                    store.updateCellMetrics(cellSize)
                }
            }
            return AnyView(
                GhosttyPaneView(
                    model: model,
                    surface: surface,
                    geometry: geometry,
                    onFocus: { store.focus(paneId: paneId) }
                )
            )
        }

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kraal"
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 720, height: 420)

        // A bare executable has no restored frame to fall back on, so place the
        // window explicitly rather than relying on autosave.
        // AppKit's own window restoration writes the frame *after* the window is
        // ordered front, which can move it back onto a monitor that is gone. The
        // frame is persisted by hand instead (see `saveFrame`), so restoration is
        // switched off and cannot race the placement below.
        window.isRestorable = false
        if let saved = Self.savedFrame() {
            window.setFrame(saved, display: false)
        }
        // A restored frame can be off-screen (a monitor was disconnected, or the
        // saved frame predates a resolution change), and AppKit will happily put
        // the window where nothing can reach it. Keep the restored size but move
        // it onto a screen that exists now.
        // `setFrameAutosaveName` restores the previous session's frame, and that
        // frame can point at a monitor that is no longer attached. AppKit stores
        // it before this delegate runs, so it must be re-checked here rather than
        // only in the launch path.
        if let frame = Self.onScreenFrame(for: window.frame) {
            window.setFrame(frame, display: false)
            kraalLog("window: moved on-screen to \(frame)")
        }
        kraalLog("window frame after layout: \(window.frame)")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window

        // Keep the pool in sync with the store: drop terminals for closed panes
        // so their Ghostty surfaces are released.
        store.onPaneSetChanged = { [weak self] paneIds in
            _ = self
            pool.prune(keeping: paneIds)
        }

        // Mouse events are observed, not intercepted: Ghostty keeps its own
        // selection and scroll behaviour, and panes that asked for mouse
        // reporting additionally get semantic events on the daemon connection.
        let forwarder = MouseForwarder(store: store)
        forwarder.attach(to: window)
        mouseForwarder = forwarder

        store.loadDefaultSidebarConfig()
        store.connect()
    }

    /// The frame from the previous session, if it was saved.
    static func savedFrame() -> NSRect? {
        guard let frame = UserDefaults.standard.string(forKey: "KraalWindowFrame") else {
            return nil
        }
        let rect = NSRectFromString(frame)
        return rect.width > 200 && rect.height > 200 ? rect : nil
    }

    func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(
            NSStringFromRect(window.frame),
            forKey: "KraalWindowFrame"
        )
    }

    /// Clamps a frame to the nearest on-screen area, or centres a default-size
    /// window when the frame is unusable.
    static func onScreenFrame(for frame: NSRect) -> NSRect? {
        // Only screens that can actually show a window: a virtual or captured
        // display can report a frame far outside the physical layout, and
        // restoring onto one puts the window where no input can reach it.
        let mouse = NSEvent.mouseLocation
        let candidates = NSScreen.screens.filter { screen in
            screen.visibleFrame.width >= 400 && screen.frame.height >= 300
        }
        var visibleFrames = candidates.isEmpty
            ? NSScreen.screens.map(\.visibleFrame)
            : candidates.map(\.visibleFrame)
        // Prefer the screen holding the pointer, which is where the user is.
        if let active = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           candidates.contains(where: { $0 === active }) {
            visibleFrames.insert(active.visibleFrame, at: 0)
            visibleFrames.removeDuplicates()
        }
        guard !visibleFrames.isEmpty else { return nil }

        // Already mostly visible: leave the user's placement alone.
        for visible in visibleFrames {
            let overlap = visible.intersection(frame)
            if !overlap.isNull,
               overlap.width >= frame.width * 0.9,
               overlap.height >= frame.height * 0.9 {
                return nil
            }
        }

        // Pick the screen with the largest overlap, or the main one.
        let best = visibleFrames.max { lhs, rhs in
            lhs.intersection(frame).size.area < rhs.intersection(frame).size.area
        } ?? visibleFrames[0]

        let size = NSSize(
            width: min(max(frame.width, 720), best.width - 20),
            height: min(max(frame.height, 420), best.height - 20)
        )
        return NSRect(
            x: best.minX + (best.width - size.width) / 2,
            y: best.minY + (best.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func applicationWillResignActive(_ notification: Notification) {
        saveFrame()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveFrame()
        mouseForwarder?.detach()
        store.disconnect()
    }
}

@main
struct KraalMacMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = KraalAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

private extension NSSize {
    var area: CGFloat { max(width, 0) * max(height, 0) }
}

private extension Array where Element == NSRect {
    mutating func removeDuplicates() {
        var seen: [NSRect] = []
        for rect in self where !seen.contains(rect) {
            seen.append(rect)
        }
        self = seen
    }
}
