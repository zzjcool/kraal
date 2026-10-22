// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import ApplicationServices
import Foundation

// `kraal-gui` — drives a running Kraal window from the outside.
//
// Deliberately has no dependency on any Kraal target: it only speaks AppKit and
// the Accessibility API. That keeps it buildable anywhere (it is pushed into a
// Tart VM as a single binary) and keeps it honest — a driver that shared code
// with the app could "pass" by agreeing with the app's own bugs.
//
// Backend-agnostic by construction: it knows how to find a window and press
// things, not whether it is running on the host or inside a VM.

// MARK: - Exit codes

/// Exit codes double as a message to the agent driving the loop.
///
/// `docs/DEBUGGING.md` §2 is the reason `harness` exists: when the driver
/// cannot find its target, that is *not* evidence of a product bug, and an
/// agent that "fixes" code in response to it will thrash.
enum Exit: Int32 {
    case success = 0
    case assertion = 1   // product behaviour is wrong → fix code
    case harness = 2     // could not drive the app → report a blocker
    case crash = 3       // app under test died
}

func fail(_ code: Exit, _ message: String) -> Never {
    FileHandle.standardError.write(Data("kraal-gui: \(message)\n".utf8))
    exit(code.rawValue)
}

// MARK: - Argument parsing

/// Minimal `--flag value` parser. `--flag` alone sets a boolean true.
struct Arguments {
    private var values: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            guard token.hasPrefix("--") else {
                index += 1
                continue
            }
            let key = String(token.dropFirst(2))
            let next = index + 1 < raw.count ? raw[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                values[key] = next
                index += 2
            } else {
                values[key] = ""
                index += 1
            }
        }
    }

    func string(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }

    func has(_ key: String) -> Bool { values[key] != nil }
    func int(_ key: String) -> Int? { string(key).flatMap(Int.init) }
    func double(_ key: String) -> Double? { string(key).flatMap(Double.init) }

    func selector() -> Selector {
        Selector(
            id: string("id"),
            desc: string("desc"),
            title: string("title"),
            role: string("role"),
            index: int("index") ?? 0
        )
    }
}

// MARK: - Signal handling for "watch for crash"

/// Returns false once the process is gone.
func isRunning(_ app: TargetApp) -> Bool { !app.application.isTerminated }

/// After an action, a dead process is a crash — a distinct outcome from a
/// failed assertion, and the one case where the artifact that matters is the
/// crash report rather than a screenshot.
func requireAlive(_ app: TargetApp, context: String) {
    if !isRunning(app) {
        fail(.crash, "app '\(app.name)' died during \(context) — check DiagnosticReports")
    }
}

// MARK: - Commands

func commandProbe(_ args: Arguments) -> Never {
    let trusted = AXIsProcessTrusted()
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    let named = windows.filter { ($0[kCGWindowName as String] as? String)?.isEmpty == false }
    print("axTrusted=\(trusted)")
    print("windows=\(windows.count) withName=\(named.count)")
    // Without Screen Recording, `screencapture` still exits 0 but produces the
    // desktop-wallpaper-only image and every kCGWindowName is nil. Treating a
    // silent half-permission as "ready" is how a run later "fails" for reasons
    // that have nothing to do with the code.
    if named.isEmpty {
        fail(.harness, "no window titles visible — Screen Recording is not granted")
    }
    exit(Exit.success.rawValue)
}

func commandAX(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let maxDepth = args.int("depth") ?? 16
    var lines: [String] = []

    func describe(_ element: AXUIElement, _ depth: Int) {
        guard depth <= maxDepth else { return }
        let role = element.string(kAXRoleAttribute) ?? "?"
        let title = element.string(kAXTitleAttribute) ?? ""
        let desc = element.string(kAXDescriptionAttribute) ?? ""
        let id = element.string("AXIdentifier") ?? ""
        let actions = element.actionNames
        lines.append(
            "\(String(repeating: "  ", count: depth))\(role) title=\(title) "
                + "desc=\(desc) id=\(id) actions=\(actions)"
        )
        for child in element.children {
            describe(child, depth + 1)
        }
    }
    describe(app.element, 0)

    if let out = args.string("out") {
        try? lines.joined(separator: "\n").write(
            toFile: out, atomically: true, encoding: .utf8
        )
    }
    print(lines.joined(separator: "\n"))
    exit(Exit.success.rawValue)
}

