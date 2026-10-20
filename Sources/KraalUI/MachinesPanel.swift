// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Machine management: the list, the add form, and the destructive actions.
//
// Everything here runs against `HerdrMachineClient`, which shells out to the
// same `herdr machine …` commands a user would type. There is no daemon
// equivalent — see that file for why.
//
// Three interactions shape the design:
//
//   * `machine add` really does open SSH and can take seconds, so every write
//     goes through a Task that runs off the main actor and reports failure in the
//     panel instead of freezing it.
//   * `machine add` is also the only thing that *verifies* a host. A machine that
//     cannot be reached is not saved, which is why the add form stays open on
//     error rather than optimistically inserting a row.
//   * Remove and disable are confirmed first. Both are one keystroke away from a
//     list row, and getting either back requires a working SSH connection.

import KraalTransport
import SwiftUI

@MainActor
@Observable
public final class MachinesStore {
    public private(set) var machines: [HerdrMachine] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// Set while a write is in flight; the UI disables its controls with this.
    public private(set) var isBusy = false
    /// Whether the CLI could be found at all. Distinguishes "no machines saved"
    /// from "cannot ask", which would otherwise both render as an empty list.
    public private(set) var available: Bool

    private let client: HerdrMachineClient?

    public init(client: HerdrMachineClient? = HerdrMachineClient.discover()) {
        self.client = client
        self.available = client != nil
    }

    public func reload() {
        guard let client else {
            available = false
            kraalLog("machines: herdr CLI not found")
            return
        }
        kraalLog("machines: list via \(client.executable.path)")
        isLoading = true
        error = nil
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try client.list()
                }.value
                self.machines = loaded.sorted { lhs, rhs in
                    if (lhs.selected ?? false) != (rhs.selected ?? false) {
                        return lhs.selected ?? false
                    }
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                self.isLoading = false
                // Proves the UI holds real CLI data, not a stub: label + id of
                // every machine the panel is showing.
                kraalLog("machines: loaded \(loaded.count) -> "
                    + loaded.map { "\($0.label)[\($0.id.prefix(8))]" }.joined(separator: ", "))
            } catch {
                self.error = String(describing: error)
                self.isLoading = false
                kraalLog("machines: list failed \(error)")
            }
        }
    }

    public func add(target: String, label: String, remoteSession: String, done: @escaping (Bool) -> Void) {
        guard let client else { return }
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else {
            error = "An SSH target is required."
            done(false)
            return
        }
        perform(done: done) {
            try client.add(
                target: trimmedTarget,
                label: label.isEmpty ? nil : label,
                remoteSession: remoteSession.isEmpty ? nil : remoteSession
            )
        }
    }

    public func rename(_ machine: HerdrMachine, to label: String, done: ((Bool) -> Void)? = nil) {
        guard let client else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != machine.label else {
            done?(true)
            return
        }
        perform(done: done) {
            try client.rename(id: machine.id, label: trimmed)
        }
    }

    public func setEnabled(_ machine: HerdrMachine, enabled: Bool, done: ((Bool) -> Void)? = nil) {
        guard let client else { return }
        perform(done: done) {
            try client.setEnabled(id: machine.id, enabled: enabled)
        }
    }

    public func remove(_ machine: HerdrMachine, done: ((Bool) -> Void)? = nil) {
        guard let client else { return }
        perform(done: done) {
            try client.remove(id: machine.id)
        }
    }

    /// Runs a mutation off the main actor, then reloads the list from the CLI.
    ///
    /// The reload is not a nicety: `herdr machine` rewrites its own config, and
    /// fields the UI does not set (the default-selected machine, the session
    /// name) are only visible by asking again. Reporting what we hoped happened
    /// would drift from what is on disk.
    private func perform(done: ((Bool) -> Void)?, _ work: @escaping @Sendable () throws -> Void) {
        guard let client else { return }
        kraalLog("machines: mutation via \(client.executable.path)")
        isBusy = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try work() }.value
                self.isBusy = false
                self.reload()
                done?(true)
            } catch {
                self.error = String(describing: error)
                self.isBusy = false
                done?(false)
            }
        }
    }
}

