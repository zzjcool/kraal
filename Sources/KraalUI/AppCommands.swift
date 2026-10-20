// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// One table of user-reachable actions.
//
// The menu bar, the context menus and the key shortcuts are three views of the
// same set of actions, so they are defined once here and rendered three times.
// Splitting them would let the menu drift away from what ⌘T does, which is how
// desktop apps end up with menu items that no longer match their shortcut.
//
// The vocabulary follows Herdr's own action list (its binary carries one
// `<id><Title>` pair per action, e.g. `split_rightSplit Right`) so a user
// switching between the two clients finds the same words in the same places.

import KraalProtocol
import SwiftUI

/// Which way a split/swap/resize goes. The daemon accepts exactly these four.
public enum PaneDirection: String, Sendable, CaseIterable {
    case left
    case right
    // The wire values are `up`/`down`; the case names are longer only to satisfy
    // the project's 3-character minimum for identifiers.
    case ascend = "up"
    case descend = "down"

    /// Herdr's menu says "Split Right" / "Split Down"; only two of the four
    /// directions create a pane, so splitting has its own narrower type.
    public var title: String { rawValue.capitalized }
}

/// A split only makes sense along one axis; Herdr exposes Right and Down.
public enum SplitOrientation: String, Sendable, CaseIterable {
    case right
    case down

    public var title: String { "Split \(rawValue.capitalized)" }
}

/// Every action the UI can trigger. `id` matches Herdr's action id where one
/// exists, which keeps the two clients' keybinding configs interchangeable.
public enum AppCommand: String, Sendable, CaseIterable {
    // Workspace
    case newWorkspace = "new_workspace"
    case renameWorkspace = "rename_workspace"
    case closeWorkspace = "close_workspace"
    case previousWorkspace = "previous_workspace"
    case nextWorkspace = "next_workspace"
    case focusWorkspace1 = "focus_workspace_1"
    case focusWorkspace2 = "focus_workspace_2"
    case focusWorkspace3 = "focus_workspace_3"
    case focusWorkspace4 = "focus_workspace_4"
    case focusWorkspace5 = "focus_workspace_5"
    case focusWorkspace6 = "focus_workspace_6"
    case focusWorkspace7 = "focus_workspace_7"
    case focusWorkspace8 = "focus_workspace_8"
    case focusWorkspace9 = "focus_workspace_9"

    // Tab
    case newTab = "new_tab"
    case renameTab = "rename_tab"
    case closeTab = "close_tab"
    case previousTab = "previous_tab"
    case nextTab = "next_tab"
    case moveTabPrevious = "move_tab_previous"
    case moveTabNext = "move_tab_next"
    case focusTab1 = "focus_tab_1"
    case focusTab2 = "focus_tab_2"
    case focusTab3 = "focus_tab_3"
    case focusTab4 = "focus_tab_4"
    case focusTab5 = "focus_tab_5"
    case focusTab6 = "focus_tab_6"
    case focusTab7 = "focus_tab_7"
    case focusTab8 = "focus_tab_8"
    case focusTab9 = "focus_tab_9"

    // Pane
    case splitRight = "split_right"
    case splitDown = "split_down"
    case closePane = "close_pane"
    case renamePane = "rename_pane"
    case clearPane = "clear_pane"
    case toggleZoom = "toggle_zoom"
    case focusLeft = "focus_left"
    case focusRight = "focus_right"
    case focusUp = "focus_up"
    case focusDown = "focus_down"
    case swapPaneLeft = "swap_pane_left"
    case swapPaneRight = "swap_pane_right"
    case swapPaneUp = "swap_pane_up"
    case swapPaneDown = "swap_pane_down"
    case resizePaneLeft = "resize_pane_left"
    case resizePaneRight = "resize_pane_right"
    case resizePaneUp = "resize_pane_up"
    case resizePaneDown = "resize_pane_down"
    case previousPane = "previous_pane"
    case nextPane = "next_pane"

