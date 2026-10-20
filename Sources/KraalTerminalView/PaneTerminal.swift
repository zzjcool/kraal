// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Pane rendering through Ghostty.
//
// The daemon sends the authoritative screen as a `PaneSurface` cell grid. We
// re-encode each pane's cells as VT sequences (`SurfaceANSIRenderer`) and feed
// them to an `InMemoryTerminalSession`, which is Ghostty's headless backend. That
// gives the pane real Ghostty rendering — correct wide glyphs, emoji, box
// drawing, colors, selection, and scrollback — while keeping us on one connection
// with no `terminal attach` takeover races.
//
// Input goes the other way: Ghostty encodes keys and mouse into bytes, and those
// bytes are handed back as `TextCommit`/`Paste` events on the same connection.
// Alt-screen TUIs that want raw bytes are handled by the paste path, which is
// what the daemon's semantic input codec expects.

import Foundation
import GhosttyTerminal
import KraalProtocol
import KraalUI
import SwiftUI

/// One pane's terminal, keyed by pane id.
@MainActor
public final class PaneTerminalModel {
    public let paneId: String
    public let session: InMemoryTerminalSession
    /// Ghostty's window padding would shrink the usable cell area inside the
    /// view, so its grid would come out narrower than the pane frame we hand it:
    /// 450 pt / 8.5 pt = 52 columns of text, but padding eats a few, and the
    /// renderer then reflows every row we send. The pane is already inset by the
    /// daemon's own border rects, so the padding must be zero here.
    public let state = TerminalViewState(
        terminalConfiguration: TerminalConfiguration { builder in
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
        }
    )
    private var renderer = SurfaceANSIRenderer()
    private var lastRevision: UInt64 = 0
    /// Set when a frame was rejected because the terminal's grid did not match
    /// it. The stale rows are still in the terminal's scrollback, and an
    /// incremental repaint only touches rows that changed — so the skew survives
    /// every later update until the screen is explicitly cleared.
    private var needsCleanRepaint = false
    /// Reports the renderer's measured cell size, in device pixels.
    public var onCellMetrics: ((CGSize) -> Void)?

    init(paneId: String, size: ClientSurfaceSize, onInput: @escaping @Sendable (Data) -> Void) {
        self.paneId = paneId
        session = InMemoryTerminalSession(
            write: { data in
                // Ghostty -> daemon: key bytes, paste payloads, replies to queries.
                onInput(data)
            },
            resize: { _ in
                // The daemon owns the grid size: it renders the surface at the
                // geometry we asked for, so a resize here must not drive a
                // second, conflicting notion of the size.
            }
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        _ = size
    }

    /// Feeds a pane's cells to the terminal, skipping redundant revisions.
    ///
    /// The pane geometry is read back out of `surface` rather than trusted from a
    /// separately captured value: SwiftUI can hand this view a surface and a
    /// geometry that came from different revisions, and slicing the new surface
    /// with a rect measured on the old one produces a frame of the wrong width.
    func apply(surface: PaneSurfaceFrame) {
        guard let geometry = surface.panes.first(where: { $0.paneId == paneId }) else {
            return
        }
        guard geometry.contentRevision != lastRevision else { return }
        lastRevision = geometry.contentRevision

        let frame = paneFrame(from: surface, geometry: geometry)
        reportCellMetrics()

        // If the terminal's grid disagrees with the frame, writing this frame
        // would wrap every row and push the overflow into scrollback, leaving a
        // permanently skewed screen. Repaint from a clean slate in that case and
        // let the next apply land on a grid that matches.
        if let grid = state.surfaceSize,
           grid.columns != frame.width || grid.rows != frame.height {
            let all = surface.panes.map {
                "\($0.paneId)=\($0.innerRect.width)x\($0.innerRect.height)"
            }
            kraalLog("grid mismatch: pane=\(paneId) ghostty=\(grid.columns)x\(grid.rows) "
                + "frame=\(frame.width)x\(frame.height) "
                + "surface=\(surface.frame.width)x\(surface.frame.height) panes=[\(all.joined(separator: " "))]")
            needsCleanRepaint = true
            lastRevision = 0
            return
        }

        if needsCleanRepaint {
            // The grid is trustworthy again: wipe the screen and scrollback so
            // the rows written at the wrong width cannot reappear, then paint the
            // whole frame instead of a delta.
            needsCleanRepaint = false
            renderer.reset()
            session.receive(Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8))
        }

        session.receive(renderer.render(frame))
    }

