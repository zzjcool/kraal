// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The pane's cells drawn over the engine, but only while that helps.
//
// Why only during a drag: the engine's picture is better than ours in every way except one.
// A drag resizes the engine's layer continuously, and the compositor stretches the previous
// frame until the engine repaints at the new size — so each step of a drag shows glyphs at a
// slightly wrong scale, which is the jitter users report. Drawing the same cells at paint
// time has no window between "the size changed" and "the pixels are right".
//
// Outside a drag the engine keeps the picture: selection, links, sixel, IME preedit and search
// highlights are all things this renderer cannot draw yet, and none of them jitter.

import KraalProtocol
import SwiftUI

public struct PaneCellOverlay: View {
    private let store: AppStore
    private let frame: FrameData
    private let inner: SurfaceRect
    private let cellSize: CGSize
    private let palette: AnsiPalette

    public init(
        store: AppStore,
        frame: FrameData,
        inner: SurfaceRect,
        cellSize: CGSize,
        palette: AnsiPalette
    ) {
        self.store = store
        self.frame = frame
        self.inner = inner
        self.cellSize = cellSize
        self.palette = palette
    }

    public var body: some View {
        if CellPainterPolicy.shouldPaint(dragging: store.isDraggingSplit) {
            PaneCellCanvas(frame: frame, inner: inner, cellSize: cellSize, palette: palette)
                .allowsHitTesting(false)
        }
    }
}
