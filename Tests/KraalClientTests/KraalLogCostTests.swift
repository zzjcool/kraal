// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #56: logging cost paid while logging is off.
//
// `kraalLog(_ message: @autoclosure () -> String)` looks lazy, but `@autoclosure`
// only defers evaluation to the function body — `KraalLog.write(message())` called
// it before the `enabled` check inside `write` ran. So every call built its string
// and threw it away. Measured on the input path: 0.955 us per keystroke for the
// message alone, and 103.7 us for a 200-byte paste, all while `KRAAL_LOG=0`.
//
// Two more costs in the same file: `timestamp()` built a `DateFormatter` per line
// (31.4 us against 0.67 us for a shared one), and the input callback built a hex
// dump unconditionally.
//
// The assertion here is a counter, not a clock: correctness is "was the closure
// called", which is exactly what the bug was. A timing assertion would pass or
// fail depending on the machine.

import Foundation
import Testing

@testable import KraalUI

/// Counts evaluations of a log message from wherever the closure runs.
///
/// A class with a lock rather than a captured `var`: an autoclosure that escapes
/// (or a test that later runs concurrently) must not become a data race in the
/// thing that is supposed to detect waste.
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var evaluations: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// Serialized: the two evaluation tests flip the process-wide `KraalLog.shared`
// singleton, so running them concurrently lets one test's `setEnabled(false)` land
// inside the other's measurement — observed as "enabled log built 0 messages".
@Suite("Logging cost when disabled", .serialized)
struct KraalLogCostTests {
    @Test("a disabled log never builds its message")
    func disabledLogDoesNotEvaluate() {
        let previous = KraalLog.shared.isEnabled
        KraalLog.shared.setEnabled(false)
        defer { KraalLog.shared.setEnabled(previous) }
        let counter = EvaluationCounter()
        kraalLog("expensive message \(counter.next())")
        #expect(counter.evaluations == 0,
                "the message was built \(counter.evaluations) time(s) while logging was off")
    }

    @Test("an enabled log still builds and writes its message")
    func enabledLogEvaluates() {
        // The complement, so "never evaluate" cannot be achieved by never logging:
        // a disabled-log fix that also disabled the enabled path would pass the
        // test above and lose every diagnostic.
        let previous = KraalLog.shared.isEnabled
        KraalLog.shared.setEnabled(true)
        defer { KraalLog.shared.setEnabled(previous) }
        let counter = EvaluationCounter()
        kraalLog("expensive message \(counter.next())")
        #expect(counter.evaluations == 1,
                "an enabled log must build its message exactly once, built \(counter.evaluations)")
    }

    @Test("timestamps keep their shape across many calls")
    func timestampsAreStable() {
        // `timestamp()` now shares one `DateFormatter`. Pinning the output shape
        // means a shared formatter that started emitting garbage would be visible.
        for stamp in [KraalLog.timestampForTesting(), KraalLog.timestampForTesting()] {
            // HH:mm:ss.SSS — 12 characters, two colons, three-digit fraction.
            #expect(stamp.count == 12, "unexpected timestamp shape: \(stamp)")
            #expect(stamp.filter { $0 == ":" }.count == 2, "unexpected timestamp: \(stamp)")
            let fraction = String(stamp.dropFirst(9))
            #expect(fraction.count == 3 && fraction.allSatisfy { $0.isNumber },
                    "no milliseconds: \(stamp)")
        }
    }

    @Test("concurrent writers get well-formed timestamps")
    func concurrentTimestampsAreWellFormed() async {
        // A `DateFormatter` is not thread-safe, and the fix shares one. Concurrent
        // stamping is the cheap version of the failure that matters: a torn string
        // in the log is worse than a slow one.
        let stamps = await withTaskGroup(of: String.self) { group in
            for _ in 0 ..< 20 {
                group.addTask { KraalLog.timestampForTesting() }
            }
            var collected: [String] = []
            for await stamp in group { collected.append(stamp) }
            return collected
        }
        #expect(stamps.count == 20)
        for stamp in stamps {
            #expect(stamp.count == 12, "torn timestamp under concurrency: \(stamp)")
        }
    }
}
