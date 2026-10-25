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
        kraalLog("theme: applied \(name) (appearance=\(resolvedAppearance.rawValue))")
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
        let resolved = ThemeResolver.resolve(configuration, appearance: appearance)
        palette = resolved.palette
        themeName = resolved.name
        kraalLog("theme: applied \(resolved.name) (appearance=\(appearance.rawValue))")
    }

    /// Re-reads `config.toml` from disk.
    public func reloadFromDisk(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        apply(configuration: ThemeConfig.load(environment: environment))
    }
}
