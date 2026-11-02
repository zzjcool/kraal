// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Agents are what the programs say they are: OSC 7501 words in the core's
// `status`, plus the turn counter and the `herdr.seen`/`herdr.pinned` labels
// shared with every other client. Nothing here reads the screen.

import Foundation
import KraalHC
import KraalModel

public enum HcAgentStatus: String, CaseIterable, Sendable, Equatable {
    case working
    case blocked
    case done
    case idle

    public var priority: Int {
        switch self {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        }
    }

    public var label: String {
        switch self {
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Finished"
        case .idle: "Idle"
        }
    }
}

public struct HcAgent: Identifiable, Sendable, Equatable {
    public let address: String
    public let pane: String?
    public let name: String
    public let detail: String
    public let spaceID: String?
    public let spaceName: String
    public let tabName: String
    public let machine: String?
    /// The program's own word, child agents normalized as the app shows them.
    public let word: String
    public let app: String?
    public let status: HcAgentStatus
    public let turn: Int
    public let seenTurn: Int?
    public let pinned: Bool
    public let parent: String?
    public let depth: Int
    /// When this word last changed (ms since the epoch; 0: not since launch).
    public let since: UInt64

    public var id: String { address }
    public var isChild: Bool { parent != nil }
    public var isPinned: Bool { pinned }
}

private extension HcAgent {
    func with(status: HcAgentStatus, depth: Int) -> HcAgent {
        HcAgent(
            address: address,
            pane: pane,
            name: name,
            detail: detail,
            spaceID: spaceID,
            spaceName: spaceName,
            tabName: tabName,
            machine: machine,
            word: word,
            app: app,
            status: status,
            turn: turn,
            seenTurn: seenTurn,
            pinned: pinned,
            parent: parent,
            depth: depth,
            since: since
        )
    }
}

public struct HcAgentAlert: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case blocked
        case done
    }

    public let address: String
    public let kind: Kind
    public let title: String
    public let detail: String
}

public struct HcAgentToast: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let title: String
    public let detail: String
    public let level: Level

    public enum Level: Sendable, Equatable {
        case info
        case error
    }
}

public enum HcAgentViewMode: String, CaseIterable, Identifiable, Sendable {
    case priority
    case space

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .priority: "Priority"
        case .space: "Spaces"
        }
    }
}

public struct HcAgentGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let agents: [HcAgent]
    /// Set for machine sections; nil for the local section or a space group.
    public let machineID: String?
    public let spaceID: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        agents: [HcAgent],
        machineID: String? = nil,
        spaceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.agents = agents
        self.machineID = machineID
        self.spaceID = spaceID
    }
}

/// Everything one agent pass needs; a value so tests can build it field by field.
public struct HcAgentInput: Sendable {
    public var terminals: [HcTerminal] = []
    public var model: KraalModel
    public var placed: Set<String> = []
    public var visible: Set<String> = []
    public var appActive = false
    public var seenOverrides: [String: Int] = [:]
    public var unread: Set<String> = []
    public var focused: String?
    public var now: UInt64 = 0

    public init(model: KraalModel) {
        self.model = model
    }
}

/// Tracks the word each terminal last said, and what that means for attention.
public struct HcAgentTracker: Sendable {
    private struct State: Sendable {
        var word: String
        var seen: Bool
        var since: UInt64
        var seq: UInt64
    }

    private var states: [String: State] = [:]
    private var sequence: UInt64 = 0
    /// A focused agent that turned done→idle stays in Done until focus leaves.
    private var held: (address: String, rank: Int)?

    public init() {}

    public mutating func update(_ input: HcAgentInput) -> (agents: [HcAgent], alerts: [HcAgentAlert]) {
        let built = build(input)
        if let current = built.agents.first(where: { $0.address == input.focused }) {
            if held?.address != current.address || current.status != .idle {
                held = (current.address, current.status.priority)
            }
        } else {
            held = nil
        }
        let ordered = flatten(built.agents)
        let live = Set(input.terminals.map(\.address))
        states = states.filter { live.contains($0.key) }
        return (ordered, built.alerts)
    }

