// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarSectionsTests.swift
//  KraalClientTests
//
//  The sidebar puts spaces above agents in one column. Upstream draws the same
//  split in `src/ui/sidebar.rs:30-66`; these tests pin the properties that make it
//  look right rather than the arithmetic.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Sidebar section split")
struct SidebarSectionsTests {
    /// Whatever the ratio, the two panes must tile the height exactly. A gap shows
    /// as a stripe the sidebar background does not cover; an overlap clips a row.
    @Test("the two panes always fill the height")
    func heightsTileTheTotal() {
        for total in [CGFloat(0), 40, 119, 120, 200, 481, 1000, 2400] {
            for ratio in [CGFloat(0.1), 0.25, 0.5, 0.75, 0.9] {
                let split = SidebarSections.heights(totalHeight: total, ratio: ratio)
                #expect(split.spaces + split.agents == total,
                        "total \(total) ratio \(ratio) gave \(split.spaces)+\(split.agents)")
                #expect(split.spaces >= 0 && split.agents >= 0)
            }
        }
    }

    /// The default is an even split, which is what makes the two panes read as
    /// peers — spaces is not more important than agents, it just comes first.
    @Test("the default ratio halves the sidebar")
    func defaultRatiosHalves() {
        let split = SidebarSections.heights(totalHeight: 600)
        #expect(split.spaces == 300)
        #expect(split.agents == 300)
    }

    /// Neither pane may be squeezed out. Upstream clamps the ratio to `0.1...0.9`
    /// and then to three rows; without the minimum a drag to the bottom edge would
    /// leave the agents pane a single row tall, which cannot show a heading.
    @Test("neither pane collapses below its minimum")
    func minimumsHold() {
        let atBottom = SidebarSections.heights(totalHeight: 600, ratio: 0.9)
        #expect(atBottom.agents >= SidebarSections.minSection)
        let atTop = SidebarSections.heights(totalHeight: 600, ratio: 0.1)
        #expect(atTop.spaces >= SidebarSections.minSection)
    }

    /// A ratio from outside the range is clamped rather than honoured, so a stale
    /// persisted value cannot produce an unusable layout.
    @Test("an out-of-range ratio is clamped")
    func outOfRangeRatioIsClamped() {
        let extreme = SidebarSections.heights(totalHeight: 600, ratio: 5.0)
        let clamped = SidebarSections.heights(totalHeight: 600, ratio: SidebarSections.maxRatio)
        #expect(extreme == clamped)

        let negative = SidebarSections.heights(totalHeight: 600, ratio: -2.0)
        let floorClamped = SidebarSections.heights(totalHeight: 600, ratio: SidebarSections.minRatio)
        #expect(negative == floorClamped)
    }

    /// `NaN` reaches `min`/`max` as a value that always loses, which would hand the
    /// whole height to one pane. It falls back to the default instead.
    @Test("a non-finite ratio falls back to the default")
    func nonFiniteRatioFallsBack() {
        let nan = SidebarSections.heights(totalHeight: 600, ratio: .nan)
        #expect(nan == SidebarSections.heights(totalHeight: 600))
        let infinity = SidebarSections.heights(totalHeight: 600, ratio: .infinity)
        #expect(infinity.spaces + infinity.agents == 600)
    }

    /// Too little height for two panes with headings: halve evenly and drop the
    /// minimums, which is what upstream does below six rows. Keeping the minimums
    /// there would push the second pane past the bottom of the sidebar.
    @Test("a short sidebar halving evenly")
    func shortSidebarHalves() {
        let split = SidebarSections.heights(totalHeight: 100, ratio: 0.9)
        #expect(split.spaces == 50)
        #expect(split.agents == 50)
    }

    @Test("zero height yields two empty panes")
    func zeroHeight() {
        let split = SidebarSections.heights(totalHeight: 0)
        #expect(split.spaces == 0)
        #expect(split.agents == 0)
    }

    /// A drag turns a position into a ratio; past either edge it stops instead of
    /// producing a ratio the layout would immediately rewrite.
    @Test("a drag past an edge is clamped")
    func dragIsClamped() {
        let total: CGFloat = 600
        #expect(SidebarSections.ratio(draggedTo: 300, totalHeight: total) == 0.5)
        #expect(SidebarSections.ratio(draggedTo: 0, totalHeight: total) == SidebarSections.minRatio)
        #expect(SidebarSections.ratio(draggedTo: 600, totalHeight: total) == SidebarSections.maxRatio)
        #expect(SidebarSections.ratio(draggedTo: -50, totalHeight: total) == SidebarSections.minRatio)
        #expect(SidebarSections.ratio(draggedTo: 900, totalHeight: total) == SidebarSections.maxRatio)
        #expect(SidebarSections.ratio(draggedTo: 300, totalHeight: 0) == SidebarSections.defaultRatio)
    }
}
