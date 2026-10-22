// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  CopyMode.swift
//  Kraal
//
//  A keyboard-driven mode for selecting text out of a pane's **history**.
//
//  ## Why this exists at all
//
//  Selecting with the mouse already works, inside one screenful, because Ghostty
//  owns that: `⌘C` runs the surface's own `copy_to_clipboard` binding. What it
//  cannot reach is anything above the top of the screen. The pane's scrollback
//  lives in the daemon — the renderer paints a fixed screen with absolute cursor
//  addressing and never emits a newline, so the local terminal accumulates no
//  history (see `MouseCoordinateMapper.ScrollTarget`). Copy mode is therefore not
//  a second way to do what the mouse does; it is the only way to reach history.
//
//  ## The coordinates are the daemon's, not the screen's
//
//  A `PaneTextPoint` is `(row, col)` in the daemon's own text space: row 0 is the
//  first line the pane ever printed. The viewport is a window into that space, so
//  `row = viewportTop + rowOnScreen`. Getting this wrong is subtle — a selection
//  made one screenful up would read the right shape of text from the wrong place,
//  and the wrong text still copies fine.
//
//  ## The entry point is not a prefix
//
//  Upstream enters with `prefix+[`, because its terminal consumes a prefix key.
//  This app has no prefix mode on purpose (`AGENTS.md`): macOS already has a
//  menu bar and real key equivalents, and a prefix would take a key away from the
//  pane. So the mode is entered from the menu / `⌘F`, and once inside it takes
//  bare keys — which is exactly what a modal editor is, minus the prefix.
//
//  The consequence is that the mode has to be **visible**: nothing outside the
//  app's own memory says it is active. `CopyModeState.isActive` drives an on-screen
//  bar, and Escape leaves.
//

import Foundation
import KraalProtocol

/// Where the copy-mode cursor is, in the daemon's text space.
public struct CopyModeCursor: Equatable, Sendable {
    /// Absolute row in the pane's text, 0 = the first line ever printed.
    public var row: Int
    /// Column, 0-based, in cells.
    public var column: Int

    /// A column past any real line, meaning "as far as this line goes".
    ///
    /// **Not sent to the daemon as-is.** `PaneTextPoint.col` is a `u16`, and a
    /// column past the pane's last one makes `pane.selection.read` extract nothing
    /// at all — it answers `selection_unavailable`, not "clamped text". Both were
    /// measured against a live daemon:
    ///
    /// - `1 << 30` → `invalid_request: invalid value: integer 1073741824, expected
    ///   u16` (the field is a `u16`);
    /// - `65535` on a 118-column pane → `selection_unavailable` (200 fails too;
    ///   117 works).
    ///
    /// So the sentinel only marks intent, and `clampedColumn(_:paneColumns:)` is
    /// what has to be applied before it crosses the wire. Both mistakes passed
    /// every unit test, because unit tests never cross the wire.
    public static let lineEndColumn = Int(UInt16.max)

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Clamping a column into what the pane can actually address.
///
/// Kept here, next to `CopyModeCursor.lineEndColumn`, because the two are one
/// decision: the sentinel says "to the end of the line", this says "the end of the
/// line is somewhere inside the pane". A caller that applies one without the other
/// either asks for a column the protocol cannot carry or a range the daemon
/// refuses to extract.
public enum CopyModeColumn {
    /// Clamps `column` into `0...paneColumns-1`.
    ///
    /// `paneColumns == 0` means the pane's width is not known yet (before the first
    /// surface lands). There is no right answer at that point, so the choice is
    /// between two wrong ones:
    ///
    /// - collapse to 0 → the first copy silently selects an empty range, which
    ///   looks like the mode being broken rather than early;
    /// - pass it through → the daemon gets a column it may refuse.
    ///
    /// Neither is good, so this refuses instead: `nil` when the width is unknown
    /// *and* the column is the "to the end of the line" sentinel, because that
    /// combination is known to fail (`selection_unavailable` — a `u16`-sized
    /// sentinel is still past the pane's last column). The caller then says
    /// "try again" rather than sending a request it knows will be refused. An
    /// ordinary column is passed through: it came from a real position and may
    /// well be addressable.
    public static func clamped(_ column: Int, paneColumns: Int) -> Int? {
        if paneColumns > 0 {
            return min(max(column, 0), paneColumns - 1)
        }
        let capped = min(max(column, 0), Int(UInt16.max))
        // The sentinel is "far past anything real"; an ordinary column is not.
        if capped >= Int(UInt16.max) {
            return nil
        }
        return capped
    }
}

/// Whether a selection takes whole lines or the exact character range.
public enum CopyModeSelectionKind: Equatable, Sendable {
    /// `v` — from the anchor to the cursor, character-wise.
    case character
    /// `V` — the anchor line through the cursor line, whole lines.
    case linewise
}

/// One movement, as the daemon understands it.
///
/// These are the motions the daemon computes (`pane.copy_motion`), because word
/// boundaries depend on the terminal's own notion of a word — the daemon has the
/// text, so it is the thing that can answer "where does the next word start".
/// Everything that can be computed from the cursor alone (`h`/`j`/`k`/`l`,
/// `$`, `0`, `g`, `G`) is done locally instead of costing a round trip.
public enum CopyModeMotion: String, Equatable, Sendable, CaseIterable {
    case lineEnd = "line_end"
    case firstNonBlank = "first_non_blank"
    case nextWordStart = "next_word_start"
    case previousWordStart = "previous_word_start"
    case nextWordEnd = "next_word_end"
    case nextBigWordStart = "next_big_word_start"
    case previousBigWordStart = "previous_big_word_start"
    case nextBigWordEnd = "next_big_word_end"
    case previousParagraph = "previous_paragraph"
    case nextParagraph = "next_paragraph"
}

/// The bounds the cursor may not leave: the daemon's whole text for this pane.
public struct CopyModeBounds: Equatable, Sendable {
    /// The pane's current viewport, in text space. Scrolling moves this, so the
    /// mode has to keep up with it rather than capturing it once.
    public var viewportTop: Int
    /// How many rows the viewport shows.
    public var viewportRows: Int

