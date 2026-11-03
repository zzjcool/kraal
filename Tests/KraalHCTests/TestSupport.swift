// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Test scaffolding: isolated directories, a fake core, and a timeout that does
// not wait for the operation it abandons.

import Foundation

@testable import KraalHC

struct TestTimeout: Error {}

/// Opens a connection off Swift's cooperative pool.
///
/// `HcConnection.open` blocks on the handshake. Called directly from a test, and
/// with dozens of tests in flight, it blocked the pool's threads and the tests'
/// own `Task.sleep` deadlines stopped firing — the callbacks had arrived; the
/// test could not run to see them.
func openTestConnection(path: String) async throws -> HcConnection {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            do {
                continuation.resume(returning: try HcConnection.open(path: path))
            } catch {
                continuation.resume(throwing: error)
            }
        }
        thread.name = "kraal.test.connect"
        thread.stackSize = 512 * 1024
        thread.start()
    }
}

/// Opens a connection over an injected link, off the cooperative pool.
func openTestConnection(link: any HcByteLink) async throws -> HcConnection {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            do {
                continuation.resume(returning: try HcConnection.open(link: link))
            } catch {
                continuation.resume(throwing: error)
            }
        }
        thread.name = "kraal.test.link"
        thread.stackSize = 512 * 1024
        thread.start()
    }
}

func withTempDirectory(_ body: (String) async throws -> Void) async throws {
    // /tmp keeps the unix socket path inside sun_path's 103-byte budget; the
    // per-user temporary directory on macOS is already ~50 bytes.
    let path = "/tmp/kraalhc-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await body(path)
}

func withFakeCore(
    hello: JSONValue? = nil,
    _ body: (FakeCore) async throws -> Void
) async throws {
    try await withTempDirectory { directory in
        let core = try FakeCore(directory: directory, hello: hello)
        core.start()
        defer { core.stop() }
        try await body(core)
    }
}

/// Races `operation` against a deadline. The loser keeps running in the
/// background; tests are short-lived and this keeps a broken stream from
/// hanging the suite.
func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let lock = NSLock()
        var resumed = false
        func finish(_ result: Result<T, Error>) {
            lock.lock()
            if resumed {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()
            continuation.resume(with: result)
        }

        Task {
            do {
                finish(.success(try await operation()))
            } catch {
                finish(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            finish(.failure(TestTimeout()))
        }
    }
}

enum ProbeEvent: Sendable, Equatable {
    case data(Data)
    case resize(UInt16, UInt16)
    case closed(JSONValue?)
}

/// Collects channel callbacks into an async stream, in delivery order.
final class ChannelProbe: @unchecked Sendable {
    let events: AsyncStream<ProbeEvent>
    private let continuation: AsyncStream<ProbeEvent>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<ProbeEvent>.makeStream()
        events = stream
        self.continuation = continuation
    }

    func handlers() -> HcStreamHandlers {
        HcStreamHandlers(
            onData: { [continuation] data in continuation.yield(.data(data)) },
            onResize: { [continuation] cols, rows in continuation.yield(.resize(cols, rows)) },
            onClose: { [continuation] reason in
                continuation.yield(.closed(reason))
                continuation.finish()
            }
        )
    }

    func next(_ seconds: Double = 2) async throws -> ProbeEvent? {
        try await withTimeout(seconds) { [events] in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
    }
}

func resizePayload(cols: UInt16, rows: UInt16) -> Data {
    var data = Data()
    data.append(UInt8(cols & 0xFF))
    data.append(UInt8(cols >> 8))
    data.append(UInt8(rows & 0xFF))
    data.append(UInt8(rows >> 8))
    return data
}
