// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

import KraalProtocol
import KraalUI

@testable import KraalSidebar

@Suite("TOML parsing")
struct TOMLTests {
    @Test("scalars, tables, and dotted keys land where expected")
    func scalarsAndTables() throws {
        let tree = try TOMLParser.parse("""
        # a comment
        title = "kraal"
        count = 42
        enabled = true
        ratio = 0.5

        [ui.sidebar]
        agents.row_gap = 2

        [ui.sidebar.spaces]
        row_gap = 1
        """)

        #expect(tree["title"]?.string == "kraal")
        #expect(tree["count"]?.integer == 42)
        #expect(tree["enabled"]?.boolean == true)

        let uiTable = try #require(tree["ui"]?.table)
        let sidebar = try #require(uiTable["sidebar"]?.table)
        #expect(sidebar["agents"]?.table?["row_gap"]?.integer == 2)
        #expect(sidebar["spaces"]?.table?["row_gap"]?.integer == 1)
    }

    @Test("comments inside strings are preserved")
    func hashInsideString() throws {
        let tree = try TOMLParser.parse(#"label = "issue #42" # trailing"#)
        #expect(tree["label"]?.string == "issue #42")
    }

    @Test("arrays of strings and of arrays parse")
    func arrays() throws {
        let tree = try TOMLParser.parse("""
        ui.sidebar.agents.rows = [["state_icon", "agent"], ["workspace"]]
        """)
        let rows = try #require(
            tree["ui"]?.table?["sidebar"]?.table?["agents"]?.table?["rows"]?.array
        )
        #expect(rows.count == 2)
        #expect(rows[0].array?.compactMap(\.string) == ["state_icon", "agent"])
    }

    @Test("multi-line arrays continue across lines")
    func multilineArray() throws {
        let tree = try TOMLParser.parse("""
        rows = [
            ["state_icon", "agent"],
            ["workspace", "tab"],
        ]
        """)
        #expect(tree["rows"]?.array?.count == 2)
    }

    @Test("inline tables with nested rule arrays parse")
    func inlineTable() throws {
        let tree = try TOMLParser.parse("""
        rows = [["agent", { token = "agent", bold = true, fg = "red",
                   rules = [{ when = "contains", value = "claude", fg = "purple" }] }]]
        """)
        let rows = try #require(tree["rows"]?.array)
        let cell = try #require(rows[0].array?[1].table)
        #expect(cell["bold"]?.boolean == true)
        #expect(cell["fg"]?.string == "red")
        #expect(cell["rules"]?.array?.first?.table?["when"]?.string == "contains")
    }

    @Test("escapes decode")
    func escapes() throws {
        let tree = try TOMLParser.parse(#"path = "a\tb\nc\"d\u0041""#)
        #expect(tree["path"]?.string == "a\tb\nc\"dA")
    }

    @Test("a duplicate key is an error, not a silent overwrite")
    func duplicateKey() {
        #expect(throws: TOMLParseError.self) {
            try TOMLParser.parse("""
            a = 1
            a = 2
            """)
        }
    }
}

