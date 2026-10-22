// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for the copy-mode state machine.
//
// The behaviours worth pinning are the ones where a plausible implementation is
// silently wrong: a cursor that drifts out of the viewport, a selection made
// upwards reading in the wrong direction, `y` with no selection copying nothing
// instead of leaving, and linewise selection not covering the last line.
//

import Foundation
import Testing

@testable import KraalUI

@Suite("Copy mode")
struct CopyModeTests {
    private func state(
        row: Int = 2,
        column: Int = 3,
        revision: UInt64 = 7,
        totalRows: Int = 0
    ) -> CopyModeState {
        CopyModeState(
            paneId: "w1:p1",
            cursor: CopyModeCursor(row: row, column: column),
            contentRevision: revision,
            totalRows: totalRows
        )
    }

    /// A viewport showing rows 2...5 of a longer text.
    private let bounds = CopyModeBounds(viewportTop: 2, viewportRows: 4)

    // MARK: - Entering

    /// The mode starts where the terminal's own cursor is, clamped into the
    /// viewport. The clamp matters: a *hidden* cursor is parked at its last visible
    /// position, which can be outside the current viewport after a scroll.
    @Test("entering clamps a cursor that is outside the viewport")
    func enteringClamps() {
        let outside = CopyModeState.entering(
            paneId: "w1:p1",
            cursor: CopyModeCursor(row: 900, column: 4),
            bounds: bounds,
            contentRevision: 1
        )
        #expect(outside.cursor.row == 5)

        let above = CopyModeState.entering(
            paneId: "w1:p1",
            cursor: CopyModeCursor(row: 0, column: 4),
            bounds: bounds,
            contentRevision: 1
        )
        #expect(above.cursor.row == 2)
    }

    /// Nothing is selected until `v` is pressed, so `y` cannot copy something the
    /// user never chose.
    @Test("entering selects nothing")
    func enteringSelectsNothing() {
        let copyMode = CopyModeState.entering(
            paneId: "w1:p1",
            cursor: CopyModeCursor(row: 3, column: 0),
            bounds: bounds,
            contentRevision: 1
        )
        #expect(!copyMode.isSelecting)
        #expect(!copyMode.canCopy)
    }

    // MARK: - Vertical movement

    /// `j` stops at the bottom of the viewport instead of running into text that is
    /// not on screen. A cursor you cannot see while selecting is the bug this
    /// prevents.
    @Test("j stops at the last visible row")
    func jClampsAtViewportBottom() {
        var copyMode = state(row: 4, column: 0)
        #expect(copyMode.handle(.init(raw: "j"), bounds: bounds) == .redraw)
        #expect(copyMode.cursor.row == 5)
        // Again: no further movement, and no silent scroll.
        _ = copyMode.handle(.init(raw: "j"), bounds: bounds)
        #expect(copyMode.cursor.row == 5)
    }

    /// ...and `k` at the top.
    @Test("k stops at the first visible row")
    func kClampsAtViewportTop() {
        var copyMode = state(row: 3, column: 0)
        _ = copyMode.handle(.init(raw: "k"), bounds: bounds)
        #expect(copyMode.cursor.row == 2)
        _ = copyMode.handle(.init(raw: "k"), bounds: bounds)
        #expect(copyMode.cursor.row == 2)
    }

    /// `G` needs to know how long the text is. With that unknown the cursor stays
    /// put — but the key is still **consumed**.
    ///
    /// The first version returned `.none` here, and `.none` means "not my key": the
    /// event was passed on, so `G` reached the pty and typed a capital G into
    /// whatever was running in the pane, while the bar still said copy mode was
    /// active. A modal mode must never leak the keys it claims to own.
    @Test("G without a known line count consumes the key and does not move")
    func gWithoutTotalRowsIsConsumed() {
        var copyMode = state(row: 3, column: 0, totalRows: 0)
        #expect(copyMode.handle(.init(raw: "G"), bounds: bounds) == .redraw)
        #expect(copyMode.cursor.row == 3)
    }

    /// ...and with it, goes to the last line **that is visible**.
    ///
    /// Not the last line of the text: this mode never scrolls, so jumping to row 49
    /// of a 50-row text would put the cursor off screen mid-selection. vim's `G`
    /// scrolls to its target; here the honest equivalent is the bottom of the
    /// viewport, clamped so a short text lands on its real last line.
    @Test("G goes to the last visible line")
    func gGoesToVisibleEnd() {
        var copyMode = state(row: 3, column: 0, totalRows: 50)
        #expect(copyMode.handle(.init(raw: "G"), bounds: bounds) == .redraw)
        #expect(copyMode.cursor.row == bounds.viewportBottom, "should stop at the viewport, not row 49")
    }

