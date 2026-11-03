// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The one pure part of the first-launch dialogs: how `~/.ssh/config` becomes the
// host list the Add-a-machine dialog offers. The views themselves need a window,
// so they are checked in the VM (docs/AUTOMATION.md); the parser is checked here.

import Foundation
import Testing

@testable import KraalHCTerminal

@Suite("Welcome and add-machine")
struct HcWelcomeTests {
    @Test("a Host block keeps its alias, its other names, hostname and user")
    func hostBlock() {
        let hosts = HcSSHConfig.parse(
            "Host rohan rohan.lan\n  HostName 10.0.0.7\n  User can\n"
        )
        #expect(hosts.count == 1)
        #expect(hosts.first?.alias == "rohan")
        #expect(hosts.first?.aliases == ["rohan.lan"])
        #expect(hosts.first?.hostname == "10.0.0.7")
        #expect(hosts.first?.user == "can")
    }

    @Test("patterns are not pickable hosts, and their keys stay in their own block")
    func patterns() {
        let hosts = HcSSHConfig.parse(
            "Host *.internal\n  User admin\nHost db? prod\n  HostName prod.example\nHost !bad\n  User nobody\n"
        )
        // `*.internal` and `db?` open nothing; `prod` survives; `!bad` opens nothing.
        #expect(hosts.map(\.alias) == ["prod"])
        #expect(hosts.first?.hostname == "prod.example")
        #expect(hosts.first?.user == nil)
    }

    @Test("a Match block creates no host and ends the block above it")
    func matchBlock() {
        let hosts = HcSSHConfig.parse(
            "Host web\n  User root\nMatch host web\n  HostName 203.0.113.9\n"
        )
        #expect(hosts.map(\.alias) == ["web"])
        #expect(hosts.first?.user == "root")
        #expect(hosts.first?.hostname == nil)
    }

    @Test("Hostname and User before any Host are ignored")
    func keysBeforeHost() {
        #expect(HcSSHConfig.parse("HostName 198.51.100.4\nUser nobody\n").isEmpty)
    }

    @Test("a keyword may use = instead of whitespace")
    func equalsSeparator() {
        let hosts = HcSSHConfig.parse("Host=web\nHostName = web.example\nUser=deploy\n")
        #expect(
            hosts == [
                HcSSHConfig.Host(alias: "web", aliases: [], hostname: "web.example", user: "deploy")
            ]
        )
    }

    @Test("comments and lines outside a Host block are not hosts")
    func comments() {
        let hosts = HcSSHConfig.parse(
            "# Host ignored\nSendEnv LANG\nHost keep\n  # HostName nope\n  HostName keep.example\n"
        )
        #expect(hosts.map(\.alias) == ["keep"])
        #expect(hosts.first?.hostname == "keep.example")
    }

    @Test("several Host lines keep the file's order")
    func order() {
        let hosts = HcSSHConfig.parse("Host one\nHost two\nHost three\nHostName three.example\n")
        #expect(hosts.map(\.alias) == ["one", "two", "three"])
        #expect(hosts.map(\.hostname) == [nil, nil, "three.example"])
    }

    @Test("empty and garbage text yield no hosts")
    func emptyText() {
        #expect(HcSSHConfig.parse("").isEmpty)
        #expect(HcSSHConfig.parse("\n\n   \n").isEmpty)
        #expect(HcSSHConfig.parse("nonsense here\n= leading equals\n").isEmpty)
    }
}
