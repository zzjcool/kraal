// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  Density.swift
//  KraalUI
//
//  How much air the chrome gives each row.
//
//  Rex separates density from the theme (`MaterialStyles-*.json` carries
//  `density: comfortable|compact` next to the glass settings, and the app has
//  `client.sidebar.density.toggle`), which is the right split: a theme decides
//  colour, and how many rows fit on the screen is a different question — asked by
//  a different user, on a different day.
//
//  ## Two numbers, not a scale factor
//
//  A multiplier would have to be applied at every `padding(...)` call, and a
//  missed one shows as a row that is half compact. The two densities are instead
//  spelled out per surface, so a change to one cannot silently resize another.
//
//  Only the vertical padding is here. Horizontal spacing is a reading-width
//  decision that does not get better when compressed; the terminal grid has its
//  own scaling (`FontScale`) and is not affected by this at all.
//

import SwiftUI

public enum Density: String, CaseIterable, Sendable {
    case comfortable
    case compact

    public var title: String {
        switch self {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }

    /// Padding above and below a sidebar row's content.
    ///
    /// Comfortable is what every version before this used: 2pt of padding around a
    /// 16pt content band, so a row is 20pt and its highlight fills it. Compact
    /// drops the padding and lets the content define the row.
    public var rowVerticalPadding: CGFloat {
        switch self {
        case .comfortable: 2
        case .compact: 0
        }
    }

    /// Padding above and below the tab bar's labels. Comfortable keeps the 4pt the
    /// bar always had; compact halves it.
    public var tabBarVerticalPadding: CGFloat {
        switch self {
        case .comfortable: KraalTheme.Space.tight
        case .compact: 2
        }
    }

    public var toggled: Density {
        self == .comfortable ? .compact : .comfortable
    }

    public static let defaultsKey = "KraalSidebarDensity"

    /// The saved density, or comfortable — the shape every earlier version drew.
    public static func stored(in defaults: UserDefaults = .standard) -> Density {
        guard let raw = defaults.string(forKey: defaultsKey), let density = Density(rawValue: raw) else {
            return .comfortable
        }
        return density
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Density.defaultsKey)
    }
}

private struct DensityKey: EnvironmentKey {
    static let defaultValue = Density.comfortable
}

public extension EnvironmentValues {
    /// How much vertical air the chrome gives each row.
    var density: Density {
        get { self[DensityKey.self] }
        set { self[DensityKey.self] = newValue }
    }
}
