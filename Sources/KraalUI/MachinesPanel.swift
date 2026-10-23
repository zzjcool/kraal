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
    public private(set) var machines: [MachineEntry] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// Set while a write is in flight; the UI disables its controls with this.
    public private(set) var isBusy = false
    /// Whether the CLI could be found at all. Distinguishes "no machines saved"
    /// from "cannot ask", which would otherwise both render as an empty list.
    public private(set) var available: Bool

    private let client: HerdrMachineClient?
    /// How this Mac is labelled and reached. Held here so the roster always has
    /// a local row even when the CLI is missing or the remote list fails.
    private let local: LocalMachineDescriptor
    /// Fired after a write lands. The store owns no connection and cannot refresh
    /// the sidebar itself; this is the only signal that the saved profiles on
    /// disk, and therefore the sidebar's machine list, just changed.
    public var onProfilesChanged: (() -> Void)?

    public init(
        client: HerdrMachineClient? = HerdrMachineClient.discover(),
        local: LocalMachineDescriptor = .resolve()
    ) {
        self.client = client
        self.local = local
        self.available = client != nil
        // Seed the roster with this Mac immediately. `herdr machine list` only
        // returns SSH profiles — the local daemon is implicit and never appears
        // in it — so without this seed the panel's first frame, and every frame
        // when herdr is not installed, shows a machine list with this Mac
        // missing. Seeding also means a failed `list` cannot drop it.
        self.machines = [.local(local)]
    }

    public func reload() {
        guard let client else {
            available = false
            // Keep this Mac visible: it is reachable without the CLI, and it is
            // the one entry a user can always connect to.
            machines = MachineRoster.compose(local: local, remote: [])
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
                let sorted = loaded.sorted { lhs, rhs in
                    if (lhs.selected ?? false) != (rhs.selected ?? false) {
                        return lhs.selected ?? false
                    }
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                self.machines = MachineRoster.compose(local: self.local, remote: sorted)
                self.isLoading = false
                // Proves the UI holds real CLI data, not a stub: label + id of
                // every machine the panel is showing, local row included.
                kraalLog("machines: loaded \(loaded.count) remote + 1 local -> "
                    + self.machines.map { "\($0.displayLabel)[\($0.id.prefix(8))]" }
                        .joined(separator: ", "))
            } catch {
                self.error = String(describing: error)
                // The local row survives a failed read, so the panel never
                // claims there are zero machines when this Mac is right here.
                self.machines = MachineRoster.compose(local: self.local, remote: [])
                self.isLoading = false
                kraalLog("machines: list failed \(error)")
            }
        }
    }

    /// Footer text: how many entries the roster has, and where they come from.
    ///
    /// The local row is described separately because it is not a saved profile and
    /// is not managed by the CLI — saying "6 saved · managed by the herdr CLI" while
    /// showing 7 rows was the visible half of this bug.
    public var footerSummary: String {
        let saved = machines.filter { !$0.isLocal }.count
        let hasLocal = machines.contains(where: \.isLocal)
        let savedText = saved == 1 ? "1 saved machine" : "\(saved) saved machines"
        guard hasLocal else { return "\(savedText) · managed by the herdr CLI" }
        return "This Mac + \(savedText) · managed by the herdr CLI"
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
            let output = try client.add(
                target: trimmedTarget,
                label: label.isEmpty ? nil : label,
                remoteSession: remoteSession.isEmpty ? nil : remoteSession
            )
            kraalLog(addReport(
                target: trimmedTarget,
                session: remoteSession.isEmpty ? HerdrDiscovery.defaultSession : remoteSession,
                output: output
            ))
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
                // After the reload, so a listener that re-reads the catalog sees
                // the same list this panel is about to draw.
                self.onProfilesChanged?()
                done?(true)
            } catch {
                self.error = String(describing: error)
                self.isBusy = false
                done?(false)
            }
        }
    }
}

