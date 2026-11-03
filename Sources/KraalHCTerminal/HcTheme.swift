// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The window's colors, as tokens — one layer between the theme presets and every
// view. Nothing outside this file hardcodes a hex value for chrome.
//
// A theme is a terminal palette (background, foreground, selection, cursor, 16
// ANSI colors) plus the panel colors derived from it. The derivation is a port of
// herdr-app `src/settings.rs` `resolve()`: `chrome` (titlebar/sidebar/status bar)
// and `canvas` (behind pane cards) step away from the terminal's background, the
// dark halving going toward black and the light one toward a warm grey. The two
// mix factors below are the measured ones, not the ones in the 0.1.11 sources:
//
//   dark  graphite   chrome #0A0B0D  canvas/pane header #0F1013  popover #25272B
//   light paper      chrome #F1F1EE  canvas/pane header #FFFFFF  popover #FFFFFF
//
// Those numbers come from `docs/audits/2026-11/official-dark.png` and
// `official-main.png` (pixel samples, see `HcThemeTests`). The light half matches
// the source derivation exactly; the dark half measures 0.55/0.35 instead of the
// 0.32/0.16 in the checked-out 0.1.11 source, so the shipped 0.1.12 build differs
// from its own sources here. Screenshots win: they are the acceptance evidence.

import SwiftUI

/// One color token. Channels are 0...255 so a hex round-trip is exact, and so a
/// token can be compared in a test without going through `NSColor`.
public struct HcColor: Equatable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int
    /// 0...255. Tokens like `hover`, `selected`, `border` and `input` are
    /// translucent on purpose: they sit on whatever panel is behind them.
    public let alpha: Int

    public init(red: Int, green: Int, blue: Int, alpha: Int = 255) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// `#rrggbb` or `#rrggbbaa`, lowercase or not.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(rgb: value)
        } else {
            self.init(
                red: Int((value >> 24) & 0xFF),
                green: Int((value >> 16) & 0xFF),
                blue: Int((value >> 8) & 0xFF),
                alpha: Int(value & 0xFF)
            )
        }
    }

    public init(rgb: UInt32, alpha: Int = 255) {
        self.init(
            red: Int((rgb >> 16) & 0xFF),
            green: Int((rgb >> 8) & 0xFF),
            blue: Int(rgb & 0xFF),
            alpha: alpha
        )
    }

    public static let clear = HcColor(rgb: 0x000000, alpha: 0)
    public static let black = HcColor(rgb: 0x000000)
    public static let white = HcColor(rgb: 0xFFFFFF)

    public var hex: String {
        let body = String(format: "#%02x%02x%02x", red, green, blue)
        guard alpha < 255 else { return body }
        return body + String(format: "%02x", alpha)
    }

    public var color: Color {
        Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }

    /// `t == 0` is `a`, `t == 1` is `b`; channels round half away from zero like
    /// the Rust `f32::round` the upstream derivation uses. Alpha follows `a`.
    public static func mix(_ from: HcColor, _ into: HcColor, _ amount: Double) -> HcColor {
        func blend(_ start: Int, _ end: Int) -> Int {
            Int((Double(start) * (1 - amount) + Double(end) * amount).rounded())
        }
        return HcColor(
            red: blend(from.red, into.red),
            green: blend(from.green, into.green),
            blue: blend(from.blue, into.blue),
            alpha: from.alpha
        )
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 255) }
}

/// A preset. `paper` is the light half; the rest are dark, like upstream.
public enum HcThemeName: String, CaseIterable, Codable, Sendable {
    case graphite
    case ink
    case moss
    case atomOneDark = "atom-one-dark"
    case paper

    public var isLight: Bool { self == .paper }

    /// The swatch label: `atom-one-dark` reads `atom one dark`.
    public var displayName: String { rawValue.replacingOccurrences(of: "-", with: " ") }

    /// The themes the Look page offers for one appearance, presets in upstream
    /// order (the settings screen draws them as swatches in this order).
    public static func presets(isLight: Bool) -> [HcThemeName] {
        isLight ? [.paper] : [.graphite, .ink, .moss, .atomOneDark]
    }

    public static func presets(for appearance: HcAppearance) -> [HcThemeName] {
        appearance == .light ? presets(isLight: true) : presets(isLight: false)
    }
}

