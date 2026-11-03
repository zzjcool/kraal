// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The settings Kraal applies itself (not the shared layout document). Values are
// persisted in UserDefaults and pushed into every live Ghostty surface.

import AppKit
import Foundation
import GhosttyTerminal

public enum HcDensity: String, CaseIterable, Codable, Sendable {
    case comfortable
    case compact

    public var title: String { self == .comfortable ? "Comfortable" : "Compact" }
    public var rowPadding: CGFloat { self == .comfortable ? 2 : 0 }
    public var tabPadding: CGFloat { self == .comfortable ? 3 : 1 }
}

public enum HcAppearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

public struct HcTerminalSettings: Codable, Equatable, Sendable {
    public var fontSize: Double = 13
    public var paddingX: Int = 0
    public var paddingY: Int = 0
    public var backgroundOpacity: Double = 1
    public var minimumContrast: Double = 0
    public var density: HcDensity = .comfortable
    public var soundEnabled = true
    public var appearance: HcAppearance = .system
    public var optionAsAlt = false
    /// The light and dark halves of the window's own theme pair. Each appearance
    /// keeps its own, like the official app: switching to dark does not forget
    /// which dark theme was picked.
    public var themeLight: HcThemeName = .paper
    public var themeDark: HcThemeName = .graphite

    public static let defaultsKey = "kraal.hc.terminal-settings"

    /// The upstream app keeps both a line and a byte ceiling and stops at
    /// whichever comes first. Ghostty applies them as it trims scrollback.
    public static let scrollbackLines = 10_000
    public static let scrollbackBytes = 10 * 1024 * 1024

    public init() {}

    /// Added fields must not reset an existing settings blob. Every field is
    /// decoded with a fallback for the same reason.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        paddingX = try container.decodeIfPresent(Int.self, forKey: .paddingX) ?? 0
        paddingY = try container.decodeIfPresent(Int.self, forKey: .paddingY) ?? 0
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
        minimumContrast = try container.decodeIfPresent(Double.self, forKey: .minimumContrast) ?? 0
        density = try container.decodeIfPresent(HcDensity.self, forKey: .density) ?? .comfortable
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        appearance = try container.decodeIfPresent(HcAppearance.self, forKey: .appearance) ?? .system
        optionAsAlt = try container.decodeIfPresent(Bool.self, forKey: .optionAsAlt) ?? false
        // A name this build does not know (a hand-edited blob, a theme from a
        // newer build) must not reset the rest of the settings.
        let light = try container.decodeIfPresent(String.self, forKey: .themeLight)
        let dark = try container.decodeIfPresent(String.self, forKey: .themeDark)
        themeLight = light.flatMap(HcThemeName.init(rawValue:)) ?? .paper
        themeDark = dark.flatMap(HcThemeName.init(rawValue:)) ?? .graphite
        if !themeLight.isLight { themeLight = .paper }
        if themeDark.isLight { themeDark = .graphite }
    }

    public static func load(from defaults: UserDefaults = .standard) -> HcTerminalSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(HcTerminalSettings.self, from: data)
        else { return HcTerminalSettings() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// What the surface is actually built with. `fontSize` and padding are
    /// deliberately explicit: Ghostty's defaults differ from Kraal's old 13pt.
    public var terminalConfiguration: TerminalConfiguration {
        TerminalConfiguration()
            .fontSize(Float(fontSize))
            .windowPaddingX(max(0, paddingX))
            .windowPaddingY(max(0, paddingY))
            .backgroundOpacity(min(max(backgroundOpacity, 0.1), 1))
            .minimumContrast(min(max(minimumContrast, 0), 1))
            .custom("macos-option-as-alt", optionAsAlt ? "true" : "false")
            .custom("copy-on-select", "true")
            .custom("scrollback-limit-lines", String(Self.scrollbackLines))
            .custom("scrollback-limit", String(Self.scrollbackBytes))
    }
}

public enum HcFontZoom {
    public static let base: Double = 13
    public static let minimum: Double = 8
    public static let maximum: Double = 32

    public static func next(_ current: Double, by delta: Double) -> Double {
        min(max(current + delta, minimum), maximum)
    }

    public static func reset() -> Double { base }
}

/// The Settings dialog's left rail, in the official order. `app.settings:section`
/// takes these raw values, so they are part of the action contract.
public enum HcSettingsSection: String, CaseIterable, Codable, Sendable {
    case look
    case keyboard
    case machines
    case alerts
    case updates
    case privacy

    public var title: String {
        switch self {
        case .look: "Look"
        case .keyboard: "Keyboard"
        case .machines: "Machines"
        case .alerts: "Alerts"
        case .updates: "Updates"
        case .privacy: "Privacy"
        }
    }

    public var symbol: String {
        switch self {
        case .look: "paintpalette"
        case .keyboard: "keyboard"
        case .machines: "server.rack"
        case .alerts: "bell"
        case .updates: "arrow.triangle.2.circlepath"
        case .privacy: "hand.raised"
        }
    }
}
