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

import Foundation

public final class KraalLog: @unchecked Sendable {
    public static let shared = KraalLog()

    private static let defaultsKey = "kraal.verboseLogging"

    private let lock = NSLock()
    private let url: URL
    private var enabled: Bool

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
        url = (logs ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Kraal.log")

        // UserDefaults wins when the user has toggled from the Debug menu;
        // otherwise honour KRAAL_LOG (anything other than "0" keeps logging on).
        if UserDefaults.standard.object(forKey: Self.defaultsKey) != nil {
            enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        } else {
            enabled = ProcessInfo.processInfo.environment["KRAAL_LOG"] != "0"
        }
    }

    /// Path of the session log file (`~/Library/Logs/Kraal.log`).
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

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

public func kraalLog(_ message: @autoclosure () -> String) {
    KraalLog.shared.write(message())
}
