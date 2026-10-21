// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression guard for bug 6: the machine roster shipped without this Mac.
//
// The cause is structural rather than a typo, so the tests pin the structure:
// `herdr machine list` only ever returns SSH profiles, and the local daemon is
// implicit (a unix socket, not an entry in `endpoints.json`). A roster built
// straight from the CLI output is therefore missing the one machine the app is
// usually connected to.

import Foundation
import Testing

import KraalTransport

@testable import KraalUI

@Suite("Machine roster")
struct MachineRosterTests {
    /// A saved profile, with the field shape `herdr machine list --json` uses.
    private func profile(
        id: String = "191645f46cf4bc677a393cf0ca51d193",
        label: String = "nj-mac",
        target: String = "ssh://user@host:31415",
        enabled: Bool = true,
        selected: Bool? = false
    ) -> HerdrMachine {
        HerdrMachine(
            id: id,
            label: label,
            target: target,
            session: "default",
            enabled: enabled,
            selected: selected
        )
    }

    private let local = LocalMachineDescriptor(label: "This Mac", socketPath: "/tmp/herdr-client.sock")

    /// The bug itself: `herdr machine list` returns only SSH profiles, so a roster
    /// fed straight from it has no local entry and the Machines panel showed a
    /// machine list that excluded the machine it was running on.
    @Test("this Mac is in the roster even when herdr has no saved machines")
    func localIsPresentWithNoSavedMachines() {
        let roster = MachineRoster.compose(local: local, remote: [])

        #expect(roster.count == 1)
        #expect(roster[0].isLocal)
        #expect(roster[0].displayLabel == "This Mac")
        #expect(roster[0].targetDescription == "/tmp/herdr-client.sock")
    }

    @Test("this Mac comes first, then the saved machines in the order given")
    func localComesFirst() {
        let roster = MachineRoster.compose(
            local: local,
            remote: [profile(label: "devcloud"), profile(label: "nj-hw")]
        )

        #expect(roster.map(\.displayLabel) == ["This Mac", "devcloud", "nj-hw"])
        #expect(roster.first?.isLocal == true)
        #expect(roster.dropFirst().allSatisfy { !$0.isLocal })
    }

    /// The local row's id must not be mistakable for a herdr profile id, which is
    /// 32 hex characters. If it ever collided, `ForEach` would drop a row.
    @Test("the synthesised local id cannot collide with a saved profile id")
    func localIdIsDistinctInShape() {
        let roster = MachineRoster.compose(local: local, remote: [profile()])
        let ids = roster.map(\.id)

        #expect(ids == [LocalMachineDescriptor.stableId, profile().id])
        #expect(Set(ids).count == ids.count)
        #expect(!LocalMachineDescriptor.stableId.allSatisfy { $0.isHexDigit })
    }

    /// The local destination is resolved through `HerdrDiscovery`, the same path a
    /// connection takes, so the row cannot advertise a socket the app would not dial.
    @Test("the local row reports the socket the app would actually dial")
    func localRowUsesDiscoveryPath() {
        let descriptor = LocalMachineDescriptor.resolve(
            settings: .local,
            environment: ["HOME": "/Users/tester", "KRAAL_HERDR_SOCKET": ""]
        )

        #expect(descriptor.target == "/Users/tester/.config/herdr/herdr-client.sock")
    }

    @Test("an environment override is reflected in the local row")
    func localRowHonoursOverride() {
        let descriptor = LocalMachineDescriptor.resolve(
            settings: .local,
            environment: ["KRAAL_HERDR_SOCKET": "/tmp/kraal-mine/herdr-client.sock"]
        )

        #expect(descriptor.target == "/tmp/kraal-mine/herdr-client.sock")
    }

    @Test("a named session nests its socket under sessions/, as the daemon does")
    func localRowHonoursSession() {
        let descriptor = LocalMachineDescriptor.resolve(
            settings: ConnectionSettings(name: "This Mac", session: "work"),
            environment: ["HOME": "/Users/tester"]
        )

        #expect(descriptor.target == "/Users/tester/.config/herdr/sessions/work/herdr-client.sock")
    }

    @Test("a renamed local connection keeps its label in the roster")
    func localRowUsesSettingsName() {
        let descriptor = LocalMachineDescriptor.resolve(
            settings: ConnectionSettings(name: "sandbox", transport: .local),
            environment: ["KRAAL_HERDR_SOCKET": "/tmp/sandbox.sock"]
        )
        let roster = MachineRoster.compose(local: descriptor, remote: [])

        #expect(roster[0].displayLabel == "sandbox")
    }

    /// `enabled` drives the row's dimming and the toggle; this Mac is always usable
    /// and has no write controls, so it must never render as disabled.
    @Test("this Mac is always enabled and never offers write controls")
    func localIsAlwaysEnabled() {
        let roster = MachineRoster.compose(local: local, remote: [profile(enabled: false)])

        #expect(roster[0].enabled)
        #expect(roster[0].machine == nil, "no saved profile behind the local row")
        #expect(roster[1].enabled == false)
        #expect(roster[1].machine?.enabled == false)
    }

