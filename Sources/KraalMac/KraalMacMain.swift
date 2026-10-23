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
    /// Owns the copy-mode session for this window: its cursor, its visible bar and
    /// the key monitor that drives it. Lives here rather than in the store because
    /// it is per-window view state.
    private var copyMode: CopyModeController?
    private let store = AppStore(target: KraalAppDelegate.initialTarget)
    private var mouseForwarder: MouseForwarder?
    /// Terminals, kept so the pane menu can reach a pane's selection and clipboard.
    private var paneTerminalPool: PaneTerminalPool?
    private let windowActions = WindowActions()
    private var menuBar: MacMenuBar?
    /// Owns the AppKit side of terminal events (pasteboard, title, bell).
    /// Retained so the closure installed on the store does not have to capture
    /// it strongly — see `onEffectsChanged` in `applicationDidFinishLaunching`.
    private var terminalEffects: TerminalEffectsApplier?

    /// Whether this launch is allowed to take the desktop.
    ///
    /// A background dev session (see `DevSession`) skips every call that would
    /// move the pointer, raise its window over the user's work or steal keyboard
    /// focus: `activate(ignoringOtherApps:)`, `makeKeyAndOrderFront` and the
    /// `.regular` activation policy that puts it in the Dock and the ⌘-Tab list.
    private let runsInBackground = DevSession.runsInBackground

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
            // The name is what the sidebar and the status bar show, so it has to
            // describe the socket, not the fact that an override was used. Pointing
            // the override at this Mac's own daemon is exactly how a developer asks
            // for the real session; calling that "sandbox" made a live run look like
            // fake data at a glance.
            return ConnectionSettings(name: connectionName(forSocket: path), transport: .local)
        }
        kraalLog("launch: no socket override, using this Mac's herdr")
        return .local
    }

    /// "This Mac" when the path is this Mac's own daemon, "sandbox" otherwise.
    ///
    /// Compared by canonical path so a symlinked or `~`-relative spelling of the
    /// real socket still counts as real.
    private static func connectionName(forSocket path: String) -> String {
        let candidate = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let real = "\(home)/.config/herdr/herdr-client.sock"
        return candidate == real ? "This Mac" : "sandbox"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An accessory launch has no Dock tile and never activates, which is what
        // keeps a second copy from pulling focus away from the first. It still
        // has a menu bar while its window is key, so ⌘Q and ⌘W keep working when
        // the user does bring it forward.
        NSApp.setActivationPolicy(runsInBackground ? .accessory : .regular)
        if !runsInBackground {
            NSApp.activate(ignoringOtherApps: true)
        }
        KraalLog.shared.rotate()
        kraalLog("launch: bundle=\(Bundle.main.bundleIdentifier ?? "none") bundlePath=\(Bundle.main.bundlePath)")
        kraalLog("launch: session=\(KraalLog.shared.sessionName ?? "(none)") "
            + "background=\(runsInBackground) log=\(KraalLog.shared.fileURL.path)")
        kraalLog("launch: screens=\(NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | "))")

        let pool = PaneTerminalPool { [weak self] target, data in
            self?.routeInput(target: target, data: data)
        }

        let copyController = makeCopyModeController(store: store)

        let root = RootView(
            store: store,
            windowActions: windowActions,
            copyModeBanner: copyController.banner
        ) { store, paneId, geometry in
            guard let surface = store.surface else {
                return AnyView(Color(nsColor: .textBackgroundColor))
            }
            // Point the pool at whichever machine this surface came from before
            // asking it for a model. Pane ids are only unique within one daemon
            // (two machines can both have `w1:p1`), so the pool keys on the pair
            // and drops everything when the machine actually changes.
            pool.selectMachine(surface.bootId)
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
        } popupPaneContent: { store, popup, _ in
            self.popupView(store: store, popup: popup, pool: pool)
        }

        let window = makeWindow(root: root)
        self.window = window

        // Terminal events (OSC 52 clipboard, pane title, bell, notification) are
        // reduced to a value by the store and applied here, which is the only
        // code that touches AppKit for them. Assigned before `connect()` so no
        // event from the first frame is missed.
        let effects = TerminalEffectsApplier()
        effects.attach(window: window)
        terminalEffects = effects
        store.onEffectsChanged = { [weak effects] pending in
            guard let effects else { return }
            let applied = effects.apply(pending)
            guard !applied.isEmpty else { return }
            kraalLog("effects: \(applied.joined(separator: " "))")
        }

        // Keep the pool in sync with the store: drop terminals for closed panes
        // so their Ghostty surfaces are released.
        store.onPaneSetChanged = { [weak self] paneIds in
            _ = self
            pool.prune(keeping: paneIds)
        }

        // Mouse events are observed, not intercepted: Ghostty keeps its own
        // selection and scroll behaviour, and panes that asked for mouse
        // reporting additionally get semantic events on the daemon connection.
        let forwarder = MouseForwarder(store: store, paneActions: self)
        forwarder.attach(to: window)
        mouseForwarder = forwarder
        self.paneTerminalPool = pool

        // Now that there is a window, the key monitor can attach to it.
        copyController.attach(to: window)

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
                showSettings: { [windowActions] in windowActions.showSettings() },
                showDebugInfo: { [windowActions] in windowActions.showDebugInfo() },
                enterCopyMode: { [weak self] paneId in self?.copyMode?.enter(paneId: paneId) }
            )
        )
        menu.install()
        menuBar = menu

        store.loadDefaultSidebarConfig()
        store.connect()
    }

    /// Sends Ghostty's encoded bytes to whichever daemon-side terminal produced
    /// them.
    ///
    /// A popup's terminal id is not a pane id, and the two paths are not
    /// interchangeable: sending a popup's keys down the pane path types them into
    /// whatever is focused underneath, and focusing "pane \(terminalId)" would fail
    /// and drop the focus the popup was opened over.
    ///
    /// `nonisolated` on purpose: Ghostty hands us these bytes from its own
    /// output thread, not the main actor. The only work done before the hop
    /// below is a log line, and `KraalLog` is locked and `@unchecked Sendable`.
    /// Declaring this main-actor-isolated made that call an isolation
    /// violation the compiler can only warn about in Swift 5 mode — and it
    /// turns into a real data race the moment anything that reads `store`
    /// moves above the hop.
    nonisolated private func routeInput(target: String, data: Data) {
        kraalLog("input: target=\(target) bytes=\(data.count) "
            + "raw=\(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.store.hasPopup, self.store.activePopup?.terminalId == target {
                self.store.sendPopupInput(data, terminalId: target)
            } else {
                self.store.sendInput(data, to: target)
                self.store.focus(paneId: target)
            }
        }
    }

    /// Builds the popup's terminal view.
    ///
    /// A popup is its own terminal on the daemon, so it gets its own model: reusing
    /// a pane's would merge two independent cell streams into one screen. The pool is
    /// keyed by `(machine, id)` and popup terminal ids live in a different namespace
    /// from pane ids, so one pool holds both safely.
    private func popupView(
        store: AppStore,
        popup: ClientShellPopupSurface,
        pool: PaneTerminalPool
    ) -> AnyView {
        guard let surface = store.surface else {
            return AnyView(Color(nsColor: .textBackgroundColor))
        }
        pool.selectMachine(surface.bootId)
        let model = pool.model(for: popup.terminalId)
        model.onCellMetrics = { [weak store] cellSize in
            guard let store else { return }
            Task { @MainActor in store.updateCellMetrics(cellSize) }
        }
        // The daemon sends the popup's grid already cropped to its own frame, so it
        // is painted straight in — no surface cropping, no diffing against the panes'
        // stream.
        //
        // A popup has no revision of its own on the wire, so the parent surface's is
        // used: the popup's grid only changes when the surface is re-projected, and
        // repainting identical cells every frame would be wasteful at 60 Hz.
        model.applyPopup(frame: popup.frame, revision: surface.surfaceRevision)
        return AnyView(GhosttyPopupView(model: model, terminalId: popup.terminalId))
    }

    /// Creates this window's copy-mode controller.
    ///
    /// Split out of `applicationDidFinishLaunching`, which the linter holds to 80
    /// lines — and which is genuinely easier to read without a three-line aside in
    /// the middle about where the banner goes.
    private func makeCopyModeController(store: AppStore) -> CopyModeController {
        // Created before the view so its banner can be handed to the status bar;
        // attached to the window once there is one.
        let controller = CopyModeController(store: store)
        copyMode = controller
        return controller
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
        window.title = DevSession.title(name: DevSession.name, background: runsInBackground)
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
        Self.installTitlebarMaterial(in: window)
        kraalLog("window chrome: isOpaque=\(window.isOpaque) "
            + "backgroundColor=\(window.backgroundColor.alphaComponent) "
            + "titlebarTransparent=\(window.titlebarAppearsTransparent) "
            + "fullSizeContent=\(window.styleMask.contains(.fullSizeContentView))")
        // `orderBack` puts the window on screen without making it key or main:
        // the session can still render, and window-level capture still finds it
        // (the window server draws it whether or not it is frontmost), but the
        // user's pointer, keyboard focus and front window are untouched.
        // `orderFrontRegardless` is exactly the call a background session must
        // not make — it raises the window over the active app.
        if runsInBackground {
            window.orderBack(nil)
            kraalLog("window: ordered back (background session, no focus taken)")
        } else {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        // The window number is how a screenshot of *this* window is taken without
        // screen recording and without the window being frontmost:
        //   screencapture -l <windowNumber> …
        // An off-screen or ordered-back window keeps its number, so a background
        // session can still prove what it rendered while the user works in front
        // of it. Accessibility is not needed for any of that, which matters here
        // because the terminal is drawn by Metal and has no useful AX tree.
        kraalLog("window: number=\(window.windowNumber) pid=\(ProcessInfo.processInfo.processIdentifier)")
        return window
    }

    /// Puts a real material behind the titlebar strip.
    ///
    /// The window is non-opaque with a clear background (required for
    /// `.behindWindow` vibrancy to reach the desktop) and hides its titlebar
    /// (`titlebarAppearsTransparent`). Those two together leave the top strip
    /// with nothing drawn in it: SwiftUI lays its content out below the titlebar's
    /// safe area, and AppKit's own titlebar chrome was told to go away. The strip
    /// therefore showed the desktop straight through — the traffic lights and the
    /// toolbar buttons floating on raw wallpaper, with a hard edge where the
    /// sidebar's material began 38pt lower.
    ///
    /// The material has to be installed as a sibling *below* the titlebar
    /// container rather than as part of the SwiftUI tree, because the strip is
    /// outside the hosting view's frame entirely: anything the view tree draws
    /// there would be clipped away.
    private static func installTitlebarMaterial(in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        let height = window.frame.height - window.contentLayoutRect.height
        guard height > 0 else { return }

        let glass = NSVisualEffectView(
            frame: NSRect(x: 0, y: frameView.bounds.height - height,
                          width: frameView.bounds.width, height: height)
        )
        // Same role as the bars below it (`GlassLayer.bar`), so the seam between
        // the titlebar and the tab bar is invisible: the two strips are the same
        // system material, adjacent.
        glass.material = .headerView
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        glass.autoresizingMask = [.width, .minYMargin]

        // Below the titlebar container (which holds the traffic lights and the
        // toolbar items) so those keep drawing on top, but above the frame view's
        // own background.
        if let titlebar = frameView.subviews.first(where: {
            String(describing: type(of: $0)).contains("TitlebarContainer")
        }) {
            frameView.addSubview(glass, positioned: .below, relativeTo: titlebar)
        } else {
            frameView.addSubview(glass, positioned: .below, relativeTo: nil)
        }
        kraalLog("titlebar material: height=\(height) frame=\(glass.frame) "
            + "material=headerView blending=behindWindow")
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

    /// The frame from the previous session, if it was saved.
    ///
    /// Keyed by dev session so a background copy cannot restore itself onto the
    /// frame the user left their own window at.
    static func savedFrame() -> NSRect? {
        let key = DevSession.windowFrameDefaultsKey(name: DevSession.name)
        guard let frame = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        let rect = NSRectFromString(frame)
        return rect.width > 200 && rect.height > 200 ? rect : nil
    }

    func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(
            NSStringFromRect(window.frame),
            forKey: DevSession.windowFrameDefaultsKey(name: DevSession.name)
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

// MARK: - Pane context menu

/// The pane menu reaches the app delegate for everything that is not already an
/// `AppCommand`: the pane it acts on comes from the menu the click raised, and
/// the two clipboard actions have to reach that pane's Ghostty surface.
extension KraalAppDelegate: PaneContextMenuProviding, PaneContextTarget, PaneContextMenuValidating {
    func showPaneContextMenu(for paneId: String, event: NSEvent) {
        // Focus follows the click: a right-click is a deliberate act on one pane,
        // and every item in the menu reads "the focused pane". Without this, a
        // right-click in a background pane would silently act on another one.
        store.focus(paneId: paneId)

        // Commands go to the menu bar, not to `self`: `MacMenuBar` is the object
        // that answers `validateMenuItem` and implements `runCommand`. Pointing
        // them at the delegate instead left them greyed out, because AppKit
        // disables an item whose target does not respond to its selector.
        let menu = PaneContextMenuBar.menu(
            paneId: paneId,
            rightClickPassthrough: store.rightClickPassthrough(paneId: paneId),
            target: self,
            commandTarget: menuBar ?? self,
            commandSelector: #selector(MacMenuBar.runCommand(_:))
        )
        // Anchor the menu to the click, not to the view's origin: this is what
        // makes it open where the user right-clicked.
        let location = event.locationInWindow
        if let view = window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: location, in: nil)
        }
        kraalLog("contextmenu: pane=\(paneId) at=\(Int(location.x)),\(Int(location.y))")
    }

    func paneHasSelection(_ paneId: String) -> Bool {
        paneTerminalPool?.model(for: paneId).state.surface?.hasSelection() == true
    }

    /// Runs Ghostty's own `copy_to_clipboard` binding, so what lands on the
    /// pasteboard is exactly what the user would get from ⌘C inside the pane.
    func copySelection(in paneId: String) {
        guard let surface = paneTerminalPool?.model(for: paneId).state.surface else { return }
        _ = surface.performBindingAction("copy_to_clipboard")
    }

    // MARK: PaneContextTarget

    func focusPane(_ sender: NSMenuItem) {
        guard let paneId = sender.menu?.owningPaneId else { return }
        store.focus(paneId: paneId)
    }

    func copySelection(_ sender: NSMenuItem) {
        guard let paneId = sender.menu?.owningPaneId else { return }
        copySelection(in: paneId)
    }

    /// Paste is sent as a *paste* event, not as keystrokes.
    ///
    /// The daemon owns the pane's content, so the text has to go back over the
    /// connection — but as `.paste(text)` (wire tag 3), not as raw bytes through
    /// the key decoder. Sending bytes made a paste indistinguishable from typing:
    /// every newline arrived as Enter, so pasting a three-line command ran all
    /// three (issue #20).
    func pasteIntoPane(_ sender: NSMenuItem) {
        guard let paneId = sender.menu?.owningPaneId else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        store.sendPaste(text, to: paneId)
    }

    func renamePane(_ sender: NSMenuItem) {
        guard let paneId = sender.menu?.owningPaneId else { return }
        presentPaneRename(paneId: paneId)
    }

    /// Flips this pane's right-click routing via `pane.input.set`.
    ///
    /// Deliberately does not flip a local flag: the daemon owns this setting and
    /// reports it back as `right_click_passthrough` in the next snapshot. A local
    /// flip would put a checkmark on screen that the daemon never agreed to, and
    /// the pane would keep opening the menu because `MouseForwarder` reads the
    /// snapshot. Sending the request and letting the snapshot land is the only
    /// version where the menu and the behaviour cannot disagree.
    func toggleRightClickPassthrough(_ sender: NSMenuItem) {
        guard let paneId = sender.menu?.owningPaneId else { return }
        let current = store.rightClickPassthrough(paneId: paneId)
        store.setRightClickPassthrough(paneId: paneId, passthrough: !current)
        kraalLog("contextmenu: right_click pane=\(paneId) \(current) -> \(!current)")
    }

    /// The menu bar's rename flow, reused so a rename started from a pane looks
    /// and behaves the same as one started from the menu.
    private func presentPaneRename(paneId: String) {
        let alert = NSAlert()
        alert.messageText = CommandPrompt.renamePane(
            paneId: paneId,
            current: store.paneLabel(paneId) ?? ""
        ).title
        alert.informativeText = "Enter a new name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = store.paneLabel(paneId) ?? ""
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.rename(paneId: paneId, to: name)
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
