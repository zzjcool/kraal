// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ThemeEnvironment.swift
//  KraalUI
//
//  Carries the resolved palette down the view tree, and keeps it current.
//
//  A custom `EnvironmentKey` rather than `@Environment(\.colorScheme)`: the palette is
//  the user's theme, not the system's, and a theme can legitimately disagree with the
//  appearance (a dark theme on a light Mac is a choice, not a bug). Views ask for a
//  token through `@Environment(\.palette)` and never for a literal colour.
//
//  ## Why a single source of truth matters here
//
//  Before, `sidebarColor("green")` was a free function, so any view could produce a
//  colour that no theme could change and no test could observe. Routing everything
//  through one environment value means "did the theme apply?" is answerable by looking
//  at one object instead of grepping for literals.
//

import AppKit
import KraalProtocol
import SwiftUI

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.catppuccin
}

public extension EnvironmentValues {
    /// The colours this view tree draws with.
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Owns the current theme and re-resolves it when the system appearance changes.
///
/// `@Observable` so a theme change redraws the views that read it; the alternative —
/// reading the config file in each view's body — would mean I/O per frame.
@MainActor
@Observable
public final class ThemeStore {
    /// The palette every view uses.
    public private(set) var palette: Palette
    /// The canonical name of the theme in use, for the debug panel and the GUI gate.
    public private(set) var themeName: String
    /// The config this store was built from, kept so a reload can be compared.
    public private(set) var config: ThemeConfig
    /// The appearance the current palette was chosen for.
    public private(set) var appearance: HostAppearance
    /// The Ghostty theme the user picked in the app, when there is one.
    ///
    /// `nil` means "follow `config.toml`", which is the behaviour every version
    /// before the picker had. A pick says the opposite: the chrome and the terminal
    /// are this theme, whatever the daemon's config says — the same split Rex has
    /// between its `client.theme.change` and the server's own settings.
    public private(set) var ghostty: GhosttyTheme?

    /// Called after every palette swap, for owners that need a colour outside SwiftUI.
    ///
    /// The terminals are the one such owner: Ghostty takes its background as a
    /// construction-time configuration command, so it cannot read the environment
    /// palette and has to be rebuilt instead.
    public var onPaletteChange: ((Palette) -> Void)?
    /// Called after every theme swap with the picked Ghostty theme, so the
    /// terminals can take its foreground, cursor and sixteen colours.
    ///
    /// Separate from ``onPaletteChange`` because a `config.toml` theme has no ANSI
    /// palette on this side: the daemon resolves it, and passing `nil` leaves the
    /// engine's own colours alone.
    public var onTerminalTheme: ((GhosttyTheme?) -> Void)?

    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?

    /// Builds a store from the user's `config.toml`.
    ///
    /// `config` defaults to reading the file, not to `.default`: the first version of
    /// this initialiser defaulted to `.default` and every caller used the default, so
    /// the config was never loaded and the client silently drew Catppuccin while
    /// `theme.name = "nord"` sat in the file. The default is the *sane* behaviour; a
    /// caller that wants a fixed theme passes one explicitly.
    public init(
        config: ThemeConfig? = nil,
        appearance: HostAppearance? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let config = config ?? ThemeConfig.load(environment: environment)
        let resolvedAppearance = appearance ?? ThemeResolver.hostAppearance
        let (palette, name) = ThemeResolver.resolve(config, appearance: resolvedAppearance)
        self.config = config
        self.palette = palette
        self.themeName = name
        self.appearance = resolvedAppearance
        self.ghostty = Self.savedTheme(environment: environment)
        if let ghostty {
            // A saved pick wins over the config; `apply` below is what keeps the
            // two from disagreeing after a reload.
            self.palette = Palette.derived(from: ghostty)
            self.themeName = ghostty.name
        }
        let source = ghostty == nil ? "config" : "ghostty"
        kraalLog("theme: applied \(themeName) (source=\(source) appearance=\(resolvedAppearance.rawValue))")
    }

    /// The theme name saved by the picker, resolved to a bundled theme.
    ///
    /// `KRAAL_THEME` comes first so a GUI case can pin a theme without writing to
    /// the user's defaults — a test that edits `UserDefaults.standard` leaves the
    /// developer's own pick changed behind it.
    static func savedTheme(environment: [String: String]) -> GhosttyTheme? {
        let candidate = environment["KRAAL_THEME"]
            ?? UserDefaults.standard.string(forKey: themeDefaultsKey)
        guard let candidate, !candidate.isEmpty else { return nil }
        let theme = GhosttyThemeCatalog.named(candidate) ?? GhosttyThemeCatalog.identified(by: candidate)
        if theme == nil { kraalLog("theme: \(candidate) is not a bundled theme; following config.toml") }
        return theme
    }

    static let themeDefaultsKey = "KraalThemeName"

    /// Applies the theme the user picked, or goes back to `config.toml` with `nil`.
    ///
    /// Persisting here rather than in the picker keeps the rule in one place: what
    /// is saved is what is applied, and a relaunch lands on the same theme.
    public func selectTheme(_ pick: GhosttyTheme?) {
        UserDefaults.standard.set(pick?.id, forKey: Self.themeDefaultsKey)
        kraalLog("theme: picked \(pick?.name ?? "config.toml")")
        apply(configuration: config)
    }

    /// Starts following the system's light/dark setting.
    ///
    /// Only meaningful with `auto_switch = true`, but the observer is installed either
    /// way: the config can be reloaded at any time, and an observer that had to be
    /// added later would be one more thing to forget.
    public func followSystemAppearance(_ app: NSApplication = NSApp) {
        guard appearanceObserver == nil else { return }
        appearanceObserver = app.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshAppearance()
            }
        }
    }

    /// Re-reads the system appearance; a no-op when it has not changed.
    public func refreshAppearance() {
        let now = ThemeResolver.hostAppearance
        guard now != appearance else { return }
        appearance = now
        apply(configuration: config)
    }

    /// Swaps in a newly loaded config.
    public func apply(configuration: ThemeConfig) {
        config = configuration
        // The pick is re-read rather than trusted: `selectTheme` is not the only
        // writer (a test can set `KRAAL_THEME`, a relaunch reads defaults), and a
        // stale `ghostty` here is how a reload would silently undo the user's pick.
        ghostty = Self.savedTheme(environment: ProcessInfo.processInfo.environment)
        if let ghostty {
            palette = Palette.derived(from: ghostty)
            themeName = ghostty.name
            kraalLog("theme: applied \(ghostty.name) (source=ghostty appearance=\(appearance.rawValue))")
        } else {
            let resolved = ThemeResolver.resolve(configuration, appearance: appearance)
            palette = resolved.palette
            themeName = resolved.name
            kraalLog("theme: applied \(resolved.name) (source=config appearance=\(appearance.rawValue))")
        }
        onPaletteChange?(palette)
        onTerminalTheme?(ghostty)
    }

    /// Re-reads `config.toml` from disk.
    ///
    /// Called after the daemon's own `server.reload_config`, which is what the user
    /// triggers when they edit the file: the daemon re-reads its side, and this re-reads
    /// the client's. Without it the palette needed a relaunch while everything else
    /// updated, which reads as "the theme is broken".
    public func reloadFromDisk(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        kraalLog("theme: reload requested")
        let loaded = ThemeConfig.load(environment: environment)
        apply(configuration: loaded)
    }
}