    private mutating func build(_ input: HcAgentInput) -> (agents: [HcAgent], alerts: [HcAgentAlert]) {
        var candidates: [HcAgent] = []
        var alerts: [HcAgentAlert] = []
        let included = includedAddresses(input)

        for terminal in input.terminals where included.contains(terminal.address) {
            let rawWord = terminal.agentState ?? "idle"
            let child = terminal.parent
            let word = child == nil ? rawWord : Self.childWord(rawWord)
            let looking = input.appActive && input.visible.contains(terminal.address)
            let previous = states[terminal.address]
            if previous?.word != word {
                let wasBusy = Self.busy(previous?.word)
                let seen: Bool
                if Self.blocked(word) || word == "working" {
                    seen = true
                } else if wasBusy {
                    seen = looking
                } else {
                    seen = previous?.seen ?? true
                }
                sequence += 1
                states[terminal.address] = State(word: word, seen: seen, since: input.now, seq: sequence)

                if child == nil, input.placed.contains(terminal.address),
                   let alert = Self.alert(previous: previous?.word, new: word, looking: looking) {
                    let name = Self.displayName(terminal)
                    let place = Self.place(terminal: terminal, model: input.model)
                    alerts.append(HcAgentAlert(
                        address: terminal.address,
                        kind: alert,
                        title: alert == .blocked ? "\(name) needs you" : "\(name) finished",
                        detail: place
                    ))
                }
            } else if previous == nil {
                sequence += 1
                states[terminal.address] = State(word: word, seen: true, since: input.now, seq: sequence)
            }

            let state = states[terminal.address] ?? State(word: word, seen: true, since: input.now, seq: sequence)
            candidates.append(candidate(terminal, state: state, word: word, child: child, input: input))
        }
        return (candidates, alerts)
    }

    private mutating func candidate(
        _ terminal: HcTerminal,
        state: State,
        word: String,
        child: String?,
        input: HcAgentInput
    ) -> HcAgent {
        let labelSeen = terminal.labels["herdr.seen"].flatMap(Int.init)
        let override = input.seenOverrides[terminal.address]
        let seenTurn = [labelSeen, override].compactMap(\.self).max()
        let pane = input.model.paneID(ofTerminal: terminal.address)
        let tab = pane.flatMap { input.model.tab(ofPane: $0) }
        let space = tab.flatMap { input.model.space(of: $0.id) }
        let namedTab = tab?.name ?? ""
        let ownTitle = Self.clean(terminal.status?["title"]?.stringValue ?? "")
        let kind: HcAgentStatus
        if word == "working" {
            kind = .working
        } else if word == "blocked" || word == "error" {
            kind = .blocked
        } else if input.unread.contains(terminal.address) {
            kind = .done
        } else {
            kind = Self.status(word: word, turn: terminal.turn, seenTurn: seenTurn, seen: state.seen)
        }
        // A sub-agent reports to its parent: its quiet word is never "done"
        // for the person, even when the window was in the background.
        let shownKind: HcAgentStatus = child != nil && kind == .done ? .idle : kind
        let detail = !namedTab.isEmpty ? namedTab
            : (!ownTitle.isEmpty ? ownTitle : (terminal.foreground?.name ?? terminal.agent))
        return HcAgent(
            address: terminal.address,
            pane: pane,
            name: Self.displayName(terminal),
            detail: detail,
            spaceID: space?.id,
            spaceName: space?.displayName ?? "",
            tabName: tab?.displayName ?? "",
            machine: terminal.machine,
            word: word,
            app: terminal.status?["app"]?.stringValue,
            status: Self.heldStatus(shownKind, address: terminal.address, focused: input.focused, held: held),
            turn: terminal.turn,
            seenTurn: seenTurn,
            pinned: terminal.labels["herdr.pinned"].map { !$0.isEmpty } ?? false,
            parent: child,
            depth: 0,
            since: state.since
        )
    }

    /// A parent row is an agent in a shown pane. Its subtree is every live
    /// terminal that reports to it, whether or not that child has a pane or
    /// has said a word yet (an unexplained child is idle).
    private func includedAddresses(_ input: HcAgentInput) -> Set<String> {
        var included = Set(
            input.terminals
                .filter { $0.agentState != nil && input.placed.contains($0.address) }
                .map(\.address)
        )
        var grew = true
        while grew {
            grew = false
            for terminal in input.terminals where terminal.isLive {
                guard let parent = terminal.parent, included.contains(parent),
                      !included.contains(terminal.address) else { continue }
                included.insert(terminal.address)
                grew = true
            }
        }
        return included
    }

    /// Parents before children, each level by pinned then urgency then recency.
    private func flatten(_ candidates: [HcAgent]) -> [HcAgent] {
        let byID = Dictionary(candidates.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        var roots: [HcAgent] = []
        var children: [String: [HcAgent]] = [:]
        for agent in candidates {
            if let parent = agent.parent, byID[parent] != nil {
                children[parent, default: []].append(agent)
            } else {
                roots.append(agent)
            }
        }

        func rollup(_ agent: HcAgent) -> HcAgentStatus {
            var best = agent.status
            for child in children[agent.id] ?? [] {
                let value = rollup(child)
                if value.priority > best.priority { best = value }
            }
            return best
        }

        func sort(_ list: [HcAgent]) -> [HcAgent] {
            list.sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                let left = rollup(lhs).priority
                let right = rollup(rhs).priority
                if left != right { return left > right }
                if lhs.since != rhs.since { return lhs.since > rhs.since }
                return lhs.address < rhs.address
            }
        }

        var ordered: [HcAgent] = []
        func append(_ agent: HcAgent, depth: Int) {
            ordered.append(agent.with(status: rollup(agent), depth: depth))
            for child in sort(children[agent.id] ?? []) {
                append(child, depth: depth + 1)
            }
        }
        for root in sort(roots) {
            append(root, depth: 0)
        }
        return ordered
    }