/// The log line written after a machine is added, holding the CLI's text verbatim.
///
/// Issue #70 wanted "this session did not exist, it was just created" to be
/// visible. That fact is **not** in the CLI's output, so it is not inferred here:
///
///  - every successful `machine add` prints the same two lines
///    (`Saved SSH machine <id>. Remote server is ready.` / `Open Herdr clients
///    connect automatically.` — herdr 0.9.5 `src/cli/machine.rs:388-389`);
///  - with `--remote-session` supplied, the CLI never queries the remote's
///    session list first (that happens only when the flag is omitted *and* stdin
///    is a terminal), so it does not know either;
///  - the session is created by `remote-client-bridge` on the remote side, whose
///    output is consumed as a status probe and never printed.
///
/// So the raw text is recorded instead of a guess. A wrong "session was just
/// created" banner would be exactly the kind of confident-but-unfounded claim
/// this repository keeps paying for.
func addReport(target: String, session: String, output: String) -> String {
    // Every line the CLI printed is kept; newlines are folded to ` | ` so the
    // entry stays one line per event in the log file.
    let lines = output
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let body = lines.isEmpty ? "<herdr said nothing>" : lines.joined(separator: " | ")
    return "machines: add \(target) session=\(session) -> \(body)"
}

// MARK: - Panel

public struct MachinesPanel: View {
    @State private var store: MachinesStore
    @State private var showingAdd = false
    @State private var renaming: HerdrMachine?
    @State private var confirmingRemove: HerdrMachine?
    @State private var confirmingDisable: HerdrMachine?

    private let onClose: () -> Void
    /// Called after any write (add / rename / enable / disable / remove) lands.
    /// The panel talks to the herdr CLI directly and owns no connection, so it
    /// cannot refresh the sidebar by itself — without this the sidebar kept
    /// showing the pre-edit roster until the next launch.
    private let onProfilesChanged: () -> Void
    /// Whether this panel is a pane of something larger (the settings window)
    /// rather than a sheet of its own. Embedded, it gives up the fixed frame, the
    /// sheet material and the Done button — all three belong to the host.
    private let embedded: Bool

