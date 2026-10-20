// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Theme and small shared view pieces.
//
// Colors are resolved from the same vocabulary `config.toml` uses ("red",
// "#ff8800", "blue"), so an imported config styles the native UI directly instead
// of needing a second color system.

import SwiftUI
import KraalProtocol
import KraalSidebar
import KraalTransport

public enum KraalTheme {
    public static let sidebarWidth: CGFloat = 220
    public static let tabBarHeight: CGFloat = 32
    public static let statusBarHeight: CGFloat = 24
    public static let rowSpacing: CGFloat = 1
    public static let cornerRadius: CGFloat = 6

    /// Corner radii, in three sizes so a bar, a row and an overlay read as one
    /// family instead of three hand-picked numbers.
    public enum Radius {
        /// Selection pills inside bars and rows.
        public static let control: CGFloat = 6
        /// Floating overlays (command palette, HUDs).
        public static let overlay: CGFloat = 12
        /// Sheets and panels.
        public static let panel: CGFloat = 10
    }

    /// Spacing scale. Values are multiples of 2 so vertical rhythm stays even
    /// across bars, list rows and sheet headers.
    public enum Space {
        public static let hairline: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 6
        public static let base: CGFloat = 8
        public static let roomy: CGFloat = 12
        public static let loose: CGFloat = 16
        public static let section: CGFloat = 20
    }

    /// Text sizes used by the chrome.
    ///
    /// The terminal picks its own font from cell metrics and is intentionally not
    /// part of this scale — chrome text is UI, terminal text is content.
    public enum Font {
        public static let barLabel = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let rowTitle = SwiftUI.Font.system(size: 12)
        public static let rowTitleFocused = SwiftUI.Font.system(size: 12, weight: .semibold)
        public static let rowDetail = SwiftUI.Font.system(size: 10)
        public static let sectionHeader = SwiftUI.Font.system(size: 10, weight: .semibold)
        public static let caption = SwiftUI.Font.system(size: 10)
        public static let micro = SwiftUI.Font.system(size: 9)
    }
}

/// Resolves a `config.toml` color name or hex literal.
public func sidebarColor(_ name: String, fallback: Color = .primary) -> Color {
    switch name.lowercased() {
    case "black": return Color(red: 0.12, green: 0.12, blue: 0.14)
    case "red": return Color(red: 0.90, green: 0.35, blue: 0.36)
    case "green": return Color(red: 0.42, green: 0.78, blue: 0.48)
    case "yellow": return Color(red: 0.92, green: 0.78, blue: 0.38)
    case "blue": return Color(red: 0.40, green: 0.62, blue: 0.95)
    case "magenta": return Color(red: 0.83, green: 0.47, blue: 0.92)
    case "cyan": return Color(red: 0.38, green: 0.80, blue: 0.84)
    case "white": return Color(red: 0.92, green: 0.92, blue: 0.94)
    case "gray", "grey": return Color(red: 0.55, green: 0.56, blue: 0.60)
    case "purple": return Color(red: 0.70, green: 0.50, blue: 0.95)
    case "orange": return Color(red: 0.95, green: 0.60, blue: 0.30)
    case "pink": return Color(red: 0.95, green: 0.55, blue: 0.72)
    default:
        return Color(hex: name) ?? fallback
    }
}

public extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Applies a `TokenStyle` on top of the environment's defaults.
struct StyledText: View {
    let text: String
    let style: TokenStyle
    var monospaced = false

    var body: some View {
        var view = Text(text)
        if style.bold == true { view = view.bold() }
        if style.italic == true { view = view.italic() }
        if let foreground = style.foreground {
            view = view.foregroundStyle(sidebarColor(foreground, fallback: .primary))
        }
        if style.dim == true {
            view = view.foregroundStyle(sidebarColor("gray", fallback: .secondary))
        }
        if monospaced {
            view = view.monospaced()
        }
        return view
    }
}

/// A state glyph with a stable color, so a row's left edge reads at a glance.
struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityLabel(SidebarTokenResolver.statusWord(for: status))
    }

    private var color: Color {
        switch status {
        case .idle: sidebarColor("gray")
        case .working: sidebarColor("yellow")
        case .blocked: sidebarColor("red")
        case .done: sidebarColor("green")
        case .unknown: sidebarColor("gray").opacity(0.5)
        }
    }
}
