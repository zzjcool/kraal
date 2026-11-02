// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Darwin
import Foundation
import KraalHC
import KraalModel
import Testing

@testable import KraalHCTerminal

/// The real ownership loop: a terminal is started with labels, the model adopts
/// it, a pane attaches, closing kills the program, and a kept worker comes back
/// after its program dies. Opt-in because it starts a core and PTYs.
///
///     KRAAL_LIVE_HC_TESTS=1 swift test --filter KraalHCTerminalTests.LiveHcOwnershipTests
@MainActor
@Suite(
    "Live hc ownership",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["KRAAL_LIVE_HC_TESTS"] == "1")
)
struct LiveHcOwnershipTests {
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
        throw OwnershipTimeout(what: what)
    }

    private struct OwnershipTimeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    @Test("a tab, a split, a close and a kept worker all go through labels and the model")
    func ownership() async throws {
        guard let binary = binary() else {
            Issue.record("hc binary not found; set KRAAL_HC_BINARY")
            return
        }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let root = "/tmp/km-own-\(suffix)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let core = Core(binary: binary, root: root, variables: env(root, "own-\(suffix)"))
        defer { _ = try? run(binary, ["server", "stop"], core.variables) }

        _ = try run(binary, ["ls", "--json"], core.variables)
        let paths = try HcPaths.resolve(environment: core.variables)
        let viewPath = URL(fileURLWithPath: root + "/view.json")
        let workspace = HcWorkspaceModel(path: paths.socket, viewPath: viewPath)
        var messages: [String] = []
        workspace.log = { messages.append($0) }
        workspace.start()
        defer { workspace.stop() }
        try await waitFor("the core and an empty layout") {
            guard case .ready = workspace.status else { return false }
            return workspace.workspace.activeSpace != nil || workspace.workspace.spaces.isEmpty
        }

        let client = workspace.client
        // No document yet: the first tab creates a space and writes version 1.
        await workspace.newTab(name: "first-\(suffix)")
        try await waitFor("the first tab and its attachment") {
            workspace.workspace.activeTab?.terminals.count == 1 && workspace.paneSessions.count == 1
        }
        let firstTab = try #require(workspace.workspace.activeTab)
        let firstSpace = try #require(workspace.workspace.activeSpace)
        let firstAddress = try #require(firstTab.terminals.first)
        let firstRecord = try await client.terminal(firstAddress)
        #expect(firstRecord.labels["herdr.space"] == firstSpace.id)
        #expect((firstRecord.labels["herdr.tab"], firstRecord.labels["herdr.seen"]) == (firstTab.id, "0"))
        #expect(firstRecord.cwd == workspace.workspace.home)
        try await checkStoredTab(client: client, tab: firstTab.id)
        // Adoption marks a terminal keep so a lost program becomes a shell
        // instead of a dead pane; this is the official behavior, not a client
        // choice for terminals the person started.
        try await waitFor("the adopted terminal to be kept") {
            (try? await client.terminal(firstAddress))?.keep == true
        }

        await workspace.splitFocusedPane(.row)
        try await waitFor("the split and both attachments") {
            workspace.workspace.activeTab?.panes.count == 2 && workspace.paneSessions.count == 2
        }
        let tab = try #require(workspace.workspace.activeTab)
        #expect(tab.root.terminals.count == 2)
        for address in tab.terminals {
            let record = try await client.terminal(address)
            #expect(record.labels["herdr.space"] == firstSpace.id)
            #expect(record.labels["herdr.tab"] == firstTab.id)
        }
        try await checkLivePaneRestart(workspace: workspace, client: client)

        // A close that would end both terminals asks once; cancelling keeps them.
        await workspace.closeTab(tab.id)
        #expect(workspace.closeRequest != nil)
        #expect(workspace.workspace.activeTab?.panes.count == 2)
        workspace.closeRequest = nil

        // Closing a pane ends its program, not just the local node.
        let focused = try #require(workspace.workspace.focusedPane)
        let closingAddress = try #require(workspace.workspace.terminal(ofPane: focused))
        await workspace.closeFocusedPane()
        try await waitFor("the pane to close") {
            workspace.workspace.activeTab?.panes.count == 1
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(workspace.workspace.paneID(ofTerminal: closingAddress) == nil)
        try await waitFor("the program to end") {
            if let record = try? await client.terminal(closingAddress) {
                return record.state == "finished" || record.reason == "killed" || record.reason == "exited"
            }
            return true
        }

        let external = try await checkExternal(
            workspace: workspace,
            client: client,
            suffix: suffix,
            keeping: firstSpace.id
        )

        try await checkWorker(workspace: workspace, client: client, suffix: suffix, external: external)

        #expect(messages.contains { $0.contains("layout saved") })
        try await waitFor("the private view file") {
            FileManager.default.fileExists(atPath: viewPath.path)
        }
        try await checkReload(path: paths.socket, viewPath: viewPath)
    }

    /// A second window on the same core must not mistake "no snapshot yet" for
    /// "every pane died" and wipe the document while loading it.
    private func checkReload(path: String, viewPath: URL) async throws {
        let reloaded = HcWorkspaceModel(path: path, viewPath: viewPath)
        reloaded.start()
        defer { reloaded.stop() }
        try await waitFor("the saved layout and its attachment") {
            reloaded.workspace.activeTab != nil && reloaded.paneSessions.count >= 1
        }
        #expect(reloaded.workspace.spaces.count >= 1)
        #expect(reloaded.workspace.activeTab?.terminals.count == 1)
        let document = try await reloaded.client.document("herdr-app")
        #expect(document.version > 0)
    }

    private func checkWorker(
        workspace: HcWorkspaceModel,
        client: HcClient,
        suffix: String,
        external: HcTerminal
    ) async throws {
        // A worker without labels stays out of the layout and in the terminal list.
        let worker = try await client.runTerminal(
            argv: ["sh", "-c", "printf 'WORKER\\n'; sleep 30"],
            name: "worker-\(suffix.prefix(4))"
        )
        try await waitFor("the worker in the flat list") {
            workspace.terminals.contains { $0.address == worker.address }
        }
        #expect(workspace.workspace.paneID(ofTerminal: worker.address) == nil)

        // Keep: the core replaces a lost program with a shell in the same
        // terminal; the model sees live again and reattaches.
        _ = try await client.keepTerminal(worker.address, keep: true)
        let oldPID = try await client.terminal(worker.address).pid
        #expect(oldPID != nil)
        if let oldPID {
            kill(pid_t(oldPID), SIGKILL)
        }
        try await waitFor("the kept worker to come back", seconds: 30) {
            guard let record = try? await client.terminal(worker.address) else { return false }
            return record.state == "live" && record.pid != nil && record.pid != oldPID
        }
        _ = try await client.killTerminal(worker.address)
        _ = try await client.killTerminal(external.address)

    }

    private func checkExternal(
        workspace: HcWorkspaceModel,
        client: HcClient,
        suffix: String,
        keeping activeSpace: String
    ) async throws -> HcTerminal {
        // A terminal started outside the window is adopted by its labels.
        let external = try await client.runTerminal(
            argv: ["sh", "-c", "printf 'EXT\\n'; sleep 30"],
            cwd: "/tmp",
            labels: ["herdr.space": "sp9", "herdr.tab": "tb9"],
            name: "external-\(suffix.prefix(4))"
        )
        try await waitFor("the external terminal to be adopted") {
            workspace.workspace.space("sp9") != nil
        }
        #expect(workspace.workspace.paneID(ofTerminal: external.address) != nil)
        #expect(workspace.workspace.activeSpace?.id == activeSpace)

        return external
    }

    /// A kept pane comes back as a shell and the pane attaches to it again.
    private func checkLivePaneRestart(workspace: HcWorkspaceModel, client: HcClient) async throws {
        let pane = try #require(workspace.workspace.focusedPane)
        let address = try #require(workspace.workspace.terminal(ofPane: pane))
        let oldSession = try #require(workspace.paneSessions[pane])
        try await checkPaneRestart(
            workspace: workspace,
            client: client,
            pane: pane,
            address: address,
            oldSession: oldSession
        )
    }

    private func checkPaneRestart(
        workspace: HcWorkspaceModel,
        client: HcClient,
        pane: String,
        address: String,
        oldSession: HcTerminalSession
    ) async throws {
        let oldPID = try await client.terminal(address).pid
        if let oldPID { kill(pid_t(oldPID), SIGKILL) }
        try await waitFor("the pane terminal to restart", seconds: 30) {
            guard let record = try? await client.terminal(address) else { return false }
            return record.state == "live" && record.pid != nil && record.pid != oldPID
        }
        try await waitFor("the pane to reattach") {
            guard let session = workspace.paneSessions[pane] else { return false }
            return session !== oldSession
        }
    }

    private func checkStoredTab(client: HcClient, tab: String) async throws {
        let document = try await client.document("herdr-app")
        let stored = try #require(document.value)
        let tabs = (stored["spaces"]?.arrayValue ?? [])
            .flatMap { $0["tabs"]?.arrayValue ?? [] }
            .compactMap { $0["id"]?.stringValue }
        #expect(tabs.contains(tab))
    }
}
