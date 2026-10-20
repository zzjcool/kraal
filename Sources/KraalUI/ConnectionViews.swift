// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Connection settings, plus the states that need explaining: a daemon that is
// too old, a codec mismatch, or a socket that is not there.

import KraalProtocol
import KraalTransport
import SwiftUI
import KraalSidebar

struct ConnectionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionSettings
    @State private var discoveredSessions: [String] = []

    init(store: AppStore) {
        _draft = State(initialValue: store.target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection")
                .font(.title3.weight(.semibold))

            Picker("Transport", selection: $draft.transport) {
                Text("This Mac").tag(HerdrTransportKind.local)
                Text("SSH").tag(HerdrTransportKind.ssh)
            }
            .pickerStyle(.segmented)

            switch draft.transport {
            case .local:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Socket")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(localSocketDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            case .ssh:
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Host").font(.caption).foregroundStyle(.secondary)
                        TextField("server.example.com", text: $draft.sshHost)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("User").font(.caption).foregroundStyle(.secondary)
                        TextField("optional", text: Binding(
                            get: { draft.sshUser ?? "" },
                            set: { draft.sshUser = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Port").font(.caption).foregroundStyle(.secondary)
                        TextField("22", text: Binding(
                            get: { draft.sshPort.map(String.init) ?? "" },
                            set: { draft.sshPort = UInt16($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    }
                }
                Text("Uses your `~/.ssh/config` and keys; the bridge runs `herdr remote-client-bridge` "
                    + "on the host, so no port forwarding is involved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Session").font(.caption).foregroundStyle(.secondary)
                TextField("default", text: $draft.session)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            if case let .failed(reason) = store.phase {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(sidebarColor("red"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Use This Mac") {
                    draft = .local
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    store.target = draft
                    store.connect()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding(KraalTheme.Space.loose)
        .frame(width: 460)
        .glassChrome(.sheet, rim: false)
    }

    private var canConnect: Bool {
        switch draft.transport {
        case .local: return true
        case .ssh: return !draft.sshHost.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var localSocketDescription: String {
        guard let path = try? HerdrDiscovery.sessionSocket(name: draft.session) else {
            return "Invalid session name"
        }
        let exists = FileManager.default.fileExists(atPath: path)
        return exists ? path : "\(path)  (not found — is Herdr running?)"
    }
}

/// The first-run view: shown when nothing is connected and nothing is cached.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Kraal")
                .font(.largeTitle.weight(.light))

            Text("A native window onto your Herdr agents, panes, and tabs.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Connect to This Mac") {
                    store.target = .local
                    store.connect()
                }
                .keyboardShortcut(.defaultAction)

                Button("Remote Host…") {
                    showSettings = true
                }
            }
            .padding(.top, 4)

            if case let .failed(reason) = store.phase {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let path = try? HerdrDiscovery.sessionSocket(name: "default"),
               !FileManager.default.fileExists(atPath: path) {
                Text("No socket at \(path). Start Herdr, or connect to a remote host.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSettings) {
            ConnectionSheet(store: store)
        }
    }
}
