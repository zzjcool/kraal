// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SidebarCollapsedTests.swift
//  KraalClientTests
//
//  The narrow sidebar splits its height between workspaces (top) and agents (bottom).
//
//  Upstream's arithmetic is `div_ceil(2)` with the remainder spent on a divider, and
//  a special case below 7 rows where the detail half is dropped entirely
//  (`src/client/shell/sidebar.rs:27-45`). Off-by-one here is invisible in a screenshot
//  but means an agent is silently unreachable, so the boundaries get their own tests.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Collapsed sidebar")
struct SidebarCollapsedTests {
    @Test("no height fits nothing")
    func noHeight() {
        let counts = SidebarCollapsed.counts(rows: 0)
        #expect(counts.workspaces == 0)
        #expect(counts.agents == 0)
    }

    /// Below the threshold upstream shows only workspaces: there is no room for a
    /// divider plus a row on each side, and a one-row agent list would be worse than
    /// showing none.
    @Test("a short sidebar shows workspaces only")
    func shortSidebarShowsWorkspacesOnly() {
        for rows in 1...6 {
            let counts = SidebarCollapsed.counts(rows: rows)
            #expect(counts.workspaces == rows, "rows=\(rows) lost workspaces")
            #expect(counts.agents == 0, "rows=\(rows) should not show agents")
        }
    }

    /// At the threshold the halves and the divider have to add back up to the height.
    /// This is the property that matters: every row is accounted for exactly once.
    @Test("the halves and the divider add back up to the height")
    func halvesAddUp() {
        for rows in 7...40 {
            let counts = SidebarCollapsed.counts(rows: rows)
            #expect(
                counts.workspaces + counts.agents + 1 <= rows,
                "rows=\(rows) overflowed: \(counts)"
            )
            // And the wasted space is at most the divider.
            #expect(rows - (counts.workspaces + counts.agents) <= 1,
                    "rows=\(rows) wasted more than the divider: \(counts)")
        }
    }

    /// The extra row goes to the top half, matching `div_ceil(2)`.
    @Test("an odd height gives the extra row to workspaces")
    func oddHeightFavoursWorkspaces() {
        // 9 rows: divider at index 5 (after 5 workspaces), 3 agents left.
        let counts = SidebarCollapsed.counts(rows: 9)
        #expect(counts.workspaces == 5)
        #expect(counts.agents == 3)
    }

    /// An even height splits evenly.
    @Test("an even height splits evenly")
    func evenHeightSplitsEvenly() {
        // 10 rows: 5 workspaces, divider, 4 agents.
        let counts = SidebarCollapsed.counts(rows: 10)
        #expect(counts.workspaces == 5)
        #expect(counts.agents == 4)
    }

    /// Exactly at the threshold the detail half is present, not dropped.
    @Test("the threshold itself keeps both halves")
    func thresholdKeepsBothHalves() {
        let counts = SidebarCollapsed.counts(rows: 7)
        #expect(counts.workspaces == 4)
        #expect(counts.agents == 2)
    }

    /// Indices are 1-based and padded, so a single-digit index lines up with a
    /// two-digit one instead of shifting the glyph.
    @Test("row labels are 1-based and padded")
    func labelsArePadded() {
        #expect(SidebarCollapsed.label(index: 0) == "1 ")
        #expect(SidebarCollapsed.label(index: 8) == "9 ")
        #expect(SidebarCollapsed.label(index: 9) == "10")
    }

    /// Every status has its own glyph — a missing case would draw nothing and the row
    /// would look like a workspace with no state.
    @Test("every agent status has a glyph")
    func everyStatusHasAGlyph() {
        let glyphs = AgentStatus.allCases.map(SidebarCollapsed.glyph(for:))
        #expect(Set(glyphs).count == AgentStatus.allCases.count, "two states share a glyph")
        for glyph in glyphs {
            #expect(glyph.count == 1, "glyph '\(glyph)' is not a single character")
        }
    }
}