/// Every color the window uses, resolved for one theme.
public struct HcTheme: Equatable, Sendable {
    public let name: HcThemeName
    public let isLight: Bool

    /// The terminal's own background and text; also what inputs sit on.
    public let background: HcColor
    public let terminalForeground: HcColor
    /// Text in chrome (sidebar rows, labels, buttons).
    public let foreground: HcColor
    /// Titlebar, sidebar and status bar — one panel, one color.
    public let chrome: HcColor
    /// Behind pane cards, and the pane header's own fill.
    public let canvas: HcColor
    public let paneHeader: HcColor
    /// Dialogs, the palette, sheets: the panel that floats over `canvas`.
    public let popover: HcColor
    /// Selected rows, cards, buttons.
    public let raised: HcColor
    public let hover: HcColor
    public let selected: HcColor
    public let border: HcColor
    public let input: HcColor
    public let muted: HcColor
    public let dim: HcColor
    public let accent: HcColor
    public let accentForeground: HcColor
    /// Primary button fill and its text (upstream `solid`).
    public let solid: HcColor
    public let solidForeground: HcColor
    public let ring: HcColor
    public let selection: HcColor
    public let cursor: HcColor
    public let working: HcColor
    public let blocked: HcColor
    public let done: HcColor
    public let idle: HcColor
    public let unknown: HcColor
    /// The 16 ANSI colors, for swatches and the terminal.
    public let ansi: [HcColor]

    /// The ANSI colors the Look page shows under a theme name.
    public var swatchDots: [HcColor] { [accent, ansi[1], ansi[2], ansi[3], ansi[5]] }

    public static let darkMix = 0.55
    public static let canvasMix = 0.35

    public static func resolve(_ name: HcThemeName) -> HcTheme {
        let palette = HcPalette(name: name)
        let base = HcColor(rgb: palette.background)
        let text = HcColor(rgb: palette.foreground)
        let light = name.isLight
        let warm = HcColor(rgb: 0xE8E8E2)

        let chrome = light ? HcColor.mix(base, warm, 0.6) : HcColor.mix(base, .black, darkMix)
        let canvas = light ? base : HcColor.mix(base, .black, canvasMix)
        let popover = light ? base : HcColor.mix(base, .white, 0.06)
        let raised = light ? HcColor.mix(base, .black, 0.035) : HcColor.mix(base, .white, 0.09)
        let uiText = light ? HcColor(rgb: 0x1B1B1E) : HcColor(rgb: 0xEEEEEF)
        let status = palette.status ?? [palette.ansi[3], palette.ansi[1], palette.ansi[4]]

        return HcTheme(
            name: name,
            isLight: light,
            background: base,
            terminalForeground: text,
            foreground: uiText,
            chrome: chrome,
            canvas: canvas,
            paneHeader: canvas,
            popover: popover,
            raised: raised,
            hover: light ? HcColor(rgb: 0x000000, alpha: 0x0C) : HcColor(rgb: 0xFFFFFF, alpha: 0x0E),
            selected: light ? HcColor(rgb: 0x000000, alpha: 0x12) : HcColor(rgb: 0xFFFFFF, alpha: 0x17),
            border: light ? HcColor(rgb: 0x000000, alpha: 0x17) : HcColor(rgb: 0xFFFFFF, alpha: 0x18),
            input: light ? HcColor(rgb: 0x000000, alpha: 0x26) : HcColor(rgb: 0xFFFFFF, alpha: 0x24),
            muted: HcColor.mix(base, uiText, light ? 0.66 : 0.6),
            dim: HcColor.mix(base, uiText, light ? 0.46 : 0.38),
            accent: HcColor(rgb: palette.ansi[4]),
            accentForeground: base,
            solid: uiText,
            solidForeground: light ? .white : HcColor.mix(base, .black, 0.28),
            ring: HcColor.mix(base, uiText, 0.7),
            selection: HcColor(rgb: palette.selection),
            cursor: HcColor(rgb: palette.cursor ?? palette.foreground),
            working: HcColor(rgb: status[0]),
            blocked: HcColor(rgb: status[1]),
            done: HcColor(rgb: status[2]),
            idle: HcColor.mix(base, uiText, 0.38),
            unknown: HcColor.mix(base, uiText, 0.38),
            ansi: palette.ansi.map { HcColor(rgb: $0) }
        )
    }

