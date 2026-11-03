// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The agents half of the window: OSC 7501 status, the shared seen/pinned
// labels, notifications, and the peek stream for a sub-agent.

import AppKit
import Foundation
import KraalHC

extension HcWorkspaceModel {
    /// Rebuilds the sidebar rows after any terminal or layout change.
    ///
    /// `visible` is what the person is actually shown: the panes of the active
    /// tab, plus a peek. That set drives both the done-vs-seen rule and the
    /// `herdr.seen` writes.
    func updateAgents() {
        let placed = Set(workspace.placedTerminals.keys)
        var visible = Set(visiblePaneTerminals().map(\.terminal))
        if let peekAddress { visible.insert(peekAddress) }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let focused = workspace.focusedPane.flatMap { workspace.terminal(ofPane: $0) }
        var input = HcAgentInput(model: workspace)
        input.terminals = terminals
        input.placed = placed
        input.visible = visible
        input.appActive = appActive
        input.seenOverrides = seenOverrides
        input.unread = unreadAgents
        input.focused = focused
        input.now = now
        let result = agentTracker.update(input)
        agents = result.agents
        refreshAgentGroups()
        shareSeen(visible: visible)
        if listedAgents {
            for alert in result.alerts {
                deliver(alert)
            }
        }
        listedAgents = true
    }

    /// Rebuilds the section list after a mode switch without waiting for the
    /// next terminal event.
    public func refreshAgentGroups() {
        agentGroups = agentViewMode == .space
            ? HcAgentGrouping.bySpace(agents: agents, model: workspace)
            : HcAgentGrouping.groups(agents: agents, machines: machines, localName: localName)
    }

    /// Writes `herdr.seen` for what is on screen, once per turn, only upward.
    func shareSeen(visible: Set<String>) {
        guard appActive, !visible.isEmpty else { return }
        unreadAgents.subtract(visible)
        for agent in agents where visible.contains(agent.address) {
            guard agent.turn > 0 else { continue }
            let seen = max(agent.seenTurn ?? 0, seenOverrides[agent.address] ?? 0)
            guard agent.turn > seen else { continue }
            guard (writtenSeen[agent.address] ?? 0) < agent.turn else { continue }
            let turn = agent.turn
            writtenSeen[agent.address] = turn
            seenOverrides[agent.address] = turn
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.client.labelTerminal(
                        agent.address,
                        labels: ["herdr.seen": String(turn)]
                    )
                    self.log?("hc: seen \(agent.address) turn \(turn)")
                } catch {
                    if self.writtenSeen[agent.address] == turn {
                        self.writtenSeen.removeValue(forKey: agent.address)
                        if self.seenOverrides[agent.address] == turn {
                            self.seenOverrides.removeValue(forKey: agent.address)
                        }
                    }
                    self.log?("hc: seen \(agent.address) failed: \(error)")
                }
            }
        }
    }

    /// Pins a row to the top; the label is shared with the official app.
    public func togglePin(_ agent: HcAgent) async {
        let value = agent.pinned ? "" : "1"
        do {
            _ = try await client.labelTerminal(agent.address, labels: ["herdr.pinned": value])
            log?("hc: \(value.isEmpty ? "unpinned" : "pinned") \(agent.address)")
        } catch {
            showToast(title: "Could not pin", detail: String(describing: error), level: .error)
        }
    }

    /// Explicit pin state, for `terminal.pin {pinned}`. `togglePin` is the UI
    /// shortcut; scripts know which state they want.
    public func setPinned(_ address: String, pinned: Bool) async {
        do {
            _ = try await client.labelTerminal(
                address,
                labels: ["herdr.pinned": pinned ? "1" : ""]
            )
            log?("hc: \(pinned ? "pinned" : "unpinned") \(address)")
        } catch {
            showToast(title: "Could not pin", detail: String(describing: error), level: .error)
        }
    }

    /// Marks a finished agent unread by writing `turn - 1`; the next look at it
    /// writes the full turn again.
    public func markUnread(_ agent: HcAgent) async {
        guard agent.turn > 0 else { return }
        let value = agent.turn - 1
        let previousOverride = seenOverrides[agent.address]
        let previousWritten = writtenSeen[agent.address]
        unreadAgents.insert(agent.address)
        seenOverrides[agent.address] = value
        writtenSeen[agent.address] = value
        do {
            _ = try await client.labelTerminal(
                agent.address,
                labels: ["herdr.seen": String(value)]
            )
            log?("hc: unread \(agent.address) turn \(value)")
        } catch {
            unreadAgents.remove(agent.address)
            seenOverrides[agent.address] = previousOverride
            writtenSeen[agent.address] = previousWritten
            showToast(title: "Could not mark unread", detail: String(describing: error), level: .error)
        }
    }

    /// A row click: a sub-agent opens a peek, a pane focuses its own terminal,
    /// and a worker without a pane is shown in the peek surface.
    public func selectAgent(_ agent: HcAgent) async {
        selected = agent.address
        if agent.isChild || agent.pane == nil {
            await peek(agent.address)
        } else if let pane = agent.pane {
            focusPane(pane)
        }
    }

    /// Opens a sub-agent beside the layout without moving focus.
    public func peek(_ address: String) async {
        if peekAddress == address, peekSession != nil { return }
        closePeek()
        do {
            let session = try await HcTerminalSession.open(client: client, terminal: address)
            guard client.isConnected else {
                session.close()
                return
            }
            peekSession = session
            peekAddress = address
            updateAgents()
            log?("hc: peek \(address)")
        } catch {
            showToast(title: "Could not peek", detail: String(describing: error), level: .error)
        }
    }

    func closePeek() {
        peekSession?.close()
        peekSession = nil
        peekAddress = nil
    }

    private func deliver(_ alert: HcAgentAlert) {
        let toast = HcAgentToast(
            title: alert.title,
            detail: alert.detail,
            level: alert.kind == .blocked ? .error : .info
        )
        agentToast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.agentToast?.id == toast.id else { return }
            self?.agentToast = nil
        }
        // A test process has no running app to show a notification; the toast
        // and log are still enough there.
        guard NSApp != nil else { return }
        let notification = NSUserNotification()
        notification.title = alert.title
        notification.informativeText = alert.detail
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    func showToast(title: String, detail: String, level: HcAgentToast.Level) {
        let toast = HcAgentToast(title: title, detail: detail, level: level)
        agentToast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.agentToast?.id == toast.id else { return }
            self?.agentToast = nil
        }
    }
}
