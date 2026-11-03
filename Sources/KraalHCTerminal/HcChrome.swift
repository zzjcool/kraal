// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The chrome's numbers, colors and pure labels in one place. The values are the
// official herdr-app `resolve()` outputs (see
// docs/audits/2026-11-ui-round1.md §A/F); views read them instead of carrying
// their own literals, and the pure helpers here are unit-tested.

import AppKit
import SwiftUI

// MARK: - Metrics

/// Every fixed size the window chrome uses, in points. Measured from the
/// official app and frozen in the UI contract; keep them in one place so the
/// titlebar, sidebar, panes and status bar cannot drift apart.
public enum HcChromeMetrics {
    public static let windowDefaultWidth: CGFloat = 1280
    public static let windowDefaultHeight: CGFloat = 820
    public static let windowMinWidth: CGFloat = 720
    public static let windowMinHeight: CGFloat = 420

    /// Titlebar height; the 1pt bottom border is drawn on top of it.
    public static let titlebarHeight: CGFloat = 40
    public static let sidebarWidth: CGFloat = 268
    public static let sidebarHeaderHeight: CGFloat = 31
    public static let sidebarRowHeight: CGFloat = 30
    public static let sidebarRowInset: CGFloat = 8
    /// Two 28pt footer rows plus the top border and padding.
    public static let sidebarFooterHeight: CGFloat = 112

    public static let tabHeight: CGFloat = 29
    public static let tabRadius: CGFloat = 7
    public static let tabSpacing: CGFloat = 3
    public static let tabContentInset: CGFloat = 10

    /// Pane header height; the 1pt bottom border is drawn on top of it.
    public static let paneHeaderHeight: CGFloat = 34
    public static let paneRadius: CGFloat = 10
    /// Space between sibling panes; the 1pt divider is centred in it.
    public static let paneGap: CGFloat = 8
    /// Inset around the whole pane tree.
    public static let workInset: CGFloat = 8
    public static let terminalInsetX: CGFloat = 14
    public static let terminalInsetY: CGFloat = 12

    /// Status bar height; the 1pt top border is drawn on top of it.
    public static let statusBarHeight: CGFloat = 26

    public static let spaceAvatarSize: CGFloat = 18
    public static let spaceAvatarRadius: CGFloat = 5
}

// MARK: - Hex palette

/// The same palette as strings, so tests and non-SwiftUI code can talk about
/// the colors without building `Color` values. Light and dark are separate
/// tables: the dark one is derived from background `#0f1013`, not by inverting
/// the light one.
public struct HcChromeHex: Equatable, Sendable {
    public let chrome: String
    public let canvas: String
    public let surface: String
    public let raised: String
    public let hover: String
    public let selected: String
    public let border: String
    public let foreground: String
    public let muted: String
    public let dim: String
    public let accent: String
    public let working: String
    public let blocked: String
    public let done: String
    public let idle: String

    public static let light = HcChromeHex(
        chrome: "#f1f1ee",
        canvas: "#fafaf9",
        surface: "#ffffff",
        raised: "#f6f6f6",
        hover: "#0000000c",
        selected: "#00000012",
        border: "#00000017",
        foreground: "#1b1b1e",
        muted: "#69696b",
        dim: "#969698",
        accent: "#1f62d0",
        working: "#9a6700",
        blocked: "#c93c2c",
        done: "#2f6fe4",
        idle: "#a8a8aa"
    )

    public static let dark = HcChromeHex(
        chrome: "#0a0b0d",
        canvas: "#0c0e10",
        surface: "#0f1013",
        raised: "#1d1e21",
        hover: "#ffffff0e",
        selected: "#ffffff17",
        border: "#ffffff18",
        foreground: "#eeeeef",
        muted: "#959596",
        dim: "#646466",
        accent: "#96b2d7",
        working: "#e5c07b",
        blocked: "#f0705f",
        done: "#76a8ff",
        idle: "#646466"
    )
}

// MARK: - Colors