    /// The half of the pair the appearance asks for. `systemIsDark` is the
    /// window's `colorScheme`; a light name in the dark slot (or the other way
    /// round) falls back to that half's default instead of painting a dark
    /// window white.
    public static func resolve(
        _ appearance: HcAppearance,
        light: HcThemeName,
        dark: HcThemeName,
        systemIsDark: Bool
    ) -> HcTheme {
        let lightName = light.isLight ? light : .paper
        let darkName = dark.isLight ? .graphite : dark
        switch appearance {
        case .light: return resolve(lightName)
        case .dark: return resolve(darkName)
        case .system: return resolve(systemIsDark ? darkName : lightName)
        }
    }
}

/// A terminal palette, as herdr-app shipped it (`src/settings.rs`).
struct HcPalette {
    let background: UInt32
    let foreground: UInt32
    let selection: UInt32
    let cursor: UInt32?
    let ansi: [UInt32]
    /// working, blocked, done. Theme files take them from ANSI yellow/red/blue;
    /// the presets pick their own so the sidebar reads the same in every preset.
    let status: [UInt32]?

    private static let darkStatus: [UInt32] = [0xE5C07B, 0xF0705F, 0x76A8FF]

    init(name: HcThemeName) {
        switch name {
        case .graphite:
            background = 0x17191D
            foreground = 0xD2D4D9
            selection = 0x394454
            cursor = nil
            status = Self.darkStatus
            ansi = [
                0x45484F, 0xDC8C95, 0xA6BD91, 0xD8BE87, 0x96B2D7, 0xB5A2CE, 0x8CBDC3, 0xD2D4D9,
                0x818793, 0xF0A5AD, 0xBAD5A2, 0xEAD2A1, 0xB0CBEF, 0xCBB7E6, 0xA4D5DB, 0xF0F0F2,
            ]
        case .ink:
            background = 0x111720
            foreground = 0xCDD6E4
            selection = 0x344861
            cursor = nil
            status = Self.darkStatus
            ansi = [
                0x414B5A, 0xE58C9A, 0x89C5AA, 0xD9BE82, 0x91B6EE, 0xB9A0E2, 0x85C4D0, 0xCDD6E4,
                0x7F91A7, 0xF5A5B2, 0xA5DEC3, 0xEDD39C, 0xACCBFA, 0xD0B7F4, 0xA0DCE5, 0xF0F5FC,
            ]
        case .moss:
            background = 0x151C19
            foreground = 0xCDD7CE
            selection = 0x354A40
            cursor = nil
            status = Self.darkStatus
            ansi = [
                0x435248, 0xDF978D, 0xA0C4A2, 0xD4BC8B, 0x99B9CD, 0xBBA4C8, 0x8BBDB5, 0xCDD7CE,
                0x82968A, 0xF1AFA3, 0xB8DAB9, 0xE9D2A5, 0xB1D0E2, 0xD1BDDC, 0xA4D6CA, 0xEFF5EE,
            ]
        case .atomOneDark:
            background = 0x21252B
            foreground = 0xABB2BF
            selection = 0x323844
            cursor = 0xABB2BF
            status = nil
            ansi = [
                0x454C59, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                0x767676, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
            ]
        case .paper:
            background = 0xFFFFFF
            foreground = 0x25272C
            selection = 0xCFDCF5
            cursor = 0x25272C
            status = [0x9A6700, 0xC93C2C, 0x2F6FE4]
            // Bright white is ink, not white: programs write it as "strong" text.
            ansi = [
                0x25272C, 0xC62A2A, 0x1A7F37, 0x8F5D00, 0x1F62D0, 0x7A45C8, 0x0F6F74, 0x5F6068,
                0x7B7E87, 0xD1242F, 0x1F883D, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x111214,
            ]
        }
    }
}

// MARK: - Environment

private struct HcThemeKey: EnvironmentKey {
    static let defaultValue = HcTheme.resolve(.graphite)
}

public extension EnvironmentValues {
    /// Every view that paints chrome reads its colors from here, so a window
    /// only has to inject the theme once.
    var hcTheme: HcTheme {
        get { self[HcThemeKey.self] }
        set { self[HcThemeKey.self] = newValue }
    }
}

public extension View {
    func hcTheme(_ theme: HcTheme) -> some View {
        environment(\.hcTheme, theme)
    }
}
