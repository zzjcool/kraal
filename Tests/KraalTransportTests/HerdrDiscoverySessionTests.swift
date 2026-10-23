// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #70: `--session` typos were accepted over SSH.
//
// The local branch already rejected a name that could escape the session root.
// The `.ssh` branch passed `settings.session` through untouched, so a typo did
// not fail — upstream `herdr --session <name>` *creates* a session that does not
// exist. The user therefore connected to a brand-new empty daemon and saw an
// empty workspace, which is indistinguishable from having picked the wrong
// machine. Measured before the fix:
//
//     $ kraal --ssh admin@127.0.0.1 --session '../escape' probe
//     connect failed: the connection closed before the handshake finished
//
// The `kraal` CLI had the same hole for a second reason: it built `.sshShell`
// itself instead of asking `HerdrDiscovery`, so the rule lived in one caller and
// not in the other. Both now resolve through `HerdrDiscovery.resolve`.
//
// These tests never touch the network, a daemon, or `~/.config/herdr`.

import Foundation
import Testing

import KraalTransport

@Suite("Session name validation over SSH")
struct HerdrDiscoverySessionTests {
    /// Builds SSH settings with `session` set verbatim — including the empty
    /// string, which is what an untouched form field produces.
    private func sshSettings(session: String) -> ConnectionSettings {
        ConnectionSettings(
            name: "box",
            transport: .ssh,
            session: session,
            sshHost: "127.0.0.1",
            sshUser: "admin",
            sshPort: 2222
        )
    }

    // MARK: - Rejected names

