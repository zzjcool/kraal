// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC
@testable import KraalHCTerminal

@Suite("Machine grouping")
struct HcMachineGroupingTests {
    private func machine(
        _ name: String,
        state: String = "connected",
        temporary: Bool = false,
        why: String? = nil
    ) -> HcMachine {
        var record: [String: JSONValue] = [
            "name": .string(name),
            "target": .string("can@\(name)"),
            "host": .string("\(name)-mac"),
            "version": .string("0.1.16"),
            "temporary": .bool(temporary),
            "state": .string(state),
        ]
        if let why { record["why"] = .string(why) }
        return HcMachine(json: .object(record))
    }

    private func terminal(_ address: String, state: String = "live") -> HcTerminal {
        HcTerminal(json: .object([
            "address": .string(address),
            "state": .string(state),
            "name": .string(address),
        ]))
    }

    @Test("this core first, then machines in the core's order; terminals sort by number")
    func sections() {
        let groups = HcMachineGrouping.groups(
            machines: [machine("rohan"), machine("vps")],
            terminals: [
                terminal("vps/t10"), terminal("t2"), terminal("rohan/t2"),
                terminal("rohan/t1"), terminal("t1"),
            ],
            localName: "this-mac"
        )
        #expect(groups.map(\.title) == ["this-mac", "rohan", "vps"])
        #expect(groups[0].terminals.map(\.address) == ["t2", "t1"])
        #expect(groups[1].terminals.map(\.address) == ["rohan/t1", "rohan/t2"])
        #expect(groups[2].terminals.map(\.address) == ["vps/t10"])
        #expect(groups[0].subtitle == "this core")
        #expect(groups[1].subtitle == "connected")
    }

    @Test("temporary machines and their terminals stay out of the sidebar")
    func temporaryHidden() {
        let groups = HcMachineGrouping.groups(
            machines: [machine("sandbox", temporary: true), machine("rohan")],
            terminals: [terminal("sandbox/t1"), terminal("rohan/t1"), terminal("t1")],
            localName: "this-mac"
        )
        #expect(groups.map(\.title) == ["this-mac", "rohan"])
        #expect(groups.flatMap(\.terminals).map(\.address) == ["t1", "rohan/t1"])
    }

    @Test("a terminal whose machine is not listed still gets a section")
    func orphan() {
        let groups = HcMachineGrouping.groups(
            machines: [],
            terminals: [terminal("gone/t2"), terminal("t1")],
            localName: "this-mac"
        )
        #expect(groups.map(\.title) == ["this-mac", "gone"])
        #expect(groups[1].kind == .orphan)
        #expect(groups[1].subtitle == "not in machine.list")
        #expect(groups[1].terminals.map(\.address) == ["gone/t2"])
    }

    @Test("why is shown next to the state")
    func why() {
        let groups = HcMachineGrouping.groups(
            machines: [machine("rohan", state: "needs_login", why: "Permission denied (publickey)")],
            terminals: [],
            localName: "this-mac"
        )
        #expect(groups[1].subtitle == "needs login · Permission denied (publickey)")
        #expect(groups[1].state == .needsLogin)
    }
}
