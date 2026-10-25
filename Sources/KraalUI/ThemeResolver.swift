// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ThemeResolver.swift
//  KraalUI
//
//  Turns `[theme]` from `config.toml` plus the host's appearance into one palette.
//
//  Mirrors upstream `resolve_effective_theme` (`src/app/mod.rs:320-350`):
//
//      auto_switch off -> name
//      auto_switch on  -> dark_name when the host is dark, light_name when it is light
//      unset names     -> the sibling of `name` (catppuccin <-> catppuccin-latte, …)
//      unknown name    -> the mode's fallback, then `catppuccin`
//
//  Split from the parser and from the views so the *choice* is testable without a
//  window, a config file, or a system appearance.
//

import SwiftUI

/// Light or dark, as the host reports it.
public enum HostAppearance: String, Sendable, Equatable {
    case light
    case dark
}

/// Resolves the palette to use.
public enum ThemeResolver {
    /// Upstream's fallbacks when a name is unknown (`src/app/mod.rs:326-336`).
    static let darkFallback = "catppuccin"
    static let lightFallback = "catppuccin-latte"

    /// The dark/light partner of a theme, so `auto_switch` works without the user
    /// naming both halves.
    ///
    /// Themes without a partner resolve to themselves — upstream's `_ =>` arm. That is
    /// what makes `theme.name = "terminal"` with `auto_switch = true` stay on
    /// `terminal` rather than jumping to Catppuccin when the sun goes down.
    public static func siblings(of name: String) -> (dark: String, light: String) {
        switch Palette.canonicalThemeName(name) ?? name.lowercased() {
        case "catppuccin", "catppuccin-latte": ("catppuccin", "catppuccin-latte")
        case "tokyo-night", "tokyo-night-day": ("tokyo-night", "tokyo-night-day")
        case "gruvbox", "gruvbox-light": ("gruvbox", "gruvbox-light")
        case "one-dark", "one-light": ("one-dark", "one-light")
        case "solarized", "solarized-light": ("solarized", "solarized-light")
        case "kanagawa", "kanagawa-lotus": ("kanagawa", "kanagawa-lotus")
        case "rose-pine", "rose-pine-dawn": ("rose-pine", "rose-pine-dawn")
        default: (name, name)
        }
    }

    /// The theme name to use, given a config and the host appearance.
    ///
    /// The name is returned alongside the palette because the GUI gate asserts *which
    /// theme was chosen* — a palette alone cannot be checked against a config without
    /// comparing 19 numbers.
    public static func resolve(
        _ config: ThemeConfig,
        appearance: HostAppearance
    ) -> (palette: Palette, name: String) {
        let manual = config.name ?? darkFallback
        let siblings = siblings(of: manual)
        let (wanted, fallback): (String, String)
        if config.autoSwitch {
            switch appearance {
            case .dark: (wanted, fallback) = (config.darkName ?? siblings.dark, darkFallback)
            case .light: (wanted, fallback) = (config.lightName ?? siblings.light, lightFallback)
            }
        } else {
            (wanted, fallback) = (manual, darkFallback)
        }

        if let palette = Palette.named(wanted) {
            return (palette, Palette.canonicalThemeName(wanted) ?? wanted)
        }
        // Unknown name: upstream logs and falls back rather than drawing nothing. A
        // typo in `theme.name` should look like the default theme, not like a broken
        // client with invisible text.
        kraalLog("theme: unknown name \(wanted); using \(fallback)")
        return (Palette.named(fallback) ?? .catppuccin, fallback)
    }

    /// The host's current appearance.
    ///
    /// Read from AppKit rather than from `NSApp.effectiveAppearance` so the value is
    /// available before the app finishes launching — the first frame is the one that
    /// would otherwise flash the wrong theme.
    @MainActor
    public static var hostAppearance: HostAppearance {
        let match = NSApp?.effectiveAppearance
            ?? NSAppearance.currentDrawing()
        let best = match.bestMatch(from: [.aqua, .darkAqua])
        return best == .darkAqua ? .dark : .light
    }
}