/// `HcChromeHex` turned into SwiftUI colors. Parsing never traps: an entry that
/// is not `#rrggbb`/`#rrggbbaa` falls back to `.clear` instead of force-unwrapping
/// a `Color(_: String:)` that does not exist on macOS 14.
public struct HcChromeColors {
    public let chrome: Color
    public let canvas: Color
    public let surface: Color
    public let raised: Color
    public let hover: Color
    public let selected: Color
    public let border: Color
    public let foreground: Color
    public let muted: Color
    public let dim: Color
    public let accent: Color
    public let working: Color
    public let blocked: Color
    public let done: Color
    public let idle: Color

    /// The selected theme's tokens in the shell's vocabulary. Keeping this
    /// initializer here means the shell and the themed dialogs cannot drift:
    /// both read the same `HcTheme` resolved from the user's settings.
    public init(theme: HcTheme) {
        chrome = theme.chrome.color
        canvas = theme.canvas.color
        surface = theme.paneHeader.color
        raised = theme.raised.color
        hover = theme.hover.color
        selected = theme.selected.color
        border = theme.border.color
        foreground = theme.foreground.color
        muted = theme.muted.color
        dim = theme.dim.color
        accent = theme.accent.color
        working = theme.working.color
        blocked = theme.blocked.color
        done = theme.done.color
        idle = theme.idle.color
    }

    public init(hex: HcChromeHex) {
        chrome = Self.parse(hex.chrome)
        canvas = Self.parse(hex.canvas)
        surface = Self.parse(hex.surface)
        raised = Self.parse(hex.raised)
        hover = Self.parse(hex.hover)
        selected = Self.parse(hex.selected)
        border = Self.parse(hex.border)
        foreground = Self.parse(hex.foreground)
        muted = Self.parse(hex.muted)
        dim = Self.parse(hex.dim)
        accent = Self.parse(hex.accent)
        working = Self.parse(hex.working)
        blocked = Self.parse(hex.blocked)
        done = Self.parse(hex.done)
        idle = Self.parse(hex.idle)
    }

    public static func forScheme(_ scheme: ColorScheme) -> HcChromeColors {
        HcChromeColors(hex: scheme == .dark ? .dark : .light)
    }

    /// `#rrggbb` (opaque) or `#rrggbbaa` (the 8-digit hover/selected/border
    /// entries); anything else is `.clear`.
    private static func parse(_ value: String) -> Color {
        guard let rgba = HcChromeRGBA(hex: value) else { return .clear }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

/// The one place a hex string becomes channels, so the two hex formats cannot
/// diverge between the palette and its tests.
private struct HcChromeRGBA {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    /// Accepts `#rrggbb` and `#rrggbbaa`, with or without the `#`.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        if text.count == 8 {
            red = Double((value >> 24) & 0xff) / 255
            green = Double((value >> 16) & 0xff) / 255
            blue = Double((value >> 8) & 0xff) / 255
            alpha = Double(value & 0xff) / 255
        } else {
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
            alpha = 1
        }
    }
}

// MARK: - Labels

