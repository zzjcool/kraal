// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// State for "the baseline diverged, ask the daemon for a whole new surface".
//
// Split out of `AppStore.swift`, which is at swiftlint's 400-line body limit: the
// latch is one concern with three properties, and keeping them together beats
// scattering a few lines into the main class file to stay under a line budget.
//
// Why a latch at all (issue #50): a rejected patch means the client's baseline no
// longer matches the daemon's, and the only recovery is re-projecting the tab
// (`client_shell.surface.set` off and on, or a fresh handshake). Doing that once
// per rejected patch is a storm — a diverged baseline rejects *every* patch, up to
// 60/s, and each request is two commands on a connection that serves one per tick
// (see `call`). So: ask once, and do not ask again until something settles it.

public extension AppStore {
    /// Set when a resync has been requested and not yet paid off by a fresh
    /// surface.
    ///
    /// Replaces an earlier `resyncInFlight` flag, which cleared when the *request*
    /// completed — before the fresh surface lands — so a diverged baseline
    /// (every patch rejected) re-armed it immediately.
    ///
    /// Two release kinds, documented at their call sites in `AppStore+Events.swift`:
    /// `clearResyncLatch()` when the question is settled, and the weaker-evidence
    /// `releaseResyncLatch(_:)`, which is bounded because a resync in flight makes
    /// *every* dropped frame look like a moved projection. Kept apart from
    /// `resyncPending`, which covers a stale *surface* rather than a rejected patch.
    var surfaceResyncLatched: Bool {
        get { surfaceResyncState.latched }
        set { surfaceResyncState.latched = newValue }
    }

    /// Weaker-evidence releases used within one settled baseline.
    ///
    /// Bounding this is what stops the release points from mirroring the old bug:
    /// unbounded, a stuck latch becomes one resync per frame. Two lets the answer
    /// arrive late; churn cannot amplify it into a flood. Reset by
    /// `clearResyncLatch()`, never by `releaseResyncLatch`.
    var surfaceResyncLatchReleases: Int {
        get { surfaceResyncState.releases }
        set { surfaceResyncState.releases = newValue }
    }

    /// How many times a rejected patch has asked for a fresh surface.
    ///
    /// Diagnostic state, and the only *synchronous* evidence that the recovery path
    /// ran: the request itself is asynchronous (one command per connection tick),
    /// so a test cannot assert on the wire without a daemon. Incremented where the
    /// decision is made, which is also where a real failure would be invisible.
    var surfaceResyncRequests: Int {
        get { surfaceResyncState.requests }
        set { surfaceResyncState.requests = newValue }
    }

    /// How many weaker-evidence releases one latch allows. See
    /// ``surfaceResyncLatchReleases``.
    static let resyncLatchReleaseLimit = 2
}

/// The three numbers behind ``AppStore/surfaceResyncLatched``, in one stored
/// property so the `@Observable` class does not grow a stored property per field.
///
/// Not observed: nothing in the UI reads these. They gate a request, and a test
/// reads them synchronously.
struct SurfaceResyncState {
    var latched = false
    var releases = 0
    var requests = 0
}
