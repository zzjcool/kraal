// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #90: two limits, one input field.
//
// `isValidSessionName` allows 64 characters. The socket path that name produces
// has its own limit — `sun_path` is 104 bytes on Darwin, so the path may be at
// most 103 — and on a machine with a normal-length home directory a 64-character
// name does not fit. The name passed validation and the connection then failed
// somewhere else, with a `pathTooLong` that says nothing about the field the user
// typed in.
//
// The budget is not a constant: it depends on the home directory, and a longer
// `$HOME` shrinks it. So the tests assert the relationship (path length versus
// limit, name versus budget) rather than a remembered number of characters.

import Foundation
import Testing

@testable import KraalTransport

@Suite("Session name fits the socket path")
struct SessionSocketLengthTests {
    /// A home directory with a known length, so the arithmetic below is checkable
    /// by hand. 12 bytes is what the developer's own machine has
    /// (`/Users/zzjcool`), and it is the *short* case — every longer home makes the
    /// budget smaller.
    private func environment(home: String) -> [String: String] {
        ["HOME": home]
    }

    @Test("the platform limit is derived, not remembered")
    func limitMatchesTheAddressLayout() {
        // 103 on Darwin (104-byte sun_path, one byte kept for the NUL). Asserted
        // through the same API the socket uses, so a change to the constant cannot
        // silently disagree with the check.
        #expect(unixSocketMaxPathBytes >= 90)
        #expect(unixSocketMaxPathBytes <= 107)
    }

    @Test("a short session name produces a path inside the limit")
    func shortNameFits() throws {
        let path = try HerdrDiscovery.sessionSocket(
            name: "work",
            environment: environment(home: "/Users/zzjcool")
        )
        #expect(Array(path.utf8).count <= unixSocketMaxPathBytes)
    }

    @Test("a 64-character session name is legal but does not fit a normal home")
    func longestLegalNameDoesNotFit() {
        // The whole point of the issue: this name passes validation, yet the path
        // it asks for is too long. The name rule is stated in characters, the path
        // rule in bytes, and nothing connected them before the fix.
        let name = String(repeating: "z", count: 64)
        #expect(HerdrDiscovery.isValidSessionName(name))

        // The path it *would* produce, computed the same way the discovery code
        // builds it: config root + sessions/<name> + herdr-client.sock.
        let root = HerdrDiscovery.configDirectory(
            environment: environment(home: "/Users/zzjcool")
        )
        let wouldBe = root + "/sessions/" + name + "/herdr-client.sock"
        #expect(Array(wouldBe.utf8).count > unixSocketMaxPathBytes)
    }

    @Test("sessionSocket refuses a name whose path would overflow, and says why")
    func rejectsNameThatOverflows() {
        // The fix: the error has to name the session and both numbers, because the
        // user can only act on "this name is too long", not on "path too long".
        let name = String(repeating: "z", count: 64)
        #expect(throws: DiscoveryError.self) {
            _ = try HerdrDiscovery.sessionSocket(
                name: name,
                environment: environment(home: "/Users/zzjcool")
            )
        }
        do {
            _ = try HerdrDiscovery.sessionSocket(
                name: name,
                environment: environment(home: "/Users/zzjcool")
            )
            Issue.record("expected a refusal")
        } catch let error as DiscoveryError {
            let text = error.description
            // The name, so the user knows which field to edit.
            #expect(text.contains(name))
            // Both limits, so the message can be acted on without reading code.
            #expect(text.contains("103"))
            // And the number that actually has to shrink.
            let budget = HerdrDiscovery.maxSessionNameLength(
                environment: environment(home: "/Users/zzjcool")
            )
            #expect(budget > 0 && budget < 64)
            #expect(text.contains("\(budget)"))
        } catch {
            Issue.record("expected DiscoveryError, got \(error)")
        }
    }

    @Test("the budget shrinks when the home directory grows")
    func budgetFollowsHomeLength() {
        // Not a constant: the same name can be fine on one machine and too long on
        // another. This is why the check has to run at resolution time with the
        // real environment, not once at build time.
        let shortHome = HerdrDiscovery.maxSessionNameLength(
            environment: environment(home: "/Users/zzjcool")
        )
        let longHome = HerdrDiscovery.maxSessionNameLength(
            environment: environment(home: "/Users/someone-with-a-longer-name")
        )
        #expect(longHome < shortHome)
    }

    @Test("a name exactly at the budget is accepted, one longer is refused")
    func budgetBoundary() throws {
        let env = environment(home: "/Users/zzjcool")
        let budget = HerdrDiscovery.maxSessionNameLength(environment: env)
        #expect(budget > 0)

        let atBudget = String(repeating: "z", count: budget)
        let path = try HerdrDiscovery.sessionSocket(name: atBudget, environment: env)
        #expect(Array(path.utf8).count <= unixSocketMaxPathBytes)

        let overBudget = String(repeating: "z", count: budget + 1)
        #expect(throws: DiscoveryError.self) {
            _ = try HerdrDiscovery.sessionSocket(name: overBudget, environment: env)
        }
    }

    @Test("an invalid name is still refused for being invalid, not for being long")
    func invalidNameKeepsItsOwnError() {
        // The two refusals must not collapse into one: "a/b" is not a length
        // problem, and telling the user to shorten it would be wrong advice.
        do {
            _ = try HerdrDiscovery.sessionSocket(
                name: "../escape",
                environment: environment(home: "/Users/zzjcool")
            )
            Issue.record("expected a refusal")
        } catch let error as DiscoveryError {
            if case .invalidSessionName = error {
                // Right refusal.
            } else {
                Issue.record("expected invalidSessionName, got \(error)")
            }
        } catch {
            Issue.record("expected DiscoveryError, got \(error)")
        }
    }

    @Test("the default session is not affected by the budget")
    func defaultSessionFits() throws {
        // `default` sits in the config root, not under `sessions/<name>/`, so it
        // is 19 bytes shorter. It must never be refused.
        let path = try HerdrDiscovery.sessionSocket(
            name: HerdrDiscovery.defaultSession,
            environment: environment(home: "/Users/zzjcool")
        )
        #expect(Array(path.utf8).count <= unixSocketMaxPathBytes)
    }
}
