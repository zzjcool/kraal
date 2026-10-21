// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for per-session isolation.
//
// The bug this covers: two copies of the app (a user's and a second agent's)
// shared a saved window frame and one log file, and the second launch rotated
// away the first one's log. The presence of `activate(ignoringOtherApps:)` in
// the launch path is what made the collision visible — but the collision existed
// in the stored state regardless of who won the focus fight.
//
// What is pinned down here is the naming rule, because it is the thing that
// silently stops isolating anything if a key or a file name drifts: an
// unnamespaced launch must keep the historical names (so a release build does
// not orphan users' saved frames), and every distinct session must get distinct
// keys.

import Foundation
import Testing
@testable import KraalUI

@Suite("Dev session isolation")
struct DevSessionTests {
    /// A user launch has no session: the historical names are the contract for
    /// anyone upgrading, and renaming them would drop their saved window frame.
    @Test("an unnamespaced launch keeps the historical names")
    func unnamespacedKeepsHistoricalNames() {
        #expect(DevSession.logFileName(name: nil) == "Kraal.log")
        #expect(DevSession.windowFrameDefaultsKey(name: nil) == "KraalWindowFrame")
        #expect(DevSession.windowTitleSuffix(name: nil) == "")
        #expect(DevSession.title(name: nil, background: false) == "Kraal")
    }

    /// Two sessions must not share either piece of state.
    @Test("distinct sessions get distinct keys and files")
    func sessionsDoNotCollide() {
        let firstLog = DevSession.logFileName(name: "dev-a")
        let secondLog = DevSession.logFileName(name: "dev-b")
        #expect(firstLog != secondLog)
        #expect(firstLog == "Kraal-dev-a.log")
        #expect(DevSession.windowFrameDefaultsKey(name: "dev-a")
            != DevSession.windowFrameDefaultsKey(name: "dev-b"))
        #expect(DevSession.windowFrameDefaultsKey(name: "dev-a") == "KraalWindowFrame.dev-a")
    }

    /// A debug session is visually distinguishable from the user's window, and a
    /// background one says why it will not come forward.
    @Test("the title names the session and the background state")
    func titleDescribesSession() {
        #expect(DevSession.title(name: "dev-a", background: false) == "Kraal — dev-a")
        #expect(DevSession.title(name: "dev-a", background: true) == "Kraal — dev-a (background)")
        #expect(DevSession.title(name: nil, background: true) == "Kraal (background)")
    }

    /// The session name reaches a file name, so anything path-ish in it has to
    /// go. A pasted path is the realistic mistake: it would otherwise create a
    /// nested directory, or on a `"../"` land outside the log directory.
    @Test("session names are reduced to a safe token")
    func sessionNamesAreSanitised() {
        #expect(DevSession.sanitized("dev-a") == "dev-a")
        #expect(DevSession.sanitized("Dev A/B") == "dev-a-b")
        #expect(DevSession.sanitized("../../etc/passwd") == "etc-passwd")
        #expect(DevSession.sanitized("") == nil)
        #expect(DevSession.sanitized("...") == nil)
        #expect(DevSession.sanitized("///") == nil)
    }

    /// A long value must stay short enough to be a file name on any volume.
    @Test("session names are capped")
    func sessionNamesAreCapped() {
        let long = String(repeating: "a", count: 200)
        let sanitised = DevSession.sanitized(long)
        #expect(sanitised?.count == 32)
    }

    /// The derived name is what makes the isolation automatic: a build pointed at
    /// a sandbox daemon is isolated without a second variable to keep in sync.
    @Test("a session name is derived from the daemon socket")
    func nameIsDerivedFromSocket() {
        let sandbox = DevSession.derivedName(forSocketPath: "/tmp/kraal-mine/herdr-client.sock")
        let other = DevSession.derivedName(forSocketPath: "/tmp/kraal-other/herdr-client.sock")
        #expect(sandbox != nil)
        #expect(sandbox != other)
        // Stable across calls, or the saved frame would be orphaned every launch.
        #expect(sandbox == DevSession.derivedName(forSocketPath: "/tmp/kraal-mine/herdr-client.sock"))
        // Derived names obey the same file-name rules as explicit ones.
        #expect(sandbox == DevSession.sanitized(sandbox ?? ""))
    }

    /// No socket override means the machine's own herdr, which is the user's
    /// own session — not a namespaced dev one.
    @Test("no socket override yields no derived session")
    func noSocketMeansNoSession() {
        #expect(DevSession.derivedName(forSocketPath: nil) == nil)
        #expect(DevSession.derivedName(forSocketPath: "") == nil)
    }
}