/// Presses one element. **Does not activate the app.**
///
/// Verified on the host: with the target ordered to the back and Brave in
/// front, `AXPress` still delivered and the frontmost app never changed. That
/// is what lets the `local` backend run while the machine is in use — and it is
/// the reason `AX` is the default strategy and synthetic events are the fallback.
func commandPress(_ args: Arguments) -> Never {
    let selector = args.selector()
    if selector.isEmpty { fail(.harness, "press needs --title, --desc, --id or --role") }

    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    guard let element = app.find(selector) else {
        fail(.harness, "no element matching \(selector.humanReadable)")
    }
    let actions = element.actionNames
    guard actions.contains(kAXPressAction) else {
        fail(.harness, "element \(selector.humanReadable) has no AXPress (actions=\(actions))")
    }

    let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
    if error != .success {
        fail(.harness, "AXPress failed with AXError \(error.rawValue)")
    }
    // AXPress returning success means "the action was dispatched", not "the
    // feature worked". Callers must assert on state (daemon, window tree)
    // before believing anything happened.
    print("pressed \(selector.humanReadable)")
    requireAlive(app, context: "press \(selector.humanReadable)")
    exit(Exit.success.rawValue)
}

func commandWait(_ args: Arguments) -> Never {
    let selector = args.selector()
    if selector.isEmpty { fail(.harness, "wait needs a selector") }
    let timeout = args.double("timeout") ?? 10
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if app.find(selector) != nil {
            print("found \(selector.humanReadable)")
            exit(Exit.success.rawValue)
        }
        usleep(120_000)
    }
    fail(.harness, "timed out after \(timeout)s waiting for \(selector.humanReadable)")
}

/// Prints the window frame and window number. Exists because every coordinate
/// bug so far (VM probe E15) came from guessing a position instead of asking.
///
/// Geometry comes from the window server, not from `AXWindows` — see the note on
/// `WindowInfo`. Polls until a real-size window appears rather than failing on
/// the first attempt: a window that has just been ordered in exists but may not
/// have its final bounds yet.
func commandWindow(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let timeout = args.double("timeout") ?? 10
    let deadline = Date().addingTimeInterval(timeout)
    var found: WindowInfo?
    while Date() < deadline {
        if let candidate = primaryWindow(for: app.pid, title: args.string("title")) {
            found = candidate
            break
        }
        usleep(150_000)
    }
    guard let window = found else {
        fail(.harness, "app '\(app.name)' showed no window with real bounds after \(timeout)s")
    }
    print("pid=\(app.pid) windowNumber=\(window.number) "
        + "x=\(Int(window.frame.origin.x)) y=\(Int(window.frame.origin.y)) "
        + "w=\(Int(window.frame.size.width)) h=\(Int(window.frame.size.height))")
    exit(Exit.success.rawValue)
}

/// Screenshots one window of the app under test.
///
/// `CGWindowListCreateImage` was removed in macOS 15, so this shells out to
/// `screencapture -l`. Window-by-window capture also means the shot is stable
/// even if the app is behind other windows — which is the normal case for the
/// `local` backend.
func commandShot(_ args: Arguments) -> Never {
    guard let out = args.string("out") else { fail(.harness, "shot needs -o/--out") }
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let number: Int
    if args.has("full") {
        number = 0
    } else {
        guard let found = primaryWindow(for: app.pid, title: args.string("title")) else {
            fail(.harness, "app '\(app.name)' has no window to capture")
        }
        number = found.number
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = number == 0
        ? ["-x", out]
        : ["-x", "-o", "-l", String(number), out]
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: out) else {
        fail(.harness, "screencapture failed (\(process.terminationStatus))")
    }
    print("wrote \(out) window=\(number == 0 ? "full" : String(number))")
    exit(Exit.success.rawValue)
}

/// A window as the window server describes it.
///
/// `AXWindows` is not usable here. On macOS 27 every element it returns reports
/// `AXRole = AXApplication` — the app itself — and `AXPosition`/`AXSize` fail
/// with AXError -25205 (`.illegalArgument`). That is not a Kraal problem: Finder
/// returns an `AXScrollArea` from the same attribute. The window server still
/// knows the truth, so geometry comes from `CGWindowListCopyWindowInfo`, which
/// is also what `screencapture -l` needs anyway.
struct WindowInfo {
    let number: Int
    let frame: CGRect
    let title: String?
}

func windows(of pid: pid_t) -> [WindowInfo] {
    let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return list.compactMap { entry -> WindowInfo? in
        guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let number = entry[kCGWindowNumber as String] as? Int,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double
        else { return nil }
        var rect = CGRect()
        CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect)
        return WindowInfo(
            number: number,
            frame: CGRect(x: rect.origin.x, y: rect.origin.y, width: width, height: height),
            title: entry[kCGWindowName as String] as? String
        )
    }
}

