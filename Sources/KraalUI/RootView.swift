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
    @State private var showSettings = false
    @State private var showDebugInfo = false
    @State private var sidebarVisible = true
    @State private var statusBarVisible = true
    /// Mirror of `store.pendingGroupClose` that the alert is presented from.
    @State private var pendingGroupPrompt: AppStore.PendingGroupClose?

    /// Window-level intents raised by the AppKit menu bar. Optional so previews
    /// and tests can build the view without an AppKit host.
    private let windowActions: WindowActions

    /// The terminal renderer, injected by the app target so this file stays
    /// buildable (and previewable) without the Ghostty framework.
    private let paneContent: (AppStore, String, PaneSurfacePane) -> AnyView

    /// The copy-mode bar's text. `nil` in previews and tests, where there is no
    /// copy mode — the status bar simply has one less thing to show.
    private let copyModeBanner: CopyModeBanner?

    /// Builds the popup's terminal view. Injected like `paneContent` so this file
    /// stays free of the Ghostty dependency.
    private let popupPaneContent: (AppStore, ClientShellPopupSurface, PopupGeometry) -> AnyView

    public init(
        store: AppStore,
        windowActions: WindowActions? = nil,
        copyModeBanner: CopyModeBanner? = nil,
        paneContent: @escaping (AppStore, String, PaneSurfacePane) -> AnyView,
        popupPaneContent: @escaping (AppStore, ClientShellPopupSurface, PopupGeometry) -> AnyView
            = { _, _, _ in AnyView(Color(nsColor: .textBackgroundColor)) }
    ) {
        _store = State(initialValue: store)
        self.windowActions = windowActions ?? WindowActions()
        self.copyModeBanner = copyModeBanner
        self.paneContent = paneContent
        self.popupPaneContent = popupPaneContent
    }

    private var content: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView()
                    .environment(store)
                    // The sidebar's footer `menu` needs the same actions the system
                    // menu bar has, so it reads the same object instead of growing a
                    // second copy of "open settings" plumbing.
                    .environment(windowActions)
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
                    PaneLayoutView(
                        paneContent: { paneId, geometry in
                            paneContent(store, paneId, geometry)
                        },
                        popupContent: { popup, geometry in
                            popupPaneContent(store, popup, geometry)
                        }
                    )
                    .environment(store)
                    Divider()
                }
                if statusBarVisible {
                    StatusBarView(
                        onShowCommands: { showCommands = true },
                        copyMode: copyModeBanner
                    )
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
        .sheet(isPresented: $showSettings) {
            SettingsView(target: store.target) {
                showSettings = false
            } onProfilesChanged: {
                // A machine was added, renamed, disabled or removed: the sidebar's
                // roster comes from the same saved profiles, so it has to re-read
                // them or it keeps drawing the pre-edit list.
                Task { await store.loadEndpoints() }
            }
        }
        .sheet(isPresented: $showDebugInfo) {
            DebugInfoView()
                .environment(store)
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
                    store.reconnectAllEndpoints()
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
            // Machines load beside the connection: the sidebar can draw the local
            // group before any remote profile is known, and the groups appear as
            // soon as the list arrives.
            Task { await store.loadEndpoints() }
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
        .onChange(of: windowActions.settingsCount) { showSettings = true }
        .onChange(of: windowActions.debugInfoCount) { showDebugInfo = true }
        // Confirmations the daemon asked for. Mounted here, at the root, because
        // the two ways to trigger a close live in different UI layers: the
        // sidebar's context menu is SwiftUI, the File menu is AppKit. A dialog
        // owned by either one would be invisible to the other.
        //
        // The prompt is mirrored into local `@State` rather than driven straight
        // off `store.pendingGroupClose`. A `.alert(isPresented: Binding { store.x
        // != nil })` never appeared here even though the store was set in the same
        // millisecond as the refusal (the log line "close: refusing to close
        // alone, asking" proves the value was assigned): SwiftUI keeps its own
        // presentation state, and a binding whose `get` reads an observable
        // property outside a view body does not reliably invalidate. `onChange` on
        // the observable does, so the alert is owned by view state and the store
        // stays the source of the request.
        .onChange(of: store.pendingGroupClose) { _, pending in
            pendingGroupPrompt = pending
        }
        .alert(
            pendingGroupPrompt?.method == "workspace.close"
                ? "Close the whole worktree group?"
                : "Close this too?",
            isPresented: Binding(
                get: { pendingGroupPrompt != nil },
                set: { if !$0 { pendingGroupPrompt = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { store.cancelPendingGroupClose() }
            Button("Close", role: .destructive) { store.confirmPendingGroupClose() }
        } message: {
            Text(Self.groupCloseMessage(for: pendingGroupPrompt))
        }
    }

    /// What the daemon's refusal means, in the user's terms.
    ///
    /// The daemon refuses rather than warning because closing one workspace of a
    /// worktree group — or the last pane of a workspace that shares a group —
    /// takes the whole group down. Saying so is the entire point of the prompt.
    static func groupCloseMessage(for pending: AppStore.PendingGroupClose?) -> String {
        guard let pending else { return "" }
        switch pending.method {
        case "workspace.close":
            return "This workspace is part of a worktree group. Closing it also "
                + "closes the other workspaces in the group.\n\n"
                + "Herdr refused to close it alone, so nothing has been closed yet."
        case "pane.close":
            return "This is the last pane of its workspace, and that workspace is "
                + "part of a worktree group. Closing it closes the group.\n\n"
                + "Nothing has been closed yet."
        default:
            return "This is the last tab of its workspace, and that workspace is "
                + "part of a worktree group. Closing it closes the group.\n\n"
                + "Nothing has been closed yet."
        }
    }
}
