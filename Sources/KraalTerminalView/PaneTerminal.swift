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

extension SurfaceGraphicsScene {
    /// Keeps only what belongs to the popup `terminalId`.
    ///
    /// Placements are dropped along with their assets: a placement whose asset was
    /// removed would reference an image the terminal never received, and kitty
    /// answers that with an error rather than a no-op.
    ///
    /// Pane placements address cells inside the pane's grid, not the popup's, so
    /// keeping them would draw a pane's picture over the popup (upstream splits on
    /// exactly this: `client_placement_origin` uses `popup_origin` for
    /// popup-sourced placements, `kitty_graphics/surface.rs:938-958`).
    func filtered(toPopup terminalId: String) -> SurfaceGraphicsScene {
        let kept = placements.filter { placement in
            if case let .terminal(target: .popup(id), _) = placement.asset.source {
                return id == terminalId
            }
            return false
        }
        let keys = Set(kept.map(\.asset))
        return SurfaceGraphicsScene(
            assets: assets.filter { keys.contains($0.key) },
            placements: kept,
            retainedAssets: retainedAssets.filter { keys.contains($0) }
        )
    }
}

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
    /// Turns the daemon's graphics scene into kitty bytes (issue #105, parent #37).
    ///
    /// Must be reset together with `renderer` — see `resetSurfaces()`.
    private var graphicsEncoder = GraphicsEncoder()
    /// The machine this pane belongs to, used only to scope graphics image ids.
    ///
    /// Image ids are a hash of `scope + asset key`, so two machines that both name
    /// a pane `w1:p1` would otherwise share an id namespace and one pane's
    /// `d=I` would delete the other's picture. Pane ids are scoped to one daemon —
    /// upstream says so outright (`docs/next/website/.../connecting-machines.mdx:118`).
    private let machine: String
    /// Whether this model draws a popup rather than a pane.
    ///
    /// It changes two things, both about id spaces: which graphics targets this
    /// terminal accepts, and the scope its image ids are hashed from. The pool keys
    /// popup models by the popup's `terminalId`, which can coincide with a pane id,
    /// so the kind cannot be inferred from the id alone.
    private let isPopup: Bool
    private var lastRevision: UInt64 = 0
    /// The pane grid the last rendered frame was composed for.
    private var frameGrid: FrameData?
    /// The projection the renderer's baseline belongs to.
    ///
    /// Nothing else the pane compares can see a workspace or machine switch.
    /// `contentRevision` keeps climbing across the whole daemon session and is
    /// not reset by a re-projection, and the grid is *identical* by design — two
    /// machines name their first workspace's first pane the same way and split it
    /// the same way. So a switch can arrive with every number unchanged, get
    /// judged "nothing to do", and leave the previous machine's picture on
    /// screen. `bootId` is stamped at daemon boot and never shared, which is the
    /// one field that separates them.
    private var lastProjection: SurfaceGeometry.ProjectionIdentity?
    /// A frame that arrived before Ghostty's surface existed, or before its grid
    /// caught up with the frame's size.
    private var pendingFrame: FrameData?
    /// The retry chain that keeps trying to paint `pendingFrame`.
    private var pendingRetryTask: Task<Void, Never>?

    /// The frame parked because the terminal had no grid yet, if any.
    ///
    /// Exposed read-only so tests can see what `apply(surface:)` produced without a
    /// Ghostty surface: with no grid, the frame is parked rather than painted, and
    /// parking is the observable seam. It is also the *real* path — `apply` is what
    /// the view calls — so a test on it cannot pass while the wiring is cut.
    var parkedFrame: FrameData? { pendingFrame }

    /// How many times a screen reset has been applied. Test-observable because the
    /// reset and the image bytes race inside one `apply` call, and `parkedFrame`
    /// alone cannot say whether the reset ran.
    private(set) var screenResetCount = 0

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
    /// Paints a popup's own grid.
    ///
    /// A popup carries a complete `FrameData` of its own — it is a separate terminal
    /// on the daemon, not a crop of the surface — so this bypasses the whole
    /// crop/diff/geometry path in `apply(surface:)` and paints the frame directly.
    ///
    /// The diffing is skipped on purpose. A popup is short-lived and small, its
    /// revision numbering is its own (not the surface's), and diffing it against the
    /// previous popup's baseline across an open/close cycle would paint one popup's
    /// cells onto another's. Repainting whole costs a few hundred cells per frame.
    ///
    /// - Parameter revision: the daemon's `contentRevision` for this popup, used only
    ///   to skip frames that changed nothing.
    public func applyPopup(frame: FrameData, revision: UInt64, scene: SurfaceGraphicsScene) {
        guard revision != lastRevision || frameGrid == nil else { return }
        lastRevision = revision
        var frame = frame
        // Only the popup's own images belong here. The scene is the whole tab's —
        // pane placements address cells inside the pane's grid, and this terminal is
        // the popup, so drawing them would put a pane's picture over the popup
        // (upstream does the same split: `client_placement_origin` picks
        // `popup_origin` for popup-sourced placements and `main_origin` for
        // everything else, `kitty_graphics/surface.rs:938-958`).
        //
        // Reset first, for the same reason as `apply(surface:)`: the encoder is
        // stateful, so encoding before the reset would produce the pre-reset
        // (possibly zero) bytes for a frame that just cleared the screen.
        resetSurfaces()
        frame.graphics = graphicsEncoder.encode(
            scene: scene.filtered(toPopup: paneId),
            scope: graphicsScope
        )
        frameGrid = frame

        // Same reason as `apply(surface:)`: the terminal attaches asynchronously, and
        // a frame that arrives before the grid exists has nowhere to go.
        guard let grid = state.surfaceSize, grid.columns > 0, grid.rows > 0 else {
            pendingFrame = frame
            return
        }
        pendingFrame = nil
        session.receive(Data(clearScreenSequence.utf8))
        let painted = renderer.render(frame)
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: scene.assets.count, placements: scene.placements.count)
        session.receive(painted)
    }

    /// One line per frame that carried graphics, recording **both** the encoder's
    /// output and what the renderer actually produced.
    ///
    /// Both numbers, because they answer different questions and only the pair is
    /// evidence. `encoded` proves the client turned the daemon's scene into kitty
    /// bytes; `kitty` proves the renderer wrote sequences out. An encoder whose
    /// output the renderer drops looks identical to a working chain if only the
    /// first number is logged — `SurfaceANSIRenderer` skips graphics it believes are
    /// unchanged (`lastGraphics`), so "encoded > 0, kitty == 0" is a real state
    /// (measured while injecting that bug for the GUI gate).
    ///
    /// Narrow on purpose: a line per frame would make "an image arrived"
    /// unfalsifiable.
    private func logGraphics(encoded: Data, painted: Data, assets: Int, placements: Int) {
        guard !encoded.isEmpty || !painted.isEmpty else { return }
        kraalLog("graphics: pane=\(paneId) scope=\(graphicsScope) "
            + "assets=\(assets) placements=\(placements) "
            + "encoded=\(encoded.count) painted=\(painted.count) "
            + "kitty=\(Self.kittySequenceCount(painted))")
    }

    /// How many kitty graphics sequences an output buffer contains.
    static func kittySequenceCount(_ bytes: Data) -> Int {
        let needle = Data("\u{1B}_G".utf8)
        var count = 0
        var searchStart = bytes.startIndex
        while searchStart < bytes.endIndex,
              let found = bytes.range(of: needle, in: searchStart ..< bytes.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// Shifts a scene's placements into this pane's coordinate space, dropping the
    /// ones that fall outside it.
    ///
    /// Placements are surface-absolute (upstream `client_host_piece` adds the pane
    /// origin to get them), and this terminal is only the pane. A placement whose
    /// cells are entirely outside the pane is dropped rather than clamped: kitty
    /// would draw it over the neighbouring pane's cells, and this terminal has no
    /// way to clip it.
    private func sceneInPaneSpace(
        _ scene: SurfaceGraphicsScene,
        origin: (x: Int, y: Int),
        paneSize: (width: Int, height: Int)
    ) -> SurfaceGraphicsScene {
        guard origin.x != 0 || origin.y != 0 else { return scene }
        let width = paneSize.width
        let height = paneSize.height
        var shifted = scene
        shifted.placements = scene.placements.compactMap { placement in
            // Compare in signed space: the placement's cells are unsigned on the
            // wire, so a origin shift can go negative only if the data is wrong.
            let column = Int(placement.cellX) - origin.x
            let row = Int(placement.cellY) - origin.y
            guard column >= 0, row >= 0 else { return nil }
            // A pane with no measured size yet cannot answer "is this inside", so
            // keep everything and let the next frame decide.
            if width > 0, column >= width { return nil }
            if height > 0, row >= height { return nil }
            var moved = placement
            moved.cellX = UInt16(column)
            moved.cellY = UInt16(row)
            return moved
        }
        return shifted
    }

    /// The id namespace for this pane's images.
    ///
    /// `machine + paneId`, not `paneId`: two machines both name a pane `w1:p1`, and
    /// image ids are a hash of this string. Sharing it would put both daemons'
    /// images in one namespace, where one pane's `d=I` deletes the other's picture.
    private var graphicsScope: String {
        let base = machine.isEmpty ? paneId : "\(machine)/\(paneId)"
        // A popup and a pane never draw into the same terminal, but the image ids
        // they hand to Ghostty are per *terminal*, and a popup model is keyed by the
        // same string a pane can be. Tagging the kind keeps the two id spaces apart
        // even when the ids coincide, so one's `d=I` cannot delete the other's image.
        return isPopup ? "popup/\(base)" : "pane/\(base)"
    }

    /// Reports the renderer's measured cell size, in device pixels.
    public var onCellMetrics: ((CGSize) -> Void)?

    init(
        paneId: String,
        machine: String = "",
        isPopup: Bool = false,
        onInput: @escaping @Sendable (Data) -> Void
    ) {
        self.paneId = paneId
        self.machine = machine
        self.isPopup = isPopup
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
        // Decide whether this frame needs a screen reset **before** encoding it.
        //
        // The order matters and it is subtle: `paneFrame` encodes the graphics
        // scene, and `GraphicsEncoder` is stateful — a frame whose images did not
        // change encodes to *zero* bytes. If the reset ran after that encode, the
        // frame would be computed against the pre-reset cache (possibly empty
        // bytes), then `resetSurfaces()` would forget the images, and the `2J`
        // would erase them with nothing to put back. The picture would stay gone
        // until the next frame — which for a still program may never come.
        //
        // A grid change reaches this on every resize (dragging a window,
        // splitting), so this is not a rare path.
        let projection = SurfaceGeometry.ProjectionIdentity(
            bootId: surface.bootId,
            revision: surface.projectionRevision
        )
        let projectionChanged = SurfaceGeometry.projectionChanged(
            previous: lastProjection,
            current: projection
        )
        let resetNeeded = projectionChanged || SurfaceGeometry.needsScreenReset(
            deltaStreamRestarted: SurfaceGeometry.deltaStreamRestarted(
                previousRevision: lastRevision,
                incomingRevision: geometry.contentRevision
            ),
            previousGrid: frameGrid.map { (width: Int($0.width), height: Int($0.height)) },
            currentGrid: (width: Int(surface.frame.width), height: Int(surface.frame.height))
        )
        if resetNeeded {
            screenResetCount += 1
            resetSurfaces()
        }
        let frame = paneFrame(from: surface, geometry: geometry)
        // A different projection means the screen this renderer built its
        // baseline from is gone, whatever the numbers say. It has to be taken as
        // a whole frame, not diffed against cells that came from somewhere else.
        lastProjection = projection

        // A pane's content revision only moves when its *content* changes, so the
        // same revision is normal for a pane that merely got a new grid: going
        // from a split to full width changes every row's width but not one cell
        // of text. Skipping those frames on the revision alone left the pane blank
        // until it printed something. The grid is what decides whether the frame
        // already on screen is still valid.
        //
        // The projection is a third reason to repaint, and the one that covers a
        // workspace or machine switch: the same cells have to be re-taken whole
        // rather than diffed onto a baseline from another projection.
        guard projectionChanged || SurfaceGeometry.needsRepaint(
            contentRevisionChanged: geometry.contentRevision != lastRevision,
            previousGrid: frameGrid.map { (width: Int($0.width), height: Int($0.height)) },
            currentGrid: (width: Int(frame.width), height: Int(frame.height)),
            // Scrolling rewrites the whole viewport without moving the revision and
            // without changing the grid, so neither cheap reason above fires. The
            // cells are the only thing that says the screen changed — see
            // `needsRepaint`'s note on scrolling.
            cellsDiffer: SurfaceGeometry.cellsChanged(previous: frameGrid, current: frame),
            // An image can move or change without touching a cell: the cells it
            // covers are not part of the daemon's cell buffer. Comparing cells alone
            // dropped those frames, freezing the picture at its old position (#105).
            graphicsDiffer: frameGrid?.graphics != frame.graphics
        ) else { return }
        // Printed only when the cells alone decided a repaint — the revision and the
        // grid both said "nothing changed" and the frame's contents said otherwise.
        // That is exactly a scroll, and it is what the GUI case asserts on. Kept
        // this narrow on purpose: logging every repaint would make "the scroll was
        // painted" unfalsifiable.
        if !projectionChanged, geometry.contentRevision == lastRevision,
           let previous = frameGrid,
           previous.width == frame.width, previous.height == frame.height,
           previous.buffer != frame.buffer {
            kraalLog("scroll repaint: pane=\(paneId) rev=\(geometry.contentRevision) "
                + "offset=\(geometry.scroll?.offsetFromBottom ?? 0)"
                + "/\(geometry.scroll?.maxOffsetFromBottom ?? 0)")
        }
        if resetNeeded {
            // Revisions going backwards means this pane's delta stream restarted:
            // the daemon began a fresh projection (a tab switch, a reconnect, a
            // new boot) and renumbered from scratch. The renderer still holds the
            // old stream's state, so a delta would paint onto a baseline that no
            // longer exists. Wipe and take this frame whole.
            //
            // A changed *grid* lands here too, and only a changed grid. This used
            // to be `frameGrid != frame`, a whole-frame comparison that also
            // included the cursor: dropping the cursor one row made the frames
            // unequal, so pressing Return erased the screen and scrollback and
            // repainted every row — the visible flicker. Comparing sizes keeps
            // the reset for the case that actually needs it (the old rows are the
            // wrong width, so incremental repainting would leave them behind) and
            // lets a cursor move or fresh text go out as a delta.
            //
            // `resetSurfaces()` already ran above, *before* the encode, so this
            // frame's graphics were computed against an empty cache and therefore
            // re-send the image the `2J` is about to erase.
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
            // Same reason as the grid-mismatch branch: the grid appearing fires
            // `onChange` only while it is still *changing*. If the surface reports
            // its first size before the view observes it, nothing else will come.
            schedulePendingRetry()
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
            // Keep the frame instead of dropping it. Resizing a window re-renders
            // the tab at a new grid, but Ghostty's own surface still reports the
            // *previous* grid for a moment, so this check fails on the frame that
            // carries the new size. Dropping it left the pane with nothing to
            // paint and no later trigger: revisions only advance when the
            // program prints, so a still screen stayed frozen at the old size
            // forever. Parking it lets the grid arriving below repaint it.
            pendingFrame = frame
            // Parking alone is not enough: this frame is only ever painted again
            // by a *later* trigger, and after the window stops moving there are no
            // more grid changes to trigger it. The daemon has already rendered the
            // final grid, so nothing else will arrive. Schedule our own retry —
            // the grid does catch up, it just does it after the last event any
            // observer is watching for.
            schedulePendingRetry()
            return
        }

        if needsCleanRepaint {
            // The grid is trustworthy again: wipe the screen and scrollback so
            // the rows written at the wrong width cannot reappear, then paint the
            // whole frame instead of a delta.
            needsCleanRepaint = false
            resetSurfaces()
            session.receive(Data(clearScreenSequence.utf8))
        }

        let painted = renderer.render(frame)
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: surface.graphics.assets.count,
                    placements: surface.graphics.placements.count)
        session.receive(painted)
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
        // Only paint once the terminal's grid actually matches the frame. A parked
        // frame can now also come from the grid-mismatch path above, where the
        // terminal has not caught up with the new window size yet; painting then
        // would wrap every row. Leaving it parked is correct — another grid report
        // follows.
        guard let grid = state.surfaceSize,
              Self.gridMatches(
                  frameWidth: Int(frame.width),
                  frameHeight: Int(frame.height),
                  gridColumns: grid.columns,
                  gridRows: grid.rows
              ) else { return }
        pendingFrame = nil
        lastRevision = 0
        frameGrid = nil
        resetSurfaces()
        let clear = Data(clearScreenSequence.utf8)
        let painted = renderer.render(frame)
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: 0, placements: 0)

        session.receive(clear)
        session.receive(painted)
        lastRevision = 0
        frameGrid = frame

    }

    /// How many times a parked frame is retried, and how far apart.
    ///
    /// Read by the tests as the contract for how long a park may live: long
    /// enough to outlast the launch grid burst, short enough that a pane whose
    /// grid genuinely disagrees is not repainted into the wrong width.
    static let pendingRetryAttempts = 12
    static let pendingRetryIntervalMilliseconds = 80

    /// Whether a parked frame can be painted at the grid the terminal reports.
    ///
    /// Split out so the rule is testable without a Ghostty surface: painting at
    /// a different width wraps every row and pushes the overflow into
    /// scrollback, which is worse than staying blank for one more turn.
    static func gridMatches(
        frameWidth: Int, frameHeight: Int,
        gridColumns: UInt16, gridRows: UInt16
    ) -> Bool {
        gridColumns == frameWidth && gridRows == frameHeight
    }

    /// Retries a parked frame on a short timer.
    ///
    /// The bug this exists for: the pane stayed blank until the user switched
    /// tabs. `flushPendingFrame` was only called from `onChange(of:
    /// surfaceSize)`, so a frame parked on the *last* grid change had nothing
    /// left to wake it — the window settled, the grid stopped changing, and the
    /// frame sat in `pendingFrame` forever. Switching tabs rebuilt the view,
    /// `onAppear` ran again against a grid that now matched, and the content
    /// appeared. That is why the trigger looked like "switch a tab".
    ///
    /// The retry is bounded and cheap: it polls the grid a handful of times over
    /// roughly a second, which is the window in which Ghostty's surface catches
    /// up with a resize. It stops as soon as the frame paints, and it does
    /// nothing at all when no frame is parked.
    private func schedulePendingRetry() {
        // One timer per model. Re-parking during an active retry must not start a
        // second chain that would double-paint when the grid finally matches.
        guard pendingRetryTask == nil else { return }
        pendingRetryTask = Task { @MainActor [weak self] in
            defer { self?.pendingRetryTask = nil }
            // The first attempt is immediate: most parks are one runloop turn
            // behind the grid, and waiting would add a visible delay for them.
            for _ in 0..<Self.pendingRetryAttempts {
                guard let self, !Task.isCancelled, self.pendingFrame != nil else { return }
                self.flushPendingFrame()
                guard self.pendingFrame != nil else { return }
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.pendingRetryIntervalMilliseconds) * 1_000_000
                )
            }
            // Gave up: the grid never matched the frame. Drop the park rather than
            // leaving it to be painted at some arbitrary later moment against a
            // grid it was not rendered for. The next surface frame repaints.
            guard let self, !Task.isCancelled else { return }
            self.pendingFrame = nil
        }
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
        resetSurfaces()
        lastRevision = 0
        frameGrid = nil
        lastProjection = nil
        pendingFrame = nil
        needsCleanRepaint = false
        // The view this chain was polling for is gone. Its successor runs
        // `onAppear` against the live grid, and a surviving retry would paint into
        // a terminal it knows nothing about.
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
    }

    /// Forgets everything the terminal was told: cells *and* graphics.
    ///
    /// The two resets are one operation on purpose. `GraphicsEncoder.reset()` emits
    /// no deletes, and the reason it can get away with that is that the screen was
    /// cleared — the renderer's next frame sends `2J`, and the terminal's `ED2`
    /// reclaims the images. Doing one without the other breaks that reasoning in
    /// the direction that hurts: reset the renderer alone and the encoder still
    /// believes it uploaded the image, so the next frame sends no `a=t` and the
    /// picture stays erased **permanently** (#101 review, `GraphicsSeamTests`).
    func resetSurfaces() {
        renderer.reset()
        graphicsEncoder.reset()
    }

    func reset() {
        resetSurfaces()
        lastRevision = 0
        lastProjection = nil
        frameGrid = nil
    }

    /// Crops the composited tab surface down to this pane's content area.
    ///
    /// The terminal only ever knows about its own pane, so the surrounding
    /// borders and sibling panes must not be fed to it — otherwise a patch in a
    /// neighbouring pane would repaint ours.
    ///
    /// Rows are handed to the frame already chunked (`CellBuffer(rows:width:)`)
    /// rather than flattened into one array and re-split. The flatten-then-chunk
    /// shape copied the pane twice — once into `[CellData]`, once per row by
    /// `Array(slice)` inside `CellBuffer.init(_:width:)`, which does not share
    /// storage with the slice it comes from. The storage step alone is what that
    /// removes, and it is the reproducible part: 200x50, 37.5 us -> 0.033 us
    /// (docs/PERFORMANCE.md, "`paneFrame`：本次改动自己制造、又自己还回去的那笔
    /// 存储拷贝"). The whole-path timings this comment used to quote could not be
    /// reproduced independently and were dropped — do not reintroduce them.
    private func paneFrame(
        from surface: PaneSurfaceFrame,
        geometry: PaneSurfacePane
    ) -> FrameData {
        // Encode *here*, once per frame, so every path that paints this frame —
        // including the parked-frame retries below — carries the graphics without
        // each one having to remember. The encoder diffs against what it already
        // sent, so a frame with unchanged images contributes no bytes.
        //
        // The scene is in **surface** coordinates: a placement's `cellX`/`cellY`
        // address the whole tab, while this terminal only knows its own pane. The
        // cells below are cropped by `innerRect` for exactly that reason, and the
        // placements have to be shifted the same way or an image in a split pane is
        // drawn at the wrong column. Upstream does the same addition in reverse
        // (`client_host_piece`, `kitty_graphics/surface.rs:1032`: `origin.0 +
        // placement.x`), so subtracting the origin here restores pane-local space.
        let paneOrigin = (x: Int(geometry.innerRect.originX), y: Int(geometry.innerRect.originY))
        let paneSize = (
            width: Int(geometry.innerRect.width),
            height: Int(geometry.innerRect.height)
        )
        let graphics = graphicsEncoder.encode(
            scene: sceneInPaneSpace(surface.graphics, origin: paneOrigin, paneSize: paneSize),
            scope: graphicsScope
        )
        let area = geometry.innerRect
        let width = Int(area.width)
        let height = Int(area.height)
        let frameWidth = Int(surface.frame.width)
        var rows: [[CellData]] = []
        rows.reserveCapacity(height)

        // Row at a time: a row of the surface is one array, so this is one retain
        // per row instead of one per cell. The bounds check is per cell because a
        // malformed frame's last row can be shorter than the grid says; a cell the
        // surface does not cover is filled blank, exactly as `surface.frame[c, r]`
        // returning nil used to do.
        for row in 0 ..< height {
            let sourceRow = Int(area.originY) + row
            let rowCells = surface.frame.buffer.row(sourceRow)
            let available = rowCells.count
            var cropped: [CellData] = []
            cropped.reserveCapacity(width)
            for column in 0 ..< width {
                let sourceColumn = Int(area.originX) + column
                if sourceColumn < frameWidth, sourceColumn < available {
                    cropped.append(rowCells[rowCells.startIndex + sourceColumn])
                } else {
                    cropped.append(.blank)
                }
            }
            rows.append(cropped)
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
            buffer: CellBuffer(rows: rows, width: width),
            width: UInt16(width),
            height: UInt16(height),
            cursor: cursor,
            hyperlinks: surface.frame.hyperlinks,
            // The encoder's output, not `surface.frame.graphics`. Kitty graphics do
            // not live in the cell frame: the daemon sends them as a *scene*
            // (`surface.graphics`) and the client encodes it. Reading
            // `surface.frame.graphics` here — what this used to do — reads the ANSI
            // path's field, which the daemon leaves empty for semantic clients, so
            // an image was decoded, laid out against the grid, and thrown away
            // (issues #37, #105).
            graphics: graphics
        )
    }
}

