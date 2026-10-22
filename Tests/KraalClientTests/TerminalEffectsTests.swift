// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Tests for the four terminal events that used to be dropped.
//
// The reason these exist as `swift test` rather than only a GUI case: the whole
// point of the bug is that the events arrived, decoded correctly, and then went
// nowhere. A test that a `ConnectionEvent` produces a clipboard write is only
// possible because the reduction is a pure value function — the AppKit side
// (`TerminalEffectsApplier`) is not asserted here, and saying so is the honest
// thing rather than pretending a passing test proves the pasteboard was written.
//

import Testing

@testable import KraalClient
@testable import KraalProtocol
@testable import KraalUI

@Suite("Terminal effects")
@MainActor
struct TerminalEffectsTests {
    private func reduce(
        _ effects: TerminalEffects = .none,
        event: ConnectionEvent,
        fallback: String = "Local",
        suffix: String = ""
    ) -> TerminalEffects {
        TerminalEffectsReducer.reduce(
            effects,
            event: event,
            fallbackTitle: fallback,
            sessionSuffix: suffix
        )
    }

    /// OSC 52 is the one that was outright broken: `herdr` decodes the escape
    /// sequence in the pane and forwards the payload, and this client dropped it
    /// on the floor, so a remote `pbcopy` did nothing.
    ///
    /// The payload is **base64 on the wire** (`wire.rs:1421-1424`). The first
    /// version of this test passed `"hello"` and asserted `"hello"` came out,
    /// which is why it agreed with a bug that put the base64 blob itself on the
    /// pasteboard: it asserted my own value, not the daemon's encoding. The
    /// fixture is now what the daemon actually sends.
    @Test("clipboard event decodes the base64 payload from the wire")
    func clipboardBecomesEffect() {
        // "hello" in base64
        let next = reduce(event: .clipboard(data: "aGVsbG8="))
        #expect(next.clipboard == "hello")
        #expect(!next.isEmpty)
    }

    /// Pinned because this is the exact mistake that shipped: writing the raw
    /// payload puts `S1JBQUxfT1NDNTJfT0s=` on the pasteboard, which pastes
    /// successfully and is garbage.
    @Test("the base64 blob itself never reaches the clipboard")
    func clipboardIsNotLeftEncoded() {
        let next = reduce(event: .clipboard(data: "S1JBQUxfT1NDNTJfT0s="))
        #expect(next.clipboard == "KRAAL_OSC52_OK")
        #expect(next.clipboard != "S1JBQUxfT1NDNTJfT0s=")
    }

    @Test("an undecodable payload produces no clipboard effect")
    func invalidBase64Dropped() {
        let next = reduce(event: .clipboard(data: "not base64!!!"))
        #expect(next.clipboard == nil)
        #expect(next.isEmpty)
    }

    /// Two writes in one batch: the pasteboard can only hold the last one, and
    /// modelling that keeps a consumer from believing it can replay both.
    @Test("the last clipboard write in a batch wins")
    func clipboardLastWins() {
        var effects = reduce(event: .clipboard(data: "Zmlyc3Q="))
        effects = reduce(effects, event: .clipboard(data: "c2Vjb25k"))
        #expect(effects.clipboard == "second")
    }

    /// An empty payload is a legitimate "copy nothing" — e.g. `pbcopy < /dev/null`.
    /// It has to clear the clipboard rather than be ignored, or the previous
    /// contents look stuck.
    @Test("an empty clipboard payload is an effect, not a no-op")
    func emptyClipboardIsAnEffect() {
        let next = reduce(event: .clipboard(data: ""))
        #expect(next.clipboard == "")
        #expect(!next.isEmpty)
    }

    @Test("window title is rendered with the session suffix")
    func windowTitleRendered() {
        let next = reduce(event: .windowTitle("vim README.md"), suffix: " — dev-abc")
        #expect(next.reportedTitle == "vim README.md")
        #expect(next.windowTitle == "vim README.md — dev-abc")
    }

    /// A pane with no title falls back to the machine label. Blank and nil are
    /// the same state: a TUI clearing its title mid-redraw must not blank the
    /// window for a frame.
    @Test("a blank title falls back to the machine label")
    func blankTitleFallsBack() {
        let next = reduce(event: .windowTitle("   "), fallback: "vps-01")
        #expect(next.reportedTitle == nil)
        #expect(next.windowTitle == "vps-01")
    }

