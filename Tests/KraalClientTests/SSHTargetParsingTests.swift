// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #68: a saved machine's `target` is an ssh *destination*, not a URL.
//
// `herdr machine add admin@127.0.0.1` stores that string verbatim, and
// `URL(string:)` finds no host in it — measured on this Mac:
//
//     URL(string: "admin@127.0.0.1")        host=nil       user=nil   port=nil
//     URL(string: "ssh://admin@127.0.0.1")  host=127.0.0.1 user=admin port=nil
//
// The old fallback ("no host? then the whole string is the host") therefore gave
// one machine two different `sshHost` values depending on how it was spelled.
// `EndpointID.matching` compares `sshHost`, so the same machine landed in the
// sidebar twice — and its user, never extracted, was shown as part of the host.
//
// These tests pin the parse *and* the row identity it feeds, without a daemon.

import Foundation
import KraalTransport
import Testing

@testable import KraalUI

@Suite("SSH target parsing")
struct SSHTargetParsingTests {
    /// The shape `herdr machine add host` writes: no scheme, no port.
    @Test("user@host is split into user and host")
    func userAtHost() throws {
        let parsed = try #require(ParsedSSHTarget.parse("admin@127.0.0.1"))
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.user == "admin")
        #expect(parsed.port == nil)
    }

    /// The shape `herdr machine add ssh://user@host:port` writes. This is the
    /// *only* way to save a non-default port — `machine add` has no `--port`.
    @Test("ssh://user@host:port is fully split")
    func sshURLWithPort() throws {
        let parsed = try #require(ParsedSSHTarget.parse("ssh://admin@127.0.0.1:2222"))
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.user == "admin")
        #expect(parsed.port == 2222)
    }

    @Test("ssh://user@host without a port leaves port nil")
    func sshURLWithoutPort() throws {
        let parsed = try #require(ParsedSSHTarget.parse("ssh://admin@127.0.0.1"))
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.user == "admin")
        #expect(parsed.port == nil)
    }

    /// A bare host: `SSHTransport` passes it to ssh unchanged.
    @Test("a bare host parses with no user and no port")
    func bareHost() throws {
        let parsed = try #require(ParsedSSHTarget.parse("devcloud"))
        #expect(parsed.host == "devcloud")
        #expect(parsed.user == nil)
        #expect(parsed.port == nil)
    }

    @Test("ssh://host:port parses with no user")
    func sshURLHostOnly() throws {
        let parsed = try #require(ParsedSSHTarget.parse("ssh://devcloud:2222"))
        #expect(parsed.host == "devcloud")
        #expect(parsed.user == nil)
        #expect(parsed.port == 2222)
    }

    /// `machine add user@host:port` fails on herdr's side (ssh reads the port as
    /// part of the host name), but a hand-written roster can contain it and the
    /// parser must not fall over. Reading it as host:port is the only reading that
    /// matches what the user meant.
    @Test("user@host:port parses even though machine add would refuse it")
    func userAtHostPort() throws {
        let parsed = try #require(ParsedSSHTarget.parse("admin@127.0.0.1:2222"))
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.user == "admin")
        #expect(parsed.port == 2222)
    }

    // MARK: - IPv6 literals

    /// Brackets are punctuation, not part of the address: ssh resolves the
    /// unbracketed form (`ssh 'admin@[::1]'` fails with "Could not resolve
    /// hostname [::1]", measured).
    @Test("an IPv6 literal is stored without its brackets")
    func ipv6Literal() throws {
        let parsed = try #require(ParsedSSHTarget.parse("[::1]"))
        #expect(parsed.host == "::1")
        #expect(parsed.user == nil)
        #expect(parsed.port == nil)
    }

    @Test("a bracketed IPv6 literal keeps its port")
    func ipv6LiteralWithPort() throws {
        let parsed = try #require(ParsedSSHTarget.parse("[::1]:2222"))
        #expect(parsed.host == "::1")
        #expect(parsed.port == 2222)
    }

    @Test("user@[::1] parses user and a bracketless host")
    func ipv6LiteralWithUser() throws {
        let parsed = try #require(ParsedSSHTarget.parse("user@[::1]"))
        #expect(parsed.host == "::1")
        #expect(parsed.user == "user")
        #expect(parsed.port == nil)
    }

    @Test("the full IPv6 form parses")
    func ipv6LiteralWithUserAndPort() throws {
        let parsed = try #require(ParsedSSHTarget.parse("ssh://admin@[2001:db8::1]:2222"))
        #expect(parsed.host == "2001:db8::1")
        #expect(parsed.user == "admin")
        #expect(parsed.port == 2222)
    }

    /// Two or more colons cannot be `host:port`. This is the one shape where
    /// guessing would be worse than the rule: reading `::1:2222` as host `::1`
    /// plus port 2222 would dial the wrong address, so it is read as one IPv6
    /// address — the same thing ssh does (measured: hostname `::0.1.34.34`).
    @Test("an unbracketed IPv6 address carries no port")
    func unbracketedIPv6HasNoPort() throws {
        let parsed = try #require(ParsedSSHTarget.parse("admin@::1:2222"))
        #expect(parsed.host == "::1:2222")
        #expect(parsed.user == "admin")
        #expect(parsed.port == nil)
    }

    // MARK: - Equivalence: the issue itself

    /// The two spellings of one machine must produce one set of parts. This is the
    /// assertion the old three-function code failed.
    @Test("the same machine spelled two ways parses to the same parts")
    func spellingsAgree() {
        let plain = ParsedSSHTarget.parse("admin@127.0.0.1")
        let uri = ParsedSSHTarget.parse("ssh://admin@127.0.0.1")
        #expect(plain == uri)
        #expect(plain?.host == "127.0.0.1")
        #expect(plain?.user == "admin")

        let ported = ParsedSSHTarget.parse("admin@127.0.0.1:2222")
        let portedURI = ParsedSSHTarget.parse("ssh://admin@127.0.0.1:2222")
        #expect(ported == portedURI)
        #expect(ported?.port == 2222)
    }

    /// The old behaviour, kept as the reason the new one exists: `URL` cannot
    /// read the common shape at all.
    @Test("URL(string:) cannot read the shape machine add writes")
    func urlCannotReadDestination() {
        // Not a claim about Kraal's code any more — a claim about the API the old
        // implementation relied on, so the regression cannot be reintroduced by
        // reaching for it again.
        #expect(URL(string: "admin@127.0.0.1")?.host == nil)
        #expect(URL(string: "ssh://admin@127.0.0.1")?.host == "127.0.0.1")
    }

    // MARK: - Row identity (the user-visible symptom)

    /// The symptom in issue #68: one machine, two rows. Feed the parser's output
    /// through the same path the catalog uses and the sidebar must see one row.
    @MainActor
    @Test("both spellings select the same machine row")
    func bothSpellingsMatchOneRow() throws {
        let store = AppStore(target: .local)
        store.rebuildEndpoints(roster: [
            .remote(HerdrMachine(
                id: "aaaa0000000000000000000000000001",
                label: "sandbox",
                target: "admin@127.0.0.1",
                session: "default",
                enabled: true
            ))
        ])
        let rowID = EndpointID.ssh(id: "aaaa0000000000000000000000000001")
        let settings = try #require(store.endpoints.first { $0.id == rowID }?.settings)

        // The catalog parsed `admin@127.0.0.1`; these are the settings the sheet
        // would build from `ssh://admin@127.0.0.1` (same host, same user, same
        // port). Under the old code the first had host `admin@127.0.0.1` and the
        // second had `127.0.0.1`, so this lookup fell through to `settings.name`
        // — a second row for one machine.
        let renamed = ConnectionSettings(
            name: "sandbox (typed the other way)",
            transport: .ssh,
            session: "default",
            sshHost: "127.0.0.1",
            sshUser: "admin",
            sshPort: nil
        )
        #expect(settings.sshHost == renamed.sshHost)
        #expect(settings.sshUser == renamed.sshUser)

        let matched = EndpointID.matching(settings: renamed, in: store.endpoints)
        #expect(matched == rowID, "the two spellings produced two rows")
    }

    /// The user is no longer part of the host name, which is what made the
    /// sidebar subtitle read `admin@127.0.0.1`.
    @MainActor
    @Test("the catalog stores the user separately from the host")
    func catalogSeparatesUserFromHost() throws {
        let store = AppStore(target: .local)
        store.rebuildEndpoints(roster: [
            .remote(HerdrMachine(
                id: "bbbb0000000000000000000000000002",
                label: "sandbox",
                target: "admin@127.0.0.1",
                session: "default",
                enabled: true
            ))
        ])
        let row = try #require(store.endpoints.first { $0.id != .local })
        #expect(row.settings.sshHost == "127.0.0.1")
        #expect(row.settings.sshUser == "admin")
        #expect(row.settings.sshPort == nil)
        #expect(row.status == .connecting)
    }

    @MainActor
    @Test("the catalog carries a saved port through to the transport")
    func catalogKeepsPort() throws {
        let store = AppStore(target: .local)
        store.rebuildEndpoints(roster: [
            .remote(HerdrMachine(
                id: "cccc0000000000000000000000000003",
                label: "sandbox",
                target: "ssh://admin@127.0.0.1:2222",
                session: "default",
                enabled: true
            ))
        ])
        let row = try #require(store.endpoints.first { $0.id != .local })
        #expect(row.settings.sshHost == "127.0.0.1")
        #expect(row.settings.sshUser == "admin")
        #expect(row.settings.sshPort == 2222)
        // And it reaches the thing that actually opens the socket.
        let target = try HerdrDiscovery.resolve(row.settings)
        #expect(target == .sshShell(user: "admin", host: "127.0.0.1", port: 2222, session: "default"))
    }

    // MARK: - Rejected shapes

    /// An unreadable target is `nil` — not "the whole string is the host". The old
    /// fallback made a broken profile look like a working one whose host name
    /// happened to contain an `@`.
    @Test(
        "shapes that are not a destination return nil",
        arguments: [
            "",
            "   ",
            "@127.0.0.1",              // empty user
            "admin@",                  // empty host
            "ssh://",                  // empty authority
            "ssh://admin@",            // empty host behind a scheme
            "git://host",              // not an ssh destination
            "file:///tmp/sock",        // not an ssh destination
            "[::1",                    // unclosed bracket
            "[]",                      // empty literal
            "[host]:22",               // brackets around a name, not a literal
            "[::1]2222",               // no colon before the port
            "host:0",                  // ssh refuses port 0
            "host:70000",              // out of range
            "host:",                   // empty port
            "ssh://host:big-port",     // not a number
            "host:2222:3333",          // two colons but not an IPv6 literal
            "user name@host",          // whitespace inside the destination
            "admin@/path",             // `/` is not a host character
        ]
    )
    func rejectedShapes(target: String) {
        #expect(ParsedSSHTarget.parse(target) == nil, "parsed \(target.debugDescription)")
    }

    // MARK: - Edges

    /// A hand-edited roster picks up whitespace easily; a trailing newline must not
    /// become part of the host name.
    @Test("surrounding whitespace is ignored")
    func whitespaceIsTrimmed() throws {
        let parsed = try #require(ParsedSSHTarget.parse("  admin@127.0.0.1\n"))
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.user == "admin")
    }

    /// ssh splits the userinfo at the last `@` (`ssh -G 'a@b@c'` reports user
    /// `a@b`, host `c`, measured), and a host cannot contain one.
    @Test("the userinfo splits at the last @")
    func lastAtWins() throws {
        let parsed = try #require(ParsedSSHTarget.parse("a@b@host"))
        #expect(parsed.host == "host")
        #expect(parsed.user == "a@b")
    }

    @Test("the scheme is case-insensitive")
    func schemeCase() throws {
        let parsed = try #require(ParsedSSHTarget.parse("SSH://admin@host:2222"))
        #expect(parsed.host == "host")
        #expect(parsed.user == "admin")
        #expect(parsed.port == 2222)
    }

    /// Nothing herdr writes includes a URI path, but one that arrives must not end
    /// up inside the host name.
    @Test("a URI path is not part of the destination")
    func uriPathIsDropped() throws {
        let parsed = try #require(ParsedSSHTarget.parse("ssh://admin@host:2222/herdr"))
        #expect(parsed.host == "host")
        #expect(parsed.user == "admin")
        #expect(parsed.port == 2222)
    }

    @Test("port 65535 is accepted")
    func highestPort() throws {
        let parsed = try #require(ParsedSSHTarget.parse("ssh://host:65535"))
        #expect(parsed.port == 65_535)
    }

    /// An unreadable profile keeps its row — the machine *is* in herdr's roster,
    /// and hiding it would make the sidebar disagree with the machines dialog —
    /// but it says why, and it is not dialled.
    @MainActor
    @Test("an unreadable target gets a row that says where to look")
    func unreadableTargetIsVisible() throws {
        let store = AppStore(target: .local)
        store.rebuildEndpoints(roster: [
            .remote(HerdrMachine(
                id: "dddd0000000000000000000000000004",
                label: "typo",
                target: "git://host",
                session: "default",
                enabled: true
            ))
        ])
        let row = try #require(store.endpoints.first { $0.id != .local })
        #expect(row.status == .attention(AppStore.invalidTargetBadge))
        #expect(row.status.badge == "! check target")
        #expect(!row.enabled, "an unreadable profile must not be dialled")
    }

    /// An enabled, readable profile is unchanged by the new code path.
    @MainActor
    @Test("a readable profile stays enabled and dialable")
    func readableProfileIsEnabled() throws {
        let store = AppStore(target: .local)
        store.rebuildEndpoints(roster: [
            .remote(HerdrMachine(
                id: "eeee0000000000000000000000000005",
                label: "sandbox",
                target: "admin@127.0.0.1",
                session: "default",
                enabled: true
            ))
        ])
        let row = try #require(store.endpoints.first { $0.id != .local })
        #expect(row.enabled)
        _ = try HerdrDiscovery.resolve(row.settings)
    }

    /// Disabled is the user's own choice, so it outranks a target problem: a
    /// machine they switched off must keep saying "off" rather than nagging about
    /// a profile they are not using.
    @MainActor
    @Test("a disabled profile stays disabled even with an unreadable target")
    func disabledOutranksUnreadable() throws {
        let store = AppStore(target: .local)
        store.rebuildEndpoints(roster: [
            .remote(HerdrMachine(
                id: "ffff0000000000000000000000000006",
                label: "off",
                target: "git://host",
                session: "default",
                enabled: false
            ))
        ])
        let row = try #require(store.endpoints.first { $0.id != .local })
        #expect(row.status == .disabled)
        #expect(!row.enabled)
    }
}