    public init(viewportTop: Int, viewportRows: Int) {
        self.viewportTop = viewportTop
        self.viewportRows = viewportRows
    }

    /// Lowest row still on screen.
    public var viewportBottom: Int {
        viewportTop + max(viewportRows - 1, 0)
    }
}

/// The whole state of the mode.
///
/// Deliberately a value type with pure transitions: the interesting behaviours
/// here (clamping at the edges, a selection surviving a scroll, `Escape` restoring
/// what the cursor was) are all things that can be stated as "given this state and
/// this key, this is the next state". Anything that needs the daemon returns a
/// *request* rather than performing it, so the state machine stays testable and
/// the caller decides how to spend a round trip.
public struct CopyModeState: Equatable, Sendable {
    public var cursor: CopyModeCursor
    /// `nil` when not selecting. `v`/`V` set it, `Escape` clears it.
    public var selectionKind: CopyModeSelectionKind?
    /// Where the selection started. Kept while selecting so that moving back over
    /// the anchor shrinks the selection instead of moving it.
    public var anchor: CopyModeCursor?
    /// The pane this mode is attached to. The mode is per-pane: switching panes
    /// ends it, because a selection made against one pane's text means nothing in
    /// another's.
    public var paneId: String
    /// Guard against the daemon's text having moved on. `pane.selection.read`
    /// refuses with `stale_content` when this no longer matches, which turns a
    /// race into an error message instead of the wrong text on the clipboard.
    public var contentRevision: UInt64
    /// Line count of the pane's text, for `G`. Zero means "unknown", in which case
    /// `G` does nothing rather than guessing.
    public var totalRows: Int

    public init(
        paneId: String,
        cursor: CopyModeCursor,
        contentRevision: UInt64,
        totalRows: Int = 0
    ) {
        self.paneId = paneId
        self.cursor = cursor
        self.contentRevision = contentRevision
        self.totalRows = totalRows
    }

    public var isSelecting: Bool { selectionKind != nil }