@Suite("Sidebar config resolution")
struct SidebarConfigTests {
    @Test("no config yields the shipped defaults")
    func defaults() throws {
        let layout = try SidebarConfigResolver.layout(fromTOML: #"theme = "dark""#)
        #expect(layout.agentsRows == SidebarLayout.defaultAgentsRows)
        #expect(layout.spacesRows == SidebarLayout.defaultSpacesRows)
    }

    @Test("rows, gaps, and per-agent overrides resolve")
    func fullLayout() throws {
        let layout = try SidebarConfigResolver.layout(fromTOML: """
        [ui.sidebar.agents]
        row_gap = 1
        rows = [["state_icon", "agent"]]
        rows_by_agent = { claude = [["state_icon", "agent"], ["terminal_title"]] }

        [ui.sidebar.spaces]
        rows = [["state_icon", "workspace", "branch"]]
        """)

        #expect(layout.agentsRowGap == 1)
        #expect(layout.agentsRows.count == 1)
        #expect(layout.agentsRows[0].tokens.map(\.kind) == [.stateIcon, .agent])
        #expect(layout.spacesRows[0].tokens.map(\.kind) == [.stateIcon, .workspace, .branch])

        let override = try #require(layout.agentOverrides["claude"])
        #expect(override.count == 2)
        #expect(override[1].tokens.map(\.kind) == [.terminalTitle])
        // A non-overridden agent keeps the shared rows.
        #expect(layout.rows(for: "codex") == layout.agentsRows)
        #expect(layout.rows(for: "claude") == override)
        #expect(layout.rows(for: nil) == layout.agentsRows)
    }

    @Test("styled tokens keep their base style and rules")
    func styledTokens() throws {
        let layout = try SidebarConfigResolver.layout(fromTOML: """
        [ui.sidebar.agents]
        rows = [[{ token = "agent", bold = true, fg = "red",
                   rules = [{ when = "contains", value = "claude", fg = "purple" }] }]]
        """)
        let token = try #require(layout.agentsRows.first?.tokens.first)
        #expect(token.style.bold == true)
        #expect(token.style.foreground == "red")
        #expect(token.rules.count == 1)

        // A non-matching text keeps the base style.
        #expect(token.resolvedStyle(for: "codex").foreground == "red")
        // A matching rule overrides only the fields it sets.
        let matched = token.resolvedStyle(for: "claude-3")
        #expect(matched.foreground == "purple")
        #expect(matched.bold == true)
    }

    @Test("unknown tokens are skipped instead of blanking the sidebar")
    func unknownToken() throws {
        let layout = try SidebarConfigResolver.layout(fromTOML: """
        [ui.sidebar.agents]
        rows = [["state_icon", "not_a_real_token", "agent"]]
        """)
        #expect(layout.agentsRows[0].tokens.map(\.kind) == [.stateIcon, .agent])
    }

    @Test("custom metadata tokens parse as $key")
    func customToken() throws {
        let layout = try SidebarConfigResolver.layout(fromTOML: """
        [ui.sidebar.agents]
        rows = [["$ticket", "agent"]]
        """)
        #expect(layout.agentsRows[0].tokens.first?.kind == .custom("ticket"))
        #expect(SidebarTokenKind(name: "$ticket")?.name == "$ticket")
    }

    @Test("an oversized layout is rejected rather than truncated")
    func sizeLimit() {
        let rows = Array(repeating: #"["agent"]"#, count: SidebarLimits.maxRows + 1)
            .joined(separator: ", ")
        #expect(throws: SidebarConfigError.self) {
            try SidebarConfigResolver.layout(fromTOML: """
            [ui.sidebar.agents]
            rows = [\(rows)]
            """)
        }
    }

    @Test("row gaps are clamped to the daemon's range")
    func gapClamp() throws {
        let layout = try SidebarConfigResolver.layout(fromTOML: """
        [ui.sidebar.agents]
        row_gap = 99
        """)
        #expect(layout.agentsRowGap == SidebarLimits.maxRowGap)
    }
}

@Suite("Style rules")
struct StyleRuleTests {
    @Test("each condition matches what it says")
    func conditions() {
        #expect(StyleRule(when: .equals, value: "codex", style: .none).matches("codex"))
        #expect(!StyleRule(when: .equals, value: "codex", style: .none).matches("codex-cli"))
        #expect(StyleRule(when: .contains, value: "claude", style: .none).matches("my-claude-3"))
        #expect(StyleRule(when: .startsWith, value: "pi", style: .none).matches("pi-agent"))
        #expect(StyleRule(when: .greaterThan, value: "5", style: .none).matches("6"))
        #expect(!StyleRule(when: .greaterThan, value: "5", style: .none).matches("5"))
        #expect(StyleRule(when: .lessThan, value: "5", style: .none).matches("4"))
    }

