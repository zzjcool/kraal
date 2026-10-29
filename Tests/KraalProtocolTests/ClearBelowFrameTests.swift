// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The bytes the renderer writes when the pane is taller than the frame it paints: where the erase
// goes, which colour it uses, and in what order the rows follow.
//
// Everything here is about *order and content of the output*, because that is the part a test
// can pin without a clock. What an engine does with those bytes while it is still adopting a new
// size is pinned against a real one in `LiveGhosttyPaintTests`.
//
// Split out of SurfaceANSIRendererTests.swift, which is at the 900-line limit's doorstep.

import Foundation
import Testing

@testable import KraalProtocol

private let esc = "\u{1B}["

/// A frame whose every cell is blank text on `background`.
private func plainFrame(
    width: UInt16, height: UInt16, background: UInt32 = 0,
    rowBackgrounds: [Int: UInt32] = [:]
) -> FrameData {
    var cells: [CellData] = []
    for row in 0 ..< Int(height) {
        for _ in 0 ..< Int(width) {
            var cell = CellData.blank
            cell.background = rowBackgrounds[row] ?? background
            cells.append(cell)
        }
    }
    return FrameData(
        cells: cells, width: width, height: height, cursor: nil, hyperlinks: [], graphics: Data()
    )
}

/// `frame` with the symbol of one cell replaced, which is the smallest change a diff can see.
private func touching(_ frame: FrameData, row: Int, column: Int = 0) -> FrameData {
    var cells = frame.flatCells
    cells[row * Int(frame.width) + column].symbol = "x"
    return FrameData(
        cells: cells, width: frame.width, height: frame.height,
        cursor: nil, hyperlinks: [], graphics: Data()
    )
}

private func text(_ data: Data) -> String {
    String(bytes: data, encoding: .utf8) ?? ""
}

/// Where `needle` first occurs in `haystack`, in characters; `nil` when it does not.
private func offset(of needle: String, in haystack: String) -> Int? {
    haystack.range(of: needle).map { haystack.distance(from: haystack.startIndex, to: $0.lowerBound) }
}

/// Every row address (`CSI <row> ; 1 H`) in the output, as 1-based rows and in the order written.
///
/// A paint always ends by parking the cursor with one more `CSI <row> ; <col> H`, wherever the
/// cursor is, so the last cursor address of any kind is not a row and is dropped first.
private func rowAddresses(_ output: String) -> [Int] {
    let addresses: [(row: Int, column: Int)] = output.components(separatedBy: esc).dropFirst().compactMap { piece in
        guard let end = piece.firstIndex(of: "H") else { return nil }
        let parameters = piece[..<end].split(separator: ";", omittingEmptySubsequences: false)
        guard parameters.count == 2, let row = Int(parameters[0]), let column = Int(parameters[1]) else {
            return nil
        }
        return (row, column)
    }
    return addresses.dropLast().filter { $0.column == 1 }.map(\.row)
}

@Suite("Erasing below the frame")
struct ClearBelowFrameTests {
    private let wide: UInt16 = 8

    /// A baseline for `frame`, then the same frame painted again into a taller view, which is the
    /// call that has something to erase.
    private func repaint(
        _ frame: FrameData, into viewRows: Int, after baseline: FrameData? = nil
    ) -> String {
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(baseline ?? frame, clearingFirst: true)
        return text(renderer.render(
            frame, clearingFirst: false, invalidateBaseline: false, viewRows: viewRows
        ))
    }

    // MARK: Order

    /// Rows go from the last to the first.
    ///
    /// A terminal whose screen is shorter than the frame clamps every address past its last line
    /// onto that line, so each of those writes replaces the one before. Written top-down, the row
    /// left on that line is the frame's *last* one — a picture that no frame the daemon ever sent
    /// contains. Written bottom-up, the clamped rows go first and the row that belongs there lands
    /// last: a short screen shows a correct prefix. Against a real engine, 31.6% of the samples of a
    /// fast drag showed the first kind of picture and 0.0% the second, at no extra bytes.
    @Test("rows are written from the last to the first")
    func rowsGoBottomUp() {
        var renderer = SurfaceANSIRenderer()
        let everything = text(renderer.render(plainFrame(width: wide, height: 6), clearingFirst: true))
        #expect(rowAddresses(everything) == [6, 5, 4, 3, 2, 1], "a full repaint: \(rowAddresses(everything))")

        // A diff keeps the same direction among the rows it does write.
        let base = plainFrame(width: wide, height: 6)
        var diffing = SurfaceANSIRenderer()
        _ = diffing.render(base, clearingFirst: true)
        var edited = touching(base, row: 1)
        edited = touching(edited, row: 4)
        let diff = text(diffing.render(edited))
        #expect(rowAddresses(diff) == [5, 2], "a diff: \(rowAddresses(diff))")
    }

