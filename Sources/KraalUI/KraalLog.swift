// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A tiny file logger for the app.
//
// A GUI app is hard to inspect from the outside, and several decisions here are
// only observable at runtime (negotiated surface size, which pane is focused,
// whether a patch was rejected). Writing those to `~/Library/Logs/Kraal.log`
// keeps the app debuggable without a debugger attached.
//
// Logging is on by default. `KRAAL_LOG=0` disables it at launch; the Debug menu
// can flip it again at runtime (persisted in UserDefaults) without relaunching.
//
// The file name carries the dev session (see `DevSession`): two copies of the app
// running at once write `Kraal.log` and `Kraal-<session>.log` instead of
// overwriting each other, which matters because `rotate()` deletes the file on
// every launch. The same file holds `DevSession`, the rule that decides what
// that name is.

import Foundation

public final class KraalLog: @unchecked Sendable {
    public static let shared = KraalLog()

    private static let defaultsKey = "kraal.verboseLogging"

    /// The dev session this process belongs to, also used to namespace the file.
    public let sessionName: String?

    private let lock = NSLock()
    private let url: URL
    private var enabled: Bool

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
        let name = DevSession.name
        sessionName = name
        url = (logs ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(DevSession.logFileName(name: name))

        // UserDefaults wins when the user has toggled from the Debug menu;
        // otherwise honour KRAAL_LOG (anything other than "0" keeps logging on).
        if UserDefaults.standard.object(forKey: Self.defaultsKey) != nil {
            enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        } else {
            enabled = ProcessInfo.processInfo.environment["KRAAL_LOG"] != "0"
        }
    }

    /// Path of the session log file (`~/Library/Logs/Kraal.log`, or
    /// `Kraal-<session>.log` for a namespaced dev session).
    public var fileURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    /// Whether `kraalLog` currently writes. Safe to read from the UI.
    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Turns file logging on or off and remembers the choice across launches.
    public func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
    }

    public func write(_ message: String) {
        lock.lock()
        let shouldWrite = enabled
        let destination = url
        lock.unlock()
        guard shouldWrite else { return }
        let line = "[\(Self.timestamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: destination) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: destination)
        }
    }

    /// Removes the previous run's log so a bug report is about one session.
    public func rotate() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// One formatter, not one per line.
    ///
    /// Measured (issue #56): building a `DateFormatter` and formatting a date cost
    /// 32.3 us, against 0.667 us for a shared formatter — 47x. `DateFormatter` is
    /// not thread-safe, so every read goes through `formatterLock`; `write` already
    /// held `lock`, but a second lock kept the two concerns from nesting badly and
    /// makes this callable from the tests directly.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let formatterLock = NSLock()

    static func timestamp() -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return formatter.string(from: Date())
    }

    /// The timestamp as the log would write it, for tests that pin its shape.
    static func timestampForTesting() -> String { timestamp() }
}

/// Logs a message, but only builds it when logging is on.
///
/// The `enabled` check used to live inside `write`, so `message()` had already run
/// by the time it was reached: `@autoclosure` defers evaluation to the function
/// body, not past it. Measured on the input path that was 0.955 us per keystroke
/// and 103.7 us for a 200-byte paste, spent purely to build strings that were then
/// discarded — while `KRAAL_LOG=0` (issue #56).
///
/// The parameter stays `@autoclosure` so existing call sites need no change; what
/// moves is the guard, in front of the evaluation instead of behind it.
public func kraalLog(_ message: @autoclosure () -> String) {
    guard KraalLog.shared.isEnabled else { return }
    KraalLog.shared.write(message())
}

/// Logs a message that costs something to build (a hex dump, a joined list).
///
/// Same as `kraalLog`, and explicit at the call site: a reader can see that this
/// expression is deferred, which is the property that keeps it off the input path.
public func kraalLogLazy(_ message: () -> String) {
    guard KraalLog.shared.isEnabled else { return }
    KraalLog.shared.write(message())
}

// MARK: - Dev session isolation