    // View
    case toggleSidebar = "toggle_sidebar"
    case toggleStatusBar = "toggle_status_bar"
    case commandPalette = "command_palette"
    case reloadConfig = "reload_config"
    case machines = "machines"
    case keyboardShortcuts = "keybindings"
    case reconnect = "reconnect"

    /// Menu label. Matches Herdr's wording so muscle memory transfers.
    public var title: String {
        switch self {
        case .newWorkspace: return "New Workspace"
        case .renameWorkspace: return "Rename Workspace…"
        case .closeWorkspace: return "Close Workspace"
        case .previousWorkspace: return "Previous Workspace"
        case .nextWorkspace: return "Next Workspace"
        case .newTab: return "New Tab"
        case .renameTab: return "Rename Tab…"
        case .closeTab: return "Close Tab"
        case .previousTab: return "Previous Tab"
        case .nextTab: return "Next Tab"
        case .moveTabPrevious: return "Move Tab Left"
        case .moveTabNext: return "Move Tab Right"
        case .splitRight: return SplitOrientation.right.title
        case .splitDown: return SplitOrientation.down.title
        case .closePane: return "Close Pane"
        case .renamePane: return "Rename Pane…"
        case .clearPane: return "Clear Pane"
        case .toggleZoom: return "Toggle Pane Zoom"
        case .focusLeft: return "Focus Left"
        case .focusRight: return "Focus Right"
        case .focusUp: return "Focus Up"
        case .focusDown: return "Focus Down"
        case .swapPaneLeft: return "Swap Pane Left"
        case .swapPaneRight: return "Swap Pane Right"
        case .swapPaneUp: return "Swap Pane Up"
        case .swapPaneDown: return "Swap Pane Down"
        case .resizePaneLeft: return "Resize Pane Left"
        case .resizePaneRight: return "Resize Pane Right"
        case .resizePaneUp: return "Resize Pane Up"
        case .resizePaneDown: return "Resize Pane Down"
        case .previousPane: return "Previous Pane"
        case .nextPane: return "Next Pane"
        case .toggleSidebar: return "Toggle Sidebar"
        case .toggleStatusBar: return "Toggle Status Bar"
        case .commandPalette: return "Command Palette"
        case .reloadConfig: return "Reload Config"
        case .machines: return "Machines…"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .reconnect: return "Reconnect"
        case .focusWorkspace1, .focusWorkspace2, .focusWorkspace3,
             .focusWorkspace4, .focusWorkspace5, .focusWorkspace6,
             .focusWorkspace7, .focusWorkspace8, .focusWorkspace9:
            return "Focus Workspace \(workspaceNumber ?? 0)"
        case .focusTab1, .focusTab2, .focusTab3, .focusTab4, .focusTab5,
             .focusTab6, .focusTab7, .focusTab8, .focusTab9:
            return "Focus Tab \(tabNumber ?? 0)"
        }
    }

    /// The trailing digit of a `focus_*_N` action, if any.
    public var workspaceNumber: Int? {
        rawValue.hasPrefix("focus_workspace_")
            ? Int(rawValue.dropFirst("focus_workspace_".count))
            : nil
    }

    public var tabNumber: Int? {
        rawValue.hasPrefix("focus_tab_")
            ? Int(rawValue.dropFirst("focus_tab_".count))
            : nil
    }

    /// Directional variants, keyed by the direction they act on.
    public var direction: PaneDirection? {
        switch self {
        case .focusLeft, .swapPaneLeft, .resizePaneLeft: return .left
        case .focusRight, .swapPaneRight, .resizePaneRight: return .right
        case .focusUp, .swapPaneUp, .resizePaneUp: return .ascend
        case .focusDown, .swapPaneDown, .resizePaneDown: return .descend
        default: return nil
        }
    }

    /// Window-menu placement: Herdr groups its `File` menu into New / Go To /
    /// Close, and Kraal mirrors that order rather than inventing a new one.
    public static let newItems: [AppCommand] = [.newWorkspace, .newTab]