/// Picks the window under test.
///
/// Largest wins: the app owns several (toolbar accessory hosts, shadow windows),
/// and the content window is the big one. A title match, when one is given, is
/// more precise and wins over size.
func primaryWindow(for pid: pid_t, title: String?) -> WindowInfo? {
    let candidates = windows(of: pid).filter { $0.frame.width > 100 && $0.frame.height > 100 }
    if let title, let exact = candidates.first(where: { $0.title == title }) {
        return exact
    }
    if let title, let partial = candidates.first(where: { ($0.title ?? "").contains(title) }) {
        return partial
    }
    return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

func windowNumber(for pid: pid_t, title: String?) -> Int? {
    primaryWindow(for: pid, title: title)?.number
}

/// Types text. Prefers writing the value through AX so it works without focus;
/// falls back to synthetic key events, which do need the app frontmost.
func commandType(_ args: Arguments) -> Never {
    guard let text = args.string("text") else { fail(.harness, "type needs --text") }
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    var focused: CFTypeRef?
    if AXUIElementCopyAttributeValue(
        app.element, kAXFocusedUIElementAttribute as CFString, &focused
    ) == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() {
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        if AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFString
        ) == .success {
            print("typed via AX")
            requireAlive(app, context: "type")
            exit(Exit.success.rawValue)
        }
    }
    // Fallback: real key events. This steals focus, so say so loudly.
    FileHandle.standardError.write(Data(
        "kraal-gui: AX typing unavailable, falling back to CGEvent (steals focus)\n".utf8
    ))
    app.application.activate()
    usleep(300_000)
    for scalar in text.unicodeScalars {
        var unit = UniChar(scalar.value)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        down?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        keyUp?.post(tap: .cghidEventTap)
        usleep(20_000)
    }
    print("typed via CGEvent")
    requireAlive(app, context: "type")
    exit(Exit.success.rawValue)
}

func commandLaunch(_ args: Arguments) -> Never {
    guard let path = args.string("app") else { fail(.harness, "launch needs --app PATH") }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail(.harness, "no executable at \(path)")
    }
    var environment = ProcessInfo.processInfo.environment
    if let pair = args.string("env") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { environment[parts[0]] = parts[1] }
    }
    let process = Process()
    process.executableURL = url
    process.environment = environment
    // Detach: the app must outlive the driver invocation.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        fail(.harness, "could not launch \(path): \(error)")
    }
    print("launched pid=\(process.processIdentifier)")
    if let windowTitle = args.string("wait-window") {
        let timeout = args.double("timeout") ?? 15
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app = TargetApp.find(name: args.string("match") ?? "Kraal"),
               app.windows().contains(where: {
                   ($0.string(kAXTitleAttribute) ?? "").contains(windowTitle)
               }) {
                print("window ready: \(windowTitle)")
                exit(Exit.success.rawValue)
            }
            usleep(200_000)
        }
        fail(.harness, "window '\(windowTitle)' did not appear in \(timeout)s")
    }
    exit(Exit.success.rawValue)
}

func commandQuit(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        print("not running")
        exit(Exit.success.rawValue)
    }
    app.application.terminate()
    let deadline = Date().addingTimeInterval(args.double("timeout") ?? 5)
    while Date() < deadline {
        if app.application.isTerminated { print("terminated"); exit(Exit.success.rawValue) }
        usleep(120_000)
    }
    app.application.forceTerminate()
    print("force terminated")
    exit(Exit.success.rawValue)
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    let usage = """
    usage: kraal-gui <command> [options]

      probe                          check AX + Screen Recording; exit 2 if not ready
      ax [--out FILE] [--depth N]    dump the accessibility tree
      press --title|--desc|--id X    AXPress an element (does NOT activate the app)
      wait  --title X [--timeout S]  poll until the element exists
      window                         print window frame + window number
      shot  -o FILE [--full]         screenshot one window
      type  --text S                 type text (AX first, CGEvent fallback)
      launch --app PATH [--env K=V] [--wait-window T] [--match NAME]
      quit                           terminate the app under test

    exit codes: 0 ok · 1 assertion · 2 harness · 3 crash
    """
    print(usage)
    exit(Exit.harness.rawValue)
}

let args = Arguments(Array(argv.dropFirst()))
switch command {
case "probe": commandProbe(args)
case "ax": commandAX(args)
case "press": commandPress(args)
case "wait": commandWait(args)
case "window": commandWindow(args)
case "shot": commandShot(args)
case "type": commandType(args)
case "launch": commandLaunch(args)
case "quit": commandQuit(args)
default:
    fail(.harness, "unknown command '\(command)'")
}
