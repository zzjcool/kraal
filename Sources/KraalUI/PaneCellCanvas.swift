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
                    Run(symbols: symbols, key: key, column: column, row: row),
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
        var column: Int
        var row: Int
    }

    private func paintRun(_ run: Run, in context: inout GraphicsContext) {
        let key = run.key
        guard !run.symbols.isEmpty else { return }
        var text = Text(run.symbols)
            .font(font(bold: key.bold, italic: key.italic))
            .foregroundColor(Self.color(key.ink))
        if key.underline {
            text = text.underline()
        }
        if key.strikethrough {
            text = text.strikethrough()
        }
        let box = origin(column: run.column, row: run.row)
        context.draw(
            text,
            at: CGPoint(x: box.x, y: box.y + cellSize.height * Self.baselineInset),
            anchor: .topLeading
        )
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

    /// A monospaced advance is about 0.6 em, so this is the size whose cell is one cell wide.
    /// The engine picks its font the same way; when the two disagree the text is a little
    /// small or large but every column still lands on the same x.
    private func font(bold: Bool, italic: Bool) -> Font {
        let size = max(6, cellSize.width / 0.6)
        var font = Font.system(size: size, weight: bold ? .semibold : .regular, design: .monospaced)
        if italic {
            font = font.italic()
        }
        return font
    }

    private static let baselineInset: CGFloat = 0.1

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
