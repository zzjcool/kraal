// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Issue #70, part (b): making "was this session new?" visible.
//
// The honest answer is that it is not derivable from `herdr machine add`, so
// there is nothing to assert about a "sessionCreated" flag. What *can* be pinned
// is that the CLI's text reaches the log verbatim — including the case where the
// CLI prints nothing at all — so a bug report contains the evidence even though
// Kraal drew no conclusion from it.
//
// Verified against herdr 0.9.5 source (`src/cli/machine.rs:388-389`) and by
// running the binary: every successful add prints exactly
//
//     Saved SSH machine <32-hex id>. Remote server is ready.
//     Open Herdr clients connect automatically.
//
// with no variation for a session that already existed versus one that was just
// created. `machine add --remote-session X` never asks the remote for its session
// list either (that query runs only when `--remote-session` is omitted *and* both
// stdin and stderr are terminals), so the CLI itself does not know.

import Foundation
import Testing

@testable import KraalUI

@Suite("Machine add log line")
struct MachineAddReportTests {
    /// The exact text herdr 0.9.5 prints, from the source cited above.
    private let upstreamOutput = """
    Saved SSH machine 0123456789abcdef0123456789abcdef. Remote server is ready.
    Open Herdr clients connect automatically.

    """

    /// Every line the CLI printed must survive into the log. Parsing it into a
    /// `sessionCreated: Bool` would be inventing a signal that is not there.
    @Test("every line of CLI output is recorded")
    func outputIsRecordedVerbatim() {
        let line = addReport(target: "admin@127.0.0.1", session: "work", output: upstreamOutput)

        #expect(line.contains("Saved SSH machine 0123456789abcdef0123456789abcdef. Remote server is ready."))
        #expect(line.contains("Open Herdr clients connect automatically."))
        // Newlines are folded so one event stays one log line; the text itself is
        // not altered or dropped.
        #expect(!line.contains("\n"), "the log line must be one entry: \(line)")
        #expect(line.contains(" | "), "the two CLI lines must be joined, not lost: \(line)")
    }

    /// The session name and target belong in the line: without them the output is
    /// identical for every machine, which is exactly the ambiguity being reported.
    @Test("the line names the target and the session it was added with")
    func lineIdentifiesTheAttempt() {
        let line = addReport(target: "admin@127.0.0.1", session: "wrok", output: upstreamOutput)

        #expect(line.contains("admin@127.0.0.1"))
        #expect(line.contains("session=wrok"))
    }

    /// An empty output is stated as such rather than leaving a bare arrow. Some
    /// CLI versions print nothing on success, and "no output" is evidence too.
    @Test("silent CLI output is reported, not swallowed")
    func silentOutputIsExplicit() {
        let line = addReport(target: "host", session: "default", output: "")
        #expect(line.contains("<herdr said nothing>"))
    }

    /// Both shapes produce a different line only because of the text herdr
    /// printed — never because Kraal inferred a creation. This pins the absence of
    /// a fabricated "session was created" claim: the two identical outputs must
    /// produce identical lines, so nothing downstream can tell the cases apart.
    @Test("identical CLI output produces identical log lines")
    func identicalOutputCannotImplyDifferentOutcomes() {
        let first = addReport(target: "host", session: "work", output: upstreamOutput)
        let second = addReport(target: "host", session: "work", output: upstreamOutput)

        #expect(first == second)
        #expect(!first.lowercased().contains("created"))
        #expect(!first.lowercased().contains("new session"))
    }
}
