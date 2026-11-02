// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Credit policy for one attached pane.
//
// The core sends at most the credit it was given (256 KiB to start). Returning
// that credit the moment bytes arrive would defeat it: `InMemoryTerminalSession.receive`
// never blocks, so a fast producer would grow the parser's queue without limit.
// Instead credit waits for two things:
//
//  * a surface — before one attaches, Ghostty buffers at most 1 MiB, which is
//    more than the core's initial window, so withholding credit loses nothing;
//  * the parser draining below its low-water mark — the pane's own backlog is
//    then under 128 KiB, which is small enough to acknowledge everything.

import Foundation
import KraalHC

public final class HcCreditGate: @unchecked Sendable {
    /// The backlog at which crediting pauses, and the point where it resumes.
    public static let defaultHighWater = 512 * 1024
    public static let defaultLowWater = 128 * 1024

    private let lock = NSLock()
    private weak var stream: (any HcByteStream)?
    private var pending = 0
    private var started = false
    private var backlogged = false

    public init() {}

    /// Bytes received from the core and not yet acknowledged.
    public var outstanding: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    public var hasSurface: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    public func connect(_ stream: any HcByteStream) {
        lock.lock()
        self.stream = stream
        lock.unlock()
        flush()
    }

    /// Data arrived from the core; acknowledge it as soon as the pane can take it.
    public func received(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        pending += bytes
        lock.unlock()
        flush()
    }

    /// The engine has a grid: credit that was held while no surface existed.
    public func surfaceReady() {
        lock.lock()
        started = true
        lock.unlock()
        flush()
    }

    /// Called by the session's backlog observer.
    public func setBacklogged(_ value: Bool) {
        lock.lock()
        backlogged = value
        lock.unlock()
        flush()
    }

    private func flush() {
        lock.lock()
        guard started, !backlogged, pending > 0, let stream else {
            lock.unlock()
            return
        }
        let bytes = pending
        pending = 0
        lock.unlock()
        stream.credit(bytes)
    }
}
