// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHCTerminal

@Suite("Terminal settings")
struct HcSettingsTests {
    @Test("settings round-trip through UserDefaults")
    func roundTrip() throws {
        let name = "kraal.tests.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = HcTerminalSettings()
        settings.fontSize = 17
        settings.paddingX = 8
        settings.paddingY = 6
        settings.backgroundOpacity = 0.9
        settings.minimumContrast = 0.4
        settings.density = .compact
        settings.soundEnabled = false
        settings.appearance = .dark
        settings.save(to: defaults)
        #expect(HcTerminalSettings.load(from: defaults) == settings)
    }

    @Test("opacity and contrast are clamped for the surface")
    func clamps() {
        var settings = HcTerminalSettings()
        settings.backgroundOpacity = 0
        settings.minimumContrast = 2
        let config = settings.terminalConfiguration
        #expect(config != .init())
    }

    @Test("density changes row and tab padding")
    func density() {
        #expect(HcDensity.comfortable.rowPadding > HcDensity.compact.rowPadding)
        #expect(HcDensity.comfortable.tabPadding > HcDensity.compact.tabPadding)
    }
}
