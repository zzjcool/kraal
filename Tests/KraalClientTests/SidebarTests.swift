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
        let points = SurfaceGeometry.points(for: CGSize(width: 17, height: 37), scale: 2)
        // The expected values are written as CGFloat literal division: `17 / 2`
        // would infer Int and compare against 8, hiding a half-point error.
        #expect(points.width == 8.5)
        #expect(points.height == 18.5)
    }

    /// The global-offset bug: cell metrics were converted with `NSScreen.main`'s
    /// scale, which belongs to the menu bar's screen, not the window's. With a
    /// Retina built-in display and a scale-1 external, a window on the external
    /// one got the wrong factor, so every cell in every pane was twice its true
    /// size. The scale must be a parameter the view supplies from its own screen.
    @Test("the conversion uses the supplied screen scale, not a global default")
    func scaleIsSuppliedPerScreen() {
        let cell = CGSize(width: 17, height: 37)

        let retina = SurfaceGeometry.points(for: cell, scale: 2)
        let external = SurfaceGeometry.points(for: cell, scale: 1)

        #expect(retina.width == 8.5)
        // On a scale-1 display the same cell occupies twice as many points.
        #expect(external.width == 17)
        #expect(external.width == retina.width * 2)

        // And the grid must be derived with the same scale, or the two disagree.
        let pane = CGSize(width: 850, height: 370)
        let retinaGrid = SurfaceGeometry.cells(for: pane, cellSize: cell, scale: 2)
        let externalGrid = SurfaceGeometry.cells(for: pane, cellSize: cell, scale: 1)
        #expect(retinaGrid.cols == 100, "850*2/17 = 100")
        #expect(externalGrid.cols == 50, "850*1/17 = 50")
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
        // AppKit counts from the bottom, the surface grid from the top. This test
        // used to put the container at y = 0, which is exactly where the two
        // conventions coincide — so it passed while the code below added a
        // bottom-up container offset to a top-down pane offset. The container now
        // sits at a realistic offset, with chrome below it.
        //
        // container = (0, 33, 959, 664), contentHeight 760:
        //   container top-down top = 760 - (33 + 664) = 63
        //   pane sits 100 pt into the container, so its top is 163.
        let rect = PaneFrameMath.rect(
            container: CGRect(x: 0, y: 33, width: 959, height: 664),
            pane: CGRect(x: 0, y: 100, width: 959, height: 400),
            contentHeight: 760
        )
        #expect(rect.minY == 163)
    }

    /// The bug behind a "global" misalignment: the pane offset was added to a
    /// bottom-origin container offset, so every pane in the window shifted by the
    /// same constant. This pins the two edges that define the pane: its top sits
    /// `pane.minY` below the container's top, and its bottom `pane.maxY` below it.
    @Test("the pane offset is measured from the container top, not the content bottom")
    func paneOffsetIsRelativeToContainerTop() {
        let container = CGRect(x: 220, y: 33, width: 959, height: 664)
        let contentHeight: CGFloat = 760
        let containerTop = contentHeight - (container.minY + container.height)

        let top = PaneFrameMath.rect(
            container: container,
            pane: CGRect(x: 0, y: 0, width: 943, height: 320),
            contentHeight: contentHeight
        )
        let bottom = PaneFrameMath.rect(
            container: container,
            pane: CGRect(x: 0, y: 344, width: 943, height: 320),
            contentHeight: contentHeight
        )

        #expect(top.minY == containerTop, "a pane at the container top is at the container top")
        #expect(bottom.minY == containerTop + 344)
        // The two panes must not overlap: the lower one starts where the upper
        // one ends, plus the 24 pt divider the daemon reserved between them.
        #expect(bottom.minY == top.maxY + 24, "panes must stay ordered, no overlap")
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

    /// Ghostty derives its grid with `floor(viewPixels / cellPixels)`. A pane
    /// sized at exactly `cells * cellSize` lands on the integer, so a fraction of
    /// a pixel missing costs a whole row and column — and every glyph, the
    /// cursor and the selection then sit one cell off, identically in every pane.
    /// That is what made it look like one global offset rather than a sizing bug.
    @Test("pane sizes are snapped up so the grid cannot come out one cell short")
    func pixelSnappingKeepsTheWholeGrid() {
        // A 17x37 px cell at 2x is 8.5x18.5 pt. 111 cells => 943.5 pt exactly.
        let cellPoints = CGSize(width: 8.5, height: 18.5)
        let scale: CGFloat = 2

        let snappedWidth = PaneFrameMath.pixelSnapped(111 * cellPoints.width, scale: scale)
        let snappedHeight = PaneFrameMath.pixelSnapped(35 * cellPoints.height, scale: scale)

        // Whatever fraction the multiplication leaves, the pixelised size must
        // still fit the same number of cells Ghostty was told about.
        let pixelsWide = (snappedWidth * scale).rounded(.down)
        let pixelsHigh = (snappedHeight * scale).rounded(.down)
        #expect(pixelsWide / 17 >= 111, "\(pixelsWide) px must still hold 111 columns")
        #expect(pixelsHigh / 37 >= 35, "\(pixelsHigh) px must still hold 35 rows")
    }

    /// Snapping must never round *down*, or it reintroduces the missing cell.
    @Test("snapping only ever grows a size")
    func pixelSnappingNeverShrinks() {
        for points in [0.1, 7.3, 943.5, 1234.567] as [CGFloat] {
            let snapped = PaneFrameMath.pixelSnapped(points, scale: 2)
            #expect(snapped >= points)
        }
    }

    /// A size already on a pixel boundary must be left alone, so the common case
    /// does not drift by a hair on every layout pass.
    @Test("an already-aligned size is unchanged")
    func pixelSnappingIsIdempotent() {
        let aligned: CGFloat = 943.5 // 1887 px at 2x
        #expect(PaneFrameMath.pixelSnapped(aligned, scale: 2) == aligned)
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

    @Test("scrolling up asks the daemon for a higher offset")
    func scrollTargetMovesTowardHistory() {
        // `pane.scroll` takes an absolute offset from the bottom, so a wheel-up
        // gesture has to be turned into a position, not a delta.
        #expect(PaneMouse.ScrollTarget.offset(current: 0, lines: 3, maxOffset: 100) == 3)
        #expect(PaneMouse.ScrollTarget.offset(current: 10, lines: 3, maxOffset: 100) == 13)
        #expect(PaneMouse.ScrollTarget.offset(current: 10, lines: -4, maxOffset: 100) == 6)
    }

    @Test("scrolling never crosses either end of the history")
    func scrollTargetClamps() {
        // Past the top: stay at the oldest row rather than wrapping to zero,
        // which would look like a jump to the bottom.
        #expect(PaneMouse.ScrollTarget.offset(current: 2, lines: 500, maxOffset: 100) == 100)
        // Past the bottom: the newest row is offset 0, and it is a floor, not a
        // wrap to `maxOffset`.
        #expect(PaneMouse.ScrollTarget.offset(current: 1, lines: -50, maxOffset: 100) == 0)
    }

    @Test("a pane with no history never sends a scroll")
    func scrollTargetSkipsHistorylessPane() {
        // The daemon reports maxOffset 0 for a pane whose output fits on one
        // screen. Asking it to move would be a round trip that changes nothing.
        #expect(PaneMouse.ScrollTarget.shouldSend(current: 0, lines: 3, maxOffset: 0) == false)
        // Already pinned at the top and scrolling further up: also nothing to do.
        #expect(PaneMouse.ScrollTarget.shouldSend(current: 100, lines: 3, maxOffset: 100) == false)
        // A real move.
        #expect(PaneMouse.ScrollTarget.shouldSend(current: 10, lines: 3, maxOffset: 100) == true)
        // No movement at all.
        #expect(PaneMouse.ScrollTarget.shouldSend(current: 10, lines: 0, maxOffset: 100) == false)
    }

    @Test("a trackpad flick scrolls by distance, not by event count")
    func scrollAccumulatorFollowsDistance() {
        // A light flick is ~60 frames of a point or two. Rounding each frame up
        // to a row turned 3 rows of movement into 60, which is the "much too
        // fast" complaint. Banking the remainder gives the 3 it deserves.
        var accumulator = PaneMouse.ScrollAccumulator(cellHeight: 18.5)
        let lines = Array(repeating: 1.0, count: 60).map { accumulator.lines(for: $0) }
        #expect(lines.reduce(0, +) == 3)
    }

    @Test("sub-row deltas are banked, not dropped or rounded up")
    func scrollAccumulatorKeepsRemainder() {
        var accumulator = PaneMouse.ScrollAccumulator(cellHeight: 10)
        #expect(accumulator.lines(for: 4) == 0)
        #expect(accumulator.lines(for: 4) == 0)
        // 4 + 4 + 4 crosses one row, leaving 2 banked.
        #expect(accumulator.lines(for: 4) == 1)
        // The 2 still counts: 2 + 9 crosses another.
        #expect(accumulator.lines(for: 9) == 1)
    }

    @Test("a zero cell height cannot turn every point into a row")
    func scrollAccumulatorGuardsCellHeight() {
        // A pane reporting no rows would divide to infinity and emit a row per
        // event, which is the runaway this type exists to prevent.
        var accumulator = PaneMouse.ScrollAccumulator(cellHeight: 0)
        #expect(accumulator.cellHeight == 1)
        #expect(accumulator.lines(for: 1) == 1)
        #expect(accumulator.lines(for: 0.5) == 0)
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

    @Test("the no-agent pane rows tell sibling panes apart")
    func paneRowsAreDistinct() throws {
        // Two panes of one tab, no agents: with the agent layout the agent token
        // resolves to nothing and both rows came out as "· w2 #2" — identical,
        // so the sidebar could not be used to pick a pane.
        let tab = try JSONDecoder().decode(ClientShellTab.self, from: Data("""
        {"tab_id":"w2:t2","workspace_id":"w2","number":2,"label":"2"}
        """.utf8))
        let context = { (paneId: String) throws -> SidebarRowContext in
            let pane = try JSONDecoder().decode(ClientShellPane.self, from: Data("""
            {"pane_id":"\(paneId)","workspace_id":"w2","tab_id":"w2:t2"}
            """.utf8))
            return SidebarRowContext(tab: tab, pane: pane)
        }

        func render(_ rowContext: SidebarRowContext) -> String {
            SidebarLayout().paneRows.map { row in
                SidebarTokenResolver.resolve(row: row, context: rowContext)
                    .tokens.map(\.text).joined(separator: " ")
            }.joined(separator: " | ")
        }

        let leftPane = render(try context("w2:p2"))
        let rightPane = render(try context("w2:p3"))
        #expect(leftPane != rightPane)
        #expect(leftPane.contains("w2:p2"))
        #expect(rightPane.contains("w2:p3"))
    }

    @Test("a frame that arrives before the terminal has a grid is parked")
    func parkFrameUntilGridIsKnown() {
        // Ghostty attaches asynchronously. Writing before that both wastes the
        // frame and leaves the pane blank, which is exactly what a tab switch
        // looked like: an empty pane until something printed again.
        #expect(SurfaceGeometry.needsParkingUntilGridIsKnown(hasGrid: false))
        #expect(!SurfaceGeometry.needsParkingUntilGridIsKnown(hasGrid: true))
    }
}

@Suite("Window resize pacing")
struct ResizePacingTests {
    /// The bug this pins down: a trailing-only debounce restarts on every size
    /// change, and dragging a window emits one per frame. The negotiation then
    /// started only after the user let go, so the panes sat at the old grid for
    /// the whole gesture instead of following the window.
    @Test("a size change during a drag is released immediately")
    func leadingEdge() {
        #expect(ResizePacing.releasesImmediately(
            sinceLastRelease: ResizePacing.dragInterval,
            forced: false
        ))
        // The first change of a gesture, long after the previous one.
        #expect(ResizePacing.releasesImmediately(sinceLastRelease: 60, forced: false))
    }

    @Test("back-to-back frames coalesce instead of flooding the daemon")
    func coalesces() {
        // A 60 fps drag offers a change every ~16 ms; only one per interval goes
        // out, and the rest are covered by the trailing release.
        #expect(!ResizePacing.releasesImmediately(sinceLastRelease: 0.016, forced: false))
        #expect(!ResizePacing.releasesImmediately(sinceLastRelease: 0, forced: false))
    }

    @Test("a forced negotiation is never delayed")
    func forcedBypassesInterval() {
        // Measured cell metrics and explicit geometry re-evaluations are not part
        // of a drag; holding them back would leave the grid wrong after the very
        // event that invalidated it.
        #expect(ResizePacing.releasesImmediately(sinceLastRelease: 0, forced: true))
    }

    @Test("the trailing release waits for the gesture to stop")
    func trailingEdge() {
        // Long enough to be past a drag frame, short enough that the final size
        // lands while the user is still looking at the window.
        #expect(ResizePacing.settleDelay > ResizePacing.dragInterval)
        #expect(ResizePacing.settleDelay < 0.5)
    }
}
