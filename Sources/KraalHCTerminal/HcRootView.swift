// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The M0 window: terminals on the left, the attached one on the right.

import SwiftUI

public struct HcRootView: View {
    @ObservedObject private var model: HcWorkspaceModel

    public init(model: HcWorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 340)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { model.start() }
        .toolbar {
            ToolbarItem(placement: .status) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(model.heartbeatStale ? Color.red : Color.secondary)
            }
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!isReady)
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { model.selected },
            set: { address in
                guard let address else { return }
                Task { await model.select(address) }
            }
        )) {
            ForEach(model.terminals) { terminal in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(terminal.name).lineLimit(1)
                        Spacer()
                        Text(terminal.address)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(terminal.isLive ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(terminal.agentState ?? (terminal.agent.isEmpty ? terminal.state : terminal.agent))
                        if !terminal.cwd.isEmpty {
                            Text(terminal.cwd)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(terminal.address)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.session {
            HcTerminalPaneView(session: session)
                .id(ObjectIdentifier(session))
        } else {
            VStack(spacing: 8) {
                Text(emptyTitle).font(.headline)
                if let error = model.openError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else {
                    Text(statusText).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var isReady: Bool {
        if case .ready = model.status { return true }
        return false
    }

    private var emptyTitle: String {
        switch model.status {
        case .idle, .connecting: "Connecting to herdr-core…"
        case .ready: "No live terminal"
        case .incompatible: "Incompatible core"
        case .failed: "Connection failed"
        }
    }

    private var statusText: String {
        if model.heartbeatStale { return "core 失联（无心跳）" }
        switch model.status {
        case .idle: return "idle"
        case .connecting: return "connecting…"
        case let .ready(version): return "herdr-core \(version)"
        case let .incompatible(reason): return "incompatible: \(reason)"
        case let .failed(error): return "failed: \(error)"
        }
    }
}
