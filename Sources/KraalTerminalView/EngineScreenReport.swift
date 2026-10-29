// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation

/// The terminal engine's own statement of how big its screen is.
///
/// Every other size this app has is a *prediction* of that screen. `ghostty_surface_size`
/// (and so `surfaceSize`) changes synchronously inside `setSize`; a grid derived from the
/// view's bounds changes even earlier. The screen the parser actually writes into changes
/// later: Ghostty's IO thread applies a resize behind a 25 ms coalescing timer
/// (`termio/Thread.zig`, `Coalesce.min_ms`). Measured with a real engine, a 38-row frame
/// was written eight milliseconds *before* the engine announced 38 rows.
///
/// A frame written in that window is parsed against the old screen. Rows past its end are
/// clamped onto its last row. When the screen then resizes, the engine rearranges what is
/// already on it — on a grow it pulls scrollback back down — and a renderer whose baseline
/// says "those rows are drawn" writes nothing to repair it. The result is the band: the
/// bottom of the pane that grew, empty, wider the faster the divider moved.
///
/// Mode 2048 (in-band size reports) is the one signal emitted **after** the screen has
/// been resized, inside the lock bytes are parsed under (`Termio.resize`: after
/// `terminal.resize`, before the lock is released). So a report is ordered after the
/// resize for everything written once it has been seen — which the `resize:` callback of
/// `InMemoryTerminalSession` is not: that one fires *before* `terminal.resize`.
struct EngineScreenReport: Equatable, Sendable {
    var columns: Int
    var rows: Int
    var widthPixels: Int
    var heightPixels: Int

    /// `CSI ? 2048 h`. The engine answers at once, and again after every resize.
    static let enableSequence = Data("\u{1B}[?2048h".utf8)

    /// `ESC [ 4 8 ;` — what every report starts with.
    private static let prefix: [UInt8] = [0x1B, 0x5B, 0x34, 0x38, 0x3B]
    private static let prefixData = Data(prefix)
    private static let terminator: UInt8 = 0x74 // t
    private static let separator: UInt8 = 0x3B // ;
    private static let fieldCount = 4
    /// A field larger than this is not a screen size; refusing it keeps a hostile or
    /// corrupt stream from overflowing the accumulator.
    private static let fieldLimit = 1_000_000

    /// Whether both reports describe the same cell grid, ignoring pixel-only changes.
    func sameGrid(as other: EngineScreenReport) -> Bool {
        columns == other.columns && rows == other.rows
    }

    /// Splits engine-to-host bytes into size reports and everything else.
    ///
    /// The engine's write callback carries keystrokes, mouse reports, pastes and query
    /// replies too, so the reports have to be taken out before the rest is forwarded: a
    /// report reaching the daemon would be typed into the user's shell.
    ///
    /// A chunk is a report only if **all** of it is: the engine writes each report as one
    /// callback of its own (`HostManaged.queueWrite` passes a buffer straight through, and
    /// the session hands it on unchanged). That is deliberately stricter than scanning for
    /// the pattern — a paste that happens to contain `ESC [ 48 ; …` is the user's data and
    /// must arrive intact.
    ///
    /// Runs on every callback, i.e. once per keystroke and per mouse event, so the common
    /// case — no report in the bytes — returns the input untouched and allocates nothing.
    static func extract(from data: Data) -> (reports: [EngineScreenReport], rest: Data) {
        guard data.starts(with: prefixData) else { return ([], data) }
        let bytes = [UInt8](data)
        var reports: [EngineScreenReport] = []
        var index = 0
        while index < bytes.count {
            guard let parsed = parse(bytes, at: index) else { return ([], data) }
            reports.append(parsed.report)
            index = parsed.end
        }
        return (reports, Data())
    }

    /// `ESC [ 48 ; rows ; columns ; heightPx ; widthPx t`, per `terminal/size_report.zig`.
    private static func parse(
        _ bytes: [UInt8], at start: Int
    ) -> (report: EngineScreenReport, end: Int)? {
        let bodyStart = start + prefix.count
        guard bodyStart < bytes.count, bytes[start ..< bodyStart].elementsEqual(prefix) else {
            return nil
        }
        var fields: [Int] = []
        var current = 0
        var digits = 0
        var index = bodyStart
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x30 ... 0x39:
                current = current * 10 + Int(byte - 0x30)
                digits += 1
                if current > fieldLimit { return nil }
            case separator, terminator:
                guard digits > 0 else { return nil }
                fields.append(current)
                current = 0
                digits = 0
                guard byte == terminator else { continue }
                guard fields.count == fieldCount else { return nil }
                return (
                    EngineScreenReport(
                        columns: fields[1], rows: fields[0],
                        widthPixels: fields[3], heightPixels: fields[2]
                    ),
                    index
                )
            default:
                return nil
            }
        }
        return nil
    }
}

/// Carries the engine's reports from its IO thread to the main actor, in order.
///
/// The write callback runs on the engine's thread **while it holds the lock the screen is
/// parsed under**. Anything done there must not call back into the engine — reading the
/// viewport takes that same lock — so the only thing this does is queue the report and ask
/// the main queue to deliver it.
///
/// Reports are delivered as a batch and **not collapsed to the latest**. A screen that went
/// 34 -> 38 -> 34 rows between two deliveries ends where it started, yet a frame written
/// while it was 38 rows tall was parsed against that screen and may have been rearranged by
/// the way back. Collapsing the pair to "34, unchanged" is exactly how that is missed.
final class EngineReportRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [EngineScreenReport] = []
    private var drainScheduled = false
    private var sink: (@MainActor ([EngineScreenReport]) -> Void)?

    /// Where batches go. Set once, on the main actor, after the owner is fully built.
    @MainActor
    func connect(_ sink: @escaping @MainActor ([EngineScreenReport]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    /// Called from the engine's thread.
    func deliver(_ report: EngineScreenReport) {
        lock.lock()
        pending.append(report)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { drain() }
        }
    }

    @MainActor
    private func drain() {
        lock.lock()
        let batch = pending
        pending = []
        drainScheduled = false
        let target = sink
        lock.unlock()
        guard !batch.isEmpty else { return }
        target?(batch)
    }
}
