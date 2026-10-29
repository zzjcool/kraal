// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import SwiftUI
import Testing
@testable import KraalProtocol
@testable import KraalUI

/// The painter is only worth having if the picture it draws is the picture the daemon sent.
/// These tests are about the three things that can silently be wrong and still look like a
/// terminal: which cells it read, what a modifier did, and where the cursor landed.
@Suite("Pane cell canvas")
struct PaneCellCanvasTests {
    private static let cell = CGSize(width: 8, height: 16)
    private static let white: UInt32 = TerminalColor.rgb(red: 255, green: 255, blue: 255).rawValue
    private static let black: UInt32 = TerminalColor.rgb(red: 0, green: 0, blue: 0).rawValue
    private static let red: UInt32 = TerminalColor.rgb(red: 220, green: 20, blue: 20).rawValue

    private static func palette() -> AnsiPalette {
        AnsiPalette(
            foreground: white, background: black, cursor: red,
            named: (0 ..< 16).map { _ in black }
        )
    }

    private static func frame(
        columns: Int,
        rows: Int,
        painting paint: (inout [CellData]) -> Void,
        cursor: CursorState? = nil
    ) -> FrameData {
        var cells = Array(
            repeating: CellData(
                symbol: " ", foreground: white, background: black,
                modifier: 0, skip: false, hyperlink: nil
            ),
            count: columns * rows
        )
        paint(&cells)
        return FrameData(
            cells: cells, width: UInt16(columns), height: UInt16(rows),
            cursor: cursor, hyperlinks: [], graphics: Data()
        )
    }

    @Test("the pane draws its own window of the surface, not the top-left of it")
    @MainActor
    func drawsThePanesWindow() throws {
        // One red cell at (3, 1) in a 6x3 surface; the pane's window starts exactly there,
        // so the red cell must appear at the canvas's own (0, 0).
        let frame = Self.frame(columns: 6, rows: 3) { cells in
            cells[1 * 6 + 3] = CellData(
                symbol: " ", foreground: Self.red, background: Self.red,
                modifier: 0, skip: false, hyperlink: nil
            )
        }
        let image = try Self.pixels(
            PaneCellCanvas(
                frame: frame,
                inner: SurfaceRect(originX: 3, originY: 1, width: 2, height: 2),
                cellSize: Self.cell,
                palette: Self.palette()
            )
            .frame(width: 2 * Self.cell.width, height: 2 * Self.cell.height)
        )
        let corner = image.at(column: 2, row: 2)
        #expect(corner.red > 150 && corner.green < 90, "pane's first cell is not the red one")
        let neighbour = image.at(column: Int(Self.cell.width) + 2, row: 2)
        #expect(neighbour.red < 60, "the cell beside it should be the black one")
    }

    @Test("reversed swaps ink and paper, and hidden hides the ink")
    @MainActor
    func modifiersChangeThePaper() throws {
        let frame = Self.frame(columns: 2, rows: 1) { cells in
            cells[0] = CellData(
                symbol: " ", foreground: Self.white, background: Self.black,
                modifier: CellModifier.reversed, skip: false, hyperlink: nil
            )
        }
        let plain = try Self.pixels(
            PaneCellCanvas(
                frame: frame, inner: SurfaceRect(originX: 0, originY: 0, width: 2, height: 1),
                cellSize: Self.cell, palette: Self.palette()
            )
            .frame(width: 2 * Self.cell.width, height: Self.cell.height)
        )
        #expect(plain.at(column: 3, row: 3).brightness > 200, "reversed cell should be white paper")
        #expect(plain.at(column: Int(Self.cell.width) + 3, row: 3).brightness < 60, "plain cell stays black")

        let hiddenFrame = Self.frame(columns: 1, rows: 1) { cells in
            cells[0] = CellData(
                symbol: "█", foreground: Self.white, background: Self.black,
                modifier: CellModifier.hidden, skip: false, hyperlink: nil
            )
        }
        let hidden = try Self.pixels(
            PaneCellCanvas(
                frame: hiddenFrame, inner: SurfaceRect(originX: 0, originY: 0, width: 1, height: 1),
                cellSize: Self.cell, palette: Self.palette()
            )
            .frame(width: Self.cell.width, height: Self.cell.height)
        )
        #expect(hidden.maxBrightness(in: 0 ..< hidden.height) < 40, "hidden glyph was drawn")
    }

