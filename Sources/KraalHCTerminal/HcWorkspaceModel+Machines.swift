// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Machine actions: RPC for what core owns, a terminal for what needs a person.
// Split from the workspace model to keep each file about one thing.

import Foundation
import KraalHC

extension HcWorkspaceModel {
    // MARK: Machines

    /// The core has no machine events, so this is polled. 2.5 s is the app's
    /// cadence too: fast enough for a login to show, slow enough to be free.
    public func refreshMachines() async {
        guard client.isConnected else { return }
        do {
            let listed = try await client.machines()
            if listed != machines {
                machines = listed
                let visible = listed.filter { !$0.temporary }.map { "\($0.name):\($0.state.rawValue)" }
                log?("hc: machines \(visible.joined(separator: " "))")
            }
            publish()
            await ensureMachineLayouts()
        } catch {
            log?("hc: machine.list failed: \(error)")
        }
    }

    /// Adds through the RPC. Password/locale prompts need a person, so the
    /// caller offers a terminal fallback (`openAddTerminal`) when this throws.
    @discardableResult
    public func addMachine(
        target: String?,
        via: String?,
        name: String?,
        session: String?,
        temporary: Bool
    ) async throws -> HcMachine {
        let added = try await client.addMachine(
            target: target,
            via: via,
            name: name,
            session: session,
            temporary: temporary
        )
        log?("hc: machine added \(added.name) via \(added.target)")
        await refreshMachines()
        return added
    }

    public func reconnectMachine(_ machine: HcMachine) async {
        do {
            let view = try await client.connectMachine(machine.name)
            log?("hc: machine \(machine.name) \(view.state.rawValue)")
            await refreshMachines()
        } catch {
            machineError = HcWorkspaceModel.describe(error)
        }
    }

    public func renameMachine(_ machine: HcMachine, to newName: String) async throws {
        let renamed = try await client.renameMachine(machine.name, to: newName)
        log?("hc: machine \(machine.name) renamed to \(renamed.name)")
        await refreshMachines()
    }

    public func removeMachine(_ machine: HcMachine) async {
        do {
            try await client.removeMachine(machine.name)
            log?("hc: machine removed \(machine.name)")
            await refreshMachines()
        } catch {
            machineError = HcWorkspaceModel.describe(error)
        }
    }

    /// A login is interactive (password, code, host key); a real terminal is
    /// the only honest place for it. `hc machine login` also reconnects.
    public func openLoginTerminal(_ machine: HcMachine) async {
        await runTerminal(
            ["machine", "login", machine.name],
            name: "login-\(machine.name)"
        )
    }

    /// `machine.update` copies this `hc` to the other side; it has no RPC.
    public func openUpdateTerminal(_ machine: HcMachine) async {
        await runTerminal(
            ["machine", "update", machine.name],
            name: "update-\(machine.name)"
        )
    }

    /// The fallback for anything the RPC cannot show: the CLI can ask questions.
    public func openAddTerminal(
        target: String?,
        via: String?,
        name: String?,
        session: String?,
        temporary: Bool
    ) async {
        var arguments = ["machine", "add"]
        if let via, !via.isEmpty {
            arguments += ["--via", via]
        } else if let target, !target.isEmpty {
            arguments.append(target)
        }
        if let name, !name.isEmpty { arguments += ["--name", name] }
        if let session, !session.isEmpty { arguments += ["--session", session] }
        if temporary { arguments.append("--temp") }
        await runTerminal(arguments, name: "add-\(name ?? "machine")")
    }

    private func runTerminal(_ arguments: [String], name: String) async {
        do {
            let reply = try await client.call("terminal.run", params: .object([
                "argv": .array(([HcWorkspaceModel.hcBinary] + arguments).map { .string($0) }),
                "name": .string(HcWorkspaceModel.terminalName(name)),
            ]))
            if let address = reply["address"]?.stringValue {
                log?("hc: ran \(arguments.joined(separator: " ")) as \(address)")
                // The `created` event also arrives; selecting now makes the
                // terminal visible even if that event races this reply.
                await select(address)
            }
        } catch {
            machineError = "could not run hc: \(HcWorkspaceModel.describe(error))"
        }
    }

    /// `hc` next to the core, or on PATH. A GUI app does not inherit the shell's
    /// PATH, so the usual install locations are checked explicitly.
    public static var hcBinary: String {
        if let explicit = ProcessInfo.processInfo.environment["KRAAL_HC_BINARY"], !explicit.isEmpty {
            return explicit
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/hc",
            "/opt/homebrew/bin/hc",
            "/usr/local/bin/hc",
            "/usr/bin/hc",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "hc"
    }

    /// Terminal names are `1-32 of a-z 0-9 - _`.
    static func terminalName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        var name = raw.lowercased().map { allowed.contains($0) ? $0 : "-" }
        if name.isEmpty { name = Array("machine") }
        return String(name.prefix(32))
    }

    public static func describe(_ error: Error) -> String {
        if let rpc = error as? HcRPCError { return rpc.description }
        return String(describing: error)
    }

    /// Terminals the sidebar shows. A temporary machine's terminals exist but
    /// are hidden; selecting one would load a pane nobody can see in the list.
    public var visibleTerminals: [HcTerminal] {
        groups.flatMap(\.terminals)
    }
}