    /// The erase goes before the rows.
    ///
    /// It addresses row `height + 1`. A screen with only `height` rows clamps that onto its last
    /// line, and `0J` then empties a line that belongs to this very frame. Written after the rows,
    /// as it used to be, the erase had the last word and a full-screen program showed a band under
    /// its last line; written before them, whatever this paint writes lands on top of it.
    @Test("the erase comes before the rows it could clobber")
    func eraseComesFirst() {
        let frame = plainFrame(width: wide, height: 4)
        let output = repaint(touching(frame, row: 3), into: 10, after: frame)
        let eraseAt = offset(of: "\(esc)5;1H", in: output)
        let rowAt = offset(of: "\(esc)4;1H", in: output)
        #expect(eraseAt != nil && rowAt != nil, "no erase or no row in \(output.debugDescription)")
        if let eraseAt, let rowAt {
            #expect(eraseAt < rowAt, "the erase (\(eraseAt)) must precede the row it can hit (\(rowAt))")
        }
        if let zeroJ = offset(of: "\(esc)0J", in: output), let rowAt {
            #expect(zeroJ < rowAt, "0J must precede the row too")
        } else {
            Issue.record("no 0J in \(output.debugDescription)")
        }
    }

    /// Doing the erase first must not turn every such paint into a full one.
    ///
    /// Rewriting every row whenever there is something to erase was tried against a real engine:
    /// it showed nothing the diff did not (band 0.5-1.3%, torn 0.0% both ways), and cost 24.8 KB
    /// per paint where a one-cell change costs 3.7 KB, for as long as a pane stays taller than its
    /// frame — which is the whole time in the #188 layout.
    @Test("a diff stays a diff when there is something to erase")
    func diffStaysSmall() {
        let frame = plainFrame(width: wide, height: 6)
        let output = repaint(touching(frame, row: 2), into: 9, after: frame)
        // Row 7 is the erase (the frame has 6 rows), row 3 the one changed row; nothing else.
        let written = rowAddresses(output)
        #expect(written == [7, 3], "the erase and the one changed row, nothing else: \(written)")
    }

    // MARK: Colour