    @Test("a dim glyph is drawn, and darker than the same glyph without the bit")
    @MainActor
    func dimLowersTheInk() throws {
        func brightness(modifier: UInt16) throws -> Int {
            let frame = Self.frame(columns: 1, rows: 1) { cells in
                cells[0] = CellData(
                    symbol: "M", foreground: Self.white, background: Self.black,
                    modifier: modifier, skip: false, hyperlink: nil
                )
            }
            let image = try Self.pixels(
                PaneCellCanvas(
                    frame: frame, inner: SurfaceRect(originX: 0, originY: 0, width: 1, height: 1),
                    cellSize: Self.cell, palette: Self.palette()
                )
                .frame(width: Self.cell.width, height: Self.cell.height)
            )
            return image.maxBrightness(in: 0 ..< image.height)
        }
        let plain = try brightness(modifier: 0)
        let dimmed = try brightness(modifier: CellModifier.dim)
        #expect(plain > 200, "an undimmed white glyph should reach near-white")
        #expect(dimmed > 40, "a dim glyph is dimmer, not gone")
        #expect(dimmed < plain, "dim did not lower the ink")
    }

    @Test("the cursor is drawn where the daemon put it, and only inside the pane")
    @MainActor
    func cursorLandsOnItsCell() throws {
        let inside = Self.frame(
            columns: 2, rows: 2,
            painting: { _ in },
            cursor: CursorState(column: 1, row: 1, visible: true, shape: 0)
        )
        let image = try Self.pixels(
            PaneCellCanvas(
                frame: inside, inner: SurfaceRect(originX: 0, originY: 0, width: 2, height: 2),
                cellSize: Self.cell, palette: Self.palette()
            )
            .frame(width: 2 * Self.cell.width, height: 2 * Self.cell.height)
        )
        #expect(image.at(column: 2, row: 2).red < 60, "the cursor was drawn in the wrong cell")
        let cursor = image.at(column: Int(Self.cell.width) + 2, row: Int(Self.cell.height) + 2)
        #expect(cursor.red > 150, "the cursor cell is not the cursor colour")

        // A cursor outside the pane's window belongs to another pane.
        let outside = Self.frame(
            columns: 4, rows: 2,
            painting: { _ in },
            cursor: CursorState(column: 0, row: 0, visible: true, shape: 0)
        )
        let clipped = try Self.pixels(
            PaneCellCanvas(
                frame: outside, inner: SurfaceRect(originX: 2, originY: 0, width: 2, height: 2),
                cellSize: Self.cell, palette: Self.palette()
            )
            .frame(width: 2 * Self.cell.width, height: 2 * Self.cell.height)
        )
        #expect(clipped.maxRed() < 80, "another pane's cursor was drawn into this one")
    }

