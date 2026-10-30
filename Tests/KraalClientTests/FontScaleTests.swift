// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  FontScaleTests.swift
//  KraalClientTests
//
//  The three font-size commands, as arithmetic.
//

import Testing
@testable import KraalUI

@MainActor
struct FontScaleTests {
    @Test func increaseAddsOnePoint() {
        #expect(FontScale.next(13, change: .increase) == 14)
        #expect(FontScale.next(20, change: .increase) == 21)
    }

    @Test func decreaseSubtractsOnePoint() {
        #expect(FontScale.next(13, change: .decrease) == 12)
    }

    @Test func resetReturnsTheEngineDefault() {
        #expect(FontScale.next(31, change: .reset) == 13)
        #expect(FontScale.base == 13)
    }

    @Test func theRangeIsClamped() {
        #expect(FontScale.next(FontScale.maximum, change: .increase) == FontScale.maximum)
        #expect(FontScale.next(FontScale.minimum, change: .decrease) == FontScale.minimum)
        #expect(FontScale.clamp(100) == 32)
        #expect(FontScale.clamp(1) == 8)
    }

    @Test func pressingTenTimesDoesNotRunAway() {
        var size = FontScale.base
        for _ in 0..<30 { size = FontScale.next(size, change: .increase) }
        #expect(size == FontScale.maximum)
        for _ in 0..<40 { size = FontScale.next(size, change: .decrease) }
        #expect(size == FontScale.minimum)
    }

    @Test func theLabelHasNoTrailingZero() {
        #expect(FontScale.label(13) == "13")
        #expect(FontScale.label(13.5) == "13.5")
    }
}
