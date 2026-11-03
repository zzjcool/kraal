// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Look and first-launch state, kept out of the main model body: the window asks
// one of these for "is the terminal allowed the keyboard right now", "which
// tokens do I paint with", and "has this person seen the tour".

import AppKit
import Foundation

extension HcWorkspaceModel {
    /// A sheet or overlay owns the keyboard while it is open. The terminal
    /// keeps its AppKit first responder until the overlay asks for it, so
    /// binding focus to this flag cannot steal the palette's search field.
    var terminalFocusAllowed: Bool {
        !showPalette && !showSettings && !showHelp && !showWelcome && !pickerVisible
            && renameRequest == nil && closeRequest == nil
    }

    /// Recomputes the tokens after an appearance, theme, or system change.
    public func refreshTheme() {
        let systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        resolvedTheme = HcTheme.resolve(
            settings.appearance,
            light: settings.themeLight,
            dark: settings.themeDark,
            systemIsDark: systemIsDark
        )
    }

    /// `Appearance: System` has to follow the system while the window is up. The
    /// app-level notification is the documented switch (`NSApp.effectiveAppearance`
    /// is not KVO-reliable across macOS versions); activation refreshes too, so a
    /// change made while Kraal was hidden still lands.
    func observeAppearance() {
        guard NSApp != nil else { return }
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTheme() }
        }
        activeObservers.append(observer)
    }

    /// The first-launch tour is offered once per person, not once per window.
    public static let welcomeSeenKey = "kraal.hc.welcome-seen"

    public func welcomeIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.welcomeSeenKey), !showWelcome else { return }
        showWelcome = true
    }

    public func dismissWelcome(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.welcomeSeenKey)
        showWelcome = false
    }

    public func showWelcomeAgain() {
        showWelcome = true
    }

    /// ⌘P: the place picker, not the palette. Both the keymap (`mod.open:picker`)
    /// and the palette's own "Go to space or tab…" row land here, so there is one
    /// way in.
    public func showPlacePicker() {
        showPalette = false
        pickerVisible = true
    }
}