    /// The bug this pins was visible on the first real launch: every pane was a blank
    /// rectangle with only the cursor showing, because the shell sends `0` for both fields —
    /// "the terminal's default" — and a painter that resolves `0` as palette entry 0 paints
    /// default text in default black on default black.
    @Test("a cell that names no colour uses the palette's two defaults, not entry zero")
    @MainActor
    func defaultColoursAreTheTerminalDefaults() throws {
        let defaults = AnsiPalette(
            foreground: Self.white, background: Self.black, cursor: Self.red,
            named: (0 ..< 16).map { _ in UInt32(0x00_7F00) }
        )
        let frame = Self.frame(columns: 1, rows: 1) { cells in
            cells[0] = CellData(
                symbol: "M", foreground: 0, background: 0,
                modifier: 0, skip: false, hyperlink: nil
            )
        }
        let image = try Self.pixels(
            PaneCellCanvas(
                frame: frame, inner: SurfaceRect(originX: 0, originY: 0, width: 1, height: 1),
                cellSize: Self.cell, palette: defaults
            )
            .frame(width: Self.cell.width, height: Self.cell.height)
        )
        // Paper is palette.background (black), ink is palette.foreground (white) — the table
        // entry 0 is a dark green, and it must not appear at all.
        #expect(image.at(column: 2, row: 2).brightness < 40, "the cell's paper is not the default")
        #expect(image.maxBrightness(in: 0 ..< image.height) > 180, "the glyph is not the default ink")
        let green = image.at(column: 2, row: 2)
        #expect(green.green < 60, "palette entry 0 leaked into the background")
    }

    /// The failure this pins was visible in the first TUI anyone ran: a 130-column `btop`
    /// row ended about three columns to the right of where the daemon put it, so the box's
    /// right border was clipped and the graphs fell apart. A run is drawn as one `Text`, so
    /// glyph *n* starts at the font's advance — and `NSFont.monospacedSystemFont` advances at
    /// 0.6182 em while the font was sized by 0.6, which is +3%.
    @Test("the glyph in each cell keeps that cell's colour, all 40 columns long")
    @MainActor
    func advancesLandOnCellBoundaries() throws {
        // Each column gets its own green, so "which glyph is this" is readable from the
        // pixels. Drift shows up as a colour that is drawn outside its own cell — the
        // version this pins had the last glyph of a 40-column run 1.5 cells too far right.
        let columns = 40
        let shade = { (column: Int) in TerminalColor.rgb(red: 0, green: UInt8(20 + column * 5), blue: 0).rawValue }
        let frame = Self.frame(columns: columns, rows: 1) { cells in
            for column in 0 ..< columns {
                cells[column] = CellData(
                    symbol: "M", foreground: shade(column), background: Self.black,
                    modifier: 0, skip: false, hyperlink: nil
                )
            }
        }
        let width = CGFloat(columns) * Self.cell.width
        let image = try Self.pixels(
            PaneCellCanvas(
                frame: frame,
                inner: SurfaceRect(originX: 0, originY: 0, width: UInt16(columns), height: 1),
                cellSize: Self.cell,
                palette: Self.palette()
            )
            .frame(width: width, height: Self.cell.height)
        )
        func greenRange(_ column: Int) -> Int {
            (0 ..< image.height).map { image.at(column: column, row: $0).green }.max() ?? 0
        }
        // The last column's own green (20 + 39 * 5 = 215) must be drawn inside the last cell.
        let lastCell = (columns - 1) * Int(Self.cell.width)
        let lastGreen = (lastCell ..< columns * Int(Self.cell.width)).map(greenRange).max() ?? 0
        #expect(lastGreen > 190, "the last column's glyph is missing from its own cell")
        // And the first cell must still hold the first column's green (25), not a later one:
        // with drift the whole run slides right and the first cell shows a neighbour.
        let firstGreen = (0 ..< Int(Self.cell.width)).map(greenRange).max() ?? 0
        #expect(firstGreen > 15 && firstGreen < 60, "the first cell shows green \(firstGreen)")
    }

