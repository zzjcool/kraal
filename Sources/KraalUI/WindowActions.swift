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
    /// Settings replaced the old standalone Machines dialog: machines are a tab
    /// inside it now, so the window asks for settings and the window picks which
    /// tab to show.
    public private(set) var settingsCount = 0
    public private(set) var debugInfoCount = 0
    public private(set) var themePickerCount = 0
    /// Bumped when the terminal font size changes.
    ///
    /// A size is a construction-time command in libghostty, so the terminals are
    /// rebuilt — and rebuilding the pool's models is not enough on its own: the
    /// views hold the models they were handed, and nothing else about the tree
    /// changes, so without an identity change they keep drawing the old surfaces.
    public private(set) var fontChangeCount = 0
    /// Bumped when the menu asks for the other density.
    public private(set) var densityToggleCount = 0

    public init() {}

    public func toggleSidebar() { sidebarToggleCount += 1 }
    public func toggleStatusBar() { statusBarToggleCount += 1 }
    public func showCommandPalette() { commandPaletteCount += 1 }
    public func showShortcuts() { shortcutsCount += 1 }
    public func showSettings() { settingsCount += 1 }
    public func showDebugInfo() { debugInfoCount += 1 }
    public func showThemePicker() { themePickerCount += 1 }
    public func fontChanged() { fontChangeCount += 1 }
    public func toggleDensity() { densityToggleCount += 1 }
}