    /// Whether there is anything to copy. `y` with no selection is "leave", not
    /// "copy nothing" — matching upstream, where `y` exits either way.
    public var canCopy: Bool { isSelecting }
}

/// What the caller must do in response to a key.
///
/// Returning a value instead of mutating the world keeps the state machine pure
/// and makes each case a thing a test can assert without a daemon.
public enum CopyModeEffect: Equatable, Sendable {
    /// Nothing to do (the key is not part of the mode).
    case none
    /// The state changed; redraw.
    case redraw
    /// Ask the daemon where a word boundary is. The answer feeds
    /// `applyMotionTarget`.
    case requestMotion(CopyModeMotion)
    /// Read the selected text and put it on the clipboard.
    case copy(rowStart: Int, columnStart: Int, rowEnd: Int, columnEnd: Int)
    /// Leave the mode.
    case exit
}

public extension CopyModeState {
    /// Starts the mode at `cursor`, clamped into bounds.
    ///
    /// The cursor starts where the terminal's own cursor is when it is visible and
    /// in this pane, because that is where the user's attention already is; the
    /// caller passes that. Everything is clamped because the cursor may be parked
    /// outside the viewport (a hidden cursor is parked at its last visible
    /// position, see `SurfaceANSIRenderer.resolveHostCursor`).
    static func entering(
        paneId: String,
        cursor: CopyModeCursor,
        bounds: CopyModeBounds,
        contentRevision: UInt64,
        totalRows: Int = 0
    ) -> CopyModeState {
        CopyModeState(
            paneId: paneId,
            cursor: clamp(cursor, bounds: bounds),
            contentRevision: contentRevision,
            totalRows: totalRows
        )
    }

    /// Handles one key.
    ///
    /// `key` is a single character for printable keys; the special cases are the
    /// named strings below. Keeping this a `String` rather than keycodes means the
    /// tests read like the keymap instead of like AppKit.
    static func key(_ key: String) -> CopyModeKeyEvent {
        CopyModeKeyEvent(raw: key)
    }

    mutating func handle(_ event: CopyModeKeyEvent, bounds: CopyModeBounds) -> CopyModeEffect {
        // Split by concern rather than one long switch: the cyclomatic complexity
        // limit is 20, and a single switch over the whole keymap is 25. The split
        // is also how a reader looks for a key — "is j a movement or a selection?"
        if let effect = handleSelectionKey(event) { return effect }
        if let effect = handleVerticalKey(event, bounds: bounds) { return effect }
        if let effect = handleMotionKey(event) { return effect }
        return handleHorizontalKey(event)
    }

    /// `v`, `V`, `y`, `Escape` — entering, changing and consuming the selection.
    private mutating func handleSelectionKey(_ event: CopyModeKeyEvent) -> CopyModeEffect? {
        switch event.raw {
        // Leaving. `Escape` also drops the selection, because a selection you
        // cannot see but that still copies is a trap.
        case "escape":
            selectionKind = nil
            anchor = nil
            return .exit
        case "v":
            return toggleSelection(.character)
        case "V":
            return toggleSelection(.linewise)
        // `y` and Return both copy and leave; with no selection they just leave,
        // which is what upstream does and what makes a separate `q` unnecessary.
        case "y", "return", "enter":
            guard let kind = selectionKind, let anchor else { return .exit }
            let range = selectedRange(kind: kind, anchor: anchor)
            return .copy(
                rowStart: range.start.row,
                columnStart: range.start.column,
                rowEnd: range.end.row,
                columnEnd: range.end.column
            )
        default:
            return nil
        }
    }

    /// `j`, `k`, `g`, `G` — vertical movement, clamped to the visible viewport.
    ///
    /// Moving past the edge does not scroll: silently scrolling while the user
    /// holds `j` makes the view lurch under them.
    private mutating func handleVerticalKey(
        _ event: CopyModeKeyEvent,
        bounds: CopyModeBounds
    ) -> CopyModeEffect? {
        switch event.raw {
        case "j":
            cursor.row = min(cursor.row + 1, bounds.viewportBottom)
            return .redraw
        case "k":
            cursor.row = max(cursor.row - 1, bounds.viewportTop)
            return .redraw
        case "g":
            cursor.row = max(bounds.viewportTop, 0)
            return .redraw
        case "G":
            // vim's `G` jumps to the last line and scrolls to it. This mode does not
            // scroll (see `j`), so the honest equivalent is "the last line that is
            // on screen" — the cursor must stay visible, because the whole point of
            // a visible mode is that you can see where the selection ends.
            //
            // With `totalRows` unknown the cursor simply stays put, but the key is
            // still **consumed**. Returning `.none` here was a real bug: `.none`
            // means "not my key", so the event was passed on and `G` reached the
            // pty — typing a capital G into whatever was running in the pane while
            // the bar claimed copy mode was active.
            guard totalRows > 0 else { return .redraw }
            // Clamped into the viewport *after* the text end is applied, so a short
            // text cannot leave the cursor below the last visible line either.
            let lastTextRow = max(totalRows - 1, 0)
            cursor.row = min(lastTextRow, bounds.viewportBottom)
            cursor.row = max(cursor.row, bounds.viewportTop)
            return .redraw
        default:
            return nil
        }
    }

