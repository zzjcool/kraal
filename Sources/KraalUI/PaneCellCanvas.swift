// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The pane, drawn from the daemon's cells instead of by the terminal engine.
//
// Why it exists: every seam at a pane's bottom edge that we could not remove turned out to
// be a property of *driving a real VT* while its box changed — the engine adopts a new grid
// ~25 ms after the surface is resized, writes that land in that window clamp onto its last
// line, and its padding shows the theme's background until it repaints. Measured with the
// same frames drawn four other ways (SwiftUI Canvas, AppKit, a CALayer texture, stretched
// to the pane) the static part of the picture never flickered once; the engine path did.
//
// So this draws `FrameData` directly: glyphs at `column * cellWidth`, backgrounds per run,
// no emulator in between, nothing that has to adopt a size. What it cannot do — selection,
// links, sixel, reflow of soft-wrapped lines — stays with the engine, which keeps receiving
// the same writes at the same time: this is a second renderer, not a replacement yet.

import KraalProtocol
import SwiftUI

/// One pane's cells, drawn.
///
/// `frame` is the whole surface (the daemon's frame is surface-wide) and `inner` is this
/// pane's window into it, so a split surface can hand each pane its own canvas.
public struct PaneCellCanvas: View {
    public let frame: FrameData
    public let inner: SurfaceRect
    public let cellSize: CGSize
    public let palette: AnsiPalette

    public init(frame: FrameData, inner: SurfaceRect, cellSize: CGSize, palette: AnsiPalette) {
        self.frame = frame
        self.inner = inner
        self.cellSize = cellSize
        self.palette = palette
    }

    public var body: some View {
        Canvas { context, size in
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            paintBackgrounds(in: &context)
            paintGlyphs(in: &context)
            paintCursor(in: &context)
        }
        .accessibilityHidden(false)
    }

    // MARK: - Geometry

    private var columns: Int { Int(inner.width) }
    private var rows: Int { Int(inner.height) }
    private var grid: CGRect {
        CGRect(
            x: 0, y: 0,
            width: CGFloat(columns) * cellSize.width,
            height: CGFloat(rows) * cellSize.height
        )
    }

    /// One cell of this pane, in the overall frame's coordinates.
    private func cell(column: Int, row: Int) -> CellData? {
        frame.cell(column: Int(inner.originX) + column, row: Int(inner.originY) + row)
    }

    private func origin(column: Int, row: Int) -> CGPoint {
        CGPoint(x: CGFloat(column) * cellSize.width, y: CGFloat(row) * cellSize.height)
    }

    // MARK: - Colour

    /// What a cell's ink and paper actually are, once the modifier bits are applied.
    ///
    /// `reversed` and `hidden` are *renderer* concerns in this protocol — the daemon ships the
    /// bits, not the swapped colours — so a painter that ignores them draws terminals inside
    /// out. Both are on the hot path here rather than at the call site for that reason.
    struct Resolved {
        var ink: UInt32
        var paper: UInt32
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strikethrough: Bool
    }

    func resolve(_ cell: CellData) -> Resolved {
        var ink = self.ink(cell.foreground)
        var paper = self.paper(cell.background)
        if cell.modifier & CellModifier.reversed != 0 {
            swap(&ink, &paper)
        }
        if cell.modifier & CellModifier.dim != 0 {
            ink = Resolved.dimmed(ink)
        }
        if cell.modifier & CellModifier.hidden != 0 {
            ink = paper
        }
        return Resolved(
            ink: ink,
            paper: paper,
            bold: cell.modifier & CellModifier.bold != 0,
            italic: cell.modifier & CellModifier.italic != 0,
            underline: cell.modifier & CellModifier.underline != 0,
            strikethrough: cell.modifier & CellModifier.strikethrough != 0
        )
    }

    // MARK: - Painting

    /// A wire colour as ink. `0` means "the terminal's default", and which default it is
    /// depends on the field — the wire has no separate tag for foreground and background, so
    /// resolving it without knowing the role paints black text on a black page.
    private func ink(_ raw: UInt32) -> UInt32 {
        raw == 0 ? palette.foreground : palette.rgb(TerminalColor(raw: raw))
    }

    private func paper(_ raw: UInt32) -> UInt32 {
        raw == 0 ? palette.background : palette.rgb(TerminalColor(raw: raw))
    }

    /// The paper of one cell, or nil past the grid. A helper rather than a local so the
    /// grouping loops do not shadow the `cell(column:row:)` accessor with a `CellData`.
    private func paper(column: Int, row: Int) -> UInt32? {
        cell(column: column, row: row).map { resolve($0).paper }
    }

    private func ink(column: Int, row: Int) -> Resolved? {
        cell(column: column, row: row).map { resolve($0) }
    }