    /// Sidebar rows carry the machine name, which used to be the hard-coded literal
    /// "local" and so never matched the roster.
    @Test("sidebar rows name the machine they belong to")
    func sidebarNameComesFromSettings() {
        #expect(MachineRoster.sidebarMachineName(settings: .local) == "This Mac")
        #expect(MachineRoster.sidebarMachineName(
            settings: ConnectionSettings(name: "devcloud", transport: .ssh, sshHost: "host")
        ) == "devcloud")
    }

    /// `machine` is rendered verbatim into the row, so an empty name would leave a
    /// blank gap instead of falling back.
    @Test("an unnamed connection falls back instead of rendering an empty token")
    func sidebarNameFallsBack() {
        let unnamed = ConnectionSettings(name: "   ", transport: .local)

        #expect(MachineRoster.sidebarMachineName(settings: unnamed) == "local")
        #expect(MachineRoster.sidebarMachineName(settings: unnamed, fallback: "?") == "?")
    }
    /// The reported bug: right-clicking a row in the Machines list did nothing.
    ///
    /// The cause was not a missing `.contextMenu` — the modifier was always there.
    /// Its body was `if !isLocal { ... }`, so this Mac's row produced an empty menu
    /// body, and SwiftUI still installs a menu for that. AppKit then opens a menu
    /// with no items, which reads exactly like "the menu never appears".
    ///
    /// These tests pin the property that was violated: every row offers at least
    /// one action. They cannot watch AppKit open a menu, but they can make the empty
    /// case unreachable again.
    @Test("no row ever has an empty context menu")
    func everyRowHasMenuActions() {
        let local = MachineEntry.local(LocalMachineDescriptor(
            label: "This Mac",
            socketPath: "/tmp/herdr-client.sock"
        ))
        let remote = MachineEntry.remote(profile())

        #expect(!local.menuActions.isEmpty)
        #expect(!remote.menuActions.isEmpty)
    }

    @Test("this Mac offers identity, not write actions it cannot perform")
    func localRowOffersOnlyCopy() {
        let local = MachineEntry.local(LocalMachineDescriptor(
            label: "This Mac",
            socketPath: "/tmp/herdr-client.sock"
        ))

        // There is no `herdr machine` command that renames, disables or removes the
        // local daemon, so offering those would be a menu of failures.
        #expect(local.menuActions == [.copySocketPath, .copyLabel])
        #expect(!local.menuActions.contains(.remove))
        #expect(!local.menuActions.contains(.rename))
        #expect(!local.menuActions.contains(.toggleEnabled))
    }

    @Test("a saved profile keeps the actions it can actually perform")
    func remoteRowOffersWriteActions() {
        let remote = MachineEntry.remote(profile())

        #expect(remote.menuActions == [.rename, .toggleEnabled, .remove])
        // Copying the socket path is meaningless for an SSH profile.
        #expect(!remote.menuActions.contains(.copySocketPath))
    }
}

@Suite("Machines store roster")
@MainActor
struct MachinesStoreRosterTests {
    /// The store seeds itself with this Mac, so the panel's first frame — before
    /// `reload()` runs, and permanently when herdr is not installed — still shows a
    /// roster with the local machine in it.
    @Test("the store starts with this Mac already in the roster")
    func storeSeedsLocal() {
        let store = MachinesStore(client: nil, local: LocalMachineDescriptor(
            label: "This Mac",
            socketPath: "/tmp/herdr-client.sock"
        ))

        #expect(store.machines.count == 1)
        #expect(store.machines[0].isLocal)
        #expect(store.machines[0].displayLabel == "This Mac")
    }

    /// A missing CLI used to leave `machines` empty, which the panel rendered as
    /// "No saved machines yet." — while this Mac was perfectly reachable.
    @Test("reload without a herdr CLI keeps this Mac and reports it as unavailable")
    func reloadWithoutClientKeepsLocal() {
        let store = MachinesStore(client: nil, local: LocalMachineDescriptor(
            label: "This Mac",
            socketPath: "/tmp/herdr-client.sock"
        ))
        store.reload()

        #expect(store.available == false)
        #expect(store.machines.count == 1)
        #expect(store.machines[0].isLocal)
    }

    /// The panel and the sidebar must agree on what this machine is called.
    /// They drifted because each defaulted to `.local` independently, so a
    /// connection named "sandbox" showed as "This Mac" in the panel and "sandbox"
    /// in the sidebar — the same machine under two names.
    @Test("the panel and the sidebar name this Mac identically")
    func panelAndSidebarAgree() {
        let sandbox = ConnectionSettings(name: "sandbox", transport: .local)
        let environment = ["KRAAL_HERDR_SOCKET": "/tmp/kraal-mine/herdr-client.sock"]

        let store = MachinesStore(
            client: nil,
            local: LocalMachineDescriptor.resolve(settings: sandbox, environment: environment)
        )
        let panelName = store.machines[0].displayLabel
        let sidebarName = MachineRoster.sidebarMachineName(settings: sandbox)

        #expect(panelName == "sandbox")
        #expect(panelName == sidebarName)
    }

    @Test("the footer counts this Mac separately from the saved machines")
    func footerSeparatesLocalFromSaved() {
        let store = MachinesStore(client: nil, local: LocalMachineDescriptor(
            label: "This Mac",
            socketPath: "/tmp/herdr-client.sock"
        ))

        #expect(store.footerSummary == "This Mac + 0 saved machines · managed by the herdr CLI")
    }
}