    /// Reports the renderer's measured cell size, in device pixels.
    ///
    /// Called before the grid check in `apply`, not after it: the check bails out
    /// while the grid is wrong, and if reporting lived past that bail-out the
    /// size used for layout could never be corrected — a one-way trap where the
    /// grid stays wrong because it was never measured, and never measured
    /// because it was wrong.
    private func reportCellMetrics() {
        guard let grid = state.surfaceSize,
              grid.cellWidthPixels > 0,
              grid.cellHeightPixels > 0 else { return }
        onCellMetrics?(CGSize(
            width: CGFloat(grid.cellWidthPixels),
            height: CGFloat(grid.cellHeightPixels)
        ))
    }

    func reset() {
        renderer.reset()
        lastRevision = 0
    }

    /// Crops the composited tab surface down to this pane's content area.
    ///
    /// The terminal only ever knows about its own pane, so the surrounding
    /// borders and sibling panes must not be fed to it — otherwise a patch in a
    /// neighbouring pane would repaint ours.
    private func paneFrame(
        from surface: PaneSurfaceFrame,
        geometry: PaneSurfacePane
    ) -> FrameData {
        let area = geometry.innerRect
        let width = Int(area.width)
        let height = Int(area.height)
        var cells: [CellData] = []
        cells.reserveCapacity(width * height)

        for row in 0 ..< height {
            for column in 0 ..< width {
                let sourceColumn = Int(area.originX) + column
                let sourceRow = Int(area.originY) + row
                if let cell = surface.frame[sourceColumn, sourceRow] {
                    cells.append(cell)
                } else {
                    cells.append(.blank)
                }
            }
        }

        var cursor: CursorState?
        if let surfaceCursor = surface.frame.cursor,
           Int(surfaceCursor.column) >= Int(area.originX),
           Int(surfaceCursor.column) < Int(area.originX) + width,
           Int(surfaceCursor.row) >= Int(area.originY),
           Int(surfaceCursor.row) < Int(area.originY) + height {
            cursor = CursorState(
                column: surfaceCursor.column - area.originX,
                row: surfaceCursor.row - area.originY,
                visible: surfaceCursor.visible,
                shape: surfaceCursor.shape
            )
        }

        return FrameData(
            cells: cells,
            width: UInt16(width),
            height: UInt16(height),
            cursor: cursor,
            hyperlinks: surface.frame.hyperlinks,
            graphics: Data()
        )
    }
}

/// Hosts the pane models for one window and keeps them in sync with the store.
@MainActor
@Observable
public final class PaneTerminalPool {
    private var models: [String: PaneTerminalModel] = [:]
    private let onInput: @Sendable (String, Data) -> Void

    public init(onInput: @escaping @Sendable (String, Data) -> Void) {
        self.onInput = onInput
    }

    public func model(
        for paneId: String,
        size: ClientSurfaceSize
    ) -> PaneTerminalModel {
        if let existing = models[paneId] {
            return existing
        }
        let model = PaneTerminalModel(paneId: paneId, size: size) { [weak self] data in
            self?.onInput(paneId, data)
        }
        models[paneId] = model
        return model
    }

    /// Drops terminals for panes that no longer exist, releasing their surfaces.
    public func prune(keeping paneIds: Set<String>) {
        for key in models.keys where !paneIds.contains(key) {
            models.removeValue(forKey: key)
        }
    }

    public func reset() {
        for model in models.values {
            model.reset()
        }
    }
}

/// The SwiftUI pane view: Ghostty's surface, plus click-to-focus.
public struct GhosttyPaneView: View {
    let model: PaneTerminalModel
    let surface: PaneSurfaceFrame
    let geometry: PaneSurfacePane
    let onFocus: () -> Void

    public init(
        model: PaneTerminalModel,
        surface: PaneSurfaceFrame,
        geometry: PaneSurfacePane,
        onFocus: @escaping () -> Void
    ) {
        self.model = model
        self.surface = surface
        self.geometry = geometry
        self.onFocus = onFocus
    }

    public var body: some View {
        TerminalSurfaceView(context: model.state)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .task(id: Int(proxy.size.width * 10) &+ Int(proxy.size.height * 10)) {
                            kraalLog("pane view: \(geometry.paneId) "
                                + "size=\(Int(proxy.size.width))x\(Int(proxy.size.height))pt "
                                + "cells=\(geometry.innerRect.width)x\(geometry.innerRect.height)")
                        }
                }
            }
            .onAppear {
                model.apply(surface: surface)
            }
            .onChange(of: surface.surfaceRevision) { _, _ in
                model.apply(surface: surface)
            }
            // Give the focused pane the keyboard. `requestFocus` hops the runloop
            // and calls `acquireProgrammaticFocus` once the view is in a window,
            // which makes Ghostty's surface the first responder — the only state
            // in which its key encoder runs. Relying on the click instead is
            // fragile: SwiftUI re-hosts the view on every surface update, which
            // drops first responder status mid-session.
            .onAppear {
                if geometry.focused {
                    model.state.requestFocus()
                }
                onFocus()
            }
    }
}
