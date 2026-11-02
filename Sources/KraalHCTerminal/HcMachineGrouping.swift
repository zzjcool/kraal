// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Sidebar sections: this core, then one per machine.
//
// `temporary` machines are agent sandboxes; the core keeps them, the sidebar
// hides them (and their terminals) so they cannot pollute the list. A terminal
// from a machine the list no longer names still gets a section: a terminal that
// exists must stay reachable, and silently dropping it would look like a bug.

import Foundation
import KraalHC

public struct HcMachineGroup: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case local
        case machine(HcMachine)
        /// Terminals whose machine is not (or no longer) in `machine.list`.
        case orphan
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let kind: Kind
    public let terminals: [HcTerminal]

    public init(
        id: String,
        title: String,
        subtitle: String?,
        kind: Kind,
        terminals: [HcTerminal]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.terminals = terminals
    }

    public var machine: HcMachine? {
        if case let .machine(machine) = kind { return machine }
        return nil
    }

    public var state: HcMachineState? { machine?.state }
}

public enum HcMachineGrouping {
    public static func groups(
        machines: [HcMachine],
        terminals: [HcTerminal],
        localName: String
    ) -> [HcMachineGroup] {
        let hidden = Set(machines.filter(\.temporary).map(\.name))
        let visible = machines.filter { !$0.temporary }
        let known = Set(visible.map(\.name))

        var groups: [HcMachineGroup] = [
            HcMachineGroup(
                id: "",
                title: localName.isEmpty ? "This core" : localName,
                subtitle: "this core",
                kind: .local,
                terminals: terminals.filter { $0.machine == nil }
            ),
        ]

        for machine in visible {
            groups.append(HcMachineGroup(
                id: machine.name,
                title: machine.name,
                subtitle: subtitle(for: machine),
                kind: .machine(machine),
                terminals: terminals
                    .filter { $0.machine == machine.name }
                    .sorted(by: HcTerminal.ordered)
            ))
        }

        let orphans = Set(terminals.compactMap(\.machine))
            .subtracting(known)
            .subtracting(hidden)
            .sorted()
        for name in orphans {
            groups.append(HcMachineGroup(
                id: name,
                title: name,
                subtitle: "not in machine.list",
                kind: .orphan,
                terminals: terminals
                    .filter { $0.machine == name }
                    .sorted(by: HcTerminal.ordered)
            ))
        }
        return groups
    }

    private static func subtitle(for machine: HcMachine) -> String {
        let state = machine.state.label
        guard let why = machine.why else { return state }
        return "\(state) · \(why)"
    }
}