    private func paintBackgrounds(in context: inout GraphicsContext) {
        for row in 0 ..< rows {
            var column = 0
            while column < columns {
                guard let paperColor = paper(column: column, row: row) else { break }
                var end = column + 1
                while end < columns, paper(column: end, row: row) == paperColor {
                    end += 1
                }
                let box = CGRect(
                    origin: origin(column: column, row: row),
                    size: CGSize(
                        width: CGFloat(end - column) * cellSize.width,
                        height: cellSize.height
                    )
                )
                context.fill(Path(box), with: .color(Self.color(paperColor)))
                column = end
            }
        }
    }

    private func paintGlyphs(in context: inout GraphicsContext) {
        // Glyphs are clipped to the grid, never to the canvas: a font's line box is taller
        // than a cell, and a descender in the last row must not paint into the seam below.
        context.clip(to: Path(grid))
        for row in 0 ..< rows {
            var column = 0
            while column < columns {
                guard let key = ink(column: column, row: row) else { break }
                var symbols = ""
                var end = column
                while end < columns, let next = cell(column: end, row: row) {
                    let resolved = resolve(next)
                    guard resolved.ink == key.ink, resolved.bold == key.bold,
                          resolved.italic == key.italic, resolved.underline == key.underline,
                          resolved.strikethrough == key.strikethrough
                    else { break }
                    // `skip` marks the second column of a wide glyph: the symbol already
                    // covered both, and drawing it again is how wide characters turn into
                    // two narrower ones.
                    if !next.skip { symbols += next.symbol.isEmpty ? " " : next.symbol }
                    end += 1
                }
                if end == column {
                    end = column + 1
                }
                paintRun(
                    Run(symbols: symbols, key: key, columns: column ..< end, row: row),
                    in: &context
                )
                column = end
            }
        }
    }

    /// One stretch of cells that share ink and decoration, ready to draw.
    struct Run {
        var symbols: String
        var key: Resolved
        /// The cell range the run covers, so the slow path can place each glyph itself.
        var columns: Range<Int>
        var row: Int
    }

    private func paintRun(_ run: Run, in context: inout GraphicsContext) {
        let key = run.key
        guard !run.symbols.isEmpty else { return }
        if Self.isPlain(run.symbols) {
            paintText(
                run.symbols, key: key, column: run.columns.lowerBound, row: run.row,
                in: &context
            )
            return
        }
        // Anything that is not plain ASCII is placed cell by cell. The reason is measured,
        // not stylistic: a run is one `Text`, so every glyph after the first sits at the
        // *font's* advance. `NSFont.monospacedSystemFont` advances at 0.6182 em, not the 0.6
        // the font is sized by, so a 130-column TUI row ended 3 columns wide — its right
        // border was cut off and its graphs (braille, box drawing) drifted apart while the
        // box characters, which are drawn by the fallback font at yet another advance, split
        // into dashes. Per-cell placement makes a cell's ink start where the cell starts.
        for column in run.columns {
            guard let cell = cell(column: column, row: run.row) else { continue }
            if cell.skip || cell.symbol.isEmpty { continue }
            if let level = CellGlyphShapes.shadeLevel(for: cell.symbol) {
                let paperColor = paper(column: column, row: run.row) ?? palette.background
                let box = origin(column: column, row: run.row)
                context.fill(
                    Path(CGRect(origin: box, size: cellSize)),
                    with: .color(Self.mix(paperColor, key.ink, level))
                )
            } else if let shapes = CellGlyphShapes.shapes(for: cell.symbol) {
                paint(shapes, ink: key.ink, column: column, row: run.row, in: &context)
            } else {
                paintText(
                    cell.symbol, key: key, column: column, row: run.row,
                    span: span(column: column, row: run.row), in: &context
                )
            }
        }
    }

    /// How many cells this cell's glyph occupies: 1, or more when the daemon marks the cells
    /// it covers as `skip`.
    private func span(column: Int, row: Int) -> Int {
        var width = 1
        while column + width < columns,
              let next = cell(column: column + width, row: row), next.skip {
            width += 1
        }
        return width
    }