    /// A text that ends above the viewport's bottom: `G` lands on its real last
    /// line rather than past the end of the text.
    @Test("G stops at the text's end when that is higher than the viewport")
    func gGoesToTextEndWhenShorter() {
        var copyMode = state(row: 3, column: 0, totalRows: 4)
        _ = copyMode.handle(.init(raw: "G"), bounds: bounds)
        #expect(copyMode.cursor.row == 3, "last line of a 4-row text is row 3")
    }

    // MARK: - Horizontal movement

    /// `l` is not clamped at the line's end, because the client does not know where
    /// that is. Clamping here would make it stop at a guess.
    @Test("l does not guess the line length")
    func lDoesNotClamp() {
        var copyMode = state(row: 2, column: 79)
        _ = copyMode.handle(.init(raw: "l"), bounds: bounds)
        #expect(copyMode.cursor.column == 80)
    }

    /// `h` does clamp at zero — there is nothing to the left of the first column.
    @Test("h stops at column zero")
    func hClampsAtZero() {
        var copyMode = state(row: 2, column: 1)
        _ = copyMode.handle(.init(raw: "h"), bounds: bounds)
        #expect(copyMode.cursor.column == 0)
        _ = copyMode.handle(.init(raw: "h"), bounds: bounds)
        #expect(copyMode.cursor.column == 0)
    }

    /// `$` has to ask the daemon: only it knows where the line ends.
    @Test("$ asks the daemon for the line end")
    func dollarRequestsMotion() {
        var copyMode = state()
        #expect(copyMode.handle(.init(raw: "$"), bounds: bounds) == .requestMotion(.lineEnd))
    }

    // MARK: - Motions