    /// Every shape upstream's `validate_name` rejects, driven through `resolve`.
    ///
    /// `../escape` is the one from the issue's measured transcript; the rest are
    /// the neighbouring cases (path separator, empty, non-ASCII, the 64-byte
    /// boundary, and the two directory-relative names).
    @Test(
        "an invalid session name is refused before any remote is dialled",
        arguments: [
            "../escape",           // the measured repro: escapes the sessions/ root
            "a/b",                 // path separator
            "名字",                 // non-ASCII
            "work session",        // space
            ".",                   // directory-relative
            "..",                  // directory-relative
            String(repeating: "a", count: 65),  // one past the limit
        ]
    )
    func invalidSessionIsRefused(session: String) throws {
        let settings = sshSettings(session: session)
        #expect(
            !HerdrDiscovery.isValidSessionName(session),
            "the test's premise is wrong: \(session.debugDescription) is considered valid"
        )
        // Pattern-matched rather than `#expect(throws:)`: `DiscoveryError` is not
        // `Equatable` (and making it so for a test's convenience would change a
        // public type for no product reason).
        do {
            let target = try HerdrDiscovery.resolve(settings)
            Issue.record("invalid session \(session.debugDescription) resolved to \(target)")
        } catch let error as DiscoveryError {
            guard case let .invalidSessionName(name) = error else {
                Issue.record("expected .invalidSessionName, got \(error)")
                return
            }
            #expect(name == session, "the error must carry the rejected name")
        } catch {
            Issue.record("expected DiscoveryError, got \(error)")
        }
    }

    /// The error carries the offending name, so a user can see which field is
    /// wrong instead of reading a generic failure.
    @Test("the error names the rejected session")
    func errorNamesTheSession() {
        let error = DiscoveryError.invalidSessionName("../escape")
        #expect("\(error)".contains("../escape"))
        #expect("\(error)".contains("not a valid session name"))
    }

    // MARK: - Accepted names

    /// A valid name still resolves to `.sshShell` with the session preserved.
    /// If this broke, the fix would have traded a silent wrong connection for a
    /// loud correct one and `--session` would stop working entirely.
    @Test(
        "a valid session name resolves to .sshShell with the session kept",
        arguments: ["work", "team_1.2-beta", "a", String(repeating: "a", count: 64)]
    )
    func validSessionResolves(session: String) throws {
        let target = try HerdrDiscovery.resolve(sshSettings(session: session))
        #expect(
            target == .sshShell(user: "admin", host: "127.0.0.1", port: 2222, session: session)
        )
    }

    /// An empty session field still means `default`. This is the path the guard
    /// could plausibly have broken: validating before defaulting would reject the
    /// empty string, and every saved machine that never named a session would
    /// fail to connect.
    @Test("an empty session is still defaulted, not rejected")
    func emptySessionBecomesDefault() throws {
        let target = try HerdrDiscovery.resolve(sshSettings(session: ""))
        #expect(
            target == .sshShell(
                user: "admin",
                host: "127.0.0.1",
                port: 2222,
                session: HerdrDiscovery.defaultSession
            )
        )
    }

    /// `default` is itself a valid name, so passing it explicitly is not a
    /// special case that could diverge from leaving the field blank.
    @Test("an explicit default is accepted as-is")
    func explicitDefaultIsAccepted() throws {
        let target = try HerdrDiscovery.resolve(sshSettings(session: "default"))
        #expect(
            target == .sshShell(user: "admin", host: "127.0.0.1", port: 2222, session: "default")
        )
    }

    // MARK: - The local branch is unchanged

    /// Issue #70 is an SSH-only hole; the local branch already guarded this. These
    /// two tests pin that it still does, so a future refactor cannot move the
    /// check without one side going quiet.
    @Test("the local branch still rejects an invalid session")
    func localStillRejectsInvalidSession() {
        let settings = ConnectionSettings(name: "This Mac", transport: .local, session: "a/b")
        do {
            let target = try HerdrDiscovery.resolve(settings, environment: ["HOME": "/tmp/kraal-w70"])
            Issue.record("the local branch accepted a/b and produced \(target)")
        } catch let error as DiscoveryError {
            guard case let .invalidSessionName(name) = error else {
                Issue.record("expected .invalidSessionName, got \(error)")
                return
            }
            #expect(name == "a/b")
        } catch {
            Issue.record("expected DiscoveryError, got \(error)")
        }
    }

    @Test("the local branch still accepts a valid named session")
    func localStillAcceptsValidSession() throws {
        let settings = ConnectionSettings(name: "This Mac", transport: .local, session: "work")
        let target = try HerdrDiscovery.resolve(settings, environment: ["HOME": "/tmp/kraal-w70"])
        #expect(
            target == .unixSocket(path: "/tmp/kraal-w70/.config/herdr/sessions/work/herdr-client.sock")
        )
    }

    /// `KRAAL_HERDR_SOCKET` wins over everything on the local branch, and it is a
    /// raw path rather than a session name — so it must keep bypassing the name
    /// rule. A sandbox socket at an arbitrary path is the normal dev setup.
    @Test("the local socket override is not subject to the name rule")
    func localSocketOverrideBypassesNameRule() throws {
        let settings = ConnectionSettings(name: "sandbox", transport: .local, session: "a/b")
        let target = try HerdrDiscovery.resolve(
            settings,
            environment: ["KRAAL_HERDR_SOCKET": "/tmp/kraal-mine/herdr-client.sock"]
        )
        #expect(target == .unixSocket(path: "/tmp/kraal-mine/herdr-client.sock"))
    }

    // MARK: - isValidSessionName boundaries

    /// The predicate the guard rests on, stated directly. The rule mirrors
    /// upstream's `session::validate_name`: ASCII letters, digits, `.`, `_`, `-`;
    /// 1 to 64 bytes; never `.` or `..`.
    @Test(
        "isValidSessionName accepts the documented alphabet",
        arguments: ["a", "A", "0", "work", "a.b", "a_b", "a-b", "a.b_c-d", String(repeating: "z", count: 64)]
    )
    func acceptsValid(name: String) {
        #expect(HerdrDiscovery.isValidSessionName(name))
    }

    @Test(
        "isValidSessionName rejects everything else",
        arguments: [
            "",
            ".",
            "..",
            "../escape",
            "a/b",
            "a b",
            "名字",
            "café",
            "a\nb",
            "a\tb",
            "a+b",
            "a:b",
            "~",
            String(repeating: "z", count: 65),
        ]
    )
    func rejectsInvalid(name: String) {
        #expect(!HerdrDiscovery.isValidSessionName(name))
    }
}