    /// Braille dots, block elements and box rules, drawn as geometry in the cell's own rect.
    ///
    /// The alternative costs a visible seam per cell: a font's braille is narrower than a
    /// cell, so a field of `⣿` came out as pairs of dots with a gap at every cell boundary
    /// while the engine's was one even grid. `CellGlyphShapes` has that measurement.
    private func paint(
        _ shapes: [CellShape],
        ink: UInt32,
        column: Int,
        row: Int,
        in context: inout GraphicsContext
    ) {
        let box = origin(column: column, row: row)
        for shape in shapes {
            switch shape {
            case let .rect(unit):
                context.fill(
                    Path(CGRect(
                        x: box.x + unit.minX * cellSize.width,
                        y: box.y + unit.minY * cellSize.height,
                        width: unit.width * cellSize.width,
                        height: unit.height * cellSize.height
                    )),
                    with: .color(Self.color(ink))
                )
            case let .dot(center, radius):
                // A dot's radius is a fraction of the cell *width*; using the height would
                // give ellipses on the 8.5 x 18.5 cell this terminal uses.
                let point = CGPoint(
                    x: box.x + center.x * cellSize.width,
                    y: box.y + center.y * cellSize.height
                )
                let size = radius * cellSize.width
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - size, y: point.y - size, width: size * 2, height: size * 2
                    )),
                    with: .color(Self.color(ink))
                )
            }
        }
    }

    /// Draws `symbols` as one `Text` at `column`, correcting the advance so glyph *n* starts
    /// at `n * cellWidth` however the font rounds.
    private func paintText(
        _ symbols: String,
        key: Resolved,
        column: Int,
        row: Int,
        span: Int = 1,
        in context: inout GraphicsContext
    ) {
        var text = Text(symbols)
            .font(font(bold: key.bold, italic: key.italic))
            .foregroundColor(Self.color(key.ink))
        if key.underline {
            text = text.underline()
        }
        if key.strikethrough {
            text = text.strikethrough()
        }
        let box = origin(column: column, row: row)
        let top = CGPoint(x: box.x, y: box.y + cellSize.height * Self.baselineInset)
        if span > 1 {
            // A wide glyph owns two cells but the fallback font that provides it does not
            // necessarily advance two cells: left-aligned it leaves the gap on one side only.
            // `anchor: .top` keeps the glyph's top where it was and centres it in its span.
            context.draw(
                text,
                at: CGPoint(x: top.x + CGFloat(span) * cellSize.width / 2, y: top.y),
                anchor: .top
            )
            return
        }
        context.draw(text, at: top, anchor: .topLeading)
    }

    /// ASCII with no combining marks: one advance per character, so the run can be one Text.
    private static func isPlain(_ symbols: String) -> Bool {
        symbols.utf8.count == symbols.unicodeScalars.count
            && symbols.unicodeScalars.allSatisfy { $0.isASCII }
    }

    private func paintCursor(in context: inout GraphicsContext) {
        guard let cursor = frame.cursor, cursor.visible else { return }
        let column = Int(cursor.column) - Int(inner.originX)
        let row = Int(cursor.row) - Int(inner.originY)
        guard column >= 0, column < columns, row >= 0, row < rows else { return }
        let box = CGRect(
            origin: origin(column: column, row: row),
            size: cellSize
        )
        context.fill(Path(box), with: .color(Self.color(palette.cursor)))
        guard let cell = cell(column: column, row: row) else { return }
        let resolved = resolve(cell)
        let symbol = cell.symbol.isEmpty ? " " : cell.symbol
        context.draw(
            Text(symbol)
                .font(font(bold: resolved.bold, italic: resolved.italic))
                .foregroundColor(Self.color(resolved.paper)),
            at: CGPoint(x: box.minX, y: box.minY + cellSize.height * Self.baselineInset),
            anchor: .topLeading
        )
    }

    // MARK: - Type

    /// The size whose advance is one cell wide.
    ///
    /// SwiftUI's `design: .monospaced` face advances at exactly 0.6 em — measured by drawing
    /// 40 glyphs into a 1-pixel-per-point canvas at cell widths 8.0 and 8.5 and reading the
    /// ink back: columns landed at 8.0/8.5 pt apart in both cases. (`NSFont`'s
    /// `monospacedSystemFont` reports 0.6182 em for the same size, which is a different face
    /// and is *not* what this draws — sizing by that number only makes the text 3% small.)
    private func font(bold: Bool, italic: Bool) -> Font {
        let size = max(4, cellSize.width / 0.6)
        var font = Font.system(size: size, weight: bold ? .semibold : .regular, design: .monospaced)
        if italic {
            font = font.italic()
        }
        return font
    }

    private static let baselineInset: CGFloat = 0.1

    /// `paper` and `ink` mixed by `level` of ink, which is how a terminal draws `░▒▓`.
    static func mix(_ paper: UInt32, _ ink: UInt32, _ level: CGFloat) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let background = Double((paper >> shift) & 0xFF)
            let foreground = Double((ink >> shift) & 0xFF)
            return (background + (foreground - background) * level) / 255
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }

    /// `0xRRGGBB` as a colour.
    static func color(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

extension PaneCellCanvas.Resolved {
    /// SGR 2: the ink keeps its hue at about 60% of its brightness.
    static func dimmed(_ rgb: UInt32) -> UInt32 {
        let scale = 0.6
        let red = UInt32((Double((rgb >> 16) & 0xFF) * scale).rounded())
        let green = UInt32((Double((rgb >> 8) & 0xFF) * scale).rounded())
        let blue = UInt32((Double(rgb & 0xFF) * scale).rounded())
        return (red << 16) | (green << 8) | blue
    }
}
