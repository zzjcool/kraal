// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Pane ids are scoped to one daemon: two machines may both contain `w1:p1`
// (`docs/ENVIRONMENT.md` §2, upstream `connecting-machines.mdx:118`).
//
// `PaneTerminalPool` keys on `(machine, paneId)` for exactly this reason. The
// input decoder table in `AppStore` did not, and that table is not stateless:
// `TerminalInputDecoder` keeps a `pending` buffer of half-received escape
// sequences between calls, so two machines sharing one decoder share that
// buffer too — a partial CSI typed on one machine gets completed by a byte typed
// on the other, and the second machine receives a key nobody pressed.
//
// These tests pin both the failure and the key that fixes it, without a GUI, a
// VM, or two live daemons.

import Foundation
import KraalProtocol
import Testing

@testable import KraalUI

@Suite("Cross-machine input")
struct CrossMachineInputTests {
    /// The decoder really is stateful across calls — this is why a shared table
    /// entry is a bug rather than an inconvenience.
    @Test("one decoder carries a partial CSI into the next call")
    func aSingleDecoderCarriesState() {
        var decoder = TerminalInputDecoder()
        // ESC '[' is a CSI introducer with no final byte yet: nothing to emit.
        #expect(decoder.decode(Data([0x1B])).isEmpty)
        #expect(decoder.decode(Data([0x5B])).isEmpty)

        // The next byte completes machine A's sequence instead of being its own
        // keystroke. Whatever it decodes to, it is *not* a plain "A".
        let events = decoder.decode(Data([0x41]))
        let isPlainTextCommit: Bool = {
            guard events.count == 1, case let .textCommit(text) = events[0] else { return false }
            return text == "A"
        }()
        #expect(!isPlainTextCommit, "the buffer was expected to swallow the byte into a CSI")
    }

    /// The fix: two machines get two decoders, so machine B's `A` stays an `A`.
    @Test("a decoder per machine keeps machine B's keystroke intact")
    func perMachineDecodersAreIndependent() {
        var machineA = TerminalInputDecoder()
        var machineB = TerminalInputDecoder()

        #expect(machineA.decode(Data([0x1B])).isEmpty)
        #expect(machineA.decode(Data([0x5B])).isEmpty)

        let events = machineB.decode(Data([0x41]))
        #expect(events.count == 1)
        guard case let .textCommit(text) = events[0] else {
            Issue.record("expected a text commit, got \(events[0])")
            return
        }
        #expect(text == "A")
    }

    /// The key the store now uses. A test on the key rather than on the store
    /// because the store needs a live connection to exercise `sendInput`, while
    /// the whole bug is that the key was too narrow.
    @Test("the input decoder key separates the same pane id on two machines")
    func keySeparatesMachines() {
        let onA = AppStore.InputDecoderKey(machine: "1111-aaa", terminal: "w1:p1")
        let onB = AppStore.InputDecoderKey(machine: "2222-bbb", terminal: "w1:p1")

        #expect(onA != onB)
        #expect(onA == AppStore.InputDecoderKey(machine: "1111-aaa", terminal: "w1:p1"))
        // Same machine, different terminal: still separate.
        #expect(onA != AppStore.InputDecoderKey(machine: "1111-aaa", terminal: "w1:p2"))
    }
}