    /// The erase continues the colour the frame is drawn on.
    ///
    /// `0J` fills with the current background (xterm's BCE). Between the daemon's frame and the
    /// engine adopting its size, the rows under a full-screen program are rows nothing has written
    /// yet; left in the terminal's default they read as a band, filled in the program's colour they
    /// read as the program. Against a real engine, with a program on one background: 18.8% of the
    /// samples of a drag showed a band without this, 0.4-1.3% with it.
    @Test("the erase is made in the colour most of the frame is drawn on")
    func eraseTakesTheFramesColour() {
        let frame = plainFrame(width: wide, height: 4, background: 0x0211_2233)
        let output = repaint(frame, into: 10)
        #expect(
            output.contains("\(esc)5;1H\(esc)48;2;17;34;51m\(esc)0J\(esc)0m"),
            "erase not in the frame's colour: \(output.debugDescription)"
        )
    }

    /// A shell is drawn on the terminal's default, so there is nothing to set.
    ///
    /// **A guard, not a discriminator**: it passes without the colour logic too, and says that a
    /// frame which never set a background still erases the way it always did.
    @Test("a frame on the terminal's own background is erased without a colour")
    func defaultFramesEraseBare() {
        let output = repaint(plainFrame(width: wide, height: 4), into: 10)
        #expect(
            output.contains("\(esc)5;1H\(esc)0J"),
            "the erase should be a bare 0J: \(output.debugDescription)"
        )
        #expect(!output.contains("\(esc)49m"), "the default background was spelled out")
    }

    /// The *dominant* colour, not the last row's: a status bar on the bottom line (htop, tmux,
    /// mc) would otherwise be pulled down over the whole gap.
    @Test("a status bar on the last line does not choose the colour")
    func statusBarDoesNotChoose() {
        let frame = plainFrame(
            width: wide, height: 6, background: 0x0211_2233, rowBackgrounds: [5: 0x02AA_0000]
        )
        let output = repaint(frame, into: 12)
        #expect(output.contains("\(esc)48;2;17;34;51m\(esc)0J"), "the body colour was not used")
        #expect(!output.contains("\(esc)48;2;170;0;0m\(esc)0J"), "the status bar's colour was used")
    }

    /// Reverse video shows its *foreground*, and a wide glyph's second half has no colour of its
    /// own. Counting either as a background would let them outvote the screen they sit on.
    @Test("reversed cells and wide-character halves are not counted")
    func someCellsDoNotVote() {
        // 5 of 8 columns reversed on the odd colour: it would win if they were counted.
        var reversed = plainFrame(width: wide, height: 4, background: 0x0211_2233)
        var cells = reversed.flatCells
        for index in cells.indices where index % Int(wide) < 5 {
            cells[index].background = 0x02AA_0000
            cells[index].modifier = CellModifier.reversed
        }
        reversed = FrameData(
            cells: cells, width: wide, height: 4, cursor: nil, hyperlinks: [], graphics: Data()
        )
        let first = repaint(reversed, into: 10)
        #expect(first.contains("\(esc)48;2;17;34;51m\(esc)0J"), "reversed cells voted: \(first.debugDescription)")

        var halves = plainFrame(width: wide, height: 4, background: 0x0211_2233)
        cells = halves.flatCells
        for index in cells.indices where index % Int(wide) < 5 {
            cells[index].background = 0x02AA_0000
            cells[index].skip = true
        }
        halves = FrameData(
            cells: cells, width: wide, height: 4, cursor: nil, hyperlinks: [], graphics: Data()
        )
        let second = repaint(halves, into: 10)
        #expect(second.contains("\(esc)48;2;17;34;51m\(esc)0J"), "wide halves voted: \(second.debugDescription)")
    }

    /// When nothing outnumbers the rest the answer must not depend on dictionary order.
    @Test("a tie goes to the terminal's default, then to the lower colour")
    func tiesAreDeterministic() {
        func split(_ left: UInt32, _ right: UInt32) -> FrameData {
            let base = plainFrame(width: wide, height: 4)
            var cells = base.flatCells
            for index in cells.indices {
                cells[index].background = index % Int(wide) < 4 ? left : right
            }
            return FrameData(
                cells: cells, width: wide, height: 4, cursor: nil, hyperlinks: [], graphics: Data()
            )
        }
        // Default against a colour: the default wins, so the erase is bare.
        let withDefault = repaint(split(0, 0x0211_2233), into: 10)
        #expect(withDefault.contains("\(esc)5;1H\(esc)0J"), "a tie with the default set a colour")
        // Two colours: the lower raw value wins, in either arrangement.
        for (left, right) in [(0x0211_2233, 0x0222_3344), (0x0222_3344, 0x0211_2233)] as [(UInt32, UInt32)] {
            let output = repaint(split(left, right), into: 10)
            #expect(
                output.contains("\(esc)48;2;17;34;51m\(esc)0J"),
                "tie between \(String(left, radix: 16)) and \(String(right, radix: 16)): \(output.debugDescription)"
            )
        }
    }

    /// How a raw colour becomes the parameter of a background SGR, and which one is "nothing to set".
    @Test("the background parameter of a raw colour")
    func backgroundParameters() {
        #expect(StyleCode.backgroundParameter(0) == nil, "the default needs no SGR")
        #expect(StyleCode.backgroundParameter(0x0000_0011) == nil, "past the table falls back to default")
        #expect(StyleCode.backgroundParameter(1) == "40")
        #expect(StyleCode.backgroundParameter(8) == "47")
        #expect(StyleCode.backgroundParameter(9) == "100")
        #expect(StyleCode.backgroundParameter(16) == "107")
        #expect(StyleCode.backgroundParameter(0x0100_00AB) == "48;5;171")
        #expect(StyleCode.backgroundParameter(0x02FF_8040) == "48;2;255;128;64")
    }
}