    public static let closeItems: [AppCommand] = [.closePane, .closeTab, .closeWorkspace]

    public static let tabCycleItems: [AppCommand] = [.nextTab, .previousTab]

    public static let workspaceCycleItems: [AppCommand] = [.nextWorkspace, .previousWorkspace]

    public static let splitItems: [AppCommand] = [.splitRight, .splitDown]

    public static let paneMoveItems: [AppCommand] = [
        .focusLeft, .focusRight, .focusUp, .focusDown,
    ]

    public static let paneSwapItems: [AppCommand] = [
        .swapPaneLeft, .swapPaneRight, .swapPaneUp, .swapPaneDown,
    ]
}

/// What a command needs the user to supply before it can run.
public enum CommandPrompt: Identifiable, Sendable {
    case renameTab(tabId: String, current: String)
    case renameWorkspace(workspaceId: String, current: String)
    case renamePane(paneId: String, current: String)

    public var id: String {
        switch self {
        case .renameTab(let tabId, _): return "tab:\(tabId)"
        case .renameWorkspace(let workspaceId, _): return "workspace:\(workspaceId)"
        case .renamePane(let paneId, _): return "pane:\(paneId)"
        }
    }

    public var title: String {
        switch self {
        case .renameTab: return "Rename Tab"
        case .renameWorkspace: return "Rename Workspace"
        case .renamePane: return "Rename Pane"
        }
    }

    public var currentValue: String {
        switch self {
        case .renameTab(_, let current): return current
        case .renameWorkspace(_, let current): return current
        case .renamePane(_, let current): return current
        }
    }
}

// MARK: - Performing a command

/// Applies a command to the store. Kept as a free function so the menu bar,
/// context menus and shortcut buttons all funnel through one implementation —
/// there is exactly one place where "Close Tab" means `tab.close`.
/// The things a command needs from the view layer. Passed as a value so
/// `perform` stays independent of any particular window's @State.
public struct CommandEnvironment {
    public var prompt: (CommandPrompt) -> Void
    public var toggleSidebar: () -> Void
    public var toggleStatusBar: () -> Void
    public var showCommands: () -> Void
    public var showShortcuts: () -> Void
    /// Opens the machine-management panel. Machines live in the CLI config, not
    /// in the daemon snapshot, so they get their own panel.
    public var showMachines: () -> Void

    public init(
        prompt: @escaping (CommandPrompt) -> Void = { _ in },
        toggleSidebar: @escaping () -> Void = {},
        toggleStatusBar: @escaping () -> Void = {},
        showCommands: @escaping () -> Void = {},
        showShortcuts: @escaping () -> Void = {},
        showMachines: @escaping () -> Void = {}
    ) {
        self.prompt = prompt
        self.toggleSidebar = toggleSidebar
        self.toggleStatusBar = toggleStatusBar
        self.showCommands = showCommands
        self.showShortcuts = showShortcuts
        self.showMachines = showMachines
    }
}

/// Applies a command to the store. Kept as a free function so the menu bar,
/// context menus and shortcut buttons all funnel through one implementation —
/// there is exactly one place where "Close Tab" means `tab.close`.
///
/// Split into per-family helpers: a single 40-branch switch is unreadable and
/// trips the project's cyclomatic-complexity lint.
@MainActor
public func perform(_ command: AppCommand, on store: AppStore, env: CommandEnvironment = .init()) {
    switch command {
    case .newWorkspace, .newTab,
         .renameWorkspace, .renameTab, .renamePane,
         .closeWorkspace, .closeTab, .closePane:
        performCreateRenameClose(command, on: store, env: env)

    case .previousWorkspace, .nextWorkspace, .previousTab, .nextTab,
         .previousPane, .nextPane, .moveTabPrevious, .moveTabNext,
         .focusWorkspace1, .focusWorkspace2, .focusWorkspace3,
         .focusWorkspace4, .focusWorkspace5, .focusWorkspace6,
         .focusWorkspace7, .focusWorkspace8, .focusWorkspace9,
         .focusTab1, .focusTab2, .focusTab3, .focusTab4, .focusTab5,
         .focusTab6, .focusTab7, .focusTab8, .focusTab9:
        performNavigation(command, on: store)

    case .splitRight, .splitDown, .clearPane, .toggleZoom,
         .focusLeft, .focusRight, .focusUp, .focusDown,
         .swapPaneLeft, .swapPaneRight, .swapPaneUp, .swapPaneDown,
         .resizePaneLeft, .resizePaneRight, .resizePaneUp, .resizePaneDown:
        performPaneAction(command, on: store)

    case .toggleSidebar, .toggleStatusBar, .commandPalette,
         .reloadConfig, .keyboardShortcuts, .reconnect, .machines:
        performViewAction(command, on: store, env: env)
    }
}

