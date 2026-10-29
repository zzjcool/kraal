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

    /// Single-dash spellings people actually type. Without this, `shot -o FILE`
    /// was parsed as nothing at all and the command failed saying it needed
    /// `-o` — while `-o` was right there on the line.
    private static let shortNames: [String: String] = [
        "o": "out", "a": "app", "t": "title", "d": "desc", "i": "id",
    ]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            let isLong = token.hasPrefix("--")
            let isShort = !isLong && token.hasPrefix("-") && token.count == 2
            guard isLong || isShort else {
                index += 1
                continue
            }
            let bare = isLong ? String(token.dropFirst(2)) : String(token.dropFirst())
            let key = isLong ? bare : (Arguments.shortNames[bare] ?? bare)
            let next = index + 1 < raw.count ? raw[index + 1] : nil
            // A short flag always takes a value; a long one may be a switch.
            if let next, isShort || !next.hasPrefix("--") {
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
        var found = Selector(
            id: string("id"),
            desc: string("desc"),
            title: string("title"),
            value: string("value"),
            role: string("role"),
            index: int("index") ?? 0
        )
        // `--within-<attr> VALUE` scopes the search to the first element matching
        // that attribute. Needed because titles repeat across menus and the two
        // copies do different things.
        for attr in ["title", "desc", "id", "role", "value"] {
            if let value = string("within-\(attr)") {
                var scope = Selector()
                switch attr {
                case "title": scope.title = value
                case "desc": scope.desc = value
                case "id": scope.id = value
                case "value": scope.value = value
                default: scope.role = value
                }
                found.within = ScopeBox(scope)
                break
            }
        }
        return found
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

/// Emits the accessibility tree, as text or as JSON.
///
/// JSON is what an agent reads: `--json` gives every element a stable `path`
/// (role/subrole-free child indices from the app root) plus `pressable`, so a
/// caller can decide what to press without parsing indented text. Text stays the
/// default because it is what a human skims in a terminal.
///
/// Both forms come from the **same** traversal with a visited set. The AX graph
/// is not a tree — `AXMenuBar` is reachable from `AXApplication` and from the
/// app's children, and menu subtrees reappear below themselves — so a naive walk
/// lists each menu item many times (measured: `Split Right` 13 times). Reporting
/// those duplicates as separate elements is what made "is this title unique?"
/// answer wrong.
func commandAX(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let maxDepth = args.int("depth") ?? 16
    var nodes: [AXNode] = []
    var visited = Set<CFHashCode>()

    func walk(_ element: AXUIElement, _ depth: Int, _ path: String) {
        guard depth <= maxDepth else { return }
        guard visited.insert(CFHash(element)).inserted else { return }
        let actions = element.actionNames
        nodes.append(
            AXNode(
                path: path,
                depth: depth,
                role: element.string(kAXRoleAttribute) ?? "?",
                title: element.string(kAXTitleAttribute) ?? "",
                desc: element.string(kAXDescriptionAttribute) ?? "",
                value: element.string(kAXValueAttribute) ?? "",
                identifier: element.string("AXIdentifier") ?? "",
                enabled: element.copy(kAXEnabledAttribute) as? Bool,
                actions: actions,
                frame: element.frame.map {
                    ["x": Int($0.origin.x), "y": Int($0.origin.y),
                     "w": Int($0.size.width), "h": Int($0.size.height)]
                }
            )
        )
        for (index, child) in element.children.enumerated() {
            walk(child, depth + 1, path + "/" + String(index))
        }
    }
    walk(app.element, 0, "")

    let payload = AXTree(pid: app.pid, app: app.name, count: nodes.count, nodes: nodes)
    let text = args.has("json") ? (jsonText(payload) ?? "{}") : textTree(nodes)
    if let out = args.string("out") {
        try? text.write(toFile: out, atomically: true, encoding: .utf8)
    }
    print(text)
    exit(Exit.success.rawValue)
}

/// One element in the flattened tree.
struct AXNode: Encodable {
    let path: String
    let depth: Int
    let role: String
    let title: String
    let desc: String
    /// `AXValue`. SwiftUI `Text` puts its string here and nowhere else, so this is
    /// the only way to address a sidebar row or a machine name by content.
    let value: String
    let identifier: String
    let enabled: Bool?
    let actions: [String]
    let frame: [String: Int]?

    /// Whether `press` can act on it. An agent's first question about any element.
    var pressable: Bool { actions.contains(kAXPressAction) }

    enum CodingKeys: String, CodingKey {
        case path, depth, role, title, desc, value, identifier, enabled, actions, frame, pressable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(depth, forKey: .depth)
        try container.encode(role, forKey: .role)
        try container.encode(title, forKey: .title)
        try container.encode(desc, forKey: .desc)
        try container.encode(value, forKey: .value)
        try container.encode(identifier, forKey: .identifier)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encode(actions, forKey: .actions)
        try container.encodeIfPresent(frame, forKey: .frame)
        try container.encode(pressable, forKey: .pressable)
    }
}

struct AXTree: Encodable {
    let pid: pid_t
    let app: String
    let count: Int
    let nodes: [AXNode]
}

private func jsonText<T: Encodable>(_ value: T) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func textTree(_ nodes: [AXNode]) -> String {
    nodes.map { node in
        let indent = String(repeating: "  ", count: node.depth)
        var line = "\(indent)\(node.role) title=\(node.title) desc=\(node.desc) "
            + "value=\(node.value) id=\(node.identifier)"
        if node.enabled == false { line += " [disabled]" }
        line += " actions=\(node.actions)"
        return line
    }.joined(separator: "\n")
}

/// Presses one element. **Does not activate the app.**
///
/// Verified on the host: with the target ordered to the back and Brave in
/// front, `AXPress` still delivered and the frontmost app never changed. That
/// is what lets the `local` backend run while the machine is in use — and it is
/// the reason `AX` is the default strategy and synthetic events are the fallback.
func commandPress(_ args: Arguments) -> Never {
    let selector = args.selector()
    if selector.isEmpty { fail(.harness, "press needs --title, --desc, --id, --value or --role") }

    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    // Report ambiguity rather than quietly pressing the first match. `Copy` is in
    // both the Edit menu and the pane context menu; pressing the wrong one looks
    // exactly like the feature being broken.
    let matches = app.findAll(selector)
    if matches.isEmpty {
        fail(.harness, "no element matching \(selector.humanReadable)")
    }
    if matches.count > 1, selector.index == 0, !args.has("allow-ambiguous") {
        fail(.harness, "\(selector.humanReadable) matches \(matches.count) elements — "
            + "add --index N to choose one, --within-<kind> VALUE to narrow the subtree, "
            + "or --allow-ambiguous to take the first")
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
/// Screenshots one window of the app under test.
///
/// `CGWindowListCreateImage` was removed in macOS 15, so this shells out to
/// `screencapture`. On this host `-l <windowid>` fails with "could not create
/// image from window" for *every* app, not just this one — Herdr's window fails
/// too, while a plain full-screen capture succeeds. So the window-limited form
/// cannot be assumed to work: fall back to capturing the screen and cropping to
/// the window's own bounds. The crop is derived from the same `CGWindowList`
/// geometry the rest of the driver trusts, so the fallback is not a guess.
func commandShot(_ args: Arguments) -> Never {
    guard let out = args.string("out") else { fail(.harness, "shot needs -o/--out") }
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    guard !args.has("full") else {
        runCapture(["-x", out], label: "full", out: out)
    }
    guard let window = primaryWindow(for: app.pid, title: args.string("title")) else {
        fail(.harness, "app '\(app.name)' has no window to capture")
    }
    // Try the precise form first; it is the only one that is stable when the app
    // is behind other windows.
    if capture(["-x", "-o", "-l", String(window.number), out]) {
        reportShot(out, window: window.number)
    }
    cropFromScreen(window: window, out: out)
}

/// True when every pixel of the PNG is identical to the top-left one.
///
/// `screencapture` exits 0 and writes a perfectly valid PNG when the calling
/// process lacks the Screen Recording grant — the file is just uniformly black.
/// Reporting that as success would let a screenshot assertion pass while proving
/// nothing, so the driver checks and says so instead.
private func isUniformlyBlank(_ path: String) -> Bool {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data)
    else { return false }
    let count = CFDataGetLength(data)
    let stride = image.bitsPerPixel / 8
    guard stride > 0, count >= stride * 2 else { return false }
    for offset in stride..<count where bytes[offset] != bytes[offset % stride] {
        return false
    }
    return true
}

/// Prints the capture result, refusing to call a blank image a success.
private func reportShot(_ out: String, window: Any, note: String = "") -> Never {
    if isUniformlyBlank(out) {
        fail(.harness, "captured \(out) is uniformly blank — the calling process "
            + "lacks Screen Recording permission (screencapture still exits 0). "
            + "Grant it in System Settings > Privacy & Security > Screen Recording.")
    }
    print("wrote \(out) window=\(window)\(note)")
    exit(Exit.success.rawValue)
}

/// Runs `screencapture` and reports whether it produced the file.
/// `screencapture` of one window, usable from other files (`commandDrag` captures a burst
/// of frames while the mouse button is held).
func captureWindow(to path: String, number: Int) -> Bool {
    capture(["-x", "-o", "-l", String(number), path])
}

private func capture(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    let target = arguments.last ?? ""
    return process.terminationStatus == 0
        && (FileManager.default.fileExists(atPath: target)
            && (try? FileManager.default.attributesOfItem(atPath: target)[.size] as? Int) ?? 0 > 0)
}

private func runCapture(_ arguments: [String], label: String, out: String) -> Never {
    guard capture(arguments) else { fail(.harness, "screencapture failed for \(label)") }
    reportShot(out, window: label)
}

/// Captures the whole screen and trims it to the window rectangle.
private func cropFromScreen(window: WindowInfo, out: String) -> Never {
    let scratch = out + ".screen.png"
    guard capture(["-x", scratch]) else {
        fail(.harness, "screencapture failed for both window and screen")
    }
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    // `sips` handles the crop with no extra dependency; the rectangle has to be
    // integral or sips rejects it.
    let crop = Process()
    crop.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    crop.arguments = [
        "--cropToHeightWidth", String(Int(window.frame.height)),
        String(Int(window.frame.width)),
        "--cropOffset", String(Int(window.frame.origin.y)),
        String(Int(window.frame.origin.x)),
        scratch, "--out", out,
    ]
    crop.standardError = FileHandle.nullDevice
    try? crop.run()
    crop.waitUntilExit()
    guard crop.terminationStatus == 0, FileManager.default.fileExists(atPath: out) else {
        fail(.harness, "could not crop screen capture to window")
    }
    reportShot(out, window: window.number, note: " (cropped from screen)")
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
    // Address the field directly when a selector is given.
    //
    // The focused-element path below only works when the field is *already*
    // focused, and a SwiftUI `TextField` in a sheet is not: setting the value went
    // to whatever had focus and the field kept its old text, which read as "typing
    // did nothing". A selector makes the target explicit, which is also what a test
    // wants — it should not depend on which element happened to be focused.
    if args.string("value") != nil || args.string("desc") != nil {
        var selector = Selector()
        selector.value = args.string("value")
        selector.desc = args.string("desc")
        guard let element = app.find(selector, maxDepth: args.int("depth") ?? 30) else {
            fail(.harness, "no element matching \(selector.humanReadable) to type into")
        }
        // Focus it first: a SwiftUI TextField binds to the field editor, and
        // setting `AXValue` on an unfocused field writes to the backing store
        // without telling SwiftUI — the UI keeps showing the old text (observed:
        // the AX value changed while the label stayed `default`). Focusing first
        // makes the write go through the field editor, which does notify.
        _ = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        usleep(200_000)
        guard AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFString
        ) == .success else {
            fail(.harness, "element \(selector.humanReadable) refused AXValue "
                + "(it may not be a text field)")
        }
        print("typed into \(selector.humanReadable) via AX")
        requireAlive(app, context: "type")
        exit(Exit.success.rawValue)
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

/// Explains why a synthetic event cannot be delivered, in terms of the actual
/// cause rather than a guess.
///
/// Three quite different situations all surface as "the app is not frontmost",
/// and only one of them is about the app at all:
///
/// * the screen is locked — `loginwindow` owns the front and nothing else can
///   take it, so this is purely environmental;
/// * the app runs with `KRAAL_DEV_BACKGROUND=1`, which makes it `.accessory` and
///   therefore ineligible to become frontmost by request;
/// * something else simply has focus.
///
/// Reporting the third when the first is true sends the reader hunting for a
/// product bug. It happened during this work: the machine was locked and the
/// driver blamed the app's activation policy.
/// Not `private` because `PointTargeting.swift` needs it: a click that cannot take
/// the front is a harness problem and both paths report it the same way.
func explanation(for app: TargetApp) -> String {
    if isScreenLocked() {
        return "the screen is locked (IOConsoleLocked), so no app can become "
            + "frontmost and synthetic events go to loginwindow. Unlock the machine, "
            + "or use AXPress (which needs no focus) for this step."
    }
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
    switch app.application.activationPolicy {
    case .accessory, .prohibited:
        return "'\(app.name)' runs as an .accessory app (KRAAL_DEV_BACKGROUND=1), which "
            + "cannot become frontmost by request; synthetic events would land in "
            + "\(front). Relaunch with KRAAL_DEV_BACKGROUND=0, or use AXPress instead."
    default:
        return "'\(app.name)' did not become frontmost (currently \(front)) within the "
            + "timeout, so a synthetic event would land in the wrong app."
    }
}

/// True when the login window owns the session.
func isScreenLocked() -> Bool {
    let front = NSWorkspace.shared.frontmostApplication
    if front?.bundleIdentifier == "com.apple.loginwindow" { return true }
    // The CGSession dictionary is readable without special privileges and is the
    // same signal the screen saver uses.
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool == true
}

/// Brings the app to the front and *waits until that actually happened*.
///
/// `activate()` returns nothing and frequently does not promote the process:
/// an `.accessory` app (what `KRAAL_DEV_BACKGROUND=1` produces) is not allowed to
/// become frontmost by asking, and even for a `.regular` app the call can be
/// silently refused while the window server still has another app active. The
/// earlier version trusted the call, then posted events — which all landed in
/// whatever was actually frontmost (Herdr), so the click "worked" and nothing in
/// the app ever moved. Verifying frontmost-ness is the only thing that makes the
/// next synthetic event meaningful.
@discardableResult
/// Brings the app to the front and waits for it to actually be frontmost.
///
/// Two attempts, because activation is asynchronous and has no completion callback: in a
/// full suite run the previous case's window is still being torn down, the first
/// `activate` is swallowed, and `sidebar-divider-drag` failed with "could not bring 'Kraal'
/// to the front" while passing when run on its own. A single retry costs 300 ms on a rare
/// path and removes a failure mode that has nothing to do with the case.
func activateAndConfirm(_ app: TargetApp, timeout: Double = 5, attempts: Int = 2) -> Bool {
    for attempt in 0 ..< max(attempts, 1) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid { return true }
        app.application.activate(options: [.activateAllWindows])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid { return true }
            usleep(100_000)
        }
        if attempt + 1 < attempts { usleep(300_000) }
    }
    return false
}

/// Opens an app menu and presses one of its items.
///
/// Two steps because they are two different things: `AXPress` on a menu *bar*
/// item is what opens its menu (AX树 does not expose the contents of a closed
/// menu), and only then does the item inside become addressable. `press
/// --title "Split Right"` worked by accident — "Split Right" lives in the View
/// menu, which macOS had already populated. Any item in a menu that has never
/// been opened is invisible to AX.
///
/// The scope argument is the menu bar item's title (e.g. `View`); without it a
/// title like `Copy` resolves to whichever of the two copies the DFS reaches
/// first.
func commandMenu(_ args: Arguments) -> Never {
    guard let menuName = args.string("menu") else {
        fail(.harness, "menu needs --menu <title> and --item <title>")
    }
    guard let itemName = args.string("item") else {
        fail(.harness, "menu needs --item <title>")
    }
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }

    var barItem = Selector(title: menuName, role: kAXMenuBarItemRole as String)
    barItem.within = ScopeBox(Selector(role: kAXMenuBarRole as String))
    guard let opener = app.find(barItem) else {
        let known = app.findAll(Selector(role: kAXMenuBarItemRole as String))
            .compactMap { $0.string(kAXTitleAttribute) }
        fail(.harness, "no menu bar item '\(menuName)'; available: \(known)")
    }
    guard opener.actionNames.contains(kAXPressAction) else {
        fail(.harness, "menu bar item '\(menuName)' cannot be pressed")
    }
    let openError = AXUIElementPerformAction(opener, kAXPressAction as CFString)
    if openError != .success {
        fail(.harness, "opening menu '\(menuName)' failed with AXError \(openError.rawValue)")
    }

    // The menu's contents appear asynchronously once tracking starts.
    var item: AXUIElement?
    let deadline = Date().addingTimeInterval(args.double("timeout") ?? 5)
    while Date() < deadline {
        var candidate = Selector(title: itemName, index: args.int("index") ?? 0)
        candidate.within = ScopeBox(Selector(title: menuName))
        if let found = app.find(candidate) { item = found; break }
        usleep(120_000)
    }
    guard let target = item else {
        // Leave no menu tracking behind on failure: a stuck open menu makes the
        // next command's synthetic events go nowhere.
        AXUIElementPerformAction(opener, kAXCancelAction as CFString)
        fail(.harness, "menu '\(menuName)' has no item '\(itemName)'")
    }
    guard target.actionNames.contains(kAXPressAction) else {
        fail(.harness, "item '\(itemName)' has no AXPress")
    }
    let pressError = AXUIElementPerformAction(target, kAXPressAction as CFString)
    if pressError != .success {
        fail(.harness, "pressing '\(itemName)' failed with AXError \(pressError.rawValue)")
    }
    print("menu \(menuName) -> \(itemName)")
    requireAlive(app, context: "menu \(menuName)/\(itemName)")
    exit(Exit.success.rawValue)
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    let usage = """
    usage: kraal-gui <command> [options]

      probe                          check AX + Screen Recording; exit 2 if not ready
      ax [--out FILE] [--depth N]    dump the accessibility tree
      press --title|--desc|--id|--value X
                                     AXPress an element (does NOT activate the app)
      wait  --title X [--timeout S]  poll until the element exists
      window                         print window frame + window number
      shot  -o FILE [--full]         screenshot one window
      type  --text S                 type text (AX first, CGEvent fallback)
      click --at X,Y | --at-screen X,Y [--right] [--clicks N] [--no-activate]
                                     synthetic click; --at is window-relative,
                                     --at-screen is absolute (AX frame space)
      drag  --from X,Y --to X,Y [--steps N]
                                     synthetic drag, both points window-relative
      scroll --at X,Y | --at-screen X,Y [--lines N]
                                     synthetic wheel at a point; the app decides
                                     which pane is under it, unlike pane.scroll
      key   --name N | --char C [--mod cmd,shift]
                                     key chord (needs the app frontmost);
                                     --name escape|return|tab|space|backspace|
                                     forwardDelete|up|down|left|right|home|end|
                                     pageUp|pageDown|f1..f12
      menu  --menu T --item T [--index N]
                                     open a menu bar menu, then press an item
      launch --app PATH [--env K=V] [--wait-window T] [--match NAME]
      quit                           terminate the app under test

    Coordinates: `kraal-gui window` and `ax --json` frames are screen coordinates;
    `--at`/`drag` offsets are relative to that window's top-left corner. A point
    outside the window is refused (exit 2) instead of being clamped to its edge.

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
case "pixels": commandPixels(args)
case "rowscan": commandRowScan(args)
case "type": commandType(args)
case "launch": commandLaunch(args)
case "quit": commandQuit(args)
case "click": commandClick(args)
case "scroll": commandScroll(args)
case "drag": commandDrag(args)
case "diff": commandDiff(args)
case "key": commandKey(args)
case "menu": commandMenu(args)
default:
    fail(.harness, "unknown command '\(command)'")
}