    /// Every word/paragraph motion becomes a request, never a local guess. The
    /// table is the contract with the daemon's `pane.copy_motion`.
    @Test("word and paragraph keys map to the daemon's motions")
    func motionTable() {
        let expected: [(String, CopyModeMotion)] = [
            ("w", .nextWordStart),
            ("b", .previousWordStart),
            ("e", .nextWordEnd),
            ("W", .nextBigWordStart),
            ("B", .previousBigWordStart),
            ("E", .nextBigWordEnd),
            ("}", .nextParagraph),
            ("{", .previousParagraph),
            ("^", .firstNonBlank),
            ("$", .lineEnd)
        ]
        for (key, motion) in expected {
            var copyMode = state()
            #expect(
                copyMode.handle(.init(raw: key), bounds: bounds) == .requestMotion(motion),
                "key \(key) should ask for \(motion.rawValue)"
            )
        }
    }

    /// The daemon answers in its own text space, which can be outside the viewport.
    /// Applying the answer has to clamp, or the cursor leaves the screen.
    @Test("a motion target outside the viewport is clamped in")
    func motionTargetClamped() {
        var copyMode = state()
        copyMode.applyMotionTarget(CopyModeCursor(row: 1000, column: 5), bounds: bounds)
        #expect(copyMode.cursor.row == 5)
        #expect(copyMode.cursor.column == 5, "the column is not clamped: only the row is visible")
    }

    /// An unknown key is not an error and does not change anything — the mode is
    /// modal, so unrecognised keys are simply not part of it.
    @Test("an unknown key does nothing")
    func unknownKeyIgnored() {
        var copyMode = state()
        #expect(copyMode.handle(.init(raw: "z"), bounds: bounds) == .none)
        #expect(copyMode.cursor == CopyModeCursor(row: 2, column: 3))
    }

    // MARK: - Selection

    /// `v` starts a character selection anchored where it was pressed.
    @Test("v anchors a character selection")
    func vStartsSelection() {
        var copyMode = state(row: 3, column: 4)
        #expect(copyMode.handle(.init(raw: "v"), bounds: bounds) == .redraw)
        #expect(copyMode.selectionKind == .character)
        #expect(copyMode.anchor == CopyModeCursor(row: 3, column: 4))
        #expect(copyMode.canCopy)
    }

    /// Pressing `v` again clears it — a toggle that only toggles on is a trap.
    @Test("v again clears the selection")
    func vTogglesOff() {
        var copyMode = state(row: 3, column: 4)
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        #expect(!copyMode.isSelecting)
        #expect(copyMode.anchor == nil)
    }

    /// `v` then `V` keeps the anchor and switches kind: the first press's work is
    /// not thrown away.
    @Test("V after v keeps the anchor and switches to linewise")
    func vThenVKeepsAnchor() {
        var copyMode = state(row: 3, column: 4)
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        _ = copyMode.handle(.init(raw: "V"), bounds: bounds)
        #expect(copyMode.selectionKind == .linewise)
        #expect(copyMode.anchor == CopyModeCursor(row: 3, column: 4))
    }

    /// A character selection made **upwards** must read in the right direction.
    /// Reversing this copies the right number of characters from the wrong place.
    @Test("a selection made upwards is normalised")
    func upwardSelectionNormalised() throws {
        var copyMode = state(row: 4, column: 2)
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        // Move up two rows.
        _ = copyMode.handle(.init(raw: "k"), bounds: bounds)
        _ = copyMode.handle(.init(raw: "k"), bounds: bounds)
        #expect(copyMode.cursor.row == 2)

        // `#require` rather than `!`: if the anchor were nil the interesting
        // failure is "v did not anchor", not a crash inside the assertion.
        let anchor = try #require(copyMode.anchor)
        let range = copyMode.selectedRange(kind: .character, anchor: anchor)
        #expect(range.start.row == 2)
        #expect(range.end.row == 4)
    }

    /// Linewise covers whole lines: column 0 of the first through the last line.
    /// The end column is deliberately huge — the daemon truncates at the real line
    /// end, and measuring it would cost a round trip per line.
    @Test("linewise selects whole lines")
    func linewiseCoversWholeLines() throws {
        var copyMode = state(row: 3, column: 7)
        _ = copyMode.handle(.init(raw: "V"), bounds: bounds)
        _ = copyMode.handle(.init(raw: "j"), bounds: bounds)

        let anchor = try #require(copyMode.anchor)
        let range = copyMode.selectedRange(kind: .linewise, anchor: anchor)
        #expect(range.start == CopyModeCursor(row: 3, column: 0))
        #expect(range.end.row == 4)
        #expect(range.end.column == CopyModeCursor.lineEndColumn)
        // The wire field is a `u16`. A sentinel larger than that is refused by the
        // daemon as `invalid_request`, which the unit tests cannot see because they
        // never cross the wire — the first version of this used `1 << 30` and every
        // linewise copy failed in the GUI case only.
        #expect(
            CopyModeCursor.lineEndColumn <= Int(UInt16.max),
            "the sentinel must fit the protocol's u16 column"
        )
        // ...and even a `u16`-sized one is too large for the *pane*: the daemon
        // answers `selection_unavailable` for a range past the last column, which
        // was the second half of the same bug. `clamped` is what makes it sendable.
        #expect(CopyModeColumn.clamped(CopyModeCursor.lineEndColumn, paneColumns: 118) == 117)
    }

    // MARK: - Copying and leaving

    /// `y` with a selection asks for exactly that range.
    @Test("y copies the selected range")
    func yCopies() {
        var copyMode = state(row: 3, column: 2)
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        _ = copyMode.handle(.init(raw: "l"), bounds: bounds)
        _ = copyMode.handle(.init(raw: "l"), bounds: bounds)

        let effect = copyMode.handle(.init(raw: "y"), bounds: bounds)
        #expect(effect == .copy(rowStart: 3, columnStart: 2, rowEnd: 3, columnEnd: 4))
    }

    /// `y` with no selection leaves rather than copying an empty range — otherwise
    /// it would put an empty string on the clipboard and destroy whatever the user
    /// had there.
    @Test("y without a selection leaves without copying")
    func yWithoutSelectionLeaves() {
        var copyMode = state()
        #expect(copyMode.handle(.init(raw: "y"), bounds: bounds) == .exit)
    }

    /// Return behaves like `y`, which is what a terminal user's fingers expect.
    @Test("return copies like y")
    func returnCopies() {
        var copyMode = state(row: 3, column: 2)
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        #expect(
            copyMode.handle(.init(raw: "return"), bounds: bounds)
                == .copy(rowStart: 3, columnStart: 2, rowEnd: 3, columnEnd: 2)
        )
    }

    /// Escape leaves and drops the selection, so nothing lingers that could be
    /// copied by a later keystroke.
    @Test("escape leaves and clears the selection")
    func escapeLeaves() {
        var copyMode = state()
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        #expect(copyMode.handle(.init(raw: "escape"), bounds: bounds) == .exit)
        #expect(!copyMode.isSelecting)
        #expect(copyMode.anchor == nil)
    }

    // MARK: - Key translation

    /// Escape has no printable character, so it is matched on the key code. This is
    /// the one hardware detail the mode has to know.
    @Test("escape is recognised by key code")
    func escapeFromKeyCode() {
        #expect(CopyModeKeyEvent.from(characters: nil, keyCode: 53) == CopyModeKeyEvent(raw: "escape"))
    }

    /// Return arrives as a control character and is named, so that a `\r` does not
    /// fall through to "no effect".
    @Test("return is translated from the control character")
    func returnFromControlCharacter() {
        #expect(CopyModeKeyEvent.from(characters: "\r", keyCode: 36) == CopyModeKeyEvent(raw: "return"))
        #expect(CopyModeKeyEvent.from(characters: "\n", keyCode: 36) == CopyModeKeyEvent(raw: "return"))
    }

    /// A key event with no characters and no escape key code is not part of the
    /// mode; returning `nil` lets the caller pass the event on instead of
    /// swallowing it.
    @Test("an empty key event is not part of the mode")
    func emptyEventIsNil() {
        #expect(CopyModeKeyEvent.from(characters: nil, keyCode: 1) == nil)
        #expect(CopyModeKeyEvent.from(characters: "", keyCode: 1) == nil)
    }
}

