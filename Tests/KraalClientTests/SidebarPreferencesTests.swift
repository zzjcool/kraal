// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarPreferencesTests.swift
//  KraalClientTests
//
//  The sidebar remembers the split the user dragged it to.
//
//  Upstream keeps the same value in `ClientChromePreferences.sidebar_section_split`
//  and, importantly, keeps it `None` until the user actually drags — a stored `0.5`
//  would be indistinguishable from "never touched". These tests pin that, plus the
//  round-trip.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Sidebar split preferences")
struct SidebarPreferencesTests {
    /// Each test gets its own defaults suite so one cannot see another's writes.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "kraal.tests.sidebar.\(name).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    /// A fresh install has no stored split, and the layout falls back to the default.
    ///
    /// `nil` is the whole point: it means "never dragged", which is what lets the
    /// layout use the configured ratio in future without fighting a stored 0.5.
    @Test("no stored split means never dragged")
    func freshInstallHasNoSplit() {
        let defaults = makeDefaults("fresh")
        #expect(SidebarPreferences.storedSplit(in: defaults) == nil)
        #expect(SidebarPreferences.initialSplit(in: defaults) == SidebarSections.defaultRatio)
    }

    /// Whatever a drag produces comes back the same on the next launch.
    @Test("a dragged split round-trips")
    func splitRoundTrips() {
        let defaults = makeDefaults("roundtrip")
        for ratio in [CGFloat(0.1), 0.33, 0.5, 0.62, 0.9] {
            SidebarPreferences.storeSplit(ratio, in: defaults)
            let restored = SidebarPreferences.storedSplit(in: defaults)
            #expect(restored != nil)
            #expect(abs((restored ?? 0) - ratio) < 0.0001,
                    "stored \(ratio) came back as \(String(describing: restored))")
        }
    }

    /// Clearing returns to "never dragged" rather than storing the default.
    @Test("clearing forgets the split")
    func clearingForgetsIt() {
        let defaults = makeDefaults("clear")
        SidebarPreferences.storeSplit(0.7, in: defaults)
        #expect(SidebarPreferences.storedSplit(in: defaults) != nil)
        SidebarPreferences.clearSplit(in: defaults)
        #expect(SidebarPreferences.storedSplit(in: defaults) == nil)
    }

    /// A non-finite value would come back as NaN and collapse a pane to nothing, so
    /// it is refused at the door instead of being written and clamped later.
    @Test("a non-finite split is refused")
    func nonFiniteIsRefused() {
        let defaults = makeDefaults("nan")
        SidebarPreferences.storeSplit(.nan, in: defaults)
        #expect(SidebarPreferences.storedSplit(in: defaults) == nil)
        SidebarPreferences.storeSplit(.infinity, in: defaults)
        #expect(SidebarPreferences.storedSplit(in: defaults) == nil)
    }

    /// An out-of-range value is stored and returned unchanged: clamping belongs to
    /// the layout, so a value written by a newer build cannot be silently rewritten
    /// by this one and then persisted back in its changed form.
    @Test("an out-of-range split survives the round trip")
    func outOfRangeSurvives() {
        let defaults = makeDefaults("range")
        SidebarPreferences.storeSplit(3.5, in: defaults)
        #expect(SidebarPreferences.storedSplit(in: defaults) == 3.5)
        // And the layout clamps it rather than trusting it.
        let split = SidebarSections.heights(totalHeight: 600, ratio: 3.5)
        let clamped = SidebarSections.heights(
            totalHeight: 600,
            ratio: SidebarSections.maxRatio
        )
        #expect(split == clamped)
    }

    /// The agents ordering is remembered the same way the split is, and `nil` means
    /// "never changed", so a future config-file default can still apply.
    @Test("the agent sort round-trips, and absent means default")
    func agentSortRoundTrips() {
        let defaults = makeDefaults("agentsort")
        #expect(SidebarPreferences.storedAgentSort(in: defaults) == nil)
        #expect(SidebarPreferences.initialAgentSort(in: defaults) == .spaces)
        SidebarPreferences.storeAgentSort(.priority, in: defaults)
        #expect(SidebarPreferences.storedAgentSort(in: defaults) == .priority)
        #expect(SidebarPreferences.initialAgentSort(in: defaults) == .priority)
    }

    /// An unrecognised stored value (written by a newer build) falls back to the
    /// default rather than crashing or producing an empty list.
    @Test("an unknown stored sort falls back to the default")
    func unknownSortFallsBack() {
        let defaults = makeDefaults("badsort")
        defaults.set("some-future-mode", forKey: SidebarPreferences.agentSortKey)
        #expect(SidebarPreferences.storedAgentSort(in: defaults) == nil)
        #expect(SidebarPreferences.initialAgentSort(in: defaults) == .spaces)
    }
}
