// SPDX-License-Identifier: Apache-2.0
//
//  AppStore+Requests.swift
//  Kraal
//
//  Endpoint requests issued by the store: fire-and-forget calls whose failures
//  surface in the UI rather than to a caller.
//

import Foundation
import KraalClient

extension AppStore {
    /// Whether the daemon lets this client say which surface it wants.
    ///
    /// Older daemons (0.9.1, for instance) have no such method: they project
    /// whichever tab was focused when the connection opened and never change it.
    /// Upstream treats that as a hard requirement and refuses the connection;
    /// this client instead reconnects on a tab switch, which gets the same result
    /// with one extra handshake.
    var supportsSurfaceInterest: Bool {
        // The method is the contract; the capability list is advisory. Upstream
        // also requires `surface_interest` + `presentation_effects_fence`, but a
        // 0.9.1 daemon advertises `surface_interest` and serves this method while
        // omitting the fence capability, so requiring both would refuse a
        // connection that works.
        welcome?.methods.contains("client_shell.surface.set") == true
    }

    /// Tells the daemon which surface this client wants streamed.
    ///
    /// Without it the daemon keeps pushing whichever surface it considers
    /// current, which is how a tab switch could leave the old tab's cells on
    /// screen.
    func requestSurfaceInterest() {
        guard supportsSurfaceInterest else { return }
        // Collapse bursts: a tab switch produces a few snapshots in a row.
        surfaceInterestTask?.cancel()
        surfaceInterestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            await self.call("client_shell.surface.set", ["active": true])
        }
    }

    /// Asks the daemon to re-project whatever it now considers focused.
    ///
    /// Toggling `active` off and on is the only lever a 0.9.1 daemon offers: it
    /// re-evaluates the focused tab on activation, returning the
    /// `projection_revision` it settled on. This is what makes a tab switch
    /// visible on daemons that never send a fresh snapshot on their own.
    func reprojectSurface() async {
        guard supportsSurfaceInterest, !reprojectInFlight else { return }
        reprojectInFlight = true
        defer { reprojectInFlight = false }
        await call("client_shell.surface.set", ["active": false])
        await call("client_shell.surface.set", ["active": true])
    }

    /// Issues an endpoint request, reporting failures through `lastError`.
    ///
    /// A request issued before the snapshot lands has no boot id to address the
    /// daemon with, and the connection rejects it. That is not a failure — it is
    /// the handshake still opening — so it is skipped rather than surfaced.
    /// Reporting it left `lastError` stuck on `no snapshot yet: boot id unknown`
    /// after switching machines, which the UI showed as a permanent error even
    /// though the connection was live and correct.
    func call(_ method: String, _ params: [String: Any]) async {
        guard let connection, await connection.currentBootId != nil else {
            // Silent by design when the handshake is still opening, but a pane
            // command that reaches here is a dropped user action. Logging it is
            // the difference between "the menu did nothing" and knowing why.
            kraalLog("call: skipped \(method) (no boot id yet)")
            return
        }
        // One connection, one command at a time. Two calls issued in the same
        // tick — focus followed by the action that focus was for — race, and the
        // loser is refused with `endpoint_busy`. Retrying is correct and cheap:
        // the refusal means nothing happened, so it is safe to send again.
        for attempt in 0..<Self.busyRetryLimit {
            do {
                let response = try await connection.request(method, params: params)
                kraalLog("call: ok \(method) \(Self.describe(params))"
                    + (attempt > 0 ? " (retry \(attempt))" : ""))
                _ = response
                return
            } catch where EndpointConnection.isBusyRefusal(error) {
                if attempt == Self.busyRetryLimit - 1 {
                    lastError = "\(method): the daemon stayed busy"
                    kraalLog("call: BUSY \(method) \(Self.describe(params)) — gave up")
                    return
                }
                // Short and increasing: the holder is a command the user just
                // triggered, so it completes in milliseconds.
                try? await Task.sleep(for: .milliseconds(20 * (attempt + 1)))
            } catch {
                lastError = "\(method): \(error)"
                kraalLog("call: FAILED \(method) \(Self.describe(params)): \(error)")
                return
            }
        }
    }

    /// How many times a refused-for-busy command is resent.
    private static let busyRetryLimit = 4

    /// Issues a request and hands back the daemon's error code, if it refused.
    ///
    /// `call` collapses every failure into `lastError` (a String), which is enough
    /// for a banner but not for a caller that has to *act* on a specific code.
    /// Closing is the first such caller: `workspace_group_close_required` means
    /// "ask the user whether the whole group should go", not "something broke".
    ///
    /// Returns nil on success — including the case where the handshake has not
    /// opened yet, which is not a failure the user can do anything about.
    func callReturningErrorCode(
        _ method: String,
        _ params: [String: Any]
    ) async -> String? {
        guard let connection, await connection.currentBootId != nil else {
            kraalLog("call: skipped \(method) (no boot id yet)")
            return nil
        }
        for attempt in 0..<Self.busyRetryLimit {
            do {
                _ = try await connection.request(method, params: params)
                kraalLog("call: ok \(method) \(Self.describe(params))"
                    + (attempt > 0 ? " (retry \(attempt))" : ""))
                return nil
            } catch let BridgeError.daemon(_, code, _) where code == "endpoint_busy" {
                if attempt == Self.busyRetryLimit - 1 {
                    kraalLog("call: BUSY \(method) \(Self.describe(params)) — gave up")
                    return "endpoint_busy"
                }
                try? await Task.sleep(for: .milliseconds(20 * (attempt + 1)))
            } catch let BridgeError.daemon(_, code, _) {
                kraalLog("call: REFUSED \(method) \(Self.describe(params)): \(code)")
                return code
            } catch {
                lastError = "\(method): \(error)"
                kraalLog("call: FAILED \(method) \(Self.describe(params)): \(error)")
                return nil
            }
        }
        return nil
    }

    /// Renders request params for the log without dumping every value: pane and
    /// tab ids are what matter when a command lands somewhere unexpected.
    nonisolated static func describe(_ params: [String: Any]) -> String {
        params.keys.sorted()
            .map { "\($0)=\(params[$0] ?? "nil")" }
            .joined(separator: " ")
    }
}
