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
            return nil
        }
    }

    /// ░ ▒ ▓: how much of the ink the cell is filled with.
    ///
    /// Not a dither, and the engine is why: it fills these with the two colours mixed, so a
    /// 25% shade there is a flat dark grey that joins its neighbours. A 4x4 dither was tried
    /// first and reads as a dashed band — the same "should be continuous but broken" the
    /// braille fix was about.
    public static func shadeLevel(for symbol: String) -> CGFloat? {
        guard let scalar = symbol.unicodeScalars.first, symbol.unicodeScalars.count == 1
        else { return nil }
        switch scalar.value {
        case 0x2591: return 0.25
        case 0x2592: return 0.5
        case 0x2593: return 0.75
        default: return nil
        }
    }

    // MARK: - Box drawing

    /// Weights a box-drawing stroke can have. Light and heavy are single lines; double is two
    /// parallel ones, which is why it cannot be expressed as "a thickness".
    private enum Stroke: UInt8 {
        case none = 0
        case light = 1
        case heavy = 2
        case double = 3
    }

    /// The four ways a stroke can leave the cell's centre.
    private struct Edges {
        var left: Stroke = .none
        var right: Stroke = .none
        var top: Stroke = .none
        var bottom: Stroke = .none

        init(_ left: UInt8, _ right: UInt8, _ top: UInt8, _ bottom: UInt8) {
            self.left = Stroke(rawValue: left) ?? .none
            self.right = Stroke(rawValue: right) ?? .none
            self.top = Stroke(rawValue: top) ?? .none
            self.bottom = Stroke(rawValue: bottom) ?? .none
        }
    }

    /// Every box-drawing character whose shape is unambiguous as strokes: the light, heavy,
    /// mixed light/heavy, and the whole double set. Dashed (U+254C-2573) is deliberately
    /// absent — a font's dashes are already dashes, and drawing them solid would be worse.
    private static let boxTable: [UInt32: Edges] = [
        // straight
        0x2500: Edges(1, 1, 0, 0), 0x2501: Edges(2, 2, 0, 0),
        0x2502: Edges(0, 0, 1, 1), 0x2503: Edges(0, 0, 2, 2),
        // single corners
        0x250C: Edges(0, 1, 0, 1), 0x250F: Edges(0, 2, 0, 2),
        0x2510: Edges(1, 0, 0, 1), 0x2513: Edges(2, 0, 0, 2),
        0x2514: Edges(0, 1, 1, 0), 0x2517: Edges(0, 2, 2, 0),
        0x2518: Edges(1, 0, 1, 0), 0x251B: Edges(2, 0, 2, 0),
        // mixed light/heavy corners
        0x250D: Edges(0, 2, 0, 1), 0x250E: Edges(0, 1, 0, 2),
        0x2511: Edges(2, 0, 0, 1), 0x2512: Edges(1, 0, 0, 2),
        0x2515: Edges(0, 2, 1, 0), 0x2516: Edges(0, 1, 2, 0),
        0x2519: Edges(2, 0, 1, 0), 0x251A: Edges(1, 0, 2, 0),
        // tees and crosses
        0x251C: Edges(0, 1, 1, 1), 0x2523: Edges(0, 2, 2, 2),
        0x2524: Edges(1, 0, 1, 1), 0x252B: Edges(2, 0, 2, 2),
        0x252C: Edges(1, 1, 0, 1), 0x2533: Edges(2, 2, 0, 2),
        0x2534: Edges(1, 1, 1, 0), 0x253B: Edges(2, 2, 2, 0),
        0x253C: Edges(1, 1, 1, 1), 0x254B: Edges(2, 2, 2, 2),
        // mixed tees
        0x2521: Edges(0, 2, 1, 1), 0x2522: Edges(0, 1, 2, 2),
        0x2529: Edges(1, 0, 1, 2), 0x252A: Edges(2, 0, 2, 1),
        0x252D: Edges(1, 2, 0, 1), 0x252E: Edges(2, 1, 0, 1),
        0x2531: Edges(1, 2, 1, 0), 0x2532: Edges(2, 1, 1, 0),
        0x2535: Edges(1, 2, 1, 1), 0x2536: Edges(2, 1, 1, 1),
        0x2539: Edges(1, 1, 1, 2), 0x253A: Edges(1, 1, 2, 1),
        0x253D: Edges(1, 2, 1, 2), 0x253E: Edges(2, 1, 2, 1),
        0x2540: Edges(1, 1, 0, 2), 0x2541: Edges(2, 2, 0, 1),
        0x2542: Edges(1, 1, 2, 0), 0x2543: Edges(2, 1, 1, 1),
        0x2544: Edges(1, 2, 1, 1), 0x2545: Edges(1, 1, 2, 1),
        0x2546: Edges(1, 1, 1, 2), 0x2547: Edges(1, 1, 2, 2),
        0x2548: Edges(2, 2, 1, 1), 0x2549: Edges(1, 1, 1, 2),
        0x254A: Edges(1, 1, 2, 1),
        // double straight
        0x2550: Edges(3, 3, 0, 0), 0x2551: Edges(0, 0, 3, 3),
        0x2552: Edges(0, 3, 0, 1), 0x2553: Edges(0, 1, 0, 3),
        0x2554: Edges(0, 3, 0, 3),
        0x2555: Edges(3, 0, 0, 1), 0x2556: Edges(1, 0, 0, 3),
        0x2557: Edges(3, 0, 0, 3),
        0x2558: Edges(0, 3, 1, 0), 0x2559: Edges(0, 1, 3, 0),
        0x255A: Edges(0, 3, 3, 0),
        0x255B: Edges(3, 0, 1, 0), 0x255C: Edges(1, 0, 3, 0),
        0x255D: Edges(3, 0, 3, 0),
        0x255E: Edges(0, 3, 1, 1), 0x255F: Edges(0, 1, 3, 3),
        0x2560: Edges(0, 3, 3, 3),
        0x2561: Edges(3, 0, 1, 1), 0x2562: Edges(1, 0, 3, 3),
        0x2563: Edges(3, 0, 3, 3),
        0x2564: Edges(1, 1, 0, 3), 0x2565: Edges(3, 3, 0, 1),
        0x2566: Edges(3, 3, 0, 3),
        0x2567: Edges(1, 1, 3, 0), 0x2568: Edges(3, 3, 1, 0),
        0x2569: Edges(3, 3, 3, 0),
        0x256A: Edges(3, 3, 1, 1), 0x256B: Edges(1, 1, 3, 3),
        0x256C: Edges(3, 3, 3, 3),
        // half lines
        0x2574: Edges(1, 0, 0, 0), 0x2575: Edges(0, 0, 1, 0),
        0x2576: Edges(0, 1, 0, 0), 0x2577: Edges(0, 0, 0, 1),
        0x2578: Edges(2, 0, 0, 0), 0x2579: Edges(0, 0, 2, 0),
        0x257A: Edges(0, 2, 0, 0), 0x257B: Edges(0, 0, 0, 2),
    ]

    /// A light stroke is 8% of the cell, a heavy one 16%, and a double is a pair of 6% strokes
    /// ten points apart — the same proportions a terminal uses, so a box matches the engine's.
    private static let strokes: [Stroke: [(centre: CGFloat, thickness: CGFloat)]] = [
        .light: [(0.5, 0.08)],
        .heavy: [(0.5, 0.16)],
        .double: [(0.4, 0.06), (0.6, 0.06)],
    ]

    private static func boxDrawing(_ value: UInt32) -> [CellShape]? {
        guard let edges = boxTable[value] else { return nil }
        var shapes: [CellShape] = []
        // A stroke that leaves both ways is one rect, not two: halves that meet at 0.5 blend
        // against each other and leave a faint seam in the middle of a rule.
        if edges.left == edges.right {
            shapes += rule(edges.left, horizontal: (0, 1))
        } else {
            shapes += rule(edges.left, horizontal: (0, 0.5))
            shapes += rule(edges.right, horizontal: (0.5, 1))
        }
        if edges.top == edges.bottom {
            shapes += rule(edges.top, vertical: (0, 1))
        } else {
            shapes += rule(edges.top, vertical: (0, 0.5))
            shapes += rule(edges.bottom, vertical: (0.5, 1))
        }
        return shapes
    }

    /// A horizontal stroke of `stroke`'s weight spanning `span` in x, at each of the weight's
    /// offsets from the cell's centre line.
    private static func rule(
        _ stroke: Stroke, horizontal span: (CGFloat, CGFloat)
    ) -> [CellShape] {
        lines(stroke).map { line in
            .rect(CGRect(
                x: span.0, y: line.centre - line.thickness / 2,
                width: span.1 - span.0, height: line.thickness
            ))
        }
    }

    private static func rule(
        _ stroke: Stroke, vertical span: (CGFloat, CGFloat)
    ) -> [CellShape] {
        lines(stroke).map { line in
            .rect(CGRect(
                x: line.centre - line.thickness / 2, y: span.0,
                width: line.thickness, height: span.1 - span.0
            ))
        }
    }

    private static func lines(_ stroke: Stroke) -> [(centre: CGFloat, thickness: CGFloat)] {
        guard stroke != .none else { return [] }
        return strokes[stroke] ?? []
    }
}