/// Hosts the pane models for one window and keeps them in sync with the store.
///
/// Keys are `(machine, paneId)`, not `paneId` alone. Pane ids are scoped to one
/// daemon — upstream says so outright: "Workspace, tab, pane IDs, and agent names
/// are scoped to one server. Two machines may both contain `w1:p1`"
/// (`docs/next/website/src/content/docs/connecting-machines.mdx:118`). Keying on
/// the pane id alone made two machines' `w1:p1` share one model, and with it one
/// Ghostty `InMemoryTerminalSession`: the scrollback, the alternate-screen state
/// and the cursor of the machine you just left were still inside the surface that
/// went on to render the new one. A full-screen program like btop lives entirely
/// in the alternate screen, so that leak showed up as its picture surviving into
/// the other machine's pane.
@MainActor
@Observable
public final class PaneTerminalPool {
    private var models: [Key: PaneTerminalModel] = [:]
    private let onInput: @Sendable (String, Data) -> Void

    /// Which machine a model belongs to, plus the pane inside it.
    private struct Key: Hashable {
        let machine: String
        let paneId: String
    }

    /// The machine whose panes the pool currently holds.
    ///
    /// A switch drops every model: their surfaces belong to another daemon's
    /// session, so there is nothing in them worth carrying across, and keeping
    /// them alive is how the previous machine's screen state leaked into the next.
    private var machine: String?

