// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import KraalModel
import Testing

@testable import KraalHCTerminal

/// OSC 7501 through the real core: status transitions, the shared seen label,
/// pinning, a sub-agent peek, and the rule that a background window writes
/// nothing. Opt-in because it starts a core and PTYs.
///
///     KRAAL_LIVE_HC_TESTS=1 swift test --filter KraalHCTerminalTests.LiveHcAgentTests
@MainActor
@Suite(
    "Live hc agents",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["KRAAL_LIVE_HC_TESTS"] == "1")
)
struct LiveHcAgentTests {
    private struct Core {
        let binary: String
        let root: String
        let variables: [String: String]
    }

    private func binary() -> String? {
        let env = ProcessInfo.processInfo.environment
        return [env["KRAAL_HC_BINARY"], NSHomeDirectory() + "/.local/bin/hc",
                "/opt/homebrew/bin/hc", "/usr/local/bin/hc"]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func env(_ root: String, _ session: String) -> [String: String] {
        var variables = ProcessInfo.processInfo.environment
        variables["HC_SESSION"] = session
        variables["XDG_STATE_HOME"] = root + "/state"
        variables["XDG_CONFIG_HOME"] = root + "/config"
        variables.removeValue(forKey: "HC_SOCKET")
        variables.removeValue(forKey: "XDG_RUNTIME_DIR")
        return variables
    }

    private func run(_ binary: String, _ arguments: [String], _ variables: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = variables
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func waitFor(_ what: String, seconds: Double = 25, _ body: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await body() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentTimeout(what: what)
    }

    private struct AgentTimeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    private func report(_ word: String) -> String {
        #"printf '\033]7501;state=\#(word)\033\\';"#
    }

    @Test("status, seen, pin, and a sub-agent all go through the core")
    func agents() async throws {
        guard let binary = binary() else {
            Issue.record("hc binary not found; set KRAAL_HC_BINARY")
            return
        }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let root = "/tmp/km-agent-\(suffix)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let core = Core(binary: binary, root: root, variables: env(root, "agent-\(suffix)"))
        defer { _ = try? run(binary, ["server", "stop"], core.variables) }

        _ = try run(binary, ["ls", "--json"], core.variables)
        let paths = try HcPaths.resolve(environment: core.variables)
        let workspace = HcWorkspaceModel(
            path: paths.socket,
            viewPath: URL(fileURLWithPath: root + "/view.json")
        )
        var messages: [String] = []
        workspace.log = { messages.append($0) }
        workspace.start()
        defer { workspace.stop() }
        try await waitFor("the core and its layout") {
            guard case .ready = workspace.status else { return false }
            return workspace.workspace.spaces.isEmpty || workspace.workspace.activeSpace != nil
        }

        let client = workspace.client
        await workspace.newTab(name: "agent-\(suffix)")
        try await waitFor("a tab and pane") {
            workspace.workspace.activeTab?.terminals.count == 1 && workspace.paneSessions.count == 1
        }
        let parent = try #require(workspace.workspace.activeTab?.terminals.first)
        _ = try await client.killTerminal(parent)
        try await waitFor("the empty tab", seconds: 10) {
            workspace.workspace.activeSpace == nil
        }

        // The parent agent reports working, blocked, working, done. The app is
        // active and this pane is visible, so each turn is seen once.
        workspace.appActive = true
        let script = [
            report("working"), "sleep 1;",
            report("blocked"), "sleep 2;",
            report("working"), "sleep 1;",
            report("done"), "sleep 30",
        ].joined(separator: " ")
        let agent = try await client.runTerminal(
            line: script,
            labels: ["herdr.space": "sp-agent", "herdr.tab": "tb-agent"],
            name: "status-\(suffix.prefix(4))",
            keep: true
        )
        try await waitFor("the adopted agent") {
            workspace.agents.contains { $0.address == agent.address }
        }
        try await waitFor("working") {
            workspace.agents.first { $0.address == agent.address }?.status == .working
        }
        try await waitFor("blocked") {
            workspace.agents.first { $0.address == agent.address }?.status == .blocked
        }
        #expect(workspace.agentToast?.title.contains("needs you") == true)
        try await waitFor("done") {
            workspace.agents.first { $0.address == agent.address }?.status == .done
        }
        #expect(workspace.agents.first { $0.address == agent.address }?.word == "done")

        // The seen label is the turn the core counted; one write per turn.
        try await waitFor("herdr.seen to reach the turn") {
            guard let record = try? await client.terminal(agent.address),
                  let seen = record.labels["herdr.seen"].flatMap(Int.init)
            else { return false }
            return seen >= record.turn && record.turn > 0
        }
        let record = try await client.terminal(agent.address)
        let seen = try #require(record.labels["herdr.seen"].flatMap(Int.init))
        #expect(seen == record.turn)
        let writes = messages.filter { $0.contains("seen \(agent.address) turn \(record.turn)") }
        #expect(writes.count == 1)

        try await checkPin(workspace: workspace, client: client, address: agent.address)
        try await checkUnread(workspace: workspace, client: client, address: agent.address)

        let quiet = try await checkBackground(workspace: workspace, client: client, suffix: suffix)
        let child = try await checkChild(workspace: workspace, client: client, parent: agent.address, suffix: suffix)

        _ = try? await client.killTerminal(quiet)
        _ = try? await client.killTerminal(child)
        _ = try? await client.killTerminal(agent.address)
    }

    /// Mark unread writes turn - 1; looking at it again writes the full turn.
    private func checkUnread(
        workspace: HcWorkspaceModel,
        client: HcClient,
        address: String
    ) async throws {
        let before = try await client.terminal(address)
        let agent = try #require(workspace.agents.first { $0.address == address })
        workspace.appActive = false
        await workspace.markUnread(agent)
        try await waitFor("turn - 1 in herdr.seen") {
            (try? await client.terminal(address))?.labels["herdr.seen"].flatMap(Int.init) == before.turn - 1
        }
        workspace.appActive = true
        workspace.updateAgents()
        try await waitFor("the full turn after looking again") {
            (try? await client.terminal(address))?.labels["herdr.seen"].flatMap(Int.init) == before.turn
        }
    }

    /// A background window must not write seen for a done agent; foregrounding
    /// it writes the turn.
    private func checkBackground(
        workspace: HcWorkspaceModel,
        client: HcClient,
        suffix: String
    ) async throws -> String {
        workspace.appActive = false
        let quiet = try await client.runTerminal(
            line: [report("working"), "sleep 0.2;", report("done"), "sleep 30"].joined(separator: " "),
            labels: ["herdr.space": "sp-agent", "herdr.tab": "tb-agent"],
            name: "quiet-\(suffix.prefix(4))",
            keep: true
        )
        try await waitFor("the quiet agent") {
            workspace.agents.first { $0.address == quiet.address }?.status == .done
        }
        try await Task.sleep(for: .milliseconds(300))
        let quietRecord = try await client.terminal(quiet.address)
        #expect((quietRecord.labels["herdr.seen"].flatMap(Int.init) ?? 0) < quietRecord.turn)

        workspace.appActive = true
        workspace.updateAgents()
        try await waitFor("seen after foregrounding") {
            guard let record = try? await client.terminal(quiet.address),
                  let seen = record.labels["herdr.seen"].flatMap(Int.init)
            else { return false }
            return seen >= record.turn
        }
        return quiet.address
    }

    /// A child without a pane is under its parent and peeks instead of focusing.
    private func checkChild(
        workspace: HcWorkspaceModel,
        client: HcClient,
        parent: String,
        suffix: String
    ) async throws -> String {
        let child = try await client.runTerminal(
            line: [report("working"), "sleep 0.2;", report("done"), "sleep 30"].joined(separator: " "),
            name: "kid-\(suffix.prefix(4))",
            keep: true,
            parent: parent
        )
        try await waitFor("the child row") {
            workspace.agents.contains { $0.address == child.address && $0.parent == parent }
        }
        let childAgent = try #require(workspace.agents.first { $0.address == child.address })
        #expect(childAgent.depth == 1)
        #expect(childAgent.status == .idle)
        #expect(workspace.workspace.paneID(ofTerminal: child.address) == nil)
        await workspace.selectAgent(childAgent)
        try await waitFor("the peek") {
            workspace.peekAddress == child.address && workspace.peekSession != nil
        }
        workspace.closePeek()
        #expect(workspace.peekAddress == nil)
        return child.address
    }

    private func checkPin(
        workspace: HcWorkspaceModel,
        client: HcClient,
        address: String
    ) async throws {
        let current = try #require(workspace.agents.first { $0.address == address })
        await workspace.togglePin(current)
        try await waitFor("the pinned label") {
            (try? await client.terminal(address))?.labels["herdr.pinned"] == "1"
        }
        try await waitFor("the pinned row first") {
            workspace.agents.first?.address == address && workspace.agents.first?.pinned == true
        }
        await workspace.togglePin(try #require(workspace.agents.first))
        try await waitFor("the unpinned label") {
            let pinned = (try? await client.terminal(address))?.labels["herdr.pinned"]
            return pinned == nil || pinned == ""
        }
    }
}
