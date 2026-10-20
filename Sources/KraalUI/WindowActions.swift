// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A one-way channel for window-level actions.
//
// Sidebar visibility, the command palette sheet and the connection sheet are
// `@State` inside `RootView` — deliberately, since they are view concerns. The
// menu bar, however, lives in AppKit and has no reference to a SwiftUI view, so
// it needs a way to ask the window to toggle them.
//
// The alternative would be to lift all three into `AppStore`, which would drag
// presentation state into the protocol layer and make the store harder to reason
// about. A single broadcast object keeps the direction of the dependency right:
// AppKit publishes an intent, the view observes it.

import Observation

@MainActor
@Observable
public final class WindowActions {
    /// Bumped by AppKit when the menu asks for a toggle. `RootView` watches this
    /// with `.onChange` rather than reading a boolean, so two quick clicks are
    /// two toggles instead of one state that has not been read yet.
    public private(set) var sidebarToggleCount = 0
    public private(set) var statusBarToggleCount = 0
    public private(set) var commandPaletteCount = 0
    public private(set) var shortcutsCount = 0
    public private(set) var machinesCount = 0

    public init() {}

    public func toggleSidebar() { sidebarToggleCount += 1 }
    public func toggleStatusBar() { statusBarToggleCount += 1 }
    public func showCommandPalette() { commandPaletteCount += 1 }
    public func showShortcuts() { shortcutsCount += 1 }
    public func showMachines() { machinesCount += 1 }
}
