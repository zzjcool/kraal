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

@MainActor
public struct RootView: View {
    @State private var store: AppStore
    @State private var showCommands = false
    @State private var showConnection = false
    @State private var showShortcuts = false
    @State private var showMachines = false
    @State private var sidebarVisible = true
    @State private var statusBarVisible = true

    /// Window-level intents raised by the AppKit menu bar. Optional so previews
    /// and tests can build the view without an AppKit host.
    private let windowActions: WindowActions

    /// The terminal renderer, injected by the app target so this file stays
    /// buildable (and previewable) without the Ghostty framework.
    private let paneContent: (AppStore, String, PaneSurfacePane) -> AnyView

    public init(
        store: AppStore,
        windowActions: WindowActions? = nil,
        paneContent: @escaping (AppStore, String, PaneSurfacePane) -> AnyView
    ) {
        _store = State(initialValue: store)
        self.windowActions = windowActions ?? WindowActions()
        self.paneContent = paneContent
    }

    private var content: some View {
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
                if statusBarVisible {
                    StatusBarView { showCommands = true }
                        .environment(store)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    public var body: some View {
        // Kept in small named pieces: a single expression this size made the
        // type checker time out after the menu gained its extra modifiers.
        content
            .sheet(isPresented: $showCommands) {
            CommandPalette()
                .environment(store)
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(store: store)
        }
        .sheet(isPresented: $showShortcuts) {
            ShortcutsView()
        }
        .sheet(isPresented: $showMachines) {
            MachinesPanel { showMachines = false }
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
        // The menu bar owns the keyboard shortcuts now: AppKit gives a menu item's
        // key equivalent first refusal, so registering the same chord here as a
        // hidden button would fire the action twice. Only shortcuts the menu does
        // not carry stay in this block.
        .background {
            Group {
                // Escape dismisses an open sheet; no menu item competes with it.
                Button("") { showCommands = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        // Watching counters instead of booleans: two clicks in the menu are two
        // toggles, even if SwiftUI has not re-rendered in between.
        .onChange(of: windowActions.sidebarToggleCount) { sidebarVisible.toggle() }
        .onChange(of: windowActions.statusBarToggleCount) { statusBarVisible.toggle() }
        .onChange(of: windowActions.commandPaletteCount) { showCommands = true }
        .onChange(of: windowActions.shortcutsCount) { showShortcuts = true }
        .onChange(of: windowActions.machinesCount) { showMachines = true }
    }
}
