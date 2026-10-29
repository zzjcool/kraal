// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import KraalProtocol
@testable import KraalUI

/// The characters a VT draws itself. The reason they are geometry at all is measured: a
/// font's braille is narrower than a cell, so a field of `⣿` came out as pairs of dots with
/// a gap at every cell boundary, while the engine's was one even grid.
@Suite("Cell glyph shapes")
struct CellGlyphShapesTests {
    @Test("a full braille cell is eight dots on a half-cell grid")
    func brailleFullCell() throws {
        let shapes = try #require(CellGlyphShapes.shapes(for: "\u{28FF}"))
        #expect(shapes.count == 8)
        let centers = shapes.compactMap { shape -> CGPoint? in
            if case let .dot(center, _) = shape { return center }
            return nil
        }
        #expect(centers.count == 8)
        // Dot 1 is the top-left quarter: braille is not laid out in reading order, dot 7 and
        // 8 are the bottom row.
        #expect(centers.contains(CGPoint(x: 0.25, y: 0.125)))
        #expect(centers.contains(CGPoint(x: 0.75, y: 0.875)))
    }

    @Test("one braille dot is one dot, and blank braille is nothing")
    func brailleSingleDot() throws {
        #expect(try #require(CellGlyphShapes.shapes(for: "\u{2801}")).count == 1)
        #expect(try #require(CellGlyphShapes.shapes(for: "\u{2800}")).isEmpty)
    }

    @Test("box drawing is a rule to the cell's edges, not an inset glyph")
    func boxRules() throws {
        let cross = try #require(CellGlyphShapes.shapes(for: "\u{253C}"))
        #expect(cross.count == 2, "a cross is one horizontal and one vertical rule")
        if case let .rect(horizontal) = cross[0] {
            #expect(horizontal.minX == 0 && horizontal.maxX == 1, "the rule stops short")
        }
        if case let .rect(vertical) = cross[1] {
            #expect(vertical.minY == 0 && vertical.maxY == 1, "the rule stops short")
        }
    }

    @Test("block elements are fraction rectangles")
    func blocks() throws {
        if case let .rect(upper) = try #require(CellGlyphShapes.shapes(for: "\u{2580}")).first {
            #expect(upper == CGRect(x: 0, y: 0, width: 1, height: 0.5))
        }
        if case let .rect(full) = try #require(CellGlyphShapes.shapes(for: "\u{2588}")).first {
            #expect(full == CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    @Test("letters are left to the font")
    func textFallsThrough() {
        #expect(CellGlyphShapes.shapes(for: "M") == nil)
        #expect(CellGlyphShapes.shapes(for: "mm") == nil, "a multi-scalar cluster is not geometry")
    }

    /// The bug this pins, in pixels: a run of `⣿` must be an even dot grid across cell
    /// boundaries. Before the geometry path the boundary gap was visibly wider than the gap
    /// inside a cell, which is what made a graph look like separated blobs.
    @Test("braille dots are evenly spaced across cell boundaries")
    @MainActor
    func brailleGridIsEven() throws {
        let cell = CGSize(width: 24, height: 40)
        let columns = 4
        var cells = Array(
            repeating: CellData(
                symbol: "\u{28FF}", foreground: 0x00FF_FFFF, background: 0x0000_0000,
                modifier: 0, skip: false, hyperlink: nil
            ),
            count: columns
        )
        cells[0].foreground = 0x00FF_FFFF
        let frame = FrameData(
            cells: cells, width: UInt16(columns), height: 1,
            cursor: nil, hyperlinks: [], graphics: Data()
        )
        let palette = AnsiPalette(
            foreground: 0xFFFF_FFFF, background: 0x0000_0000, cursor: 0xFFFF_0000,
            named: Array(repeating: 0x0000_0000, count: 16)
        )
        let view = PaneCellCanvas(
            frame: frame,
            inner: SurfaceRect(originX: 0, originY: 0, width: UInt16(columns), height: 1),
            cellSize: cell, palette: palette
        )
        .frame(width: cell.width * CGFloat(columns), height: cell.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try #require(rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        })

        // The top row of dots: y = 0.125 * 40 = 5.
        let row = 5
        var gaps: [Int] = []
        var lastInk = -1
        for column in 0 ..< image.width {
            let index = (row * image.width + column) * 4
            let lit = Int(rgba[index]) > 120
            if lit {
                if lastInk >= 0, column - lastInk > 1 { gaps.append(column - lastInk - 1) }
                lastInk = column
            }
        }
        let widest = gaps.max() ?? 0
        let narrowest = gaps.min() ?? 0
        #expect(gaps.count >= 7, "expected a dot per half cell, found \(gaps.count + 1)")
        #expect(widest - narrowest <= 3, "gaps \(gaps) are uneven: the grid breaks at cell edges")
    }
}
