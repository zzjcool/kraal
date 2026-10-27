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
    private(set) var lastRevision: UInt64 = 0
    /// The pane grid the last rendered frame was composed for.
    private(set) var frameGrid: FrameData?
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
    /// The last size SwiftUI handed this pane; see `layoutSettled(size:)`.
    var lastLaidOutSize: CGSize?

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
            }
        )
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
        // Kept so the frame can be re-applied when Ghostty's grid catches up with a
        // layout SwiftUI had not applied yet. See `reapplyAfterGridViewMoved`.
        lastSurface = surface
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
        if eraseBeforePaint {
            screenResetCount += 1
            // Runs **before** `paneFrame` below for every path that erases, not
            // just the `resetNeeded` one. `GraphicsEncoder` is stateful: encoding
            // against a cache that still believes the image is on screen yields
            // zero bytes, and the erase that follows then takes the picture with
            // nothing to put it back. That is #101 review's "gone permanently".
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
            logGridMismatch(grid: grid, frame: frame, surface: surface)
            // Nothing is painted here, so nothing needs cleaning up. Clearing the
            // baseline is enough: the frame that eventually paints is taken whole
            // (`gridMoved` sees `frameGrid == nil` and repaints every row), and
            // arming `needsCleanRepaint` as well made each mismatch in a burst erase
            // the screen — measured 8 erases in 53 ms while the daemon's grid held
            // constant at 120x40 and only this check was failing.
            frameGrid = nil
            lastRevision = 0
            // Keep the frame instead of dropping it. Resizing a window re-renders
            // the tab at a new grid, but Ghostty's own surface still reports the
            // *previous* grid for a moment, so this check fails on the frame that
            // carries the new size. Dropping it left the pane with nothing to
            // paint and no later trigger: revisions only advance when the
            // program prints, so a still screen stayed frozen at the old size
            // forever. Parking it lets the grid arriving below repaint it.
            pendingFrame = frame
            // Parking alone is not enough: after the window stops moving there are
            // no more grid changes to trigger a repaint, and the daemon has already
            // rendered the final grid. Retry on our own timer.
            schedulePendingRetry()

            // Deliberately paints **nothing**.
            //
            // The grid comes from Ghostty's `bounds`, which SwiftUI updates one
            // layout pass *after* the frame that asked for it: measured, the surface
            // arrived at `.651`, `apply` ran at `.658` against the old grid, and the
            // NSView took its new size at `.668`. Ten milliseconds in which every
            // pane is measured at its previous size.
            //
            // Painting the intersection (what this used to do) put real cells in the
            // rows that agreed and left the rest showing whatever was there before:
            // on a two-pane split, one pane's 36-row screen against a 16-row frame
            // left twenty rows of the *previous* layout on screen. That is the
            // reported "drag fast and a lot of empty rows appear", and it survives
            // until something else repaints.
            //
            // Not painting costs one frame of latency and cannot be wrong: the rows
            // that would have been drawn would have to be thrown away anyway when
            // the grid arrives. `reapplyAfterGridViewMoved` is what guarantees the
            // grid arriving is not missed.
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
            invalidateBaseline: decision.repaintAll
                || Self.gridMoved(from: frameGrid, to: frame)
        )
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: surface.graphics.assets.count,
                    placements: surface.graphics.placements.count)
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
            + "cells=\(carriesCells ? 1 : 0) "
            + "eraseWrites=\(eraseWrites) resets=\(screenResetCount) "
            + "paints=\(paintCount) bytes=\(painted.count)")
        session.receive(painted)
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
        let painted = renderer.render(frame, clearingFirst: widthMoved)
        logGraphics(encoded: frame.graphics, painted: painted,
                    assets: 0, placements: 0)
        deliver(painted)
        lastRevision = 0
        frameGrid = frame
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
        /// `paneId` for a pane, the popup's terminal id for a popup.
        ///
        /// A separate field rather than a `"popup:"` prefix on `paneId`: `prune`
        /// compares `paneId` against the live pane set, and a prefixed id never
        /// matches, so every popup's Ghostty surface would be leaked forever.
        let isPopup: Bool
    }

    /// The machine whose panes the pool currently holds.
    ///
    /// A switch drops every model: their surfaces belong to another daemon's
    /// session, so there is nothing in them worth carrying across, and keeping
    /// them alive is how the previous machine's screen state leaked into the next.
    private var machine: String?

    /// The theme's terminal background, as `RRGGBB`, applied to every terminal this
    /// pool builds.
    ///
    /// Setting it retires the existing models: the colour is a construction-time
    /// configuration command in libghostty, so a theme change has to rebuild the
    /// surfaces rather than mutate them. Themes change rarely (a config reload or a
    /// light/dark switch) and a rebuild is what `selectMachine` already does on the
    /// same scale.
    public var background: String? {
        didSet {
            guard background != oldValue else { return }
            models.removeAll()
        }
    }

    public init(
        onInput: @escaping @Sendable (String, Data) -> Void,
        background: String? = nil
    ) {
        self.onInput = onInput
        self.background = background
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
        let key = Key(machine: machine ?? "", paneId: paneId, isPopup: isPopup)
        if let existing = models[key] {
            return existing
        }
        let model = PaneTerminalModel(
            paneId: paneId,
            machine: key.machine,
            isPopup: isPopup,
            background: background
        ) { [weak self] data in
            self?.onInput(paneId, data)
        }
        models[key] = model
        return model
    }

    /// Drops terminals for panes that no longer exist, releasing their surfaces.
    public func prune(keeping paneIds: Set<String>) {
        // Popups are excluded on purpose: `paneIds` is the set of *panes*, a popup
        // is not one, and its lifetime is the popup's — it closes when the surface
        // stops carrying one (`applyPopup` is not called, and the view goes away with
        // the model). Pruning by `paneId` would drop a popup's terminal every time
        // the pane set changed, throwing away its image cache mid-display.
        for key in models.keys where !key.isPopup && !paneIds.contains(key.paneId) {
            models.removeValue(forKey: key)
        }
    }

    /// Drops popup terminals for popups the surface no longer carries.
    ///
    /// Called from the same place as `prune(keeping:)` — when the store's surface
    /// changes — but keyed on the popup instead of the pane set. A popup is not in
    /// `paneIds`, so folding the two together would either leak every popup's
    /// Ghostty surface (what a `"popup:"`-prefixed `paneId` did) or delete live
    /// panes.
    public func prunePopups(keeping terminalIds: Set<String>) {
        for key in models.keys
        where key.isPopup && !terminalIds.contains(key.paneId) {
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
                            // The exact size, not `Int(...)`: the grid is
                            // `floor(pixels / cellPixels)`, so half a point is the
                            // difference between one row and two. Printing the
                            // truncated value hid that (`536.5pt` reads as `536`,
                            // and 536pt is exactly where a row disappears).
                            logPaneViewIfMismatched(
                                paneId: geometry.paneId,
                                size: proxy.size,
                                cells: geometry.innerRect,
                                // `resolvedGrid`, not `surfaceSize`: the latter
                                // goes stale, so printing it reported a grid the
                                // pane was not painting in.
                                grid: model.resolvedGrid,
                                viewSize: model.state.attachedPlatformView
                                    .map { "\($0.bounds.width)x\($0.bounds.height)pt" } ?? "none"
                            )
                            model.layoutSettled(size: proxy.size)
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