    @Test("a run of box drawing is one unbroken line, not a dashed one")
    @MainActor
    func boxDrawingHasNoGaps() throws {
        let columns = 20
        let frame = Self.frame(columns: columns, rows: 1) { cells in
            for column in 0 ..< columns {
                cells[column] = CellData(
                    symbol: "\u{2500}", foreground: Self.white, background: Self.black,
                    modifier: 0, skip: false, hyperlink: nil
                )
            }
        }
        let width = CGFloat(columns) * Self.cell.width
        let image = try Self.pixels(
            PaneCellCanvas(
                frame: frame,
                inner: SurfaceRect(originX: 0, originY: 0, width: UInt16(columns), height: 1),
                cellSize: Self.cell,
                palette: Self.palette()
            )
            .frame(width: width, height: Self.cell.height)
        )
        // Every column of the rule must carry ink: terminals draw these as a rect for exactly
        // this reason, and a fallback font's side bearings turn the rule into dashes.
        let emptyColumns = (0 ..< Int(width)).filter { column in
            (0 ..< image.height).allSatisfy { image.at(column: column, row: $0).brightness < 60 }
        }
        #expect(emptyColumns.isEmpty, "columns with no ink: \(emptyColumns.prefix(8))")
    }

    @Test("a wide glyph's second cell does not shift the cell after it")
    @MainActor
    func wideGlyphKeepsColumnsAligned() throws {
        let frame = Self.frame(columns: 4, rows: 1) { cells in
            cells[0] = CellData(
                symbol: "\u{4E16}", foreground: Self.white, background: Self.black,
                modifier: 0, skip: false, hyperlink: nil
            )
            cells[1] = CellData(
                symbol: "", foreground: Self.white, background: Self.black,
                modifier: 0, skip: true, hyperlink: nil
            )
            cells[2] = CellData(
                symbol: "M", foreground: Self.white, background: Self.black,
                modifier: 0, skip: false, hyperlink: nil
            )
        }
        let width = 4 * Self.cell.width
        let image = try Self.pixels(
            PaneCellCanvas(
                frame: frame,
                inner: SurfaceRect(originX: 0, originY: 0, width: 4, height: 1),
                cellSize: Self.cell,
                palette: Self.palette()
            )
            .frame(width: width, height: Self.cell.height)
        )
        let thirdCell = (2 * Int(Self.cell.width) ..< 3 * Int(Self.cell.width))
        let ink = thirdCell.flatMap { column in
            (0 ..< image.height).map { image.at(column: column, row: $0).brightness }
        }
        #expect(ink.max() ?? 0 > 120, "the cell after the wide glyph is empty")
    }

    @Test("the renderer is off unless asked, and one variable turns it on")
    func policyIsOffByDefault() {
        CellPainterPolicy.apply([:])
        #expect(!CellPainterPolicy.enabled)
        CellPainterPolicy.apply(["KRAAL_CELL_PAINTER": "1"])
        #expect(CellPainterPolicy.enabled)
        CellPainterPolicy.apply(["KRAAL_CELL_PAINTER": "0"])
        #expect(!CellPainterPolicy.enabled)
    }

    // MARK: - Pixels

    private struct PixelSample {
        let red: Int
        let green: Int
        let blue: Int
        var brightness: Int { (red + green + blue) / 3 }
    }

    private struct Pixels {
        let rgba: [UInt8]
        let width: Int
        let height: Int

        func at(column: Int, row: Int) -> PixelSample {
            let index = (row * width + column) * 4
            guard index + 2 < rgba.count else { return PixelSample(red: 0, green: 0, blue: 0) }
            return PixelSample(
                red: Int(rgba[index]), green: Int(rgba[index + 1]), blue: Int(rgba[index + 2])
            )
        }

        func maxBrightness(in rows: Range<Int>) -> Int {
            rows.flatMap { row in
                (0 ..< width).map { column in at(column: column, row: row).brightness }
            }.max() ?? 0
        }

        func maxRed() -> Int {
            (0 ..< height).flatMap { row in
                (0 ..< width).map { column in at(column: column, row: row).red }
            }.max() ?? 0
        }
    }

    @MainActor
    private static func pixels(_ view: some View) throws -> Pixels {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cgImage = try #require(renderer.cgImage)
        var rgba = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try #require(rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            )
            return true
        })
        return Pixels(rgba: rgba, width: cgImage.width, height: cgImage.height)
    }
}
