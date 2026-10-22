// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  KraalEffectSettings.swift
//  Kraal
//
//  The `UserDefaults` keys behind the Clipboard & Bell settings page.
//
//  Exists as a type rather than as string literals at the two call sites (the
//  settings toggles and the applier that honours them) for one specific reason: a
//  toggle whose key is misspelled only at the reading end looks like a switch
//  that does nothing. With the key in one place, the compiler is not involved but
//  the grep is.
//
//  Defaults are all `true`. Every one of these is an existing behaviour of a
//  terminal: OSC 52 works, the title follows the pane, a bell rings, the daemon's
//  notices appear. Defaulting to `false` would make upgrading silently remove
//  things, and a user who has never opened this page should get the terminal they
//  already had.
//

import Foundation

public enum KraalEffectSettings {
    /// Whether a pane may put text on this Mac's clipboard (OSC 52).
    ///
    /// A real security boundary, not a preference: a remote program writing your
    /// local clipboard can be used to plant text you later paste. That is why it
    /// is surfaced here rather than assumed.
    public static let clipboardEnabled = "kraal.effects.clipboard"

    /// Whether the window title follows the focused pane's reported title.
    public static let windowTitleEnabled = "kraal.effects.windowTitle"

    /// Whether a pane's bell sounds the system alert.
    public static let bellEnabled = "kraal.effects.bell"

    /// Whether the daemon's notices are shown at all.
    public static let notificationsEnabled = "kraal.effects.notifications"

    /// Reads a switch, treating "never set" as on.
    ///
    /// `UserDefaults.bool(forKey:)` answers `false` for a missing key, which would
    /// invert every default above the first time the app runs.
    public static func isEnabled(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
