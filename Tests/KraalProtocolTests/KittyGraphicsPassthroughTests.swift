// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Kitty graphics: the daemon pre-encodes the bytes, the renderer has to pass them
// through (issue #37).
//
// The wire carries two different things and they are easy to confuse:
//
//   * `FrameData.graphics` — a ready-to-write kitty graphics byte stream. The
//     daemon produced it; a client only has to put it in the output at the right
//     place. `PaneTerminal` handed the renderer `Data()` here, so a pane with an
//     image drew nothing.
//   * `PaneSurfaceFrame.graphics` (`SurfaceGraphicsScene`) — assets plus
//     placements, the composited scene. Encoding *that* into kitty bytes is a
//     separate job (image cache, placement, z-order) and is not what this file
//     tests.
//
// The insertion point is what makes this correct rather than merely "writes the
// bytes": the stream is wrapped in DECSC/DECRC and placed at the *end* of the
// synchronized-output block, exactly like upstream `frame_output.rs`
// (`write_composed_frame`). Writing it outside the sync pair would show a
// half-painted screen; writing it before the cells would let the cell repaint
// cover the image.

import Foundation
import Testing

@testable import KraalProtocol

@Suite("Kitty graphics passthrough")
struct KittyGraphicsPassthroughTests {
    private func frame(
        _ text: String = "hi",
        graphics: Data = Data()
    ) -> FrameData {
        let width: UInt16 = 10
        func cell(_ symbol: String) -> CellData {
            CellData(symbol: symbol, foreground: 0, background: 0,
                     modifier: 0, skip: false, hyperlink: nil)
        }
        var cells: [CellData] = text.compactMap { cell(String($0)) }
        cells = Array(cells.prefix(Int(width) * 2))
        while cells.count < Int(width) * 2 { cells.append(cell(" ")) }
        return FrameData(
            cells: cells,
            width: width,
            height: 2,
            cursor: nil,
            hyperlinks: [],
            graphics: graphics
        )
    }

    /// A minimal transmit-and-display sequence: 1x1 RGBA, image id 7.
    private var graphicsBytes: Data {
        Data("\u{1B}_Ga=T,f=32,s=1,v=1,i=7;/wAA/w==\u{1B}\\".utf8)
    }

    @Test("a frame with graphics writes them into the output")
    func graphicsAreWritten() {
        var renderer = SurfaceANSIRenderer()
        let output = renderer.render(frame(graphics: graphicsBytes))
        #expect(output.range(of: graphicsBytes) != nil,
                "the kitty bytes never reached the terminal, so a pane with an image draws nothing")
    }

    @Test("a frame without graphics writes no kitty sequence")
    func noGraphicsWritesNothing() {
        // The complement: "always write something" would pass the test above and
        // put stray escapes into every frame.
        var renderer = SurfaceANSIRenderer()
        let output = renderer.render(frame())
        #expect(output.range(of: Data("\u{1B}_G".utf8)) == nil,
                "a frame with no graphics emitted a kitty sequence")
    }

    @Test("graphics go inside the synchronized-output block")
    func graphicsAreInsideSyncBlock() {
        // Outside the pair, the terminal paints the cells and the image in two
        // separate flushes — visible as a flicker on every frame that carries one.
        var renderer = SurfaceANSIRenderer()
        let output = renderer.render(frame(graphics: graphicsBytes))
        let syncOpen = Data("\u{1B}[?2026h".utf8)
        let syncClose = Data("\u{1B}[?2026l".utf8)

        let open = output.range(of: syncOpen)
        let bytes = output.range(of: graphicsBytes)
        let close = output.range(of: syncClose)
        #expect(open != nil && bytes != nil && close != nil, "missing one of the three markers")
        if let open, let bytes, let close {
            #expect(open.lowerBound < bytes.lowerBound,
                    "graphics were written before the sync block opened")
            #expect(bytes.lowerBound < close.lowerBound,
                    "graphics were written after the sync block closed")
        }
    }

    @Test("graphics are wrapped in a cursor save and restore")
    func graphicsPreserveCursor() {
        // Upstream writes `ESC 7 … ESC 8` around them (`frame_output.rs`). Without
        // it the graphics sequence leaves the cursor wherever it stopped, and the
        // next frame's CUP starts from the wrong place.
        var renderer = SurfaceANSIRenderer()
        let output = renderer.render(frame(graphics: graphicsBytes))
        let bytes = output.range(of: graphicsBytes)
        #expect(bytes != nil)
        guard let bytes else { return }
        let before = output[output.startIndex ..< bytes.lowerBound]
        #expect(before.suffix(2) == Data("\u{1B}7".utf8),
                "no DECSC immediately before the graphics bytes")
        let after = output[bytes.upperBound...]
        #expect(after.prefix(2) == Data("\u{1B}8".utf8),
                "no DECRC immediately after the graphics bytes")
    }

    @Test("a frame that keeps the same graphics does not repeat them every repaint")
    func unchangedGraphicsAreNotRepeated() {
        // A diff frame that rewrites unchanged bytes would resend a whole image on
        // every keystroke. Upstream replaces the previous stream rather than
        // accumulating it, and so does this: the same `graphics` on the next frame
        // produces no second copy.
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(graphics: graphicsBytes))
        // Same cell content, same graphics: a diff with nothing to do.
        let second = renderer.render(frame(graphics: graphicsBytes))
        #expect(second.range(of: graphicsBytes) == nil,
                "the image bytes were re-sent on a frame that changed nothing")
    }

    @Test("new graphics on a later frame are written")
    func changedGraphicsAreWritten() {
        // The complement to the test above: suppression must key on the bytes
        // changing, not on "graphics were already sent once".
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(graphics: graphicsBytes))
        let other = Data("\u{1B}_Ga=T,f=32,s=1,v=1,i=8;/wAA/w==\u{1B}\\".utf8)
        let second = renderer.render(frame(graphics: other))
        #expect(second.range(of: other) != nil, "a changed image was not written")
    }

    @Test("reset forgets the previous graphics")
    func resetForgetsGraphics() {
        var renderer = SurfaceANSIRenderer()
        _ = renderer.render(frame(graphics: graphicsBytes))
        renderer.reset()
        let afterReset = renderer.render(frame(graphics: graphicsBytes))
        #expect(afterReset.range(of: graphicsBytes) != nil,
                "after reset the terminal has no image, so the bytes must be written again")
    }
}