/// Namespaces the state a running copy of the app owns, so a development copy and
/// the user's own copy cannot collide.
///
/// Kraal rebuilds and relaunches dozens of times an hour during development, and
/// when somebody else — a second person or an agent — drives the same Mac, two
/// running copies collide in four places that have nothing to do with the daemon:
///
///   1. focus: `NSApp.activate(ignoringOtherApps:)` and `orderFrontRegardless()`
///      drag the window over whatever the other session is doing;
///   2. position: both restore the same `KraalWindowFrame` default, so the second
///      window lands exactly on the first;
///   3. log: both write `~/Library/Logs/Kraal.log`, and the second launch rotates
///      away the first one's evidence;
///   4. verification: an assertion that reads the log cannot tell the two apart.
///
/// The daemon side is already handled by `KRAAL_HERDR_SOCKET`. This extends the
/// same idea to the parts that live on the desktop: a session key derived from
/// the environment namespaces the defaults key and the log file, and a background
/// mode keeps a development window from taking focus.
///
/// Nobody should have to pass all of this by hand either, so `build-app.sh` bakes
/// the debug bundle's launcher to set `KRAAL_DEV_BACKGROUND` unless the caller
/// already decided.
public enum DevSession {
    /// Environment variable naming this instance of the app.
    ///
    /// Two sessions that set different values cannot see each other's saved
    /// frame or log file. Unset means "the machine's own session", which keeps
    /// the historical file names and the shared defaults key.
    public static let sessionKeyVariable = "KRAAL_DEV_SESSION"

    /// Environment variable asking the app not to take over the desktop.
    public static let backgroundVariable = "KRAAL_DEV_BACKGROUND"

    /// The session name, or `nil` for an unnamespaced (user-facing) launch.
    ///
    /// An explicit `KRAAL_DEV_SESSION` wins; otherwise the name is derived from
    /// `KRAAL_HERDR_SOCKET`, so a debug build that already points at a sandbox
    /// daemon is isolated without a second variable that could disagree with it.
    /// A launch with neither (the normal user case: this Mac's own herdr) gets
    /// `nil` and keeps the historical, unsuffixed names.
    ///
    /// Trimmed and length-limited: the value ends up in a file name, and a
    /// pasted-in sentence would otherwise produce a log nobody can find.
    public static var name: String? {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment[sessionKeyVariable] {
            return sanitized(raw)
        }
        return derivedName(forSocketPath: environment["KRAAL_HERDR_SOCKET"])
    }

    /// Whether this launch may take focus, raise its window and activate.
    ///
    /// Default is `false` — a user launch behaves exactly as before. Only an
    /// explicit `KRAAL_DEV_BACKGROUND=1` opts into staying out of the way.
    public static var runsInBackground: Bool {
        ProcessInfo.processInfo.environment[backgroundVariable] == "1"
    }

    /// The default session name for a given daemon socket path.
    ///
    /// Derived from the socket so a session is isolated the moment
    /// `KRAAL_HERDR_SOCKET` is set, without needing a second variable to agree
    /// with it — and so the exclusive-or is computed in one place instead of
    /// being spelled out again in a shell script that could drift.
    ///
    /// `nil` when there is no socket override: a release build talking to this
    /// Mac's own herdr keeps the historical names.
    public static func derivedName(forSocketPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        // djb2 over UTF-8: short, stable across launches, and no Foundation hash
        // seeding to make it differ per process (Swift's `hashValue` is seeded).
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return "dev-" + String(hash % 16_777_216, radix: 36)
    }

    /// Turns an arbitrary session name into something safe for a file name.
    ///
    /// Anything outside `[a-z0-9_-]` becomes `-`, repeated separators collapse,
    /// and the result is capped so a pasted path cannot overflow the file name
    /// limit. An empty or all-separator value is treated as unset.
    public static func sanitized(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasSeparator = false
        for character in lowered {
            let isAllowed = character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "-" || character == "_")
            if isAllowed {
                out.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append("-")
                lastWasSeparator = true
            }
            if out.count >= 32 { break }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// File name for this session's log.
    ///
    /// Kept next to the historical `Kraal.log` (not in a new directory) so the
    /// existing "look at the log" habit still works, while the two sessions'
    /// files sit side by side instead of overwriting each other.
    public static func logFileName(name: String?) -> String {
        guard let name else { return "Kraal.log" }
        return "Kraal-\(name).log"
    }

    /// Defaults key for this session's saved window frame.
    ///
    /// Namespaced so a development window can never be restored onto the frame a
    /// user left their own window at.
    public static func windowFrameDefaultsKey(name: String?) -> String {
        guard let name else { return "KraalWindowFrame" }
        return "KraalWindowFrame.\(name)"
    }

    /// Suffix shown in the window title so overlapping windows are tellable
    /// apart in a screenshot or a window switcher.
    public static func windowTitleSuffix(name: String?) -> String {
        guard let name else { return "" }
        return " — \(name)"
    }

    /// Title for the Dock/app menu. A background session says so, because a
    /// window that refuses to come forward otherwise looks broken.
    public static func title(name: String?, background: Bool) -> String {
        var title = "Kraal"
        if let suffix = windowTitleSuffix(name: name) as String?, !suffix.isEmpty {
            title += suffix
        }
        if background { title += " (background)" }
        return title
    }
}