    /// Child agents' words are quieter than their parent's: a `done` child is
    /// idle, an `error` child is blocked.
    public static func childWord(_ word: String) -> String {
        switch word {
        case "done": "idle"
        case "error": "blocked"
        default: word
        }
    }

    public static func status(
        word: String,
        turn: Int,
        seenTurn: Int?,
        seen: Bool
    ) -> HcAgentStatus {
        switch word {
        case "working": return .working
        case "blocked", "error": return .blocked
        default:
            let unseen = seenTurn.map { turn > $0 } ?? !seen
            return unseen ? .done : .idle
        }
    }

    public static func alert(previous: String?, new: String, looking: Bool) -> HcAgentAlert.Kind? {
        let blocked = Self.blocked(new) && !Self.blocked(previous)
        let wasBusy = Self.busy(previous)
        if blocked { return .blocked }
        if wasBusy, !Self.busy(new), !looking { return .done }
        return nil
    }

    private static func blocked(_ word: String?) -> Bool {
        word == "blocked" || word == "error"
    }

    private static func busy(_ word: String?) -> Bool {
        word == "working" || blocked(word)
    }

    private static func displayName(_ terminal: HcTerminal) -> String {
        let app = terminal.status?["app"]?.stringValue ?? ""
        if !app.isEmpty { return app }
        if !terminal.agent.isEmpty { return terminal.agent }
        return terminal.name
    }

    private static func clean(_ value: String) -> String {
        String(value.drop(while: { !$0.isLetter && !$0.isNumber }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func heldStatus(
        _ status: HcAgentStatus,
        address: String,
        focused: String?,
        held: (address: String, rank: Int)?
    ) -> HcAgentStatus {
        guard status == .idle, address == focused,
              let held, held.address == address, held.rank == HcAgentStatus.done.priority
        else { return status }
        return .done
    }

    private static func place(terminal: HcTerminal, model: KraalModel) -> String {
        guard let pane = model.paneID(ofTerminal: terminal.address),
              let tab = model.tab(ofPane: pane),
              let space = model.space(of: tab.id)
        else { return terminal.address }
        return "\(space.displayName) / \(tab.displayName)"
    }
}

/// Groups the flattened rows into the sidebar's machine sections.
public enum HcAgentGrouping {
    public static func groups(agents: [HcAgent], machines: [HcMachine], localName: String) -> [HcAgentGroup] {
        let visible = machines.filter { !$0.temporary }
        let hidden = Set(machines.filter(\.temporary).map(\.name))
        let known = Set(visible.map(\.name))
        var result: [HcAgentGroup] = [
            HcAgentGroup(
                id: "",
                title: localName.isEmpty ? "This core" : localName,
                subtitle: "this core",
                agents: agents.filter { $0.machine == nil }
            ),
        ]
        for machine in visible {
            result.append(HcAgentGroup(
                id: machine.name,
                title: machine.name,
                subtitle: machine.state.label,
                agents: agents.filter { $0.machine == machine.name },
                machineID: machine.name
            ))
        }
        let orphans = Set(agents.compactMap(\.machine))
            .subtracting(known)
            .subtracting(hidden)
            .sorted()
        for name in orphans {
            result.append(HcAgentGroup(
                id: name,
                title: name,
                subtitle: "not in machine.list",
                agents: agents.filter { $0.machine == name }
            ))
        }
        return result.filter { !$0.agents.isEmpty || $0.id == "" || known.contains($0.id) }
    }

    /// The same rows under space headers, in document order. An agent without
    /// a space (a sub-agent of an unplaced worker) goes last.
    public static func bySpace(agents: [HcAgent], model: KraalModel) -> [HcAgentGroup] {
        var sections: [String: [HcAgent]] = [:]
        var current = ""
        for agent in agents {
            if agent.depth == 0 {
                current = agent.spaceID ?? ""
            }
            sections[current, default: []].append(agent)
        }
        var result: [HcAgentGroup] = []
        for space in model.spaces {
            guard let rows = sections[space.id], !rows.isEmpty else { continue }
            result.append(HcAgentGroup(
                id: "space:\(space.id)",
                title: space.displayName,
                subtitle: "space",
                agents: rows,
                spaceID: space.id
            ))
        }
        if let rows = sections[""], !rows.isEmpty {
            result.append(HcAgentGroup(
                id: "space:none",
                title: "No space",
                subtitle: "workers",
                agents: rows
            ))
        }
        return result
    }
}
