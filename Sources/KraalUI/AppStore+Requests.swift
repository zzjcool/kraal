// SPDX-License-Identifier: Apache-2.0
//
//  AppStore+Requests.swift
//  Kraal
//
//  Endpoint requests issued by the store: fire-and-forget calls whose failures
//  surface in the UI rather than to a caller.
//

import Foundation

extension AppStore {
    /// Tells the daemon which surface this client wants streamed.
    ///
    /// Without it the daemon keeps pushing whichever surface it considers
    /// current, which is how a tab switch could leave the old tab's cells on
    /// screen. Only sent when the daemon advertises the method, since older
    /// versions drive surface projection purely from snapshots.
    func requestSurfaceInterest() {
        guard welcome?.methods.contains("client_shell.surface.set") == true else { return }
        // Collapse bursts: a tab switch produces a few snapshots in a row.
        surfaceInterestTask?.cancel()
        surfaceInterestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            await self.call("client_shell.surface.set", ["active": true])
        }
    }

    /// Issues an endpoint request, reporting failures through `lastError`.
    func call(_ method: String, _ params: [String: Any]) async {
        guard let connection else { return }
        do {
            _ = try await connection.request(method, params: params)
        } catch {
            lastError = "\(method): \(error)"
        }
    }
}
