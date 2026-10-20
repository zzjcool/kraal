// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The main window: sidebar, tab bar, pane grid, status bar.
//
// Everything here is a function of `AppStore`; there is no view-local connection
// state, so a reconnect swaps the data underneath without the layout flashing.

import KraalProtocol
import SwiftUI
import KraalSidebar
import KraalTransport

public struct RootView: View {
    @State private var store: AppStore
    @State private var showCommands = false
    @State private var showConnection = false
    @State private var sidebarVisible = true

    /// The terminal renderer, injected by the app target so this file stays
    /// buildable (and previewable) without the Ghostty framework.
    private let paneContent: (AppStore, String, PaneSurfacePane) -> AnyView

    public init(
        store: AppStore,
        paneContent: @escaping (AppStore, String, PaneSurfacePane) -> AnyView
    ) {
        _store = State(initialValue: store)
        self.paneContent = paneContent
    }

    public var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView()
                    .environment(store)
                Divider()
            }

            VStack(spacing: 0) {
                if store.snapshot == nil {
                    WelcomeView()
                        .environment(store)
                } else {
                    TabBarView()
                        .environment(store)
                    Divider()
                    PaneLayoutView { paneId, geometry in
                        paneContent(store, paneId, geometry)
                    }
                    .environment(store)
                    Divider()
                }
                StatusBarView { showCommands = true }
                    .environment(store)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .sheet(isPresented: $showCommands) {
            CommandPalette()
                .environment(store)
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(store: store)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle sidebar (⌘B)")

                Button {
                    store.connect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reconnect")

                Button {
                    showConnection = true
                } label: {
                    Image(systemName: "network")
                }
                .help("Connection settings")
            }
        }
        .onAppear {
            if store.phase == .idle {
                store.loadDefaultSidebarConfig()
                store.connect()
            }
        }
        .background {
            // Keyboard shortcuts that are not tied to a visible control.
            Group {
                Button("") { showCommands = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("") { sidebarVisible.toggle() }
                    .keyboardShortcut("b", modifiers: .command)
                // Tabs do not have to be clicked: cycling with the keyboard is
                // how a multiplexer is normally driven, and it is the only path
                // that reaches `focus(tabId:)` without pointer coordinates.
                ForEach(1...9, id: \.self) { number in
                    Button("") { store.focusTab(number: number - 1) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(number)")),
                            modifiers: .command
                        )
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }
}
