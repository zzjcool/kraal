// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  Palette.swift
//  KraalUI
//
//  The client's colour tokens, matching the daemon's own model field for field
//  (`src/app/state.rs:35-76`).
//
//  ## Why a table instead of semantic system colours
//
//  Before this, colours came from two places that could not agree: a dozen hard-coded
//  `Color(red:...)` literals behind `sidebarColor("green")`, and SwiftUI's `.primary` /
//  `.secondary` everywhere else. Neither knew about the user's theme, so the sidebar
//  and the overlays were styled by different rules and drifted apart.
//
//  Upstream solves this with one 19-field palette resolved from the theme name; the
//  same shape is used here so a theme name selects the same colours the daemon would
//  have drawn. The field names are deliberately snake_case-identical to upstream's so
//  the two can be compared line by line.
//
//  ## A `nil` token means "no opinion"
//
//  Upstream's `Color::Reset` is "let the terminal decide". Here that maps to `nil`,
//  and the view falls back to the system's own colour for that role. Encoding it as
//  black would make a `terminal` theme paint black backgrounds over a light terminal.
//

import SwiftUI

/// One role in the interface's colour scheme.
///
/// Raw values are `0xRRGGBB`; the alpha is always 1 and is not carried.
public struct Palette: Equatable, Sendable {
    /// Highlight, active borders.
    public var accent: UInt32?
    /// Tab bar, floating panels, overlays, modals.
    public var panelBackground: UInt32?
    /// Optional sidebar background. `nil` keeps whatever is behind it.
    public var sidebarBackground: UInt32?
    /// Active workspace row, focused agent row.
    public var activeRowBackground: UInt32?
    /// Navigate-mode cursor row.
    public var selectionBackground: UInt32?
    /// Subtle surface for selected or focused items.
    public var surface0: UInt32?
    /// Slightly lighter surface for hover and active states.
    public var surface1: UInt32?
    /// Very dim surface, for separators.
    public var surfaceDim: UInt32?
    /// Muted text: secondary information, numbers.
    public var overlay0: UInt32?
    /// Slightly brighter muted text.
    public var overlay1: UInt32?
    /// Main text.
    public var text: UInt32?
    /// Subdued text: workspace numbers, dim labels.
    public var subtext0: UInt32?
    /// Branch names and other special labels.
    public var mauve: UInt32?
    /// Done and idle states.
    public var green: UInt32?
    /// Working and running states.
    public var yellow: UInt32?
    /// Blocked and needs-attention states.
    public var red: UInt32?
    /// Unseen and done notification accent.
    public var blue: UInt32?
    /// Notification accent, unseen markers.
    public var teal: UInt32?
    /// Interrupted and warning states.
    public var peach: UInt32?

    /// Every field `nil`: each role falls back to the system colour.
    public static let system = Palette()

    public init(
        accent: UInt32? = nil,
        panelBackground: UInt32? = nil,
        sidebarBackground: UInt32? = nil,
        activeRowBackground: UInt32? = nil,
        selectionBackground: UInt32? = nil,
        surface0: UInt32? = nil,
        surface1: UInt32? = nil,
        surfaceDim: UInt32? = nil,
        overlay0: UInt32? = nil,
        overlay1: UInt32? = nil,
        text: UInt32? = nil,
        subtext0: UInt32? = nil,
        mauve: UInt32? = nil,
        green: UInt32? = nil,
        yellow: UInt32? = nil,
        red: UInt32? = nil,
        blue: UInt32? = nil,
        teal: UInt32? = nil,
        peach: UInt32? = nil
    ) {
        self.accent = accent
        self.panelBackground = panelBackground
        self.sidebarBackground = sidebarBackground
        self.activeRowBackground = activeRowBackground
        self.selectionBackground = selectionBackground
        self.surface0 = surface0
        self.surface1 = surface1
        self.surfaceDim = surfaceDim
        self.overlay0 = overlay0
        self.overlay1 = overlay1
        self.text = text
        self.subtext0 = subtext0
        self.mauve = mauve
        self.green = green
        self.yellow = yellow
        self.red = red
        self.blue = blue
        self.teal = teal
        self.peach = peach
    }

