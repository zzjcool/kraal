// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarPreferences.swift
//  KraalUI
//
//  The sidebar's remembered split, mirrored from what a drag produces.
//
//  Upstream persists the same value in `ClientChromePreferences.sidebar_section_split`
//  (`src/client/shell/preferences.rs:18-34`), a JSON file per endpoint, and only once
//  the user has dragged it — until then the value is `None` and the layout uses the
//  configured ratio or `0.5`. That distinction matters: a stored `0.5` would be
//  indistinguishable from "never touched", so this keeps `nil` for "never dragged".
//

import Foundation

/// The sidebar's two-pane split, as the user last left it.
public enum SidebarPreferences {
    /// The defaults this module reads and writes.
    ///
    /// Not `.standard` directly: the GUI gate runs the app against a scratch daemon
    /// but the *user's* defaults are real and shared, so a case that drags the
    /// divider wrote its split into the developer's own preferences and the next run
    /// started at that ratio. That showed up as `sidebar-divider-drag` flipping
    /// between passing and failing as the stored value drifted toward an edge.
    ///
    /// `KRAAL_PREFS_SUITE` points the app at its own domain, which is what the gate
    /// sets. Unset means `.standard`, i.e. normal use.
    public static var defaults: UserDefaults {
        guard let suite = ProcessInfo.processInfo.environment["KRAAL_PREFS_SUITE"],
              !suite.isEmpty,
              let scoped = UserDefaults(suiteName: suite)
        else {
            return .standard
        }
        return scoped
    }

    /// `nil` when the user has never dragged the divider.
    ///
    /// A `Double` rather than a `CGFloat` so `UserDefaults` round-trips it exactly;
    /// the layout converts at the point of use.
    public static let splitKey = "kraal.sidebar.sectionSplit"

    /// Reads the stored ratio, or `nil` when there is none.
    ///
    /// A stored value outside `SidebarSections`' range is returned as-is: clamping is
    /// the layout's job (`SidebarSections.heights`), so a bad value written by a
    /// newer build cannot crash an older one.
    public static func storedSplit(in defaults: UserDefaults = SidebarPreferences.defaults) -> CGFloat? {
        guard defaults.object(forKey: splitKey) != nil else { return nil }
        let value = defaults.double(forKey: splitKey)
        return CGFloat(value)
    }

    public static func storeSplit(_ ratio: CGFloat, in defaults: UserDefaults = SidebarPreferences.defaults) {
        guard ratio.isFinite else { return }
        defaults.set(Double(ratio), forKey: splitKey)
    }

    /// Removes the stored split, so the next launch uses the default again.
    public static func clearSplit(in defaults: UserDefaults = SidebarPreferences.defaults) {
        defaults.removeObject(forKey: splitKey)
    }

    /// The ratio to start from: the stored one, or the default.
    public static func initialSplit(in defaults: UserDefaults = SidebarPreferences.defaults) -> CGFloat {
        storedSplit(in: defaults) ?? SidebarSections.defaultRatio
    }

    // MARK: - Collapsed sidebar

    /// Whether the sidebar is collapsed to a narrow strip.
    ///
    /// Upstream keeps `sidebar_collapsed` plus `sidebar_collapsed_manual`
    /// (`src/client/shell/state.rs:872-873`); the `_manual` flag records that the
    /// user chose this, so an automatic width rule cannot override them. Only the
    /// user-facing flag is stored here: this client has no automatic collapse.
    public static let collapsedKey = "kraal.sidebar.collapsed"

    /// Whether the user has ever toggled it. `nil` means no preference, which is
    /// different from "collapsed" — the same distinction `storedSplit` makes.
    public static func storedCollapsed(
        in defaults: UserDefaults = SidebarPreferences.defaults
    ) -> Bool? {
        guard defaults.object(forKey: collapsedKey) != nil else { return nil }
        return defaults.bool(forKey: collapsedKey)
    }

    public static func storeCollapsed(
        _ collapsed: Bool,
        in defaults: UserDefaults = SidebarPreferences.defaults
    ) {
        defaults.set(collapsed, forKey: collapsedKey)
    }

    public static func initialCollapsed(
        in defaults: UserDefaults = SidebarPreferences.defaults
    ) -> Bool {
        storedCollapsed(in: defaults) ?? false
    }

    // MARK: - Agents pane ordering

    /// Mirror of upstream's `ClientChromePreferences.agent_panel_sort`
    /// (`src/client/shell/preferences.rs:29`), which also lives client-side and is
    /// `None` until the user changes it.
    public static let agentSortKey = "kraal.sidebar.agentSort"

    /// The stored ordering, or `nil` when the user has never changed it.
    public static func storedAgentSort(in defaults: UserDefaults = SidebarPreferences.defaults) -> AgentPanelSort? {
        guard let raw = defaults.string(forKey: agentSortKey) else { return nil }
        return AgentPanelSort(rawValue: raw)
    }

    public static func storeAgentSort(
        _ sort: AgentPanelSort,
        in defaults: UserDefaults = SidebarPreferences.defaults
    ) {
        defaults.set(sort.rawValue, forKey: agentSortKey)
    }

    /// The ordering to start from.
    public static func initialAgentSort(in defaults: UserDefaults = SidebarPreferences.defaults) -> AgentPanelSort {
        storedAgentSort(in: defaults) ?? .default
    }
}