@Suite("Copy mode banner")
struct CopyModeBannerTests {
    /// The banner is the only thing telling the user the mode is active — nothing
    /// outside the app knows. So it has to name the mode, say where the cursor is,
    /// and show the keys that leave.
    @Test("the banner names the mode, the position and the exit key")
    func bannerContent() {
        let banner = CopyModeBanner()
        // Viewport starting at absolute row 100, showing 40 rows; the cursor is on
        // absolute row 104, so it is on the 5th visible row.
        banner.show(
            cursor: CopyModeCursor(row: 104, column: 2),
            selecting: false,
            viewportTop: 100,
            viewportRows: 40
        )

        let text = banner.text ?? ""
        #expect(banner.isActive)
        #expect(text.contains("copy"), "the mode name is missing: \(text)")
        // Position is shown **relative to the viewport**, both numbers from the same
        // space: 5th of 40 visible rows, 3rd column. The absolute row next to the
        // viewport's height produced "167:1 of 24" — two spaces, one line, which is
        // worse than showing nothing.
        #expect(text.contains("5/40:3"), "position is not viewport-relative: \(text)")
        #expect(!text.contains("105"), "the absolute row leaked into the bar: \(text)")
        #expect(text.contains("esc"), "the way out is missing: \(text)")
    }

    /// Selecting changes what `y` will do, so the banner has to say so — otherwise
    /// there is no way to tell whether a `y` will copy or merely leave.
    @Test("selecting is visible in the banner")
    func selectingIsVisible() {
        let banner = CopyModeBanner()
        banner.show(cursor: CopyModeCursor(row: 0, column: 0), selecting: false, viewportTop: 0, viewportRows: 10)
        let plain = banner.text ?? ""
        banner.show(cursor: CopyModeCursor(row: 0, column: 0), selecting: true, viewportTop: 0, viewportRows: 10)
        let visual = banner.text ?? ""

        #expect(plain != visual, "selecting must change the banner")
        #expect(visual.contains("VISUAL"), "got \(visual)")
    }

    /// Hiding clears both the text and the active flag: the bar disappears *and*
    /// nothing stale is left for a later redraw to show.
    @Test("hiding clears the banner")
    func hideClears() {
        let banner = CopyModeBanner()
        banner.show(cursor: CopyModeCursor(row: 1, column: 1), selecting: true, viewportTop: 0, viewportRows: 5)
        banner.hide()
        #expect(banner.text == nil)
        #expect(!banner.isActive)
    }
}

