// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The handshake watchdog: the bound above the connection's own bounds.
//
// Kept in its own file for two reasons. `AppStore+Endpoints.swift` is already at
// swiftlint's file-length limit, and — more to the point — this is the one piece
// of the endpoint lifecycle that does *not* belong to the endpoint: it exists so
// that a machine whose connection never answers can still be recovered, even when
// the layer below stops bounding itself. Issue #67.
//
// The mechanics, and why they are not the obvious ones, are documented at
// `startHandshake`. The short version: `await connection.stop()` cannot interrupt
// a `start()` parked in a blocking read (it is actor-isolated, so it queues
// behind it), while closing the stream from outside the actor can — which is what
// `EndpointConnection.abort()` is for.

import Foundation
import KraalClient
import KraalTransport

extension AppStore {
    /// Runs one machine's handshake under the UI's own deadline (issue #67).
    ///
    /// `EndpointConnection.start()` has its own bounds (#66) and this deliberately
    /// does not trust them. The point of a watchdog is the case where the layer
    /// below fails to bound something — a new unbounded read, a blocking step
    /// added to `StreamFactory.open` — and then the machine would sit on
    /// `connecting` forever with `connectionTask` set, which is exactly the state
    /// that made `connectMissingEndpoints` skip it *and* `connect()` return early.
    /// Two layers of bound is not paranoia here: #66 was the outer one, and its fix
    /// landed inside the connection.
    ///
    /// Shape: `start()` and a plain timer race, and the timer is a **task**, not a
    /// flag checked after a sleep — a flag is wrong the moment `start()` finishes
    /// first and the check runs anyway.
    ///
    /// What the watchdog does on expiry is `abort()`, not `stop()`. `stop()` is
    /// actor-isolated, so while `start()` is parked in a blocking read it queues
    /// *behind* the call it is meant to interrupt — measured, with
    /// `handshakeTimeout: 20`:
    ///
    ///     [ 0.32s] calling stop()
    ///     [20.00s] outcome: ["timeout-3s", "beats done"]   <- stop() only ran once start() gave up on its own
    ///
    /// `abort()` closes the stream from outside the actor instead, which a parked
    /// `read(2)` does notice (measured: `-1 errno=9`, EBADF, immediately after
    /// `shutdown`+`close` on the same fd from another thread). `start()` then
    /// throws at once, and the caller's ordinary `catch` runs the ordinary
    /// cleanup — `connectionTask = nil`, `.attention`, `scheduleEndpointRetry` —
    /// rather than a second state machine existing for "timed out".
    func startHandshake(_ connection: EndpointConnection) async throws {
        let watchdog = handshakeWatchdog
        let outcome = await withTaskGroup(of: HandshakeRace.self) { group in
            group.addTask {
                // The error is carried in a box rather than thrown: this group is
                // deliberately non-throwing. A throwing group rethrows the first
                // child error even when the *other* child was the winner, and
                // cancelling the timer turns `Task.sleep` into a `CancellationError`
                // that would then be reported as a failed handshake that had
                // actually succeeded.
                let box = ErrorBox()
                do {
                    try await connection.start()
                } catch {
                    box.error = error
                }
                return box.error == nil ? .handshakeFinished : .handshakeFailed(box)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(watchdog * 1_000_000_000))
                } catch {
                    return .watchdogCancelled
                }
                return .watchdogExpired
            }
            let first = await group.next() ?? .watchdogCancelled
            group.cancelAll()
            // Close the stream *before* the scope is left, because leaving it
            // waits for every child: the handshake child is parked in a blocking
            // `read(2)` that a cancellation flag does not reach. Without this the
            // deadline would do nothing and the catch below would not run until
            // the deadline underneath — which is the bug. Also reached on ordinary
            // failures, where `abort()` is a no-op.
            if case .watchdogExpired = first {
                connection.abort()
            }
            return first
        }

        switch outcome {
        case .handshakeFinished:
            return
        case let .handshakeFailed(box):
            throw box.error ?? BridgeError.transport("handshake failed")
        case .watchdogExpired:
            throw BridgeError.handshakeWatchdogExpired(seconds: watchdog)
        case .watchdogCancelled:
            // Neither child reported: the surrounding task was cancelled before
            // the handshake settled. The caller's epoch check decides what to do.
            throw CancellationError()
        }
    }

    /// Which of the two racers reported first.
    enum HandshakeRace: Sendable {
        case handshakeFinished
        case handshakeFailed(ErrorBox)
        case watchdogExpired
        case watchdogCancelled
    }

    /// Carries a thrown error out of a non-throwing task group.
    ///
    /// The box is written exactly once, before the group element is returned, so
    /// the `@unchecked` is about the compiler not being able to see that hand-off
    /// rather than about any real sharing.
    final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }
}