    /// `w`, `b`, `e`, `W`, `B`, `E`, `}` , `{`, `^`, `$` — the daemon's motions.
    ///
    /// These depend on the text (where does this word end?), which only the daemon
    /// has, so they become a request rather than a local computation.
    private mutating func handleMotionKey(_ event: CopyModeKeyEvent) -> CopyModeEffect? {
        let motion: CopyModeMotion? = switch event.raw {
        case "w": .nextWordStart
        case "b": .previousWordStart
        case "e": .nextWordEnd
        case "W": .nextBigWordStart
        case "B": .previousBigWordStart
        case "E": .nextBigWordEnd
        case "}": .nextParagraph
        case "{": .previousParagraph
        case "^": .firstNonBlank
        case "$": .lineEnd
        default: nil
        }
        guard let motion else { return nil }
        return .requestMotion(motion)
    }

    /// `h`, `l`, `0` and a literal column — movement that needs no text knowledge.
    ///
    /// The right edge is not clamped here: line length is the daemon's knowledge,
    /// and clamping would make `l` stop at a guess. `$` asks instead.
    private mutating func handleHorizontalKey(_ event: CopyModeKeyEvent) -> CopyModeEffect {
        switch event.raw {
        case "h":
            cursor.column = max(cursor.column - 1, 0)
            return .redraw
        case "l":
            cursor.column += 1
            return .redraw
        case "0":
            cursor.column = 0
            return .redraw
        default:
            // A digit selects that 1-based column, which is what makes `12` in a
            // status bar meaningful. Only single digits: a count prefix (upstream's
            // `3j`) is a separate feature and a half-implemented one is worse than
            // an absent one.
            if let digit = Int(event.raw), event.raw.count == 1 {
                cursor.column = max(digit - 1, 0)
                return .redraw
            }
            return .none
        }
    }

    /// Applies a word-boundary answer from the daemon.
    ///
    /// Clamped like every other movement: the daemon answers in its own text space,
    /// which can be outside the viewport, and a cursor that wanders off screen
    /// while the mode is meant to be visible is worse than a cursor that stops.
    mutating func applyMotionTarget(_ target: CopyModeCursor, bounds: CopyModeBounds) {
        cursor = Self.clamp(target, bounds: bounds)
    }

    /// The range to read, normalised so `start` precedes `end`.
    ///
    /// Selecting upwards has to work: `anchor` is where `v` was pressed, so the
    /// cursor can be above it. `Selection::absolute_range` upstream takes the two
    /// points in either order, but normalising here means the clipboard call has
    /// one shape rather than two.
    func selectedRange(
        kind: CopyModeSelectionKind,
        anchor: CopyModeCursor
    ) -> (start: CopyModeCursor, end: CopyModeCursor) {
        let (first, second) = anchor.row <= cursor.row
            ? (anchor, cursor)
            : (cursor, anchor)
        switch kind {
        case .character:
            // On one row the columns have to be ordered too. Selecting leftwards
            // over the anchor is the ordinary way to *shrink* a selection, and
            // without this it returned `columnStart > columnEnd` — a reversed range
            // the daemon extracts nothing from, which surfaced as "Nothing to copy"
            // with the selection silently gone.
            guard first.row == second.row, first.column > second.column else {
                return (first, second)
            }
            return (second, first)
        case .linewise:
            // Whole lines: from column 0 of the first line to the end of the last.
            //
            // The end column is `CopyModeCursor.lineEndColumn`, a sentinel rather
            // than a measured width: the daemon truncates at the real line end, and
            // measuring it would cost a round trip per line. A sentinel is a value
            // that means "as far as this line goes", so it is spelled out instead
            // of being `.max` — an integer that *looks* like a column but is not
            // one is exactly the kind of thing that gets copied into a real
            // comparison later.
            return (
                CopyModeCursor(row: first.row, column: 0),
                CopyModeCursor(row: second.row, column: CopyModeCursor.lineEndColumn)
            )
        }
    }