@Suite("Copy mode columns")
struct CopyModeColumnTests {
    /// Columns past the pane's last one make `pane.selection.read` extract nothing
    /// — `selection_unavailable`, not "clamped text". Measured on a 118-column
    /// pane: end column 117 returned the line, 200 and 65535 returned nothing.
    @Test("a column past the pane is clamped to its last column")
    func clampsToPaneWidth() {
        #expect(CopyModeColumn.clamped(65535, paneColumns: 118) == 117)
        #expect(CopyModeColumn.clamped(200, paneColumns: 118) == 117)
        #expect(CopyModeColumn.clamped(118, paneColumns: 118) == 117)
        #expect(CopyModeColumn.clamped(117, paneColumns: 118) == 117)
        #expect(CopyModeColumn.clamped(50, paneColumns: 118) == 50)
    }

    /// A negative column is not a thing; clamping it to 0 keeps the daemon from
    /// receiving an unsigned-underflowed value.
    @Test("a negative column clamps to zero")
    func clampsAtZero() {
        #expect(CopyModeColumn.clamped(-5, paneColumns: 118) == 0)
    }

    /// An ordinary column is passed through when the width is unknown: it came from
    /// a real position and may well be addressable. Collapsing it to zero would make
    /// the first copy silently select nothing.
    @Test("an unknown pane width passes an ordinary column through")
    func unknownWidthPassesOrdinaryColumn() {
        #expect(CopyModeColumn.clamped(40, paneColumns: 0) == 40)
        #expect(CopyModeColumn.clamped(-1, paneColumns: 0) == 0)
    }

    /// The "to the end of the line" sentinel is refused when the width is unknown.
    ///
    /// Both alternatives were measured to fail, so refusing is the only honest
    /// answer: a `u16`-sized sentinel is still past the pane's last column, so the
    /// daemon answers `selection_unavailable`; and collapsing to 0 selects nothing.
    /// Sending a request known to fail would leave the user with a vague "Nothing to
    /// copy" instead of "try again".
    @Test("an unknown width refuses the end-of-line sentinel")
    func unknownWidthRefusesSentinel() {
        #expect(CopyModeColumn.clamped(CopyModeCursor.lineEndColumn, paneColumns: 0) == nil)
        #expect(CopyModeColumn.clamped(CopyModeCursor.lineEndColumn + 1000, paneColumns: 0) == nil)
        // Just below the cap is still an ordinary (if silly) column and passes.
        #expect(CopyModeColumn.clamped(80, paneColumns: 0) == 80)
    }
}

@Suite("Copy mode same-row selection")
struct CopyModeSameRowTests {
    private let bounds = CopyModeBounds(viewportTop: 0, viewportRows: 10)

    /// Selecting leftwards over the anchor is how you *shrink* a selection, and it
    /// must produce an ordered range.
    ///
    /// The first version only ordered rows, so `v` then `h` four times returned
    /// `columnStart: 9, columnEnd: 5`. The daemon extracts nothing from a reversed
    /// range, so the copy failed with "Nothing to copy" and the selection was gone —
    /// the most common gesture in the mode, silently broken.
    @Test("selecting leftwards keeps the columns ordered")
    func leftwardsSelectionOrdersColumns() {
        var copyMode = CopyModeState(
            paneId: "w1:p1",
            cursor: CopyModeCursor(row: 3, column: 9),
            contentRevision: 1
        )
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        for _ in 0..<4 { _ = copyMode.handle(.init(raw: "h"), bounds: bounds) }
        #expect(copyMode.cursor.column == 5)

        let anchor = copyMode.anchor ?? CopyModeCursor(row: 0, column: 0)
        let range = copyMode.selectedRange(kind: .character, anchor: anchor)
        #expect(range.start.column == 5, "start should be the left edge")
        #expect(range.end.column == 9, "end should be the right edge")
    }

    /// The rightwards case must keep working (it did before).
    @Test("selecting rightwards is unchanged")
    func rightwardsSelection() {
        var copyMode = CopyModeState(
            paneId: "w1:p1",
            cursor: CopyModeCursor(row: 3, column: 2),
            contentRevision: 1
        )
        _ = copyMode.handle(.init(raw: "v"), bounds: bounds)
        _ = copyMode.handle(.init(raw: "l"), bounds: bounds)
        let anchor = copyMode.anchor ?? CopyModeCursor(row: 0, column: 0)
        let range = copyMode.selectedRange(kind: .character, anchor: anchor)
        #expect(range.start.column == 2)
        #expect(range.end.column == 3)
    }
}