    public init(onInput: @escaping @Sendable (String, Data) -> Void) {
        self.onInput = onInput
    }

    /// Points the pool at the machine whose panes it is about to be asked for.
    ///
    /// Called before any model is handed out for a new machine. A switch retires
    /// every model unconditionally: they are bound to the other daemon's session,
    /// and the whole reason `w1:p1` on two machines must not share a surface is
    /// that the Ghostty state inside it belongs to exactly one of them.
    ///
    /// Staying on the same machine is a no-op, which is the normal case —
    /// switching workspaces never reaches this.
    public func selectMachine(_ identifier: String) {
        guard machine != identifier else { return }
        machine = identifier
        models.removeAll()
    }

    /// The model for a pane, or for a popup when `isPopup` is set.
    ///
    /// The two live in separate key spaces because their graphics scopes differ and
    /// a popup's `terminalId` can coincide with a pane id: sharing one model would
    /// let a popup and a pane fight over the same image ids in one terminal.
    public func model(for paneId: String, isPopup: Bool = false) -> PaneTerminalModel {
        let key = Key(machine: machine ?? "", paneId: isPopup ? "popup:\(paneId)" : paneId)
        if let existing = models[key] {
            return existing
        }
        let model = PaneTerminalModel(
            paneId: paneId,
            machine: key.machine,
            isPopup: isPopup
        ) { [weak self] data in
            self?.onInput(paneId, data)
        }
        models[key] = model
        return model
    }

