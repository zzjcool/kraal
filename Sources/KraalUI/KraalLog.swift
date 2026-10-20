// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A tiny file logger for the app.
//
// A GUI app is hard to inspect from the outside, and several decisions here are
// only observable at runtime (negotiated surface size, which pane is focused,
// whether a patch was rejected). Writing those to `~/Library/Logs/Kraal.log`
// keeps the app debuggable without a debugger attached.

import Foundation

public final class KraalLog: @unchecked Sendable {
    public static let shared = KraalLog()

    private let lock = NSLock()
    private let url: URL
    private let enabled: Bool

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
        url = (logs ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Kraal.log")
        enabled = ProcessInfo.processInfo.environment["KRAAL_LOG"] != "0"
    }

    public func write(_ message: String) {
        guard enabled else { return }
        let line = "[\(Self.timestamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
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
