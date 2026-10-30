// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalCLI

/// `kraal run --wait` is glued together by two pure functions: the quoting that makes
/// an argv survive one shell, and the marker parser that reads the status back out of
/// the pane. Both are testable without a daemon, which is why they are separate.
@Suite("kraal run")
struct KraalRunTests {
    @Test("a plain argument is quoted, not escaped")
    func quotesPlainArguments() {
        #expect(shellQuote("npm") == "'npm'")
        #expect(shellQuote("path/with space") == "'path/with space'")
    }

    @Test("a single quote inside an argument survives the shell")
    func quotesSingleQuotes() {
        // The one construction that breaks naive quoting — `it's` — becomes
        // `'it'\''s'`, which a POSIX shell reads as `it's`.
        #expect(shellQuote("it's") == "'it'\\''s'")
    }

    @Test("a command built from argv keeps every argument separate")
    func buildsCommand() {
        let command = ["sh", "-c", "echo hi; exit 3"].map(shellQuote).joined(separator: " ")
        #expect(command == "'sh' '-c' 'echo hi; exit 3'")
    }

    @Test("the last exit marker wins")
    func parsesTheLastMarker() {
        let text = "before\n[kraal-exit:0]\nmore\n[kraal-exit:7]\nafter"
        #expect(markerMatches(in: text) == [0, 7])
    }

    @Test("markers without a number are ignored")
    func ignoresMalformedMarkers() {
        #expect(markerMatches(in: "[kraal-exit:]").isEmpty)
        #expect(markerMatches(in: "[kraal-exit:abc]").isEmpty)
        #expect(markerMatches(in: "no marker at all").isEmpty)
    }

    @Test("a herdr response is searched for the pane id it hides")
    func findsPaneIdAnywhere() {
        // Real shapes: `pane split` nests under `result`, `tab create` reports a list.
        let split: [String: Any] = ["id": "cli:pane:split", "result": ["pane_id": "w1:p2"]]
        let tab: [String: Any] = ["result": ["tab": ["pane_ids": ["w2:p1", "w2:p2"]]]]
        #expect(firstPaneId(in: split) == "w1:p2")
        #expect(firstPaneId(in: tab) == "w2:p1")
        #expect(firstPaneId(in: ["result": ["nothing": true]]) == nil)
    }
}
