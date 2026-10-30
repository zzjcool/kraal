// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  DensityTests.swift
//  KraalClientTests
//
//  The two densities as numbers, and what a launch reads back.
//

import Foundation
import Testing
@testable import KraalUI

@MainActor
struct DensityTests {
    @Test func compactIsTighterEverywhere() {
        #expect(Density.compact.rowVerticalPadding < Density.comfortable.rowVerticalPadding)
        #expect(Density.compact.tabBarVerticalPadding < Density.comfortable.tabBarVerticalPadding)
    }

    @Test func comfortableIsWhatEveryEarlierVersionDrew() {
        // 2pt around a 16pt band: the row the sidebar had before this setting.
        #expect(Density.comfortable.rowVerticalPadding == 2)
        #expect(Density.comfortable.tabBarVerticalPadding == KraalTheme.Space.tight)
    }

    @Test func togglingTwiceIsTheOriginal() {
        var density = Density.comfortable
        density = density.toggled
        #expect(density == .compact)
        #expect(density.toggled == .comfortable)
    }

    @Test func theChoiceSurvivesRelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "kraal.density.tests"))
        defaults.removeObject(forKey: Density.defaultsKey)
        #expect(Density.stored(in: defaults) == .comfortable)
        Density.compact.store(in: defaults)
        #expect(Density.stored(in: defaults) == .compact)
        defaults.removeObject(forKey: Density.defaultsKey)
    }

    @Test func anUnknownStoredValueFallsBack() throws {
        let defaults = try #require(UserDefaults(suiteName: "kraal.density.tests"))
        defaults.set("gigantic", forKey: Density.defaultsKey)
        #expect(Density.stored(in: defaults) == .comfortable)
        defaults.removeObject(forKey: Density.defaultsKey)
    }
}
