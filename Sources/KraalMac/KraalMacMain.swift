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
import KraalTransport
import KraalTerminalView
import KraalUI
import SwiftUI

@MainActor
final class KraalAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let store = AppStore(target: KraalAppDelegate.initialTarget)
    private var mouseForwarder: MouseForwarder?
    private let windowActions = WindowActions()
    private var menuBar: MacMenuBar?

    /// The daemon to open on launch.
    ///
    /// Honours `KRAAL_HERDR_SOCKET` so a development build can be pointed at a
    /// sandbox daemon. Without it the app talks to this Mac's herdr, which is the
    /// normal case for a user — but it also means a UI experiment run without the
    /// variable lands in their live session, so the override is checked first and
    /// logged loudly.
    private static var initialTarget: ConnectionSettings {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["KRAAL_HERDR_SOCKET"], !path.isEmpty {
            kraalLog("launch: overriding daemon socket -> \(path)")
            return ConnectionSettings(name: "sandbox", transport: .local)
        }
        kraalLog("launch: no socket override, using this Mac's herdr")
        return .local
    }

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

        let root = RootView(store: store, windowActions: windowActions) { store, paneId, geometry in
            guard let surface = store.surface else {
                return AnyView(Color(nsColor: .textBackgroundColor))
            }
            let model = pool.model(for: paneId)
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

        let window = makeWindow(root: root)
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

        // The menu bar is installed after the window exists so validation can
        // consult a live store; a bare NSApplication has no main menu at all, so
        // without this there is no ⌘Q, no Edit menu and no way to reach New Tab
        // except the tab bar's "+" button.
        let menu = MacMenuBar(
            store: store,
            actions: MacMenuBar.MenuActions(
                toggleSidebar: { [windowActions] in windowActions.toggleSidebar() },
                toggleStatusBar: { [windowActions] in windowActions.toggleStatusBar() },
                showCommands: { [windowActions] in windowActions.showCommandPalette() },
                showShortcuts: { [windowActions] in windowActions.showShortcuts() },
                showMachines: { [windowActions] in windowActions.showMachines() }
            )
        )
        menu.install()
        menuBar = menu

        store.loadDefaultSidebarConfig()
        store.connect()
        openPanelsRequestedByEnvironment(windowActions: windowActions)
    }

    /// Builds and shows the main window.
    ///
    /// Split out of `applicationDidFinishLaunching` for length. The window has no
    /// nib and no SwiftUI scene, so every attribute — frame restoration, on-screen
    /// clamping, titlebar style — is set by hand here.
    private func makeWindow(root: RootView) -> NSWindow {
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
        window.titleVisibility = .hidden
        // Vibrancy detail that is easy to miss: an `NSVisualEffectView` with
        // `blendingMode = .behindWindow` samples what is behind the *window*. If the
        // window is opaque, AppKit composites the effect over the window's own
        // background colour and the blur never reaches the desktop — which is
        // exactly why the chrome looked flat before this change. The window has to
        // be non-opaque with a clear background for real translucency.
        //
        // Safe here because every region is covered: the sidebar and both bars draw
        // their own material, and the terminal area paints an opaque background
        // (`PaneLayoutView` uses `.textBackgroundColor`) so glyph contrast is
        // untouched.
        window.isOpaque = false
        window.backgroundColor = .clear
        // A transparent window has no surface to composite the titlebar against,
        // so the standard titlebar strip would paint its own opaque grey over the
        // sidebar's material. Hiding it leaves one continuous glass surface from
        // the traffic lights down, which is the look the rest of this change aims
        // at. The traffic lights stay; only the bar behind them goes away.
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
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
        // Recorded because translucency is invisible in a screenshot assertion:
        // an opaque window silently downgrades every `.behindWindow` material to
        // a flat colour, and that failure looks identical to "the material works"
        // in pixel tests. Logging the flag makes the difference checkable in CI.
        // Dump the mounted vibrancy views shortly after launch. A screenshot
        // cannot prove a material exists (an opaque window renders it as flat
        // grey and looks "fine"), so the live view tree is the real evidence that
        // the chrome is backed by NSVisualEffectView and not a Material view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak window] in
            guard let window else { return }
            Self.logVibrancyTree(in: window)
        }
        kraalLog("window chrome: isOpaque=\(window.isOpaque) "
            + "backgroundColor=\(window.backgroundColor.alphaComponent) "
            + "titlebarTransparent=\(window.titlebarAppearsTransparent) "
            + "fullSizeContent=\(window.styleMask.contains(.fullSizeContentView))")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window
    }

    /// Logs every `NSVisualEffectView` in the window, with the properties that
    /// decide whether it actually blurs the desktop.
    private static func logVibrancyTree(in window: NSWindow) {
        var found: [String] = []
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let effect = view as? NSVisualEffectView {
                let blending = effect.blendingMode == .behindWindow ? "behind" : "within"
                let state = effect.state == .followsWindowActiveState ? "follows" : "always"
                found.append("\(effect.material.rawValue)/\(blending)/\(state)"
                    + "/\(Int(effect.bounds.width))x\(Int(effect.bounds.height))")
            }
            stack.append(contentsOf: view.subviews)
        }
        kraalLog("vibrancy: \(found.count) NSVisualEffectView(s) -> "
            + (found.isEmpty ? "NONE (chrome is flat!)" : found.joined(separator: " | ")))
    }

    /// Opens panels on launch when the environment asks for one.
    ///
    /// `KRAAL_SHOW_MACHINES=1` exists because a bare `NSApplication` exposes no
    /// accessible menu hierarchy, so a script cannot click File ▸ Machines…. The
    /// flag drives the same `WindowActions` counter the menu item drives, so it is
    /// a handle for automated verification rather than a second code path.
    private func openPanelsRequestedByEnvironment(windowActions: WindowActions) {
        if ProcessInfo.processInfo.environment["KRAAL_SHOW_MACHINES"] == "1" {
            windowActions.showMachines()
        }
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
