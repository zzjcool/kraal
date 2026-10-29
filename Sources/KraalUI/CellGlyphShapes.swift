// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Geometry for the characters a terminal draws itself instead of asking a font.
//
// Measured reason this exists: a fixture that fills the screen with braille `⣿` renders as a
// uniform dot grid in the engine and as *dots grouped in pairs with a gap at every cell
// boundary* through the painter, because the fallback font's braille is narrower than the
// cell and the leftover advance shows up as that gap. The same class of character — box
// drawing, block elements — is drawn by every VT as rectangles for exactly this reason.
//
// So: unit-square geometry, no font, no advance. Everything here is in 0...1 × 0...1 of one
// cell, y down, so the caller can multiply by its own cell size.

import CoreGraphics

/// One piece of a cell's ink, in the cell's own unit square.
public enum CellShape: Equatable, Hashable {
    case rect(CGRect)
    case dot(center: CGPoint, radius: CGFloat)
}

public enum CellGlyphShapes {
    /// What to draw for `symbol`, or `nil` to fall back to the font.
    ///
    /// Digits and letters never reach the geometry path: only the ranges a VT owns.
    public static func shapes(for symbol: String) -> [CellShape]? {
        guard let scalar = symbol.unicodeScalars.first, symbol.unicodeScalars.count == 1
        else { return nil }
        switch scalar.value {
        case 0x2500 ... 0x257F: return boxDrawing(scalar.value)
        case 0x2580 ... 0x259F: return blocks(scalar.value)
        case 0x2800 ... 0x28FF: return braille(scalar.value)
        default: return nil
        }
    }

    // MARK: - Braille

    /// Two dot columns by four dot rows, on a half-cell grid — which is what makes a run of
    /// `⣿` look like one continuous field across cell boundaries.
    private static func braille(_ value: UInt32) -> [CellShape]? {
        let bits = value - 0x2800
        guard bits != 0 else { return [] }
        // Unicode braille's dot numbering is not reading order: dots 1-3 and 7 down the left
        // column, 4-6 and 8 down the right one.
        struct Dot {
            let bit: UInt32
            let column: CGFloat
            let row: CGFloat
        }
        let layout = [
            Dot(bit: 0x01, column: 0, row: 0), Dot(bit: 0x02, column: 0, row: 1),
            Dot(bit: 0x04, column: 0, row: 2), Dot(bit: 0x40, column: 0, row: 3),
            Dot(bit: 0x08, column: 1, row: 0), Dot(bit: 0x10, column: 1, row: 1),
            Dot(bit: 0x20, column: 1, row: 2), Dot(bit: 0x80, column: 1, row: 3),
        ]
        let radius: CGFloat = 0.1
        return layout.compactMap { dot in
            guard bits & dot.bit != 0 else { return nil }
            return .dot(
                center: CGPoint(x: (dot.column + 0.5) / 2, y: (dot.row + 0.5) / 4),
                radius: radius
            )
        }
    }

    // MARK: - Blocks

    private static func blocks(_ value: UInt32) -> [CellShape]? {
        func rect(
            _ left: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat
        ) -> [CellShape] {
            [.rect(CGRect(x: left, y: top, width: width, height: height))]
        }
        switch value {
        case 0x2580: return rect(0, 0, 1, 0.5)          // upper half
        case 0x2581 ... 0x2588:                          // lower eighths, 0x2588 is full
            return rect(0, 1 - CGFloat(value - 0x2580) / 8, 1, CGFloat(value - 0x2580) / 8)
        case 0x2589 ... 0x258F:                          // left eighths, 0x258F is one eighth
            let eighths = CGFloat(0x2590 - value) / 8
            return rect(0, 0, eighths, 1)
        case 0x2590: return rect(0.5, 0, 0.5, 1)         // right half
        case 0x2594: return rect(0, 0, 1, 0.125)         // upper one eighth
        case 0x2595: return rect(0.875, 0, 0.125, 1)     // right one eighth
        case 0x2596 ... 0x259F:                          // quadrants, 2 bits each
            let quadrants: [UInt32] = [0x2, 0x1, 0x8, 0x4, 0xA, 0x9, 0x6, 0x5, 0x3, 0x7]
            guard let index = quadrants.firstIndex(of: value - 0x2596) else { return nil }
            let corners: [(mask: UInt32, box: CGRect)] = [
                (0x1, CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                (0x2, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
                (0x4, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
                (0x8, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
            ]
            let mask = [0x1, 0x2, 0x4, 0x8, 0x9, 0x5, 0x6, 0xA, 0x3, 0x7][index]
            return corners.filter { mask & Int($0.mask) != 0 }.map { .rect($0.box) }
        default:
            return nil                                   // shades (░▒▓) stay with the font
        }
    }

    // MARK: - Box drawing

    /// Which way a line leaves the cell's centre.
    private struct Edge: OptionSet {
        let rawValue: Int
        static let left = Edge(rawValue: 1)
        static let right = Edge(rawValue: 2)
        static let top = Edge(rawValue: 4)
        static let bottom = Edge(rawValue: 8)
    }

    private static func boxDrawing(_ value: UInt32) -> [CellShape]? {
        // Light and heavy only: the double-line set needs its parallel pair and corner gaps
        // to look right, and a font's double lines are already continuous.
        let table: [UInt32: (Edge, CGFloat)] = [
            0x2500: ([.left, .right], 0.08), 0x2501: ([.left, .right], 0.16),
            0x2502: ([.top, .bottom], 0.08), 0x2503: ([.top, .bottom], 0.16),
            0x250C: ([.right, .bottom], 0.08), 0x250F: ([.right, .bottom], 0.16),
            0x2510: ([.left, .bottom], 0.08), 0x2513: ([.left, .bottom], 0.16),
            0x2514: ([.right, .top], 0.08), 0x2517: ([.right, .top], 0.16),
            0x2518: ([.left, .top], 0.08), 0x251B: ([.left, .top], 0.16),
            0x251C: ([.right, .top, .bottom], 0.08), 0x2523: ([.right, .top, .bottom], 0.16),
            0x2524: ([.left, .top, .bottom], 0.08), 0x252B: ([.left, .top, .bottom], 0.16),
            0x252C: ([.left, .right, .bottom], 0.08), 0x2533: ([.left, .right, .bottom], 0.16),
            0x2534: ([.left, .right, .top], 0.08), 0x253B: ([.left, .right, .top], 0.16),
            0x253C: ([.left, .right, .top, .bottom], 0.08),
            0x254B: ([.left, .right, .top, .bottom], 0.16),
        ]
        guard let (edges, thickness) = table[value] else { return nil }
        // A horizontal line spans the whole cell (so neighbours join) but a vertical one is
        // centred; `thickness` is the line's width in cell units.
        let lineWidth = thickness
        var shapes: [CellShape] = []
        if edges.contains(.left) || edges.contains(.right) {
            let minX: CGFloat = edges.contains(.left) ? 0 : 0.5
            let maxX: CGFloat = edges.contains(.right) ? 1 : 0.5
            shapes.append(.rect(CGRect(
                x: minX, y: 0.5 - lineWidth / 2, width: maxX - minX, height: lineWidth
            )))
        }
        if edges.contains(.top) || edges.contains(.bottom) {
            let minY: CGFloat = edges.contains(.top) ? 0 : 0.5
            let maxY: CGFloat = edges.contains(.bottom) ? 1 : 0.5
            shapes.append(.rect(CGRect(
                x: 0.5 - lineWidth / 2, y: minY, width: lineWidth, height: maxY - minY
            )))
        }
        return shapes
    }
}
