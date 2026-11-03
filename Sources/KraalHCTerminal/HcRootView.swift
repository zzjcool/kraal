// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The window: machines/panes on the left, the layout (or a flat terminal) on
// the right.

import SwiftUI

public struct HcRootView: View {
    @ObservedObject private var model: HcWorkspaceModel
    @StateObject private var keymap: HcKeymapController
    @Environment(\.colorScheme) private var colorScheme

    public init(model: HcWorkspaceModel) {
        self.model = model
        _keymap = StateObject(wrappedValue: HcKeymapController(workspace: model))
    }

    private var colors: HcChromeColors { .forScheme(colorScheme) }

    public var body: some View {
        VStack(spacing: 0) {
            HcTitlebarView(model: model)
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    HcSidebarView(model: model)
                        .frame(width: HcChromeMetrics.sidebarWidth)
                    Rectangle()
                        .fill(colors.border)
                        .frame(width: 1)
                }
                VStack(spacing: 0) {
                    detail
                        .frame(minWidth: 451, maxWidth: .infinity, maxHeight: .infinity)
                    HcStatusBarView(model: model)
                }
            }
        }
        .background(colors.chrome)
        // The window is `fullSizeContentView` + a transparent titlebar: the
        // chrome is meant to start at y=0 so the traffic lights sit in the same
        // 40pt row as the Kraal mark and the tabs (official layout `none`).
        .ignoresSafeArea(.container, edges: .top)
        .task { model.start() }
        .onAppear { keymap.attach() }
        .onDisappear { keymap.detach() }
        .overlay(alignment: .topTrailing) {
            if let toast = model.agentToast {
                HcAgentToastView(toast: toast) { model.agentToast = nil }
                    .padding(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let session = model.peekSession, let address = model.peekAddress {
                HcAgentPeekView(address: address, session: session) {
                    model.closePeek()
                }
                .padding(16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay {
            if model.showPalette {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { model.showPalette = false }
                    HcCommandPalette(workspace: model)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.agentToast)
        .animation(.easeOut(duration: 0.2), value: model.peekAddress)
        .sheet(item: $model.renameRequest) { request in
            HcRenameView(model: model, request: request)
        }
        .sheet(isPresented: $model.showSettings) {
            HcSettingsView(model: model)
        }
        .sheet(isPresented: $model.showHelp) {
            HcHelpView(workspace: model, keyBindings: keymap.bindings)
        }
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
    }

    @ViewBuilder
    private var detail: some View {
        if model.workspace.activeTab != nil {
            HcLayoutView(model: model)
        } else if let session = model.session {
            HcTerminalPaneView(session: session, isFocused: model.terminalFocusAllowed)
                .padding(HcChromeMetrics.workInset)
                .background(colors.canvas)
                .id(ObjectIdentifier(session))
        } else {
            VStack(spacing: 8) {
                Text(emptyTitle).font(.headline)
                if let error = model.openError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(colors.blocked)
                        .textSelection(.enabled)
                } else {
                    Text(statusText).foregroundStyle(colors.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.canvas)
        }
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