/// The small strings the chrome shows. Pure functions so the formatting rules
/// (relative time, `~` abbreviation, pluralisation) are testable without a view.
public enum HcChromeFormat {
    /// `<1m`, `1m`, `29m`, `2h`, `3d`; 0/now → "<1m".
    public static func relativeTime(sinceMilliseconds: UInt64, now: UInt64) -> String {
        let elapsed = now > sinceMilliseconds ? now - sinceMilliseconds : 0
        let minutes = elapsed / 60_000
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// "N agents" (always plural, as the official status bar writes it).
    public static func agentsLabel(_ count: Int) -> String {
        "\(count) agents"
    }

    /// "N needs you".
    public static func needsYouLabel(_ count: Int) -> String {
        "\(count) needs you"
    }

    /// `~` for home, `~/x` under home, absolute otherwise; empty stays empty.
    public static func folder(_ path: String, home: String) -> String {
        guard !path.isEmpty else { return "" }
        var base = home
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        // Without a home there is nothing to abbreviate against, and for the
        // root itself `~` would claim more than it means.
        guard !base.isEmpty, base != "/" else { return path }
        if path == base { return "~" }
        let prefix = base + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    public static let commandsHint = "⌘P commands"
    public static let searchHint = "Search"
}

// MARK: - Space palette

/// The six official MARK colors, picked by a stable hash of the space id so a
/// space keeps its avatar color across launches and machines.
public enum HcSpacePalette {
    public static let hex: [String] = [
        "#22a99a",
        "#3fae6a",
        "#e3814f",
        "#5b8def",
        "#8b7cf6",
        "#d9649a",
    ]

    /// 64-bit FNV-1a over the id's UTF-8 bytes, folded into the palette.
    public static func index(for id: String) -> Int {
        guard !hex.isEmpty else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(hex.count))
    }

    public static func hex(for id: String) -> String {
        hex[index(for: id)]
    }
}

// MARK: - Agent icons

/// The SF Symbol for the OSC 7501 `app` word an agent reports. Unknown apps get
/// a generic chip rather than nothing, so a row always has a leading glyph.
public enum HcAgentAppIcon {
    /// The human name the official app gives an agent app. The pane header
    /// uses this, not the terminal's own short word: `claude` reads as the
    /// product, `Claude Code`, just like the app's tab.
    public static func displayName(for app: String?) -> String {
        let word = app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch word.lowercased() {
        case "claude", "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "aider": return "Aider"
        case "gemini": return "Gemini"
        default:
            guard !word.isEmpty else { return "" }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
    }

    public static func symbol(for app: String?) -> String {
        let word = app?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch word {
        case "claude": return "cpu"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "cursor": return "cursorarrow.rays"
        case "aider": return "wand.and.stars"
        case "gemini": return "diamond"
        default: return word.isEmpty ? "terminal" : "cpu"
        }
    }
}

// MARK: - Sidebar sections

/// One sidebar section header: the official order is Needs you, Working,
/// Finished, and Idle only when it has rows.
public struct HcAgentSectionSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: HcAgentStatus

    /// Pins are shown above the status sections, as the official app does:
    /// otherwise re-bucketing by status would hide the pin's effect.
    public static let pinned = HcAgentSectionSpec(id: "pinned", title: "Pinned", status: .idle)

    public static let all: [HcAgentSectionSpec] = [
        HcAgentSectionSpec(id: "blocked", title: "Needs you", status: .blocked),
        HcAgentSectionSpec(id: "working", title: "Working", status: .working),
        HcAgentSectionSpec(id: "done", title: "Finished", status: .done),
        HcAgentSectionSpec(id: "idle", title: "Idle", status: .idle),
    ]
}

/// A section and the rows it shows: a root agent followed by its descendants,
/// in input order.
public struct HcAgentSection: Identifiable, Equatable {
    public let spec: HcAgentSectionSpec
    public let agents: [HcAgent]

    public var id: String { spec.id }
    public var title: String { spec.title }
}

public enum HcAgentSectioning {
    /// Groups the flattened agent list by each root agent's status; a root's
    /// descendants stay in its section. Empty sections are omitted, section
    /// order follows `HcAgentSectionSpec.all`.
    public static func sections(_ agents: [HcAgent]) -> [HcAgentSection] {
        var pinned: [HcAgent] = []
        var rows: [HcAgentStatus: [HcAgent]] = [:]
        var current: HcAgentStatus?
        var currentPinned = false
        for agent in agents {
            // A child is never its own row group: it belongs to the root above it
            // even when its own status is quieter (a blocked root's idle child).
            if agent.depth == 0 {
                current = agent.status
                currentPinned = agent.pinned
            }
            let status = current ?? agent.status
            if currentPinned {
                pinned.append(agent)
            } else {
                rows[status, default: []].append(agent)
            }
        }
        var sections: [HcAgentSection] = []
        if !pinned.isEmpty {
            sections.append(HcAgentSection(spec: .pinned, agents: pinned))
        }
        sections.append(contentsOf: HcAgentSectionSpec.all.compactMap { spec in
            guard let section = rows[spec.status], !section.isEmpty else { return nil }
            return HcAgentSection(spec: spec, agents: section)
        })
        return sections
    }
}