// MARK: - Panel

public struct MachinesPanel: View {
    @State private var store = MachinesStore()
    @State private var showingAdd = false
    @State private var didRunDemo = false
    @State private var renaming: HerdrMachine?
    @State private var confirmingRemove: HerdrMachine?
    @State private var confirmingDisable: HerdrMachine?

    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 460)
        // Sheets in this app are hosted in their own `NSWindow`, so a
        // behind-window material here samples the desktop rather than the main
        // window — which is what makes the panel read as a floating pane of glass.
        .glassChrome(.sheet, rim: false)
        .onAppear {
            store.reload()
            runDemoIfRequested()
        }
        .sheet(isPresented: $showingAdd) {
            AddMachineSheet(store: store) { showingAdd = false }
        }
        .sheet(item: $renaming) { machine in
            RenameMachineSheet(store: store, machine: machine) { renaming = nil }
        }
        .alert(
            "Remove “\(confirmingRemove?.displayLabel ?? "")”?",
            isPresented: Binding(
                get: { confirmingRemove != nil },
                set: { if !$0 { confirmingRemove = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmingRemove = nil }
            Button("Remove", role: .destructive) {
                if let machine = confirmingRemove {
                    store.remove(machine)
                }
                confirmingRemove = nil
            }
        } message: {
            Text("The saved SSH machine is deleted. Re-adding it requires a working "
                + "SSH connection to \(confirmingRemove?.target ?? "").")
        }
        .alert(
            "Disable “\(confirmingDisable?.displayLabel ?? "")”?",
            isPresented: Binding(
                get: { confirmingDisable != nil },
                set: { if !$0 { confirmingDisable = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmingDisable = nil }
            Button("Disable") {
                if let machine = confirmingDisable {
                    store.setEnabled(machine, enabled: false)
                }
                confirmingDisable = nil
            }
        } message: {
            Text("A disabled machine stays saved but is hidden from the sidebar and "
                + "skipped when connecting.")
        }
    }

    /// Drives the panel's own buttons from an env var, for scripted demos.
    ///
    /// It calls the same `MachinesStore` methods the buttons call, in the same
    /// order, with the same labels — the only thing skipped is the mouse. Used to
    /// produce the demo artifacts without a human clicking.
    private func runDemoIfRequested() {
        guard !didRunDemo,
              ProcessInfo.processInfo.environment["KRAAL_MACHINES_DEMO"] == "1" else { return }
        didRunDemo = true
        kraalLog("machines-demo: start")
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                let label = store.machines.first?.label ?? "(none)"
                kraalLog("machines-demo: visible=\(store.machines.count) first=\(label)")
            }
            guard let machine = await MainActor.run(body: { store.machines.first }) else {
                await MainActor.run { kraalLog("machines-demo: nothing to operate on") }
                return
            }
            await MainActor.run {
                kraalLog("machines-demo: rename \(machine.label) -> \(machine.label)-renamed")
                store.rename(machine, to: machine.label + "-renamed")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                let now = store.machines.first?.label ?? "(none)"
                kraalLog("machines-demo: after rename first=\(now)")
                if let current = store.machines.first {
                    kraalLog("machines-demo: disable \(current.label)")
                    store.setEnabled(current, enabled: false)
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                let enabled = store.machines.first?.enabled ?? false
                kraalLog("machines-demo: after disable enabled=\(enabled)")
                if let current = store.machines.first {
                    kraalLog("machines-demo: enable \(current.label)")
                    store.setEnabled(current, enabled: true)
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                let enabled = store.machines.first?.enabled ?? false
                kraalLog("machines-demo: after enable enabled=\(enabled) — leaving profile in place")
                kraalLog("machines-demo: done")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            Text("Machines")
                .font(.headline)
            if store.isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload from herdr")
            .disabled(store.isLoading || !store.available)

            Button {
                showingAdd = true
            } label: {
                Label("Add Machine", systemImage: "plus")
            }
            .disabled(!store.available || store.isBusy)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.base)
    }

    @ViewBuilder
    private var content: some View {
        if !store.available {
            unavailableNotice
        } else if let error = store.error, store.machines.isEmpty {
            errorNotice(error)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isLoading && store.machines.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading machines…").foregroundStyle(.secondary)
                    }
                    .padding(14)
                } else if store.machines.isEmpty {
                    Text("No saved machines yet.")
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
                ForEach(store.machines) { machine in
                    MachineRow(
                        machine: machine,
                        busy: store.isBusy,
                        onRename: { renaming = machine },
                        onToggleEnabled: {
                            if machine.enabled {
                                confirmingDisable = machine
                            } else {
                                store.setEnabled(machine, enabled: true)
                            }
                        },
                        onRemove: { confirmingRemove = machine }
                    )
                    Divider().opacity(0.3)
                }
                if let error = store.error, !store.machines.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("herdr was not found")
                .font(.headline)
            Text("Machine profiles belong to the Herdr CLI, which keeps them in its own "
                + "config. Install herdr, or point KRAAL_HERDR_BIN at it, then reopen this panel.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("KRAAL_HERDR_BIN=/path/to/herdr")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func errorNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Could not read machines").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Try Again") { store.reload() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Text("\(store.machines.count) saved · managed by the herdr CLI")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.base)
    }
}

// MARK: - Row

private struct MachineRow: View {
    let machine: HerdrMachine
    let busy: Bool
    let onRename: () -> Void
    let onToggleEnabled: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: machine.enabled ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .foregroundStyle(machine.enabled ? Color.secondary : Color.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(machine.displayLabel)
                        .font(KraalTheme.Font.rowTitle)
                        .fontWeight(.medium)
                    if machine.selected == true {
                        Text("default")
                            .font(KraalTheme.Font.micro)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.selection, in: Capsule())
                    }
                    if !machine.enabled {
                        Text("disabled")
                            .font(KraalTheme.Font.micro)
                            .foregroundStyle(.orange)
                    }
                }
                Text(machine.target)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let session = machine.session, !session.isEmpty, session != "default" {
                    Text("session \(session)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { machine.enabled },
                set: { _ in onToggleEnabled() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(busy)
            .help(machine.enabled ? "Disable this machine" : "Enable this machine")

            Button("Rename", action: onRename)
                .buttonStyle(.borderless)
                .disabled(busy)
            Button("Remove", action: onRemove)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(busy)
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.snug)
        .opacity(machine.enabled ? 1 : 0.65)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…", action: onRename)
            Button(machine.enabled ? "Disable" : "Enable", action: onToggleEnabled)
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

// MARK: - Add

private struct AddMachineSheet: View {
    let store: MachinesStore
    let onClose: () -> Void

    @State private var target = ""
    @State private var label = ""
    @State private var remoteSession = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Machine").font(.headline)
            Text("Herdr prepares the remote server over SSH before saving, so this can take "
                + "a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                TextField("SSH target", text: $target, prompt: Text("ssh://user@host:port"))
                TextField("Label", text: $label, prompt: Text("optional — shown in the sidebar"))
                TextField("Remote session", text: $remoteSession, prompt: Text("optional — defaults to default"))
            }
            .formStyle(.grouped)
            .frame(height: 130)

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    store.add(target: target, label: label, remoteSession: remoteSession) { succeeded in
                        if succeeded {
                            onClose()
                        } else {
                            failure = store.error
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isBusy || target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(KraalTheme.Space.loose)
        .frame(width: 480)
        .glassChrome(.sheet, rim: false)
    }
}

// MARK: - Rename

private struct RenameMachineSheet: View {
    let store: MachinesStore
    let machine: HerdrMachine
    let onClose: () -> Void

    @State private var label: String
    @State private var failure: String?

    init(store: MachinesStore, machine: HerdrMachine, onClose: @escaping () -> Void) {
        self.store = store
        self.machine = machine
        self.onClose = onClose
        _label = State(initialValue: machine.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Machine").font(.headline)
            Text(machine.target)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isBusy || label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(KraalTheme.Space.loose)
        .frame(width: 380)
        .glassChrome(.sheet, rim: false)
    }

    private func commit() {
        store.rename(machine, to: label) { succeeded in
            if succeeded {
                onClose()
            } else {
                failure = store.error
            }
        }
    }
}
