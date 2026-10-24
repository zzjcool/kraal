// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  KittyGraphicsResponseTests.swift
//  KraalProtocolTests
//
//  The terminal's replies to kitty graphics commands must never become input.
//
//  Measured (issue #110, 2026-10-25): with `q=0` Ghostty writes
//  `ESC _ G i=367726,p=343071;OK ESC \` back through the same channel as keystrokes.
//  Kraal's encoder uses `q=2`, so this does not happen today — the guard exists for
//  the day `directGraphics` is turned on, and because the failure mode is keys
//  silently turning into nonsense (docs/DEBUGGING.md §9).
//

import Foundation
import Testing

@testable import KraalProtocol

struct KittyGraphicsResponseTests {
    private func codes(_ events: [ClientPaneInputEvent]) -> [String] {
        events.map { event in
            switch event {
            case let .textCommit(text): "text(\(text))"
            case let .paste(text): "paste(\(text))"
            case let .key(code, modifiers, _, _, _, _, _, _, _):
                "key(\(code), m\(modifiers))"
            case let .mouse(kind, _, _, _, _): "mouse(\(kind))"
            }
        }
    }

    // MARK: - kitty graphics responses (issue #110)

    /// A kitty `OK`/error response must never become input.
    ///
    /// Measured (2026-10-25): when the graphics command asks for a reply (`q=0`),
    /// Ghostty writes `ESC _ G i=367726,p=343071;OK ESC \` back through
    /// `InMemoryTerminalSession.write`, which is the same channel as keystrokes.
    /// Without this, `routeInput` forwards it to the daemon and the program receives
    /// a burst of nonsense keys — the shape of `tracksRelease` (docs/DEBUGGING.md
    /// §9), where the symptom was keys silently disappearing.
    ///
    /// Kraal's own encoder uses `q=2` (silent), so today these bytes do not occur;
    /// they will the moment `directGraphics` is turned on, which is why the guard
    /// belongs here rather than in a comment.
    @Test("a kitty graphics response is not input")
    func kittyResponseIsDropped() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data("\u{1B}_Gi=367726,p=343071;OK\u{1B}\\".utf8))
        #expect(codes(events) == [], "a kitty response was decoded as \(codes(events))")
    }

    /// The error form has the same shape and must go the same way.
    @Test("a kitty graphics error response is not input")
    func kittyErrorResponseIsDropped() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data("\u{1B}_Gi=42;EINVAL: invalid data\u{1B}\\".utf8))
        #expect(codes(events) == [], "a kitty error was decoded as \(codes(events))")
    }

    /// Keys typed after a response still arrive, in order.
    ///
    /// The dangerous fix is one that swallows the rest of the chunk; this pins that
    /// only the APC body is removed.
    @Test("keys around a kitty response survive")
    func keysAroundResponseSurvive() {
        var decoder = TerminalInputDecoder()
        let data = Data("a\u{1B}_Gi=1;OK\u{1B}\\bc".utf8)
        #expect(codes(decoder.decode(data)) == ["text(a)", "text(bc)"])
    }

    /// An Alt+`_`, typed by a human, is not an APC.
    ///
    /// `_` is a legal key and `ESC` a legal prefix, so a stripper keyed on `ESC _`
    /// alone would eat real keystrokes. Only the third byte decides, and here it is
    /// `x` rather than `G`, so it must stay a key. The genuinely hard case is the
    /// opposite one — Alt+`_` followed by a `G` — which no lookahead can distinguish
    /// from a response; `splitHeaderWaitsForTheThirdByte` covers the chunked version of
    /// that ambiguity.
    @Test("an Alt+underscore followed by text is still input")
    func altUnderscoreIsNotSpoiled() {
        var decoder = TerminalInputDecoder()
        // `ESC _` alone (Alt+_), then `x`: no APC terminator, so it is not a response.
        let events = decoder.decode(Data("\u{1B}_x".utf8))
        #expect(codes(events) == ["key(char(\"_\"), m4)", "text(x)"])
    }

    /// A whole response longer than `maxPending` is still removed.
    ///
    /// Honest note: this one passes on the old code too. A complete APC is consumed
    /// before the truncation check runs, so a *whole* long response never leaked — the
    /// leak this guards against only happens when the response arrives in pieces (see
    /// `splitLongResponseIsDropped`, which is the one that goes red without the APC
    /// exemption). It is kept because it pins the simpler property at the size where
    /// the bound actually bites, so a future refactor cannot quietly start shipping
    /// the tail of a big response as text.
    @Test("a kitty response longer than the pending buffer is dropped")
    func longResponseIsDropped() {
        var decoder = TerminalInputDecoder()
        let long = "\u{1B}_Gi=1;" + String(repeating: "x", count: 60) + "\u{1B}\\"
        let events = decoder.decode(Data(long.utf8))
        #expect(codes(events) == [], "a long response was decoded as \(codes(events))")
    }

    /// The same, delivered in two chunks. The split lands inside the content, so the
    /// first chunk leaves `pending` over the bound — which is exactly when a naive
    /// truncation used to leak.
    @Test("a long kitty response split across chunks is dropped")
    func splitLongResponseIsDropped() {
        var decoder = TerminalInputDecoder()
        let long = "\u{1B}_Gi=1;" + String(repeating: "x", count: 60) + "\u{1B}\\"
        let bytes = Array(long.utf8)
        let half = bytes.count / 2
        let first = decoder.decode(Data(bytes[0 ..< half]))
        let second = decoder.decode(Data(bytes[half...]))
        #expect(codes(first + second) == [],
                "a split long response was decoded as \(codes(first + second))")
    }

    /// An APC whose header straddles the chunk boundary is not turned into Alt+`_`.
    ///
    /// Measured before the fix: `decode([ESC, _])` emitted `key(char("_"), m4)` — it
    /// invented a keystroke *and* threw away the APC header, so the second chunk came
    /// through as `text("Gi=1;OK")` plus a stray key. A silent failure, and the exact
    /// thing this whole guard exists to prevent.
    @Test("an APC header split across chunks is not a keystroke")
    func splitHeaderWaitsForTheThirdByte() {
        var decoder = TerminalInputDecoder()
        let first = decoder.decode(Data([0x1B, 0x5F]))
        let second = decoder.decode(Data("Gi=1;OK\u{1B}\\".utf8))
        #expect(codes(first) == [], "the APC header was emitted as \(codes(first))")
        #expect(codes(second) == [], "the APC body was emitted as \(codes(second))")
    }

    /// A stranded `ESC _` becomes Alt+`_` once the stream idles.
    ///
    /// The flip side of waiting for the third byte: a human who types Alt+`_` and then
    /// stops must still get their key. Without this the `_` would sit in the buffer
    /// until the next keystroke and turn it into Alt+that.
    @Test("a stranded ESC _ flushes as Alt+underscore")
    func strandedHeaderFlushes() {
        var decoder = TerminalInputDecoder()
        #expect(codes(decoder.decode(Data([0x1B, 0x5F]))) == [])
        #expect(codes(decoder.flushEscape()) == ["key(char(\"_\"), m4)"])
        // And the buffer is clear: the next key is its own key, not Alt+key.
        #expect(codes(decoder.decode(Data("x".utf8))) == ["text(x)"])
    }

    /// An ESC glued to the end of a text run is flushed, not left to Alt the next key.
    ///
    /// Measured before the fix: `decode("ab<ESC>")` returned `text("ab")` and left the
    /// ESC in `pending`; the caller only flushed when the chunk produced *nothing*, so
    /// the next key `x` became Alt+x.
    @Test("an ESC after text does not alt the next key")
    func escapeAfterTextDoesNotLeak() {
        var decoder = TerminalInputDecoder()
        let events = decoder.decode(Data("ab\u{1B}".utf8))
        #expect(codes(events) == ["text(ab)"])
        #expect(codes(decoder.flushEscape()) == ["key(esc, m0)"])
        #expect(codes(decoder.decode(Data("x".utf8))) == ["text(x)"])
    }

    /// A never-terminated APC cannot lock the input stream forever.
    ///
    /// The APC exemption from `maxPending` has its own bound. Without one, the APC sits
    /// at the head of `pending`, `index` never advances, and every later chunk is
    /// appended and rescanned without producing an event — every keystroke after that
    /// point would silently stop reaching the program (issue #110 review, B1).
    @Test("an unterminated APC does not lock the input stream")
    func unterminatedAPCDoesNotLockInput() {
        var decoder = TerminalInputDecoder()
        _ = decoder.decode(Data("\u{1B}_Gi=1;".utf8))
        // Feed far more than the APC bound, as a stuck peer would.
        for _ in 0 ..< 200 {
            _ = decoder.decode(Data(String(repeating: "x", count: 64).utf8))
        }
        // The buffer has been dropped, so this key still arrives.
        let events = decoder.decode(Data("z".utf8))
        #expect(codes(events).contains("text(z)"),
                "the decoder stopped delivering input after an unterminated APC")
    }

    /// A response split across two chunks is still removed.
    ///
    /// The terminal writes in whatever sizes it likes; a stripper that only handled
    /// whole APCs in one buffer would leak the tail as keys.
    @Test("a kitty response split across chunks is dropped")
    func splitResponseIsDropped() {
        var decoder = TerminalInputDecoder()
        let first = decoder.decode(Data("\u{1B}_Gi=1;O".utf8))
        let second = decoder.decode(Data("K\u{1B}\\".utf8))
        #expect(codes(first + second) == [], "split response decoded as \(codes(first + second))")
    }

    /// An unfinished escape that never grows is still bounded away.
    ///
    /// The `maxPending` exemption is for APCs only; a lone `ESC` must not accumulate
    /// forever. This pins that the original guard still does its job.
    @Test("a lone escape is still bounded by maxPending")
    func loneEscapeIsStillBounded() {
        var decoder = TerminalInputDecoder()
        for _ in 0 ..< 40 {
            _ = decoder.decode(Data([0x1B]))
        }
        // Nothing asserted about the events: the point is it returns and the buffer
        // did not grow without bound. A following key still decodes.
        let events = decoder.decode(Data("z".utf8))
        #expect(codes(events).contains("text(z)"), "decoder stalled after lone escapes")
    }
}
