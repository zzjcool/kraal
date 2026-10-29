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
    public let state: TerminalViewState
    private var renderer = SurfaceANSIRenderer()
    /// Turns the daemon's graphics scene into kitty bytes (issue #105, parent #37).
    ///
    /// Must be reset together with `renderer` — see `resetSurfaces()`.
    var graphicsEncoder = GraphicsEncoder()
    /// The machine this pane belongs to, used only to scope graphics image ids.
    ///
    /// Ids are a hash of `scope + asset key`, so two machines that both name a pane
    /// `w1:p1` would share a namespace and one pane's `d=I` would delete the
    /// other's picture. Pane ids are scoped to one daemon.
    let machine: String
    /// Whether this model draws a popup rather than a pane.
    ///
    /// It changes which graphics targets this terminal accepts and the scope its
    /// image ids hash from. A popup's `terminalId` can coincide with a pane id, so
    /// the kind cannot be inferred from the id alone.
    let isPopup: Bool
    var lastRevision: UInt64 = 0
    /// The pane grid the last rendered frame was composed for.
    var frameGrid: FrameData?
    /// The surface the baseline belongs to; see `noteSurfaceIdentity`.
    ///
    /// Weak, not an `ObjectIdentifier`: a freed surface's address is the likeliest one for
    /// the next surface to be allocated at, so comparing addresses calls a replacement
    /// "the same surface".
    weak var seenSurface: TerminalSurface?
    var hasSeenSurface = false
    /// Last size the platform view settled on; see `viewDidSettle`.
    var lastAllocatedSize: CGSize?
    /// The screen size the engine last announced; see `EngineScreenReport`.
    var engineScreen: EngineScreenReport?
    /// Whether the surface in use has been asked to announce its screen size.
    var engineReportsRequested = false
    /// The engine's screen changed since the last write, so whatever the renderer believes
    /// is on it is no longer so. Cleared by the next write, which is a whole frame.
    var engineScreenMoved = false
    /// Set by `viewDidSettle` when the pane's own size moved; cleared by `apply`.
    var didViewSizeChange = false
    /// Last `view chain:` shape printed; see `logViewChain`.
    var lastViewChainShape: String?
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
    private(set) var lastProjection: SurfaceGeometry.ProjectionIdentity?
    /// A frame that arrived before Ghostty's surface existed, or before its grid
    /// caught up with the frame's size.
    private var pendingFrame: FrameData?
    /// The surface the last `apply` was given, for re-applying it once the
    /// terminal's grid catches up with a layout SwiftUI had not applied yet.
    private(set) var lastSurface: PaneSurfaceFrame?
    /// The retry chain that keeps trying to paint `pendingFrame`.
    private var pendingRetryTask: Task<Void, Never>?

    /// The frame parked because the terminal had no grid yet, if any.
    ///
    /// Exposed read-only so tests can see what `apply(surface:)` produced without a
    /// Ghostty surface: with no grid, the frame is parked rather than painted, and
    /// parking is the observable seam. It is also the *real* path — `apply` is what
    /// the view calls — so a test on it cannot pass while the wiring is cut.
    var parkedFrame: FrameData? { pendingFrame }

    /// Overrides the grid `apply` compares against, for tests only.
    ///
    /// `state.surfaceSize` is `internal(set)` and has no injection point, so the
    /// grid-mismatch branch — the one that decides whether a pane paints anything
    /// while the grid lags — was unreachable from a test. Every unit test stayed green
    /// when that branch was reduced to a bare `return`, which is how the stray
    /// background band reached a user twice.
    var gridOverride: TerminalGridMetrics?

    /// How many times a screen reset has been applied. Test-observable because the
    /// reset and the image bytes race inside one `apply` call, and `parkedFrame`
    /// alone cannot say whether the reset ran.
    private(set) var screenResetCount = 0

    /// How many times the terminal has been handed bytes.
    ///
    /// One write per visible change is what makes a divider drag smooth: the erase
    /// and the repaint travel together inside one synchronized-output block, so
    /// the terminal has no turn in which the screen is empty. Two writes per reset
    /// (the old shape) was exactly the blank frame between them.
    ///
    /// Counted here rather than inferred by a test: `swift test` has no Ghostty
    /// surface, and the GUI case can only read what the app logs.
    private(set) var paintCount = 0
    /// The bytes of the most recent write; the only output a test can assert on.
    private(set) var lastPainted: Data?
    /// Writes that carried an erase together with their repaint.
    ///
    /// Not the same count as `screenResetCount`, and the difference is the point:
    /// a model can decide a reset is needed, fail to paint at a trustworthy grid
    /// (`grid mismatch`) and park the frame instead. That path calls
    /// `resetSurfaces()` *without* writing an erase — erasing there would blank a
    /// pane that has nothing to paint yet, which is the same flash with no repaint
    /// after it. So the invariant is per **write**: every write either erases and
    /// repaints together, or does neither.
    private(set) var eraseWrites = 0

    /// Set when a frame was rejected because the terminal's grid did not match
    /// it. The stale rows are still in the terminal's scrollback, and an
    /// incremental repaint only touches rows that changed — so the skew survives
    /// every later update until the screen is explicitly cleared.
    private(set) var needsCleanRepaint = false
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
        // Note what is *not* done here, unlike the pane path: no `sceneInPaneSpace`.
        // A pane subtracts its `innerRect` origin because placements are
        // surface-absolute; a popup's are already popup-local — upstream adds
        // `popup_origin` on the host side (`client_host_piece`,
        // `kitty_graphics/surface.rs:938-958` + `:1032`), so subtracting anything
        // here would shift the image by the popup's own position.
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
        let painted = renderer.render(frame, clearingFirst: true)
        logPopupFrame(frame: frame, revision: revision, painted: painted, scene: scene)
        deliver(painted)
    }

    /// The grid this pane actually paints, which is **not** `surface.frame`.
    ///
    /// `paneFrame` crops the cells to `geometry.innerRect`, so the frame's size is the
    /// pane's inside size. `apply` used to compare the previous frame (an `innerRect`
    /// size) against `surface.frame`, which is a different quantity: a pane draws
    /// inside its box, so the surface is a cell or two larger and the two never
    /// agreed. Every apply then decided the grid had changed, erased the screen and
    /// repainted it — the white flash while scrolling.
    ///
    /// Measured in the scroll fixture before the fix: `frame=118x36`,
    /// `surface=119x36`, reset on every frame including the ones with no scroll at
    /// all. After it, the resets all happen while the window is still settling and
    /// none of them coincides with a scroll.
    static func paneGrid(_ geometry: PaneSurfacePane) -> (width: Int, height: Int) {
        (width: Int(geometry.innerRect.width), height: Int(geometry.innerRect.height))
    }

    /// Reports the renderer's measured cell size, in device pixels.
    public var onCellMetrics: ((CGSize) -> Void)?

    init(
        paneId: String,
        machine: String = "",
        isPopup: Bool = false,
        /// The theme's terminal background as `RRGGBB`, or `nil` to keep libghostty's
        /// own default.
        ///
        /// It has to be set here rather than left to the platform default. Those
        /// defaults are `alabaster` (`#F7F7F7`) on light and `afterglow` (`#212121`) on
        /// dark, so a dark theme on a light Mac got a `(247,247,247)` band wherever the
        /// terminal painted its own background — measured between two `(17,20,25)`
        /// panes. The theme never crosses the wire, so this is the only place that
        /// colour can come from.
        background: String? = nil,
        /// The theme's selection highlight as `RRGGBB`, or `nil` to keep libghostty's
        /// own default for the appearance.
        ///
        /// Measured before this existed: the client wrote three keys (`background`,
        /// `window-padding-x/y`, `window-padding-color`) and nothing else, so a gruvbox
        /// pane highlighted a selection in libghostty's neutral grey instead of the
        /// theme's brown. Only the background of the highlight is written — the ink stays
        /// each cell's own foreground, which is what the engine does when
        /// `selection-foreground` is unset.
        selectionBackground: String? = nil,
        onInput: @escaping @Sendable (Data) -> Void
    ) {
        self.paneId = paneId
        self.machine = machine
        self.isPopup = isPopup
        // The background has to go in `theme`, not `terminalConfiguration`.
        //
        // `GhosttyConfigRenderer.render` emits `configuration` first and `theme`
        // second (`Configuration/GhosttyConfigRenderer.swift:23-29`), so the theme wins
        // on any key both set — and `TerminalTheme.default` sets `background` on both
        // its arms (`alabaster` `F7F7F7`, `afterglow` `212121`). Put in
        // `terminalConfiguration`, this colour was silently overridden by libghostty's
        // own default, which is exactly the bug: measured `background: 282828` in the
        // log while the screen still painted `#F7F7F7`.
        //
        // Both arms get the same value: the theme is Kraal's, not the platform's, so
        // the terminal must not change colour when macOS switches appearance.
        let theme: TerminalTheme
        if let background {
            let arm = TerminalConfiguration { builder in
                builder.withBackground(background)
                // In the same arm as the background: that arm *replaces*
                // `TerminalTheme.default`, so the two colours travel together. It also
                // means the `background == nil` branch above keeps the default theme's own
                // `selection-background` (#C9D0D9 light / #303030 dark) — which is why a
                // selection colour is only written when the theme supplied a background.
                if let selectionBackground {
                    builder.withSelectionBackground(selectionBackground)
                }
            }
            theme = TerminalTheme(light: arm, dark: arm)
        } else {
            theme = .default
        }
        state = TerminalViewState(
            theme: theme,
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withWindowPaddingX(0)
                builder.withWindowPaddingY(0)
                // What the cell grid does not cover takes the colours of the row next to it.
                //
                // The grid is `floor(view / cell)` and the engine adopts a new size ~25 ms
                // after the view has it (`termio/Thread.zig`, `Coalesce.min_ms`). In that
                // window a pane that grew is taller than its grid, and the strip below the
                // grid is *padding*, drawn in the theme background: against a full-screen
                // program that is a band the program never drew. Measured with a real
                // engine on a program with one background, a fast drag showed it in 42.7% of
                // samples; with this setting, 8.5%.
                //
                // `extend-always`, not `extend`: `extend` is a heuristic that gives up as
                // soon as *any* cell of the edge row has the default background, which a
                // footer or a command line almost always does — measured, it left 38.2% of
                // samples with the band where this leaves 8.5%.
                builder.withCustom("window-padding-color", "extend-always")
            }
        )
        let relay = EngineReportRelay()
        session = InMemoryTerminalSession(
            write: { data in
                // Ghostty -> daemon: key bytes, paste payloads, replies to queries.
                //
                // Except the engine's screen-size reports: those are this app's own
                // question, and sent on they would be typed into the pane's shell.
                let (reports, rest) = EngineScreenReport.extract(from: data)
                reports.forEach(relay.deliver)
                if !rest.isEmpty { onInput(rest) }
            },
            resize: { _ in
                // The daemon owns the grid size: it renders the surface at the
                // geometry we asked for, so a resize here must not drive a
                // second, conflicting notion of the size.
            }
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        // See `PaneSurfaceHostView`: the view pins itself to the pane's allocation.
        // The view reports its own settled size; see `viewDidSettle`.
        state.makePlatformView = { [weak self] in
            let view = PaneSurfaceHostView(frame: .zero)
            view.onSettledSize = { [weak self] size in
                self?.viewDidSettle(size: size)
            }
            return view
        }
        relay.connect { [weak self] batch in
            self?.engineScreenDidChange(batch)
        }
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
        // Kept so the frame can be re-applied when Ghostty's grid catches up with a
        // layout SwiftUI had not applied yet. See `reapplyAfterGridViewMoved`.
        lastSurface = surface
        noteSurfaceIdentity()
        requestEngineScreenIfNeeded()
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
        let decision = eraseDecision(
            projectionChanged: projectionChanged, geometry: geometry
        )
        let eraseBeforePaint = decision.erase
        // Before `paneFrame`: `GraphicsEncoder` is stateful, and a cache that
        // believes the image is on screen encodes to zero bytes, after which the
        // erase takes the picture with nothing to put it back (#101).
        //
        // The first frame needs the same forget without erasing — which is how "no
        // previous grid" once came to look like a reason to wipe the screen.
        if eraseBeforePaint || frameGrid == nil {
            resetSurfaces()
        }
        if eraseBeforePaint {
            screenResetCount += 1
        }
        let frame = paneFrame(from: surface, geometry: geometry)
        lastProjection = projection

        // The revision alone is not enough: a pane that merely got a new grid keeps
        // its cells, so the frame must still be taken. The projection is a third
        // reason — same cells, different workspace or machine, so they have to be
        // re-taken whole rather than diffed onto another projection's baseline.
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
            graphicsDiffer: frameGrid?.graphics != frame.graphics,
            // The pane's own size, which none of the four above can express. A pane that
            // grows keeps its projection, revision, cells and grid — the daemon renders
            // at the grid it was last told about and that has not caught up — so all of
            // them say "unchanged", the frame is skipped, and the rows the view gained
            // are never written. They keep libghostty's background: the band, as wide as
            // the drag moved the divider.
            viewSizeChanged: didViewSizeChange || engineScreenMoved
        ) else {
            logSkippedFrame(paneId: paneId, revision: geometry.contentRevision,
                            frame: frame, previous: frameGrid)
            return
        }
        didViewSizeChange = false
        // A repaint owed because the engine's screen moved is discharged by the first write
        // below that is a whole frame; every path here either writes one or parks the frame
        // with no baseline, so the eventual write is whole.
        let engineMoved = engineScreenMoved
        engineScreenMoved = false
        logScrollRepaint(
            geometry: geometry, previous: frameGrid, frame: frame,
            projectionChanged: projectionChanged
        )
        if eraseBeforePaint {
            // The erase is **not** written here. It travels inside
            // `renderer.render(_:clearingFirst:)`'s synchronized-output block so
            // the terminal never composites the space between erase and repaint.
            //
            // Written here instead — one `session.receive` for the clear, a second
            // for the repaint — the surface was shown empty in between, and a split
            // divider changes the grid on nearly every drag event, so the flash
            // repeated all the way across. Returns above this point (a parked
            // frame, a grid mismatch) used to erase and then return without
            // painting at all, which is the same flash with no repaint to follow.
            needsCleanRepaint = false
        }
        lastRevision = geometry.contentRevision
        frameGrid = frame

        reportCellMetrics()

        // A grid that disagrees with the frame would wrap every row and push the
        // overflow into scrollback: a permanently skewed screen.
        // No surface yet: the view has been mounted but Ghostty has not finished
        // attaching, so `surfaceSize` is nil and anything written is queued
        // without a grid to lay it out in. Remember the frame and paint it when
        // the surface reports a size; writing now both wastes the frame and
        // leaves the pane blank even though the terminal later becomes ready.
        guard let grid = resolvedGrid else {
            parkMismatched(frame)
            return
        }
        pendingFrame = nil

        // A wider frame is still parked: cropping columns wraps every row and that skew
        // survives in scrollback. A taller one is handled by `paintBridged`.
        if grid.columns != frame.width {
            logGridMismatch(grid: grid, frame: frame, surface: surface)
            parkMismatched(frame)
            return
        }
        if grid.rows != frame.height {
            paintBridged(frame, grid: grid, surface: surface, revision: geometry.contentRevision)
            return
        }

        needsCleanRepaint = false
        logPaintGridIfMoved(paneId: paneId, from: frameGrid, to: frame)
        let painted = renderer.render(
            frame,
            clearingFirst: eraseBeforePaint,
            // A new projection invalidates the diff even when the grid held still:
            // the cells on screen came from another projection, so comparing rows
            // against them is meaningless. Repainting is required; erasing is not.
            invalidateBaseline: decision.repaintAll || engineMoved
                || Self.gridMoved(from: frameGrid, to: frame),
            viewRows: viewRows
        )
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: surface.graphics.assets.count,
                    placements: surface.graphics.placements.count)
        logSurfaceExtent(paneId: paneId, grid: grid, frame: frame)
        deliver(painted)
    }

    /// Reports the renderer's measured cell size, in device pixels.
    ///
    /// Called before the grid check in `apply`, not after it: the check bails out
    /// while the grid is wrong, and if reporting lived past that bail-out the size
    /// used for layout could never be corrected — a one-way trap where the grid stays
    /// wrong because it was never measured, and never measured because it was wrong.
    ///
    /// (The doc block above `deliver` used to be a duplicate of this one, left behind
    /// by a move. Two doc comments on one declaration is not a compile error, so it
    /// survived review.)
    /// Hands one painted frame to the terminal, and records that it was one write.
    ///
    /// Every classification the GUI case reads comes from the **bytes actually
    /// written**, never a caller flag — that is what lets the assertion catch the
    /// defect it was written for (an `erasing:` flag let a two-write erase log
    /// `erase=0` and pass). Verified by injection; see `docs/ENVIRONMENT.md` §8.11.
    private func deliver(_ painted: Data) {
        paintCount += 1
        lastPainted = painted
        // The clear pair this app erases with: `ED2` + `ED3` + cursor home.
        let carriesErase = painted.range(of: Data("\u{1B}[2J".utf8)) != nil
        // "Cells" means *row writes*: a cursor-position sequence `CSI <row>;1H`.
        // Matching a bare `H` was wrong and it mattered — the erase sequence itself
        // ends in `H` (`ESC[H` homes the cursor), so an 11-byte "erase and nothing
        // else" write was classified as carrying cells, and the case passed on the
        // exact defect it was written for. Verified by injection.
        let carriesCells = painted.range(of: Data(";1H".utf8)) != nil
        if carriesErase { eraseWrites += 1 }
        // Logged for every write, so `grep -c paint:` *is* the write count and the
        // GUI case can compare it against the erase count.
        kraalLog("paint: pane=\(paneId) erase=\(carriesErase ? 1 : 0) "
            + "rows=\(renderer.lastWroteRows) "
            + "cells=\(carriesCells ? 1 : 0) "
            + "eraseWrites=\(eraseWrites) resets=\(screenResetCount) "
            + "paints=\(paintCount) bytes=\(painted.count)")
        session.receive(painted)
    }

    /// Paints the rows the terminal holds when the frame and the grid disagree. Same
    /// width means every row keeps its coordinate, so the rows that fit are correct and
    /// the renderer clears the rest. Painting nothing is right only while the grid does
    /// catch up; in #188 it never did and the pane stopped drawing entirely.
    private func paintBridged(
        _ frame: FrameData,
        grid: TerminalGridMetrics,
        surface: PaneSurfaceFrame,
        revision: UInt64
    ) {
        logGridMismatch(grid: grid, frame: frame, surface: surface)
        guard let bridge = Self.bridgeFrame(
            frame, gridColumns: grid.columns, gridRows: grid.rows
        ) else {
            parkMismatched(frame)
            return
        }
        let painted = renderer.render(
            bridge, clearingFirst: false, invalidateBaseline: true,
            viewRows: Int(grid.rows)
        )
        frameGrid = bridge
        lastRevision = revision
        logGraphics(
            encoded: bridge.graphics, painted: painted,
            assets: surface.graphics.assets.count,
            placements: surface.graphics.placements.count
        )
        deliver(painted)
    }

    /// Keeps a frame the terminal cannot take, and keeps trying. Nothing is painted, so
    /// nothing needs cleaning: clearing the baseline makes the eventual paint whole.
    private func parkMismatched(_ frame: FrameData) {
        frameGrid = nil
        lastRevision = 0
        pendingFrame = frame
        schedulePendingRetry()
    }

    /// Paints a frame that arrived before the terminal was able to accept it.
    ///
    /// Called when the surface reports a grid: at that point the queued frame can
    /// finally be laid out. Without this the pane stays blank after a tab switch,
    /// because the only frame for that tab was dropped while the view was still
    /// being attached.
    func flushPendingFrame() {
        guard let frame = pendingFrame, let grid = resolvedGrid else { return }
        let exact = Self.parkedFrameFits(
            frameWidth: Int(frame.width),
            frameHeight: Int(frame.height),
            gridColumns: grid.columns,
            gridRows: grid.rows
        )
        guard exact else { return }
        pendingFrame = nil
        lastRevision = 0
        // Read the baseline **before** clearing it. The first version of this
        // assigned `frameGrid = nil` above and then asked whether it was nil, so the
        // answer was always yes and `wipe` was always true — the optimisation read
        // as present and did nothing. Caught by the live log still showing 509 of 565
        // paints with `erase=1` at a constant width.
        let widthMoved = Self.widthMoved(from: frameGrid, to: frame)
        frameGrid = nil
        resetSurfaces()
        // A parked frame is routinely the one that carries a new grid, so this is
        // the resize path too. Erase only when the width moved: a vertical drag is
        // one height change per mouse move, and each erase is a `2J 3J H` plus a
        // full rewrite (8-10 KB of ANSI). The renderer clears the rows this frame
        // stopped covering by itself.
        let painted = renderer.render(
            frame, clearingFirst: widthMoved, invalidateBaseline: false,
            viewRows: viewRows
        )
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: 0, placements: 0)
        deliver(painted)
        lastRevision = 0
        frameGrid = frame
        engineScreenMoved = false   // this write was the whole frame
    }

    /// How many times a parked frame is retried, and how far apart.
    ///
    /// The tests pin this as the contract for how long a park may live: long enough
    /// to outlast the launch grid burst, short enough that a genuinely wrong grid is
    /// not repainted at the wrong width.
    static let pendingRetryAttempts = 12
    static let pendingRetryIntervalMilliseconds = 80

    /// Whether a parked frame can be painted at the grid the terminal reports.
    ///
    /// Split out so the rule is testable without a Ghostty surface: a different
    /// width wraps every row and pushes overflow into scrollback.
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
        // Refresh the budget, do not keep the first one.
        //
        // A chain that is already running is *restarted* rather than left alone.
        // The budget is wall-clock (12 x 80 ms), and `apply` re-parks on every frame
        // that does not fit — a drag produces a new frame every few milliseconds.
        // Keeping the first chain meant the budget was measured from the *first*
        // mismatch of a gesture, so any drag longer than ~1 s spent it before the
        // gesture ended; the frame parked by the last mismatch then had nothing left
        // to wake it and the blank rows stayed until the program next printed. That
        // is "drag fast, lots of empty rows appear at the bottom".
        //
        // Restarting cannot double-paint: the previous task is cancelled, and
        // `flushPendingFrame` clears `pendingFrame` before it writes, so at most one
        // chain is ever alive and at most one frame is in flight.
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
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
            // Why a band can outlive the retry window: if Ghostty's bounds catch
            // up *after* this fires, the frame that would have covered the missing
            // row is gone and only a new daemon revision repaints it — which for a
            // still screen can be seconds. Logged because "it fixes itself after a
            // while" is otherwise indistinguishable from the retry having worked.
            if let parked = self.pendingFrame {
                self.logParkExpired(
                    paneId: self.paneId, frame: parked, grid: self.state.surfaceSize
                )
            }
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
        forgetEngineScreen()
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
            // No `GeometryReader` here any more: it reports the size SwiftUI is
            // *about to* give this pane, which is one layout pass ahead of the view
            // tree. `PaneSurfaceHostView.layout()` reports the size the view actually
            // has, and `viewDidSettle` is driven from it.
            .background(Color.clear)
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
                guard new != nil else { return }
                // Two different reasons the grid can move, and both need a repaint:
                //
                //   * a frame was parked because the grid had not caught up yet
                //     (`flushPendingFrame`), and
                //   * `apply` declined to paint at the stale grid at all, so the
                //     surface it was given still has to be drawn
                //     (`reapplyAfterGridViewMoved`).
                //
                // The second is the reason this used to leave a pane blank: the
                // surface was handed over before the NSView had its new size, and
                // nothing re-applied it afterwards.
                model.flushPendingFrame()
                model.reapplyAfterGridViewMoved()
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
