// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The 26pt strip under the work column: which machine the active space runs on,
// how many agents report and how many of them need a person, and the palette
// hint. Since the sidebar is a space/agent list, this label is also the one
// place the window offers machine actions besides `Add machine`.

import KraalHC
import SwiftUI

struct HcStatusBarView: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var hcTheme
    @State private var hoveringHint = false

    private var colors: HcChromeColors { HcChromeColors(theme: hcTheme) }
    private var activeMachine: String? { model.workspace.activeSpace?.machine }

    /// The status bar counts what a person counts: one row per agent, not one
    /// per sub-agent. A root's status is already the rollup of its children.
    private var rootAgents: [HcAgent] { model.agents.filter { $0.depth == 0 } }
    private var needsYou: Int { rootAgents.filter { $0.status == .blocked }.count }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.border)
                .frame(height: 1)
            HStack(spacing: 16) {
                machineLabel
                agentSummary
                Spacer(minLength: 8)
                paletteHint
            }
            .font(.system(size: 11.8))
            .foregroundStyle(colors.muted)
            .padding(.horizontal, 14)
            .frame(height: HcChromeMetrics.statusBarHeight)
        }
        .background(colors.chrome)
    }

    // MARK: - Machine

    private var machineLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: activeMachine == nil ? "laptopcomputer" : "server")
                .font(.system(size: 13))
            Text(activeMachine ?? "This computer")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .contextMenu { machineMenu }
    }

    @ViewBuilder
    private var machineMenu: some View {
        ForEach(model.machines) { machine in
            Menu("\(machine.name) — \(machine.state.label)") {
                machineActions(machine)
            }
        }
        if !model.machines.isEmpty {
            Divider()
        }
        Button("Add machine…") { model.machineSheet = .add }
    }

    /// The same four fixes the sidebar's machine header used to offer: what core
    /// can do over RPC, and a terminal for what needs a person.
    @ViewBuilder
    private func machineActions(_ machine: HcMachine) -> some View {
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
        Button("Rename…") { model.machineSheet = .rename(machine) }
        Button("Remove…", role: .destructive) { model.removingMachine = machine }
    }

    // MARK: - Agents

    private var agentSummary: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(colors.dim)
                .frame(width: 6, height: 6)
            Text(HcChromeFormat.agentsLabel(rootAgents.count))
            if needsYou > 0 {
                Text("· \(HcChromeFormat.needsYouLabel(needsYou))")
                    .foregroundStyle(colors.blocked)
            }
        }
    }

    // MARK: - Palette hint

    /// Plain text on purpose: a `Menu` here would draw a bezel and an arrow the
    /// official status bar does not have.
    private var paletteHint: some View {
        Button {
            model.showPalette = true
        } label: {
            Text(HcChromeFormat.commandsHint)
                .foregroundStyle(hoveringHint ? colors.foreground : colors.dim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hoveringHint = $0 }
        .keyboardShortcut("p", modifiers: .command)
        .help("Open the command palette")
    }
}