    /// Drops terminals for panes that no longer exist, releasing their surfaces.
    public func prune(keeping paneIds: Set<String>) {
        for key in models.keys where !paneIds.contains(key.paneId) {
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
            // the signal that the terminal can finally accept it — and it is also
            // how a pane resized by a window drag catches up, since the new grid
            // arrives *after* the frame that asked for it.
            .onChange(of: model.state.surfaceSize) { _, new in
                if new != nil {
                    model.flushPendingFrame()
                }
            }
            .onChange(of: surface.surfaceRevision) { _, _ in
                model.apply(surface: surface)
            }
            // A *different daemon* can hand this pane a surface whose revision
            // and geometry are both identical to the one already on screen, and
            // then nothing above fires: `surfaceRevision` did not move, the
            // inner rect did not move, and SwiftUI keeps the same `ForEach` id
            // because two machines name their first workspace's first pane the
            // same way. The picture stays frozen on the other machine's cells.
            //
            // `bootId` is the field that differs, so keying a repaint on it
            // closes the gap. `apply` treats a changed boot as a fresh
            // projection and takes the frame whole.
            .onChange(of: surface.bootId) { _, _ in
                model.apply(surface: surface)
            }
            // A reconnect restarts the surface revision counter from 1, so a
            // resize that lands on the same revision as the frame already on
            // screen produces no `surfaceRevision` change at all: the daemon has
            // re-rendered the tab at a new grid, the view is handed the new
            // surface, and nothing repaints it. That is why dragging a window
            // left the pane frozen at the old size.
            //
            // The revision cannot be relied on across a reconnect, but the grid
            // can: `apply` already treats a changed frame grid as "repaint the
            // whole frame", so keying the trigger on the pane's own grid closes
            // the gap without adding a second notion of size.
            .onChange(of: geometry.innerRect) { _, _ in
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