@MainActor
private func performCreateRenameClose(
    _ command: AppCommand,
    on store: AppStore,
    env: CommandEnvironment
) {
    switch command {
    case .newWorkspace: store.createWorkspace()
    case .newTab: store.createTab()
    case .renameWorkspace:
        if let workspace = store.focusedWorkspace {
            env.prompt(.renameWorkspace(
                workspaceId: workspace.workspaceId,
                current: workspace.label
            ))
        }
    case .renameTab:
        if let tab = store.focusedTab {
            env.prompt(.renameTab(tabId: tab.tabId, current: tab.label))
        }
    case .renamePane:
        if let paneId = store.actionPaneId {
            env.prompt(.renamePane(
                paneId: paneId,
                current: store.paneLabel(paneId) ?? ""
            ))
        }
    case .closeWorkspace: store.closeActionWorkspace()
    case .closeTab: store.closeActionTab()
    case .closePane: store.closeActionPane()
    default: break
    }
}

@MainActor
private func performNavigation(_ command: AppCommand, on store: AppStore) {
    switch command {
    case .previousWorkspace: store.cycleWorkspace(by: -1)
    case .nextWorkspace: store.cycleWorkspace(by: 1)
    case .previousTab: store.cycleTab(by: -1)
    case .nextTab: store.cycleTab(by: 1)
    case .previousPane: store.cyclePane(by: -1)
    case .nextPane: store.cyclePane(by: 1)
    case .moveTabPrevious: store.shiftFocusedTab(by: -1)
    case .moveTabNext: store.shiftFocusedTab(by: 1)
    default:
        if let number = command.workspaceNumber {
            store.focusWorkspace(number: number - 1)
        } else if let number = command.tabNumber {
            store.focusTab(number: number - 1)
        }
    }
}

@MainActor
private func performPaneAction(_ command: AppCommand, on store: AppStore) {
    switch command {
    case .splitRight: store.splitActionPane(.right)
    case .splitDown: store.splitActionPane(.down)
    case .clearPane:
        if let paneId = store.actionPaneId { store.clearPane(paneId: paneId) }
    case .toggleZoom: store.toggleZoomActionPane()
    default:
        guard let direction = command.direction else { return }
        switch command {
        case .swapPaneLeft, .swapPaneRight, .swapPaneUp, .swapPaneDown:
            store.swapPane(direction)
        case .resizePaneLeft, .resizePaneRight, .resizePaneUp, .resizePaneDown:
            store.resizePane(direction)
        default:
            store.focusDirection(direction)
        }
    }
}

@MainActor
private func performViewAction(
    _ command: AppCommand,
    on store: AppStore,
    env: CommandEnvironment
) {
    switch command {
    case .toggleSidebar: env.toggleSidebar()
    case .toggleStatusBar: env.toggleStatusBar()
    case .commandPalette: env.showCommands()
    case .reloadConfig: store.reloadServerConfig()
    case .keyboardShortcuts: env.showShortcuts()
    case .machines: env.showMachines()
    case .reconnect: store.connect()
    default: break
    }
}
