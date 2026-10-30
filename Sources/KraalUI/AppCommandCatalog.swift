// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AppCommandCatalog.swift
//  KraalUI
//
//  What the command palette needs to know about a command beyond its label:
//  which family it belongs to, what a person might call it instead, and an icon.
//
//  ## Why a second table
//
//  A menu bar can be read top to bottom; a palette with 58 rows cannot. Rex
//  (whose palette is the model here) gives every action a `category` and a list
//  of `keywords` — its theme action carries "theme colour color scheme palette
//  appearance" — so "colour" finds the theme command without the user having to
//  remember the words the author chose.
//
//  The synonyms are deliberately not translated from the titles: `toggleZoom`
//  has to be reachable as "maximize" and "fullscreen" because that is what a
//  person types when the pane is too small. Titles stay the menu's vocabulary.
//
//  The numbered families (`focus_workspace_3`, `focus_tab_5`) do not get a table
//  entry each: their synonyms are the same for all nine, and a 9-line copy for
//  every digit is the kind of list that goes stale when the tenth is added.

import Foundation

public extension AppCommand {
    /// The menu a command lives under. Used as a secondary search field and as
    /// the palette row's icon — an action's shape says more than its title.
    enum Category: String, CaseIterable, Sendable {
        case workspace
        case tab
        case pane
        case view

        public var title: String {
            switch self {
            case .workspace: "Workspace"
            case .tab: "Tab"
            case .pane: "Pane"
            case .view: "View"
            }
        }

        public var symbol: String {
            switch self {
            case .workspace: "square.grid.2x2"
            case .tab: "rectangle.on.rectangle"
            case .pane: "rectangle.split.2x1"
            case .view: "slider.horizontal.3"
            }
        }
    }

    /// The family this command belongs to.
    var category: Category {
        switch self {
        case .newWorkspace, .renameWorkspace, .closeWorkspace, .previousWorkspace, .nextWorkspace,
             .focusWorkspace1, .focusWorkspace2, .focusWorkspace3, .focusWorkspace4, .focusWorkspace5,
             .focusWorkspace6, .focusWorkspace7, .focusWorkspace8, .focusWorkspace9:
            .workspace
        case .newTab, .renameTab, .closeTab, .previousTab, .nextTab, .moveTabPrevious, .moveTabNext,
             .focusTab1, .focusTab2, .focusTab3, .focusTab4, .focusTab5,
             .focusTab6, .focusTab7, .focusTab8, .focusTab9:
            .tab
        case .splitRight, .splitDown, .closePane, .renamePane, .copyMode, .clearPane, .paste,
             .toggleZoom, .focusLeft, .focusRight, .focusUp, .focusDown,
             .swapPaneLeft, .swapPaneRight, .swapPaneUp, .swapPaneDown,
             .resizePaneLeft, .resizePaneRight, .resizePaneUp, .resizePaneDown, .previousPane, .nextPane:
            .pane
        case .toggleSidebar, .toggleStatusBar, .commandPalette, .changeTheme,
             .increaseFontSize, .decreaseFontSize, .resetFontSize,
             .reloadConfig, .keyboardShortcuts, .reconnect, .settings:
            .view
        }
    }

    /// Words a person might type that are not in the title.
    ///
    /// Empty is allowed (the title's own words still match), but every command
    /// that a user could plausibly name differently has an entry — see
    /// `PaletteSearchTests.everyCommandIsReachable`.
    var keywords: [String] {
        if rawValue.hasPrefix("focus_workspace_") { return ["goto", "jump", "switch", "space"] }
        if rawValue.hasPrefix("focus_tab_") { return ["goto", "jump", "switch"] }
        return Self.synonyms[self] ?? []
    }

    /// The synonym table, one line per command whose title is not how people search.
    static let synonyms: [AppCommand: [String]] = [
        .newWorkspace: ["new", "create", "add", "space"],
        .renameWorkspace: ["rename", "name", "title"],
        .closeWorkspace: ["close", "delete", "remove", "kill"],
        .previousWorkspace: ["prev", "back", "cycle", "space"],
        .nextWorkspace: ["next", "forward", "cycle", "space"],
        .newTab: ["new", "create", "add", "open"],
        .renameTab: ["rename", "name", "title"],
        .closeTab: ["close", "delete", "remove", "kill"],
        .previousTab: ["prev", "back", "cycle"],
        .nextTab: ["next", "forward", "cycle"],
        .moveTabPrevious: ["move", "reorder", "shift", "left"],
        .moveTabNext: ["move", "reorder", "shift", "right"],
        .splitRight: ["split", "vertical", "vsplit", "new", "open", "right"],
        .splitDown: ["split", "horizontal", "hsplit", "new", "open", "down"],
        .closePane: ["close", "kill", "remove", "delete"],
        .renamePane: ["rename", "name", "title", "label"],
        .copyMode: ["copy", "search", "find", "scrollback", "select", "history"],
        .clearPane: ["clear", "reset", "wipe", "screen"],
        .paste: ["paste", "insert", "clipboard"],
        .toggleZoom: ["zoom", "maximize", "maximise", "max", "fullscreen", "fill", "focus"],
        .focusLeft: ["focus", "move", "navigate", "left"],
        .focusRight: ["focus", "move", "navigate", "right"],
        .focusUp: ["focus", "move", "navigate", "up"],
        .focusDown: ["focus", "move", "navigate", "down"],
        .swapPaneLeft: ["swap", "exchange", "move", "pane", "left"],
        .swapPaneRight: ["swap", "exchange", "move", "pane", "right"],
        .swapPaneUp: ["swap", "exchange", "move", "pane", "up"],
        .swapPaneDown: ["swap", "exchange", "move", "pane", "down"],
        .resizePaneLeft: ["resize", "size", "grow", "shrink", "left", "width"],
        .resizePaneRight: ["resize", "size", "grow", "shrink", "right", "width"],
        .resizePaneUp: ["resize", "size", "grow", "shrink", "up", "height"],
        .resizePaneDown: ["resize", "size", "grow", "shrink", "down", "height"],
        .previousPane: ["prev", "back", "cycle"],
        .nextPane: ["next", "forward", "cycle"],
        .toggleSidebar: ["sidebar", "sidenav", "hide", "show", "panel", "toggle"],
        .toggleStatusBar: ["status", "footer", "bar", "hide", "show", "toggle"],
        .commandPalette: ["palette", "command", "run", "search", "find", "goto", "quick", "open"],
        .changeTheme: ["theme", "skin", "colour", "color", "scheme", "palette", "appearance"],
        .increaseFontSize: ["font", "text", "size", "bigger", "larger", "zoom", "read"],
        .decreaseFontSize: ["font", "text", "size", "smaller", "tinier", "zoom"],
        .resetFontSize: ["font", "text", "size", "default", "normal", "reset"],
        .reloadConfig: ["reload", "refresh", "config", "theme", "reconnect"],
        .keyboardShortcuts: ["keys", "shortcuts", "bindings", "hotkeys", "keyboard"],
        .reconnect: ["reconnect", "connection", "disconnect", "retry", "network", "socket"],
        .settings: ["settings", "preferences", "options", "config", "machines", "hosts"],
    ]
}

extension AppCommand: PaletteSearchable {
    public var paletteTitle: String { title }
    public var paletteCategory: String { category.title }
    /// The id's own words as well as the synonyms: `split_down` supplies "down",
    /// which is what someone types after reading the command in the menu once.
    public var paletteKeywords: [String] {
        rawValue.split(separator: "_").map(String.init) + keywords
    }
}
