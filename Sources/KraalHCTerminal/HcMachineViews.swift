// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Sidebar sections and the two sheets that edit machines.

import KraalHC
import KraalModel
import SwiftUI

/// The 268pt rail: spaces above, agents below, `Settings` / `Add machine` at the
/// bottom. The official window splits the rail into two independently scrolling
/// halves, so this view does too; the root applies the width and the trailing
/// border (docs/audits/2026-11-ui-round1.md §B, contract §2/§5-W3).
struct HcSidebarView: View {
    @ObservedObject var model: HcWorkspaceModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredSpace: String?
    @State private var hoveredAgent: String?
    /// The clock the relative times are drawn against; refreshed every 30 s so a
    /// row goes `1m` → `2m` while nothing else in the window changes.
    @State private var now = HcSidebarView.clock()

    private var colors: HcChromeColors { .forScheme(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            spacesHalf
            agentsHalf
            footer
        }
        .background(colors.chrome)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Self.clock()
            }
        }
    }

    private static func clock() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: Spaces

    /// The upper half: the `Spaces` header with its `+`, then one row per space.
    private var spacesHalf: some View {
        VStack(spacing: 0) {
            sectionHeader("Spaces") {
                IconButton(symbol: "plus", help: "New space") {
                    Task { await model.newSpace() }
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.workspace.spaces) { space in
                        spaceRow(space)
                    }
                }
                .padding(.horizontal, HcChromeMetrics.sidebarRowInset)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func spaceRow(_ space: KraalSpace) -> some View {
        let active = space.id == model.workspace.activeSpace?.id
        let hovering = hoveredSpace == space.id
        return Button {
            model.selectSpace(space.id)
        } label: {
            HStack(spacing: 9) {
                Text(initial(space.displayName))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: HcChromeMetrics.spaceAvatarSize, height: HcChromeMetrics.spaceAvatarSize)
                    .background(
                        avatarColor(space.id),
                        in: RoundedRectangle(cornerRadius: HcChromeMetrics.spaceAvatarRadius)
                    )
                Text(space.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let machine = space.machine, !machine.isEmpty {
                    Text(machine)
                        .font(.system(size: 10))
                        .foregroundStyle(colors.dim)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HcChromeMetrics.sidebarRowHeight)
            .background(
                active ? colors.selected : (hovering ? colors.hover : Color.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            if inside {
                hoveredSpace = space.id
            } else if hoveredSpace == space.id {
                hoveredSpace = nil
            }
        }
        .contextMenu {
            Button("New Tab") { Task { await model.newTab(space: space.id) } }
            Button("Rename Space…") { model.requestRename(space: space.id) }
            Button("Close Space") { Task { await model.closeSpace(space.id) } }
        }
    }

    /// `A` for "api", `?` for a space that has no name yet.
    private func initial(_ name: String) -> String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    /// The space's stable palette color; the palette ships as hex strings.
    private func avatarColor(_ id: String) -> Color {
        let hex = HcSpacePalette.hex(for: id)
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return colors.dim }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            opacity: 1
        )
    }

    // MARK: Agents

    /// The lower half: the `Agents` header with its sort menu, then the sections
    /// (Needs you / Working / Finished / Idle) or one section per space.
    private var agentsHalf: some View {
        VStack(spacing: 0) {
            sectionHeader("Agents") {
                SortMenu(model: model)
            }
            if model.agents.isEmpty {
                Text("No agent status yet. Agents show up here when they report their status. "
                    + "Older versions and agents inside tmux may not.")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(agentSections) { section in
                        sectionHeaderRow(section)
                        ForEach(section.agents) { agent in
                            agentRow(agent)
                        }
                    }
                }
                .padding(.horizontal, HcChromeMetrics.sidebarRowInset)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: model.agentViewMode) { _, _ in
            model.refreshAgentGroups()
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(colors.border)
                .frame(height: 1)
        }
    }

    /// One group of agent rows: a priority section, or a space when the sort menu
    /// says "Grouped by space".
    private struct SectionRows: Identifiable {
        let id: String
        let title: String
        let status: HcAgentStatus?
        let agents: [HcAgent]
    }

    private var agentSections: [SectionRows] {
        if model.agentViewMode == .space {
            return model.agentGroups.map {
                SectionRows(id: $0.id, title: $0.title, status: nil, agents: $0.agents)
            }
        }
        return HcAgentSectioning.sections(model.agents).map {
            SectionRows(id: $0.id, title: $0.title, status: $0.spec.status, agents: $0.agents)
        }
    }

    private func sectionHeaderRow(_ section: SectionRows) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(section.status == .blocked ? colors.blocked : colors.dim)
            Text("\(rootCount(section))")
                .font(.system(size: 11))
                .foregroundStyle(colors.dim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(height: HcChromeMetrics.sidebarRowHeight, alignment: .topLeading)
    }

    /// The official header counts agents, not the sub-agents hanging off them.
    private func rootCount(_ section: SectionRows) -> Int {
        section.agents.filter { $0.depth == 0 }.count
    }

    private func agentRow(_ agent: HcAgent) -> some View {
        let idle = agent.status == .idle
        let selected = model.selected == agent.address
        let hovering = hoveredAgent == agent.address
        return Button {
            Task { await model.selectAgent(agent) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: HcAgentAppIcon.symbol(for: agent.app))
                    .font(.system(size: 13))
                    .foregroundStyle(colors.foreground)
                    .frame(width: 16, height: 16)
                HStack(spacing: 5) {
                    Text(primaryName(agent))
                        .font(.system(size: 13))
                        .foregroundStyle(idle ? colors.muted : colors.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    let secondary = secondaryName(agent)
                    if !secondary.isEmpty {
                        Text("· \(secondary)")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.dim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                if agent.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(colors.dim)
                }
                if agent.since > 0 {
                    Text(HcChromeFormat.relativeTime(sinceMilliseconds: agent.since, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(colors.dim)
                        .lineLimit(1)
                }
                statusGlyph(agent.status)
            }
            .padding(.leading, CGFloat(agent.depth) * 12 + 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: HcChromeMetrics.sidebarRowHeight)
            .background(
                selected ? colors.selected : (hovering ? colors.hover : Color.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            if inside {
                hoveredAgent = agent.address
            } else if hoveredAgent == agent.address {
                hoveredAgent = nil
            }
        }
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

    /// The official priority row names the space ("~"), with the tab/title as
    /// the detail; grouped-by-space rows already have the space as their header,
    /// so they name the tab instead.
    private func primaryName(_ agent: HcAgent) -> String {
        if model.agentViewMode == .priority, !agent.spaceName.isEmpty {
            return agent.spaceName
        }
        return agent.detail.isEmpty ? agent.name : agent.detail
    }

    private func secondaryName(_ agent: HcAgent) -> String {
        model.agentViewMode == .priority ? agent.detail : ""
    }

    @ViewBuilder
    private func statusGlyph(_ status: HcAgentStatus) -> some View {
        switch status {
        case .blocked:
            Text("!")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(colors.blocked)
                .frame(width: 14, height: 14)
                .background(colors.blocked.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(colors.working)
                .frame(width: 12, height: 12)
        case .done:
            Circle()
                .fill(colors.done)
                .frame(width: 7, height: 7)
        case .idle:
            Circle()
                .strokeBorder(colors.idle, lineWidth: 1.5)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: Chrome

    /// A 31pt section header: 16pt leading, 10pt trailing, 11.5 medium dim.
    private func sectionHeader<Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(colors.dim)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: HcChromeMetrics.sidebarHeaderHeight)
    }

    /// 1pt border + 4pt top padding + two 28pt rows + 8pt bottom = the frozen 69.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.border)
                .frame(height: 1)
            VStack(spacing: 0) {
                FooterRow(symbol: "gearshape", title: "Settings", dim: false) {
                    model.showSettings = true
                }
                FooterRow(symbol: "plus", title: "Add machine", dim: true) {
                    model.machineSheet = .add
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .frame(height: HcChromeMetrics.sidebarFooterHeight, alignment: .top)
    }

    /// A 26pt square header button: dim, foreground on hover.
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var colors: HcChromeColors { .forScheme(colorScheme) }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? colors.foreground : colors.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The clock: the official sort menu (Priority / Grouped by space).
private struct SortMenu: View {
    @ObservedObject var model: HcWorkspaceModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var colors: HcChromeColors { .forScheme(colorScheme) }

    private var current: String {
        model.agentViewMode == .priority ? "Priority" : "Grouped by space"
    }

    var body: some View {
        Menu(content: {
            Picker("Sort agents", selection: $model.agentViewMode) {
                Text("Priority").tag(HcAgentViewMode.priority)
                Text("Grouped by space").tag(HcAgentViewMode.space)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }, label: {
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? colors.foreground : colors.dim)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        })
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .onHover { hovering = $0 }
        .help("Sort agents: \(current)")
    }
}

/// One 28pt footer row; `dim` keeps `Add machine` quieter than `Settings`.
private struct FooterRow: View {
    let symbol: String
    let title: String
    let dim: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var colors: HcChromeColors { .forScheme(colorScheme) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? colors.foreground : (dim ? colors.dim : colors.muted))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(hovering ? colors.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
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
