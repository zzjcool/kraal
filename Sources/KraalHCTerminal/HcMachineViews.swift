// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Sidebar sections and the two sheets that edit machines.

import KraalHC
import SwiftUI

struct HcSidebarView: View {
    @ObservedObject var model: HcWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Agents", selection: $model.agentViewMode) {
                ForEach(HcAgentViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .onChange(of: model.agentViewMode) { _, _ in
                model.refreshAgentGroups()
            }
            List(selection: Binding(
                get: { model.selected },
                set: { address in
                    guard let address,
                          let agent = model.agents.first(where: { $0.address == address })
                    else { return }
                    Task { await model.selectAgent(agent) }
                }
            )) {
                ForEach(model.agentGroups) { group in
                    Section {
                        ForEach(group.agents) { agent in
                            agentRow(agent)
                                .tag(agent.address)
                        }
                        if group.agents.isEmpty, let machine = machine(for: group) {
                            Text(machine.state.isConnected ? "no agents" : "no agents yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func agentRow(_ agent: HcAgent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if agent.depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                statusIcon(agent.status)
                Text(primaryLabel(agent))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(agent.isChild ? .regular : .medium)
                if !secondaryLabel(agent).isEmpty {
                    Text("· \(secondaryLabel(agent))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                if agent.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
            }
            HStack(spacing: 6) {
                Text(agent.status.label)
                    .foregroundStyle(statusColor(agent.status))
                if agent.isChild {
                    Text("sub-agent")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if agent.status == .done {
                    Text("turn \(agent.turn)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else if agent.since > 0 {
                    Text(age(agent.since))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
        }
        .padding(.leading, CGFloat(agent.depth) * 12)
        .padding(.vertical, 2)
        .background(
            agent.pane == model.workspace.focusedPane
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(agent.pinned ? "Unpin" : "Pin to top") {
                Task { await model.togglePin(agent) }
            }
            if agent.status == .done, !agent.isChild {
                Button("Mark unread") {
                    Task { await model.markUnread(agent) }
                }
            }
            if agent.isChild {
                Button("Peek") {
                    Task { await model.peek(agent.address) }
                }
            }
        }
    }

    private func primaryLabel(_ agent: HcAgent) -> String {
        if model.agentViewMode == .priority {
            return agent.spaceName.isEmpty ? agent.name : agent.spaceName
        }
        return agent.detail.isEmpty ? agent.name : agent.detail
    }

    private func secondaryLabel(_ agent: HcAgent) -> String {
        guard model.agentViewMode == .priority else { return "" }
        return agent.detail.isEmpty ? "" : agent.detail
    }

    @ViewBuilder
    private func statusIcon(_ status: HcAgentStatus) -> some View {
        switch status {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .idle:
            Image(systemName: "circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 5))
        }
    }

    private func statusColor(_ status: HcAgentStatus) -> Color {
        switch status {
        case .working: .green
        case .blocked: .red
        case .done: .blue
        case .idle: .secondary
        }
    }

    private func age(_ since: UInt64) -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let seconds = max(0, Int(now - since) / 1000)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    private func machine(for group: HcAgentGroup) -> HcMachine? {
        guard let id = group.machineID else { return nil }
        return model.machines.first { $0.name == id }
    }

    @ViewBuilder
    private func groupHeader(_ group: HcAgentGroup) -> some View {
        HStack(spacing: 6) {
            if let machine = machine(for: group) {
                Circle()
                    .fill(color(for: machine.state))
                    .frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 2)
            if let machine = machine(for: group) {
                Menu {
                    machineMenu(machine)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Machine actions")
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func machineMenu(_ machine: HcMachine) -> some View {
        if machine.state != .connected {
            Button("Reconnect") {
                Task { await model.reconnectMachine(machine) }
            }
        }
        if machine.state == .needsLogin {
            Button("Log in…") {
                Task { await model.openLoginTerminal(machine) }
            }
        }
        if machine.state == .needsUpdate {
            Button("Update…") {
                Task { await model.openUpdateTerminal(machine) }
            }
        }
        Divider()
        Button("Rename…") {
            model.machineSheet = .rename(machine)
        }
        Button("Remove…", role: .destructive) {
            model.removingMachine = machine
        }
    }

    private func color(for state: HcMachineState) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .needsLogin, .needsUpdate: .yellow
        case .unreachable: .red
        case .other: .secondary
        }
    }
}

struct HcAddMachineView: View {
    enum Reach: String, CaseIterable, Identifiable {
        case ssh = "SSH"
        case command = "Command"

        var id: String { rawValue }
    }

    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var reach: Reach = .ssh
    @State private var target = ""
    @State private var via = ""
    @State private var name = ""
    @State private var session = ""
    @State private var temporary = false
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a machine").font(.headline)
            Text("The core dials it and keeps it connected; its terminals join this list.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Reach it by", selection: $reach) {
                ForEach(Reach.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if reach == .ssh {
                labeled("SSH target", text: $target, prompt: "can@10.0.0.7:2222 or a Host from ~/.ssh/config")
            } else {
                labeled("Command", text: $via, prompt: "given a shell line as its last argument, like ssh")
            }
            labeled("Name (optional)", text: $name, prompt: "default: the target's host")

            HStack(spacing: 12) {
                labeled("Session (optional)", text: $session, prompt: "default: its default")
                Toggle("Temporary", isOn: $temporary)
                    .toggleStyle(.checkbox)
                    .help("A sandbox for one task: hidden from the sidebar")
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if error != nil {
                    Button("Open a terminal instead…") {
                        Task {
                            await model.openAddTerminal(
                                target: reach == .ssh ? target : nil,
                                via: reach == .command ? via : nil,
                                name: name,
                                session: session,
                                temporary: temporary
                            )
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? "Adding…" : "Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || !isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var isValid: Bool {
        if reach == .ssh {
            return !target.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !via.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        submitting = true
        error = nil
        Task {
            do {
                _ = try await model.addMachine(
                    target: reach == .ssh ? target : nil,
                    via: reach == .command ? via : nil,
                    name: name.isEmpty ? nil : name,
                    session: session.isEmpty ? nil : session,
                    temporary: temporary
                )
                await model.refreshMachines()
                dismiss()
            } catch {
                self.error = HcWorkspaceModel.describe(error)
            }
            submitting = false
        }
    }

    private func labeled(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct HcRenameMachineView: View {
    let machine: HcMachine
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(machine.name)").font(.headline)
            Text("Only this core's name changes. Terminals using the old name\u{2019}s addresses stop working.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("New name", text: $name, prompt: Text(machine.name))
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(submitting ? "Renaming…" : "Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || trimmed.isEmpty || trimmed == machine.name)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = machine.name }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        submitting = true
        error = nil
        Task {
            do {
                try await model.renameMachine(machine, to: trimmed)
                dismiss()
            } catch {
                self.error = HcWorkspaceModel.describe(error)
            }
            submitting = false
        }
    }
}
