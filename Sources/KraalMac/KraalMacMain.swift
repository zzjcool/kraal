// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The macOS app: one herdr-core window, its persisted frame and the AppKit
// chrome the SwiftUI tree cannot reach. There is no second client stack here;
// the Herdr 1 window and its store were removed with the old targets.

import AppKit
import KraalHC
import KraalHCTerminal
import KraalSupport
import SwiftUI

@MainActor
final class KraalAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    /// The herdr-core window's model.
    var hcWorkspace: HcWorkspaceModel?
    /// The local control socket that serves `kraal ls/status/do/shot`.
    var hcControl: HcControlServer?

    /// Whether this launch is allowed to take the desktop.
    ///
    /// A background dev session (see `DevSession`) skips every call that would
    /// move the pointer, raise its window over the user's work or steal keyboard
    /// focus: `activate(ignoringOtherApps:)`, `makeKeyAndOrderFront` and the
    /// `.regular` activation policy that puts it in the Dock and the ⌘-Tab list.
    private let runsInBackground = DevSession.runsInBackground

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(runsInBackground ? .accessory : .regular)
        if !runsInBackground {
            NSApp.activate(ignoringOtherApps: true)
        }
        KraalLog.shared.rotate()
        kraalLog("launch: bundle=\(Bundle.main.bundleIdentifier ?? "none") bundlePath=\(Bundle.main.bundlePath)")
        kraalLog("launch: session=\(KraalLog.shared.sessionName ?? "(none)") "
            + "background=\(runsInBackground) log=\(KraalLog.shared.fileURL.path)")
        kraalLog("launch: screens=\(NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | "))")

        let environment = ProcessInfo.processInfo.environment
        if let sshHost = environment["KRAAL_HC_SSH"], !sshHost.isEmpty {
            let remote = environment["KRAAL_HC_SSH_COMMAND"] ?? "hc connect"
            kraalLog("launch: mode=herdr-core ssh=\(sshHost) command=\(remote)")
            presentHcWindow(sshHost: sshHost, remoteCommand: remote)
            return
        }

        do {
            let socket = try Self.hcSocketPath()
            kraalLog("launch: mode=herdr-core socket=\(socket)")
            presentHcWindow(path: socket)
        } catch {
            kraalLog("launch: hc path resolution failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Cannot start Kraal"
            alert.informativeText = "Could not resolve the herdr-core socket: \(error)"
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func makeWindow(root: some View) -> NSWindow {
        let size = NSSize(
            width: HcChromeMetrics.windowDefaultWidth,
            height: HcChromeMetrics.windowDefaultHeight
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Keeps the window object alive across `close()`.
        //
        // AppKit's default (`isReleasedWhenClosed = true`) sends a `release` on
        // close that ARC does not know about, so the `NSWindow?` held by the
        // delegate becomes a dangling reference the moment the user closes the
        // window. `applicationWillTerminate` then reads it — closing the last
        // window is what triggers termination — and crashes on the retain:
        //
        //   EXC_BAD_ACCESS (SIGSEGV, KERN_INVALID_ADDRESS) in objc_retain
        //   -> KraalAppDelegate.saveFrame()
        //   -> KraalAppDelegate.applicationWillTerminate(_:)
        //
        // Reproduced six times in one evening, always on quit, and again in a
        // fifteen-line AppKit program before touching this file. With this flag
        // set the same program prints the frame instead of segfaulting.
        window.isReleasedWhenClosed = false
        window.title = DevSession.title(name: DevSession.name, background: runsInBackground)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The chrome is flat, opaque colour now (official `paper`/`graphite`
        // bars), so the window itself stays non-opaque and clear: that is what
        // lets the transparent titlebar reveal the SwiftUI bar underneath instead
        // of compositing a native grey band above it. Every region is covered by
        // an opaque SwiftUI fill, so nothing samples the desktop through a gap.
        window.isOpaque = false
        window.backgroundColor = .clear
        // One continuous 40pt band from the traffic lights to the tabs: no native
        // titlebar material and no native hairline under it; the bar draws its own
        // 1pt border. The traffic lights stay where AppKit puts them.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.contentView = hosting
        window.setContentSize(size)
        window.minSize = NSSize(
            width: HcChromeMetrics.windowMinWidth,
            height: HcChromeMetrics.windowMinHeight
        )

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
        // The window flags are logged because a screenshot cannot show them: a
        // native titlebar band silently reappears if transparency or the
        // full-size content mask regress, and the 40pt chrome then starts 28pt
        // too low.
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
        hcControl?.stop()
        hcWorkspace?.stop()
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
