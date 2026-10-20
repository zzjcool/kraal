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
        guard let connection, await connection.currentBootId != nil else { return }
        do {
            _ = try await connection.request(method, params: params)
        } catch {
            lastError = "\(method): \(error)"
        }
    }
}