    @Test("ignore_case is ASCII-only, matching the daemon")
    func ignoreCase() {
        let rule = StyleRule(when: .equals, value: "CODEX", ignoreCase: true, style: .none)
        #expect(rule.matches("codex"))
        #expect(!StyleRule(when: .equals, value: "CODEX", style: .none).matches("codex"))
    }
}

@Suite("Surface geometry")
struct SurfaceGeometryTests {
    /// A regression guard for the bug that made every row wrap: the grid
    /// requested from the daemon must be computed with the renderer's *device
    /// pixel* cell size, since Ghostty reports pixels while view sizes are points.
    @Test("cells are computed from pixel metrics, not point metrics")
    func pixelMetrics() {
        // 17×37 px cells at 2× scale on a 1000×700 pt pane:
        // 1000*2/17 = 117 columns, 700*2/37 = 37 rows.
        let cells = SurfaceGeometry.cells(
            for: CGSize(width: 1000, height: 700),
            cellSize: CGSize(width: 17, height: 37),
            scale: 2
        )
        #expect(cells.cols == 117)
        #expect(cells.rows == 37)
    }

    @Test("rounding down avoids asking for a column that does not fit")
    func roundsDown() {
        // At 1× a 100 px pane with 7 px cells fits 14 columns; a 15th would wrap.
        let cells = SurfaceGeometry.cells(
            for: CGSize(width: 100, height: 100),
            cellSize: CGSize(width: 7, height: 7),
            scale: 1
        )
        #expect(cells.cols == 14)
        #expect(cells.rows == 14)
    }

    @Test("degenerate sizes clamp instead of producing zero")
    func clamps() {
        let cells = SurfaceGeometry.cells(
            for: CGSize(width: 1, height: 1),
            cellSize: CGSize(width: 17, height: 37),
            scale: 2
        )
        #expect(cells.cols == 4)
        #expect(cells.rows == 2)
    }

    @Test("the fallback cell size is in the same unit as measured metrics")
    func fallbackUnit() {
        // Regression: the fallback was written in points while measured metrics
        // are device pixels, so the very first handshake asked for roughly twice
        // the columns that fit and the daemon rendered panes wider than the view.
        let fallback = SurfaceGeometry.fallbackCellSize
        #expect(fallback.width == SurfaceGeometry.fallbackCellPoints.width
            * SurfaceGeometry.backingScale)
        #expect(fallback.height == SurfaceGeometry.fallbackCellPoints.height
            * SurfaceGeometry.backingScale)
    }

    @Test("points are recovered from pixel metrics for layout")
    func pointsRoundTrip() {
        let points = SurfaceGeometry.points(for: CGSize(width: 17, height: 37))
        #expect(points.width == 17 / SurfaceGeometry.backingScale)
        #expect(points.height == 37 / SurfaceGeometry.backingScale)
    }

    @Test("a zero cell size cannot divide by zero")
    func zeroCell() {
        let cells = SurfaceGeometry.cells(
            for: CGSize(width: 500, height: 500),
            cellSize: .zero,
            scale: 2
        )
        #expect(cells.cols > 0)
        #expect(cells.rows > 0)
    }
}

@Suite("Pane hit-testing rectangles")
struct PaneFrameMathTests {
    @Test("side-by-side panes report distinct rectangles")
    func distinctPanes() {
        // Regression: both panes used to report the container's rect, so the
        // mouse monitor always resolved to whichever pane came first.
        let container = CGRect(x: 221, y: 25, width: 959, height: 652)
        let left = PaneFrameMath.rect(
            container: container,
            pane: CGRect(x: 0, y: 0, width: 450, height: 610),
            contentHeight: 760
        )
        let right = PaneFrameMath.rect(
            container: container,
            pane: CGRect(x: 476, y: 0, width: 450, height: 610),
            contentHeight: 760
        )
        #expect(left != right)
        #expect(left.minX == 221)
        #expect(right.minX == 697)
        #expect(left.width == 450)
    }

