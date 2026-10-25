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
    public static func storedSplit(in defaults: UserDefaults = .standard) -> CGFloat? {
        guard defaults.object(forKey: splitKey) != nil else { return nil }
        let value = defaults.double(forKey: splitKey)
        return CGFloat(value)
    }

    public static func storeSplit(_ ratio: CGFloat, in defaults: UserDefaults = .standard) {
        guard ratio.isFinite else { return }
        defaults.set(Double(ratio), forKey: splitKey)
    }

    /// Removes the stored split, so the next launch uses the default again.
    public static func clearSplit(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: splitKey)
    }

    /// The ratio to start from: the stored one, or the default.
    public static func initialSplit(in defaults: UserDefaults = .standard) -> CGFloat {
        storedSplit(in: defaults) ?? SidebarSections.defaultRatio
    }
}
