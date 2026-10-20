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
    /// The pane grid the last rendered frame was composed for.
    private var frameGrid: FrameData?
    /// A frame that arrived before Ghostty's surface existed.
    private var pendingFrame: FrameData?

    /// Clears the visible screen and the scrollback, then homes the cursor.
    ///
    /// Both are needed: a repaint at the wrong width leaves rows in scrollback
    /// that a later incremental render never revisits.
    private let clearScreenSequence = "\u{1B}[2J\u{1B}[3J\u{1B}[H"
    /// Set when a frame was rejected because the terminal's grid did not match
    /// it. The stale rows are still in the terminal's scrollback, and an
    /// incremental repaint only touches rows that changed — so the skew survives
    /// every later update until the screen is explicitly cleared.
    private var needsCleanRepaint = false
    /// Reports the renderer's measured cell size, in device pixels.
    public var onCellMetrics: ((CGSize) -> Void)?

    init(paneId: String, onInput: @escaping @Sendable (Data) -> Void) {
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
        let frame = paneFrame(from: surface, geometry: geometry)
        // A pane's content revision only moves when its *content* changes, so the
        // same revision is normal for a pane that merely got a new grid: going
        // from a split to full width changes every row's width but not one cell
        // of text. Skipping those frames on the revision alone left the pane blank
        // until it printed something. The grid is what decides whether the frame
        // already on screen is still valid.
        guard SurfaceGeometry.needsRepaint(
            contentRevisionChanged: geometry.contentRevision != lastRevision,
            previousGrid: frameGrid.map { (width: Int($0.width), height: Int($0.height)) },
            currentGrid: (width: Int(frame.width), height: Int(frame.height))
        ) else { return }
        if SurfaceGeometry.deltaStreamRestarted(
            previousRevision: lastRevision,
            incomingRevision: geometry.contentRevision
        ) || frameGrid != frame {
            // Revisions going backwards means this pane's delta stream restarted:
            // the daemon began a fresh projection (a tab switch, a reconnect, a
            // new boot) and renumbered from scratch. The renderer still holds the
            // old stream's state, so a delta would paint onto a baseline that no
            // longer exists. Wipe and take this frame whole.
            renderer.reset()
            session.receive(Data(clearScreenSequence.utf8))
            needsCleanRepaint = false
        }
        lastRevision = geometry.contentRevision
        frameGrid = frame

        reportCellMetrics()

        // If the terminal's grid disagrees with the frame, writing this frame
        // would wrap every row and push the overflow into scrollback, leaving a
        // permanently skewed screen. Repaint from a clean slate in that case and
        // let the next apply land on a grid that matches.
        // No surface yet: the view has been mounted but Ghostty has not finished
        // attaching, so `surfaceSize` is nil and anything written is queued
        // without a grid to lay it out in. Remember the frame and paint it when
        // the surface reports a size; writing now both wastes the frame and
        // leaves the pane blank even though the terminal later becomes ready.
        guard let grid = state.surfaceSize else {
            pendingFrame = frame
            lastRevision = 0
            frameGrid = nil
            return
        }
        pendingFrame = nil

        if grid.columns != frame.width || grid.rows != frame.height {
            let all = surface.panes.map {
                "\($0.paneId)=\($0.innerRect.width)x\($0.innerRect.height)"
            }
            kraalLog("grid mismatch: pane=\(paneId) ghostty=\(grid.columns)x\(grid.rows) "
                + "frame=\(frame.width)x\(frame.height) "
                + "surface=\(surface.frame.width)x\(surface.frame.height) panes=[\(all.joined(separator: " "))]")
            needsCleanRepaint = true
            lastRevision = 0
            frameGrid = nil
            return
        }

        if needsCleanRepaint {
            // The grid is trustworthy again: wipe the screen and scrollback so
            // the rows written at the wrong width cannot reappear, then paint the
            // whole frame instead of a delta.
            needsCleanRepaint = false
            renderer.reset()
            session.receive(Data(clearScreenSequence.utf8))
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

    /// Paints a frame that arrived before the terminal was able to accept it.
    ///
    /// Called when the surface reports a grid: at that point the queued frame can
    /// finally be laid out. Without this the pane stays blank after a tab switch,
    /// because the only frame for that tab was dropped while the view was still
    /// being attached.
    func flushPendingFrame() {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        lastRevision = 0
        frameGrid = nil
        renderer.reset()
        session.receive(Data(clearScreenSequence.utf8))
        session.receive(renderer.render(frame))
        lastRevision = 0
        frameGrid = frame
    }

    /// Prepares for a terminal view that has never painted anything.
    ///
    /// The renderer tracks what it already drew so later frames can be deltas.
    /// That state belongs to the *terminal*, not to this model: SwiftUI tears the
    /// view down when a tab switch changes the pane set, and the new view starts
    /// with an empty screen. Keeping the renderer's memory then makes the next
    /// apply emit only the rows that changed, which is nothing — the terminal
    /// holds the content but never repaints it, so the pane looks blank until
    /// something writes again. Dropping the memory forces the next apply to send
    /// the whole frame.
    func prepareForNewTerminalView() {
        renderer.reset()
        lastRevision = 0
        frameGrid = nil
        pendingFrame = nil
        needsCleanRepaint = false
    }

    func reset() {
        renderer.reset()
        lastRevision = 0
        frameGrid = nil
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

    public func model(for paneId: String) -> PaneTerminalModel {
        if let existing = models[paneId] {
            return existing
        }
        let model = PaneTerminalModel(paneId: paneId) { [weak self] data in
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
                // A freshly mounted terminal view has an empty screen, so the
                // model's memory of what it already drew is a lie. Forget it and
                // let this apply paint the whole frame.
                model.prepareForNewTerminalView()
                model.apply(surface: surface)
            }
            // Ghostty attaches its surface asynchronously, so an apply that ran in
            // `onAppear` found no grid and parked its frame. The grid appearing is
            // the signal that the terminal can finally accept it.
            .onChange(of: model.state.surfaceSize) { old, new in
                if old == nil, new != nil {
                    model.flushPendingFrame()
                }
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