    /// Re-sending the same title is not a change. Panes re-emit their title on
    /// redraws, and setting `NSWindow.title` every frame makes AppKit invalidate
    /// the titlebar.
    @Test("an unchanged title produces no new effect")
    func unchangedTitleIsDropped() {
        let first = reduce(event: .windowTitle("zsh"))
        let second = reduce(first, event: .windowTitle("zsh"))
        #expect(second == first)
    }

    /// ...but nil → "" is not a change either, because they mean the same thing.
    @Test("nil and empty count as the same title")
    func nilAndEmptyAreEquivalent() {
        let withNil = reduce(event: .windowTitle(nil), fallback: "Local")
        let withEmpty = reduce(withNil, event: .windowTitle(""), fallback: "Local")
        #expect(withEmpty == withNil)
    }

    /// Bells are coalesced. A pane in a loop can emit thousands per frame, and
    /// honouring the exact count turns a runaway program into a hang.
    @Test("bells are coalesced instead of played per character")
    func bellsCoalesce() {
        var effects = reduce(event: .bell(count: 500))
        #expect(effects.bells == TerminalEffectsReducer.maxBells)
        effects = reduce(effects, event: .bell(count: 3))
        #expect(effects.bells == TerminalEffectsReducer.maxBells)
    }

    @Test("a zero-count bell is not an effect")
    func zeroBellIgnored() {
        let next = reduce(event: .bell(count: 0))
        #expect(next.isEmpty)
    }

    @Test("a notification is kept for the UI")
    func notificationKept() {
        let notification = SemanticNotification(kind: .finished, title: "build done")
        let next = reduce(event: .notification(notification))
        #expect(next.notification == notification)
    }

    /// `updateInstalled` describes the daemon's own binary, not something this
    /// machine's user needs to be interrupted for.
    @Test("updateInstalled notifications are filtered out")
    func updateInstalledFiltered() {
        let notification = SemanticNotification(kind: .updateInstalled, title: "updated")
        let next = reduce(event: .notification(notification))
        #expect(next.notification == nil)
        #expect(next.isEmpty)
    }

    /// Events that carry no effect must not disturb the pending batch: a surface
    /// frame arriving between a clipboard write and its application is routine.
    @Test("unrelated events leave the batch untouched")
    func unrelatedEventsAreIgnored() {
        let pending = TerminalEffects(
            clipboard: "text",
            windowTitle: nil,
            reportedTitle: nil,
            bells: 0,
            notification: nil
        )
        let next = reduce(pending, event: .mouseCapture(enabled: true, sgrPixels: false))
        #expect(next == pending)
    }
}

@Suite("Window title template")
struct WindowTitleTemplateTests {
    @Test("a reported title wins over the fallback")
    func reportedWins() {
        #expect(WindowTitleTemplate.title(reported: "make", fallback: "Local", sessionSuffix: "") == "make")
    }

    @Test("blank reported title uses the fallback")
    func blankUsesFallback() {
        #expect(WindowTitleTemplate.title(reported: " \n\t", fallback: "vps-01", sessionSuffix: "") == "vps-01")
    }

    @Test("an empty fallback still yields a usable title")
    func emptyFallbackStillTitled() {
        #expect(WindowTitleTemplate.title(reported: nil, fallback: "", sessionSuffix: "") == "Kraal")
    }

    @Test("the session suffix is appended verbatim")
    func suffixAppended() {
        #expect(WindowTitleTemplate.title(reported: "htop", fallback: "Local", sessionSuffix: " — dev-abc")
            == "htop — dev-abc")
    }

    @Test("only a real difference counts as a change")
    func changeDetection() {
        #expect(!WindowTitleTemplate.isChange(from: nil, to: ""))
        #expect(!WindowTitleTemplate.isChange(from: "a", to: " a "))
        #expect(WindowTitleTemplate.isChange(from: "a", to: "b"))
        #expect(WindowTitleTemplate.isChange(from: nil, to: "a"))
    }
}