    private mutating func toggleSelection(_ kind: CopyModeSelectionKind) -> CopyModeEffect {
        if selectionKind == kind {
            // Pressing the same key again clears, like a toggle should. Pressing
            // the *other* key switches kind and keeps the anchor, so `v` then `V`
            // extends the same selection to whole lines instead of restarting.
            selectionKind = nil
            anchor = nil
        } else {
            selectionKind = kind
            // Re-anchoring only when starting: switching `v`→`V` must keep the
            // original anchor, otherwise the first press's work is lost.
            if anchor == nil { anchor = cursor }
        }
        return .redraw
    }

    /// Clamps a cursor into the visible viewport.
    ///
    /// The column is clamped at 0 only: the line length is the daemon's knowledge,
    /// and clamping it here would make `l` stop at a guess.
    static func clamp(_ cursor: CopyModeCursor, bounds: CopyModeBounds) -> CopyModeCursor {
        CopyModeCursor(
            row: min(max(cursor.row, bounds.viewportTop), max(bounds.viewportBottom, bounds.viewportTop)),
            column: max(cursor.column, 0)
        )
    }
}

/// A bridge from the copy-mode controller to SwiftUI.
///
/// The controller lives in the app target because it needs AppKit key events;
/// SwiftUI needs an `ObservableObject` to redraw. Rather than make the controller
/// itself observable (it is not a view model and must not be baked into one), the
/// controller writes the *displayable* part here and the status bar watches this.
///
/// `nil` means the mode is off, which is also the signal for the bar to disappear.
public final class CopyModeBanner: ObservableObject {
    @Published public private(set) var text: String?
    /// Whether `text` describes an active mode (as opposed to a one-off message).
    @Published public private(set) var isActive: Bool

    public init() {
        self.text = nil
        self.isActive = false
    }

    /// The common form inside the mode: where the cursor is and what to press.
    ///
    /// The key hints are spelled out because the mode is modal and nothing else
    /// announces it: a user who enters by accident has to be able to see that the
    /// app is waiting for `v`/`y` rather than their shell.
    /// - Parameter viewportTop: the absolute text row the viewport starts at, so
    ///   the position can be shown **relative to the screen the user is looking
    ///   at**. Showing the absolute row next to the viewport's *height* produced
    ///   "167:1 of 24" — two numbers from different spaces, which is worse than no
    ///   number at all in the one piece of feedback this mode has.
    public func show(
        cursor: CopyModeCursor,
        selecting: Bool,
        viewportTop: Int,
        viewportRows: Int
    ) {
        let rowOnScreen = cursor.row - viewportTop + 1
        let position = "\(max(rowOnScreen, 1))/\(max(viewportRows, 1)):\(cursor.column + 1)"
        let mode = selecting ? "VISUAL" : "copy"
        self.text = "\(mode) \(position)   v select · y copy · "
            + "hjkl move · w/b words · esc cancel"
        self.isActive = true
    }

    public func hide() {
        text = nil
        isActive = false
    }
}

/// A key, as the mode sees it.
///
/// A wrapper rather than a bare `String` so that `handle` reads as key handling and
/// so that translating AppKit's `NSEvent` into this has one obvious home.
public struct CopyModeKeyEvent: Equatable, Sendable {
    public var raw: String

    public init(raw: String) {
        self.raw = raw
    }

    /// Maps an AppKit key event's characters to the mode's vocabulary.
    ///
    /// Kept separate from `CopyModeState.handle` so tests can drive the state
    /// machine without an `NSEvent`, which cannot be constructed reliably outside
    /// a running app.
    public static func from(characters: String?, keyCode: UInt16?) -> CopyModeKeyEvent? {
        // Escape has no printable character, so it is matched on the key code
        // (53 = `kVK_Escape`) — the one place the mode has to know about hardware.
        if let keyCode, keyCode == 53 { return CopyModeKeyEvent(raw: "escape") }
        guard let characters, !characters.isEmpty else { return nil }
        // Control characters arrive for Return/Tab; name them so the keymap stays
        // readable and so `\r` does not fall through to "no effect".
        switch characters {
        case "\r", "\n": return CopyModeKeyEvent(raw: "return")
        case "\t": return CopyModeKeyEvent(raw: "tab")
        default: return CopyModeKeyEvent(raw: characters)
        }
    }
}
