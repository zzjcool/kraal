// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Testing

@testable import KraalHCTerminal

@Suite("Split drag")
struct HcSplitMathTests {
    @Test("a drag keeps the pair's total and clamps both sides")
    func drag() throws {
        let moved = try #require(HcSplitMath.resized([0.5, 0.5], index: 0, translation: 50, available: 500))
        #expect(abs(moved[0] - 0.6) < 0.0001)
        #expect(abs(moved[0] + moved[1] - 1) < 0.0001)
        let clamped = try #require(HcSplitMath.resized([0.5, 0.5], index: 0, translation: 1000, available: 500))
        #expect(abs(clamped[0] - 0.928) < 0.0001)
        #expect(abs(clamped[1] - 0.072) < 0.0001)
    }

    @Test("a pair too small for the minimum is left alone")
    func tooSmall() {
        #expect(HcSplitMath.resized([0.01, 0.01], index: 0, translation: 10, available: 20) == nil)
        #expect(HcSplitMath.resized([0.5, 0.5], index: 1, translation: 10, available: 100) == nil)
        #expect(HcSplitMath.resized([0.5, 0.5], index: 0, translation: 10, available: 0) == nil)
    }

    @Test("AX adjustment moves the same pair by a fixed step")
    func adjusted() throws {
        let next = try #require(HcSplitMath.adjusted([0.5, 0.5], index: 0, delta: 0.05))
        #expect(abs(next[0] - 0.55) < 0.0001)
        #expect(abs(next[0] + next[1] - 1) < 0.0001)
        let clamped = try #require(HcSplitMath.adjusted([0.02, 0.5], index: 0, delta: -0.2))
        #expect(abs(clamped[0] - 0.05) < 0.0001)
    }
}