    /// The palette for a theme name, or `nil` when the name is unknown.
    ///
    /// Names are canonicalised exactly as upstream does
    /// (`src/config/theme.rs:25-46`): lower-cased, spaces and underscores become
    /// hyphens, then aliases collapse. `"Catppuccin Mocha"`, `"catppuccin_mocha"` and
    /// `"catppuccin"` are the same theme — a user typing any of them expects it to work,
    /// and a config that silently did nothing because of a space is the kind of bug
    /// that gets blamed on the app being broken.
    public static func named(_ raw: String) -> Palette? {
        canonicalThemeName(raw).flatMap(builtin)
    }

    /// Collapses a user-written theme name to the canonical one.
    public static func canonicalThemeName(_ raw: String) -> String? {
        let key = raw.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return switch key {
        case "catppuccin", "catppuccin-mocha": "catppuccin"
        case "catppuccin-latte", "latte", "light": "catppuccin-latte"
        case "terminal": "terminal"
        case "tokyo-night", "tokyonight": "tokyo-night"
        case "tokyo-night-day", "tokyo-day", "tokyonight-day": "tokyo-night-day"
        case "dracula": "dracula"
        case "nord": "nord"
        case "gruvbox", "gruvbox-dark": "gruvbox"
        case "gruvbox-light": "gruvbox-light"
        case "one-dark", "onedark": "one-dark"
        case "one-light", "onelight": "one-light"
        case "solarized", "solarized-dark": "solarized"
        case "solarized-light": "solarized-light"
        case "kanagawa": "kanagawa"
        case "kanagawa-lotus", "lotus": "kanagawa-lotus"
        case "rose-pine", "rosepine": "rose-pine"
        case "rose-pine-dawn", "rosepine-dawn", "dawn": "rose-pine-dawn"
        case "vesper": "vesper"
        default: nil
        }
    }
}

// MARK: - Rendering

public extension Palette {
    /// A token as a SwiftUI colour, or `fallback` when the theme has no opinion.
    func color(_ token: UInt32?, fallback: Color) -> Color {
        guard let token else { return fallback }
        return Color(
            red: Double((token >> 16) & 0xFF) / 255,
            green: Double((token >> 8) & 0xFF) / 255,
            blue: Double(token & 0xFF) / 255
        )
    }

    var accentColor: Color { color(accent, fallback: .accentColor) }
    var panelColor: Color { color(panelBackground, fallback: .clear) }
    /// The sidebar's own background; transparent when the theme leaves it unset, so a
    /// `terminal` theme shows the window's material rather than a flat rectangle.
    var sidebarColor: Color { color(sidebarBackground, fallback: .clear) }
    var activeRowColor: Color { color(activeRowBackground, fallback: .clear) }
    var selectionColor: Color { color(selectionBackground, fallback: .clear) }
    var surface0Color: Color { color(surface0, fallback: .clear) }
    var surface1Color: Color { color(surface1, fallback: .clear) }
    var separatorColor: Color { color(surfaceDim, fallback: Color(nsColor: .separatorColor)) }
    var mutedColor: Color { color(overlay0, fallback: .secondary) }
    var mutedStrongColor: Color { color(overlay1, fallback: .secondary) }
    var textColor: Color { color(text, fallback: .primary) }
    var subtextColor: Color { color(subtext0, fallback: .secondary) }
    var mauveColor: Color { color(mauve, fallback: .purple) }
    var doneColor: Color { color(green, fallback: .green) }
    var workingColor: Color { color(yellow, fallback: .yellow) }
    var blockedColor: Color { color(red, fallback: .red) }
    var unseenColor: Color { color(blue, fallback: .blue) }
    var noticeColor: Color { color(teal, fallback: .teal) }
    var warningColor: Color { color(peach, fallback: .orange) }

    /// A `config.toml` colour *name* as this theme defines it.
    ///
    /// The sidebar's token resolver speaks names rather than roles, so the mapping has
    /// to exist somewhere. Kept next to the palette because the answer depends entirely
    /// on the theme: `gray` is the overlay scale, `green` is "done", and both move when
    /// the theme does.
    func nameColor(_ name: String) -> Color? {
        switch name.lowercased() {
        case "red", "maroon": color(red, fallback: .red)
        case "green": color(green, fallback: .green)
        case "yellow", "olive": color(yellow, fallback: .yellow)
        case "blue", "navy": color(blue, fallback: .blue)
        case "teal", "cyan": color(teal, fallback: .teal)
        case "mauve", "purple", "magenta": color(mauve, fallback: .purple)
        case "peach", "orange": color(peach, fallback: .orange)
        case "white", "text": color(text, fallback: .primary)
        case "gray", "grey": color(overlay0, fallback: .secondary)
        default: nil
        }
    }
}
