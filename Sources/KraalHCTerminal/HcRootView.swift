// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The window: machines/panes on the left, the layout (or a flat terminal) on
// the right.

import SwiftUI

public struct HcRootView: View {
    @ObservedObject private var model: HcWorkspaceModel

    public init(model: HcWorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        HSplitView {
            HcSidebarView(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { model.start() }
        .sheet(item: $model.machineSheet) { sheet in
            switch sheet {
            case .add:
                HcAddMachineView(model: model)
            case let .rename(machine):
                HcRenameMachineView(machine: machine, model: model)
            }
        }
        .confirmationDialog(
            model.closeRequest?.title ?? "Close?",
            isPresented: Binding(
                get: { model.closeRequest != nil },
                set: { if !$0 { model.closeRequest = nil } }
            ),
            presenting: model.closeRequest
        ) { request in
            Button(request.confirmTitle, role: .destructive) {
                Task { await model.confirmClose(request) }
            }
            Button("Cancel", role: .cancel) { model.closeRequest = nil }
        } message: { request in
            Text(request.detail)
        }
        .confirmationDialog(
            "Remove \(model.removingMachine?.name ?? "machine")?",
            isPresented: Binding(
                get: { model.removingMachine != nil },
                set: { if !$0 { model.removingMachine = nil } }
            ),
            presenting: model.removingMachine
        ) { machine in
            Button("Remove \(machine.name)", role: .destructive) {
                Task {
                    await model.removeMachine(machine)
                    model.removingMachine = nil
                }
            }
            Button("Cancel", role: .cancel) { model.removingMachine = nil }
        } message: { _ in
            Text("Only this core forgets it; its terminals keep running there.")
        }
        .alert(
            "Machine action failed",
            isPresented: Binding(
                get: { model.machineError != nil },
                set: { if !$0 { model.machineError = nil } }
            )
        ) {
            Button("OK") { model.machineError = nil }
        } message: {
            Text(model.machineError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(model.heartbeatStale ? Color.red : Color.secondary)
            }
            ToolbarItem {
                Button {
                    model.machineSheet = .add
                } label: {
                    Label("Add machine", systemImage: "plus")
                }
                .disabled(!isReady)
            }
            ToolbarItem {
                Button {
                    Task {
                        await model.refresh()
                        await model.refreshMachines()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!isReady)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.workspace.activeTab != nil {
            HcLayoutView(model: model)
        } else if let session = model.session {
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