    /// `target` is the connection the app is actually on, so the local row shows
    /// the same name the sidebar does. Defaulting to `.local` here instead would
    /// label a sandbox connection "This Mac" while the sidebar called it
    /// "sandbox" — one machine, two names, which is how this panel drifted from
    /// the sidebar in the first place.
    public init(
        target: ConnectionSettings = .local,
        embedded: Bool = false,
        onClose: @escaping () -> Void,
        onProfilesChanged: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
        self.onProfilesChanged = onProfilesChanged
        self.embedded = embedded
        let store = MachinesStore(local: LocalMachineDescriptor.resolve(settings: target))
        store.onProfilesChanged = onProfilesChanged
        _store = State(initialValue: store)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Embedded, the tab bar is the header: the row below would be a strip
            // of empty space holding two buttons that sit better in the footer.
            if !embedded {
                header
                Divider()
            }
            content
            Divider()
            footer
        }
        // Embedded, the host supplies the frame; standalone, this is the sheet's
        // own size. `if` rather than a zero-or-size frame: an embedded panel that
        // still demanded 640x460 would fight whatever the settings window picks.
        .modifier(PanelChrome(embedded: embedded))
        .onAppear {
            store.reload()
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

    private var header: some View {
        HStack(spacing: 10) {
            // Embedded, the settings tab bar already names this pane: repeating
            // the title here stacks two "Machines" labels a few points apart. The
            // action buttons stay either way — they are the reason this row
            // exists at all.
            if !embedded {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text("Machines")
                    .font(.headline)
            }
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
        // Embedded, this row holds only buttons; it does not need the breathing
        // room a titled header does, and the tab bar above already separates it
        // from the window chrome.
        .padding(.vertical, embedded ? KraalTheme.Space.snug : KraalTheme.Space.base)
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
                ForEach(store.machines) { entry in
                    MachineRow(
                        entry: entry,
                        busy: store.isBusy,
                        onRename: { if let machine = entry.machine { renaming = machine } },
                        onToggleEnabled: {
                            guard let machine = entry.machine else { return }
                            if machine.enabled {
                                confirmingDisable = machine
                            } else {
                                store.setEnabled(machine, enabled: true)
                            }
                        },
                        onRemove: { if let machine = entry.machine { confirmingRemove = machine } }
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
        HStack(spacing: 10) {
            // Counts the whole roster, not just the saved profiles: "1 saved"
            // next to a visible this-Mac row would read as a contradiction.
            Text(store.footerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Embedded, the header is gone (the tab bar replaces it), so the two
            // actions it held live here instead. Refreshing and adding are still
            // reachable; they just no longer cost a whole strip at the top.
            if embedded {
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
            } else {
                // No Done button when embedded: the settings window is closed the
                // way every other window is. Keeping it would also claim Return as
                // a window-closing chord, which is wrong inside a tab.
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.base)
    }
}

// MARK: - Row

private struct MachineRow: View {
    let entry: MachineEntry
    let busy: Bool
    let onRename: () -> Void
    let onToggleEnabled: () -> Void
    let onRemove: () -> Void

    var body: some View {
        // This Mac is not a saved profile, so it gets no write controls: there is
        // no `herdr machine` command that could rename, disable or remove it, and
        // showing buttons that would fail is worse than showing none. It keeps the
        // same row shape so the roster reads as one list.
        let machine = entry.machine

        HStack(spacing: 10) {
            Image(systemName: entry.isLocal
                ? "laptopcomputer"
                : (entry.enabled ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark"))
                .foregroundStyle(entry.isLocal ? Color.accentColor : (entry.enabled ? Color.secondary : Color.orange))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayLabel)
                        .font(KraalTheme.Font.rowTitle)
                        .fontWeight(.medium)
                    if entry.isLocal {
                        Text("this Mac")
                            .font(KraalTheme.Font.micro)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.selection, in: Capsule())
                    } else if machine?.selected == true {
                        Text("default")
                            .font(KraalTheme.Font.micro)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.selection, in: Capsule())
                    }
                    if !entry.enabled {
                        Text("disabled")
                            .font(KraalTheme.Font.micro)
                            .foregroundStyle(.orange)
                    }
                }
                Text(entry.targetDescription)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let session = machine?.session, !session.isEmpty, session != "default" {
                    Text("session \(session)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.isLocal {
                Text("local")
                    .font(KraalTheme.Font.micro)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("", isOn: Binding(
                    get: { entry.enabled },
                    set: { _ in onToggleEnabled() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(busy)
                .help(entry.enabled ? "Disable this machine" : "Enable this machine")

                Button("Rename", action: onRename)
                    .buttonStyle(.borderless)
                    .disabled(busy)
                Button("Remove", action: onRemove)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(busy)
            }
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.snug)
        .opacity(entry.enabled ? 1 : 0.65)
        .contentShape(Rectangle())
        .contextMenu {
            // Driven by `entry.menuActions`, which is tested to be non-empty for
            // every row. A `.contextMenu` whose body renders nothing still installs
            // a menu, and AppKit then opens an empty one — a right-click that looks
            // like a broken menu. This Mac's row used to do exactly that.
            ForEach(entry.menuActions, id: \.self) { action in
                switch action {
                case .copySocketPath:
                    Button("Copy Socket Path") { copy(entry.targetDescription) }
                case .copyLabel:
                    Button("Copy Label") { copy(entry.displayLabel) }
                case .rename:
                    Button("Rename…", action: onRename)
                case .toggleEnabled:
                    Button(entry.enabled ? "Disable" : "Enable", action: onToggleEnabled)
                case .remove:
                    Divider()
                    Button("Remove", role: .destructive, action: onRemove)
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

// MARK: - Chrome

/// The frame and material the machines list gets from its host.
///
/// Split out because the two hosts want opposite things: a sheet owns its own
/// glass and a fixed size, while a settings tab must fill whatever space the
/// window gives it and must not paint a second behind-window material inside an
/// already-material-backed window (that would sample the desktop twice and read
/// as a grey rectangle).
private struct PanelChrome: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .frame(width: 640, height: 460)
                // Sheets in this app are hosted in their own `NSWindow`, so a
                // behind-window material here samples the desktop rather than the
                // main window — which is what makes the panel read as a floating
                // pane of glass.
                .glassChrome(.sheet, rim: false)
        }
    }
}
