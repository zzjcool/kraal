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
    /// The terminal's own background — the colour behind its cells.
    ///
    /// This is the one colour that has to reach Ghostty rather than the SwiftUI
    /// chrome, so it is carried as a token and converted at the boundary (see
    /// ``terminalBackgroundHex``). `nil` leaves whatever libghostty's built-in theme
    /// picked.
    ///
    /// Why it matters, measured: libghostty's defaults are `alabaster` (`#F7F7F7`) on
    /// light and `afterglow` (`#212121`) on dark appearance, so a gruvbox user saw a
    /// `(247,247,247)` band between two `(17,20,25)` panes. That band was the terminal
    /// painting its own background into the row its view was taller than the grid.
    public var terminalBackground: UInt32?
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
        terminalBackground: UInt32? = nil,
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
        self.terminalBackground = terminalBackground
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
    /// The current row's fill.
    ///
    /// Falls back to a translucent accent rather than a literal, because most palettes
    /// leave `active_row_bg` unset (upstream treats `Color::Reset` as "let the terminal
    /// decide") and a row with no fill at all cannot be told from its neighbours.
    var activeRowColor: Color {
        color(activeRowBackground, fallback: .accentColor.opacity(0.20))
    }
    /// A weaker current-row fill, for the row that is selected but not focused.
    var selectedRowColor: Color {
        color(activeRowBackground, fallback: .accentColor.opacity(0.10))
            .opacity(0.5)
    }
    /// The selected-tab / selected-text fill.
    ///
    /// `nil` in the palette means "no opinion", and the platform's own selection colour
    /// is the right answer there. The caller cannot test this by comparing to `.clear`
    /// — SwiftUI `Color` has no useful equality — so the decision is made here.
    /// `Color.selection` is a `SelectionShapeStyle`, not a `Color`, so the platform
    /// fallback has to come from AppKit. Same shape as `separatorColor`.
    var selectionColor: Color {
        color(selectionBackground, fallback: Color(nsColor: .selectedContentBackgroundColor))
    }
    /// True when the palette names a selection colour of its own.
    var hasSelectionColor: Bool { selectionBackground != nil }
    var surface0Color: Color { color(surface0, fallback: .clear) }
    var surface1Color: Color { color(surface1, fallback: .clear) }
    var separatorColor: Color { color(surfaceDim, fallback: Color(nsColor: .separatorColor)) }

    /// The fill of the whole band a split divider sits in — the seam between two panes.
    ///
    /// `surface_dim` is the theme's "very dim surface, for separators" role, which is
    /// exactly this. A theme that leaves it unset may still name its surfaces, so
    /// `panel_background` is the next best answer: the gap belongs to the chrome, not
    /// to the terminal.
    ///
    /// The last fallback is `.clear`, **not** a platform colour, and that is the whole
    /// reason this accessor exists. `Color(nsColor: .separatorColor)` and
    /// `Color.secondary` describe the *system* appearance; the panes do not follow it.
    /// A light-mode Mac running a dark theme got a `(223,223,223)` band between two
    /// `(17,20,25)` panes — that is `.secondary` at 0.25 over a white
    /// `textBackgroundColor` — so the one piece of chrome that touches terminal content
    /// was the one piece the theme could not reach. `.clear` says "the theme has no
    /// opinion", which leaves the container's own background showing and matches what
    /// every other `nil` token in this type means.
    var paneGapColor: Color {
        color(surfaceDim, fallback: color(panelBackground, fallback: .clear))
    }

    /// The 1pt line down the middle of a split divider.
    ///
    /// `surface0` is the theme's "subtle surface" step, one notch up from the band it
    /// is drawn on, which is what makes the seam readable without a platform colour.
    ///
    /// `.clear` when the theme names no surface, for the same reason as
    /// ``paneGapColor``: the platform's separator is drawn for the system appearance,
    /// and a dark-theme terminal on a light Mac then gets a bright hairline running
    /// through its own colours. "No opinion" means the band alone is the seam.
    var paneGapLineColor: Color { color(surface0, fallback: .clear) }

    /// The fill of a pane's border cell — the ring the daemon reserves outside
    /// `innerRect`.
    ///
    /// It must match what the pane's *content* is drawn on, because the border is
    /// continuous with it: a different colour there reads as a one-row blank band
    /// above and below every pane. That is the defect this token exists for, and it
    /// became visible only once the container got a themed tint — before that the
    /// border and the container happened to be the same platform colour.
    ///
    /// `panel_background` first: it is the theme's own chrome surface and the closest
    /// thing to "the surface a pane sits on". `.clear` last, which leaves the
    /// container behind it, i.e. `paneGapColor` — the seam's colour, which is what a
    /// caller with no better information would pick anyway.
    var paneSurfaceColor: Color {
        color(panelBackground, fallback: color(surfaceDim, fallback: .clear))
    }
    /// The terminal background as the `RRGGBB` string Ghostty's config takes.
    ///
    /// `surface_dim` is the fallback because every built-in theme names it and it is
    /// the theme's "very dim surface" — for gruvbox it is `#282828`, which is literally
    /// that theme's own `background`.
    var terminalBackgroundHex: String? {
        guard let token = terminalBackground ?? surfaceDim else { return nil }
        return String(format: "%02X%02X%02X",
                      (token >> 16) & 0xFF, (token >> 8) & 0xFF, token & 0xFF)
    }

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
