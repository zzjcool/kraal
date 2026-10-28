// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import GhosttyTerminal
@testable import KraalProtocol
@testable import KraalTerminalView
import Testing

/// What the pane does with the engine's own announcements of its screen size.
///
/// The end-to-end behaviour is covered against a real engine in `LiveGhosttyDragTests`;
/// these are the parts that need none: reading the report, telling a real change from a
/// repeat, keeping reports out of the shell, and repainting when the screen moved.
@Suite("Engine screen reports")
@MainActor
struct EngineScreenReportTests {
    private func report(_ rows: Int, _ columns: Int = 100) -> EngineScreenReport {
        EngineScreenReport(
            columns: columns, rows: rows, widthPixels: columns * 17, heightPixels: rows * 37
        )
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Parsing

    /// The layout is `CSI 48 ; rows ; columns ; heightPx ; widthPx t` — rows first and
    /// height before width, the opposite of how the pixel size is usually written. It is
    /// taken from `terminal/size_report.zig` and was confirmed on a live engine
    /// (`ESC[48;20;100;740;1700t` for a 100x20 screen of 17x37 cells).
    @Test("a report is read as rows, columns, height, width")
    func parsesFieldOrder() {
        let parsed = EngineScreenReport.extract(from: bytes("\u{1B}[48;20;100;740;1700t"))
        #expect(parsed.reports == [
            EngineScreenReport(columns: 100, rows: 20, widthPixels: 1700, heightPixels: 740)
        ])
        #expect(parsed.rest.isEmpty)
    }

    @Test("several reports in one write are all read")
    func parsesABatch() {
        let parsed = EngineScreenReport.extract(
            from: bytes("\u{1B}[48;16;47;592;799t\u{1B}[48;20;100;740;1700t")
        )
        #expect(parsed.reports.map(\.rows) == [16, 20])
        #expect(parsed.rest.isEmpty)
    }

    /// The write callback also carries keystrokes, mouse reports and pastes. Taking a
    /// report out of the middle of one would corrupt it, so a chunk is a report only when
    /// *all* of it is. A paste that happens to contain the pattern must arrive intact.
    @Test("input that merely contains a report is left alone")
    func leavesOtherInputAlone() {
        for text in [
            "ls -la\r",
            "\u{1B}[A",
            "paste: \u{1B}[48;20;100;740;1700t and more",
            "\u{1B}[48;20;100;740;1700tX",
            "\u{1B}[48;20;100;740t",
            "\u{1B}[48;20;100;740;1700;1t",
            "\u{1B}[48;;100;740;1700t",
            "\u{1B}[48;2x;100;740;1700t",
        ] {
            let parsed = EngineScreenReport.extract(from: bytes(text))
            #expect(parsed.reports.isEmpty, "\(text.debugDescription) was taken for a report")
            #expect(parsed.rest == bytes(text), "\(text.debugDescription) was altered")
        }
    }

    @Test("an absurd field is refused rather than overflowing")
    func refusesHugeFields() {
        let parsed = EngineScreenReport.extract(
            from: bytes("\u{1B}[48;99999999999999999999;100;740;1700t")
        )
        #expect(parsed.reports.isEmpty)
    }

    // MARK: - Telling a change from a repeat

    @Test("the first announcement is a change; a repeat is not")
    func firstIsAChange() {
        #expect(PaneTerminalModel.screenMoved(from: nil, through: [report(20)]))
        #expect(!PaneTerminalModel.screenMoved(from: report(20), through: [report(20)]))
        #expect(PaneTerminalModel.screenMoved(from: report(20), through: [report(21)]))
        #expect(PaneTerminalModel.screenMoved(from: report(20), through: [report(20, 99)]))
    }

    /// Pixel-only differences are not a new grid: the engine repeats a report whenever the
    /// size is re-sent, and a sub-cell change moves no row.
    @Test("a pixel-only difference is not a change")
    func pixelOnlyIsNotAChange() {
        let first = EngineScreenReport(columns: 100, rows: 20, widthPixels: 1700, heightPixels: 740)
        let second = EngineScreenReport(columns: 100, rows: 20, widthPixels: 1703, heightPixels: 745)
        #expect(!PaneTerminalModel.screenMoved(from: first, through: [second]))
    }

    /// A screen that went 34 -> 38 -> 34 between two deliveries ends where it began, yet a
    /// frame parsed while it was 38 tall was rearranged on the way back. Comparing only the
    /// end with the start calls that "nothing happened".
    @Test("a round trip inside one batch is still a change")
    func roundTripIsAChange() {
        #expect(PaneTerminalModel.screenMoved(
            from: report(34), through: [report(38), report(34)]
        ))
    }

    // MARK: - The model

    private func surface(rows: UInt16) -> PaneSurfaceFrame {
        LiveFixture.surface(columns: 112, rows: Int(rows), generation: 0)
    }

    private func armedModel() -> PaneTerminalModel {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        model.gridOverride = TerminalGridMetrics(
            columns: 112, rows: 8, widthPixels: 1904, heightPixels: 296,
            cellWidthPixels: 17, cellHeightPixels: 37
        )
        model.apply(surface: surface(rows: 8))
        return model
    }

    /// The point of the whole change. Nothing about the frame, the view or the grid moved —
    /// every other repaint reason says "unchanged" — yet the engine's screen did, so what
    /// the renderer thinks is drawn may not be. The next write must be the whole frame.
    @Test("a moved engine screen repaints a frame nothing else says has changed")
    func movedScreenRepaints() {
        let model = armedModel()
        let before = model.paintCount
        model.apply(surface: surface(rows: 8))
        #expect(model.paintCount == before, "an unchanged frame must still be skipped")

        model.engineScreenDidChange([report(8, 112)])
        #expect(model.paintCount == before + 1, "the engine's screen moved; nothing was rewritten")
        let text = String(bytes: model.lastPainted ?? Data(), encoding: .utf8) ?? ""
        for row in 1 ... 8 {
            #expect(text.contains("\u{1B}[\(row);1H"), "row \(row) was not written again")
        }
    }

    @Test("an announcement that repeats the grid repaints nothing")
    func repeatedScreenDoesNotRepaint() {
        let model = armedModel()
        model.engineScreenDidChange([report(8, 112)])
        let settled = model.paintCount
        model.engineScreenDidChange([report(8, 112)])
        #expect(model.paintCount == settled)
    }

    /// Asking is once per surface; asking again on every frame would flood the engine with
    /// mode changes and answer each with a report.
    @Test("the engine is asked to announce once, and again after its surface is replaced")
    func asksOncePerSurface() {
        let model = PaneTerminalModel(paneId: "w1:p1") { _ in }
        #expect(!model.engineReportsRequested)
        model.requestEngineScreenIfNeeded()
        #expect(model.engineReportsRequested)
        model.engineScreenDidChange([report(8, 112)])
        model.forgetEngineScreen()
        #expect(!model.engineReportsRequested, "a replaced surface has never been asked")
        #expect(model.engineScreen == nil, "a replaced surface must not inherit the old size")
    }

    /// A popup is painted whole on every update and never resized mid-gesture; it does not
    /// take part, so it never turns on a mode it has no use for.
    @Test("a popup never asks for reports")
    func popupDoesNotAsk() {
        let model = PaneTerminalModel(paneId: "popup", isPopup: true) { _ in }
        model.requestEngineScreenIfNeeded()
        #expect(!model.engineReportsRequested)
    }
}