    @Test("the origin is flipped to match the surface grid")
    func topDownOrigin() {
        // AppKit counts from the bottom, the surface grid from the top. A pane at
        // the top of a 760 pt content view must report a small y.
        let rect = PaneFrameMath.rect(
            container: CGRect(x: 0, y: 0, width: 959, height: 652),
            pane: CGRect(x: 0, y: 566, width: 959, height: 86),
            contentHeight: 760
        )
        // pane.maxY is 566 + 86 = 652, so the top-down y is 760 - 652 = 108.
        #expect(rect.minY == 108)
    }
}

@Suite("Mouse mapping")
struct MouseMappingTests {
    private func mapper(
        inner: SurfaceRect = SurfaceRect(originX: 0, originY: 0, width: 80, height: 24),
        size: CGSize = CGSize(width: 800, height: 480)
    ) -> MouseCoordinateMapper {
        MouseCoordinateMapper(
            innerRect: inner,
            viewSize: size,
            gridWidth: 100,
            gridHeight: 40
        )
    }

    @Test("a point maps to the cell containing it")
    func cellMapping() {
        // 10×20 pt per cell: (25, 45) is column 2, row 2.
        let cell = mapper().cell(for: CGPoint(x: 25, y: 45))
        #expect(cell.column == 2)
        #expect(cell.row == 2)
    }

    @Test("points outside the pane clamp to its edges")
    func clamps() {
        let negative = mapper().cell(for: CGPoint(x: -50, y: -50))
        #expect(negative.column == 0)
        #expect(negative.row == 0)

        let past = mapper().cell(for: CGPoint(x: 5000, y: 5000))
        #expect(past.column == 79)
        #expect(past.row == 23)
    }

    @Test("pixel positions clamp to the view bounds")
    func pixelMapping() {
        let pixels = mapper().pixels(for: CGPoint(x: 5000, y: -10))
        #expect(pixels.x == 800)
        #expect(pixels.y == 0)
    }

    @Test("scroll deltas become a bounded line count")
    func scrollLines() {
        #expect(PaneMouse.scrollLines(from: 0.2) == 1)
        #expect(PaneMouse.scrollLines(from: -3.6) == 4)
        #expect(PaneMouse.scrollLines(from: 999) == 20)
    }

    @Test("a lower content revision means the delta stream restarted")
    func streamRestarted() {
        // A tab switch makes the daemon re-project the pane and renumber from
        // scratch. Treating that as "older frame, ignore" leaves the pane blank,
        // because no frame will ever exceed the stale revision.
        #expect(SurfaceGeometry.deltaStreamRestarted(previousRevision: 38, incomingRevision: 1))
        #expect(SurfaceGeometry.deltaStreamRestarted(previousRevision: 5, incomingRevision: 4))
        #expect(!SurfaceGeometry.deltaStreamRestarted(previousRevision: 1, incomingRevision: 1))
        #expect(!SurfaceGeometry.deltaStreamRestarted(previousRevision: 1, incomingRevision: 9))
    }

    @Test("a new grid repaints even when the content revision did not move")
    func repaintOnGridChange() {
        // Split to full width: same text, same revision, different frame width.
        // Skipping this frame left the pane blank until it printed something.
        #expect(SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: (53, 33),
            currentGrid: (111, 35)
        ))
        #expect(SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: nil,
            currentGrid: (111, 35)
        ))
        #expect(SurfaceGeometry.needsRepaint(
            contentRevisionChanged: true,
            previousGrid: (111, 35),
            currentGrid: (111, 35)
        ))
        #expect(!SurfaceGeometry.needsRepaint(
            contentRevisionChanged: false,
            previousGrid: (111, 35),
            currentGrid: (111, 35)
        ))
    }
}
