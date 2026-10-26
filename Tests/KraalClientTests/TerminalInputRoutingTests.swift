// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  TerminalInputRoutingTests.swift
//  KraalClientTests
//
//  How `AppStore.sendInput` routes keystrokes: which decoder, and what is flushed.
//
//  Two behaviours here were bugs that reached users:
//
//  * **A stranded `ESC` at the end of a chunk.** `sendInput` used to flush only when
//    the chunk produced no events. A chunk ending `"ab<ESC>"` yields `text("ab")` *and*
//    leaves the ESC, so the ESC stayed in the decoder and turned the *next* keystroke
//    into Alt+key (#110 review, M1). The fix was to flush unconditionally.
//  * **One decoder per (machine, terminal), not per pane id.** Pane ids repeat across
//    daemons, so a single dictionary keyed by pane id made two machines share half
//    parsed escape sequences.
//
//  Both are observable without a connection: the decoder table is store state, and
//  `sendInput` updates it before it ever looks at `connection`.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Terminal input routing")
@MainActor
struct TerminalInputRoutingTests {
    private func store(bootId: String) -> AppStore {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        store.surface = PaneSurfaceFrame(
            bootId: bootId,
            projectionRevision: 1,
            surfaceRevision: 1,
            frame: FrameData(
                cells: [.blank], width: 1, height: 1,
                cursor: nil, hyperlinks: [], graphics: Data()
            ),
            panes: [], splits: [], popup: nil,
            graphics: SurfaceGraphicsScene()
        )
        return store
    }

    private func key(for terminal: String, in store: AppStore) -> AppStore.InputDecoderKey {
        AppStore.InputDecoderKey(machine: store.surface?.bootId ?? "", terminal: terminal)
    }

    /// The whole point of flushing unconditionally: nothing may be left waiting.
    ///
    /// Sending `ab<ESC>` must consume the trailing ESC as a real key event rather than
    /// parking it, so the next keystroke starts from a clean state.
    @Test("a chunk ending in ESC leaves nothing parked")
    func trailingEscapeIsFlushed() throws {
        let store = store(bootId: "boot")
        store.sendInput(Data([0x61, 0x62, 0x1B]), to: "w1:p1")

        let key = key(for: "w1:p1", in: store)
        var decoder = try #require(store.inputDecoders[key])
        // If the ESC had been left in the buffer, flushing now would produce it — so a
        // second flush must be empty.
        let stranded = decoder.flushEscape()
        #expect(stranded.isEmpty,
                "an ESC was parked in the decoder and would prefix the next keystroke")
        // And the decoder state is stored back, so the next `sendInput` continues it.
        #expect(store.inputDecoders[key] != nil)
    }

    /// A plain chunk with no ESC must not produce a spurious ESC event when flushed.
    @Test("a plain chunk produces no stray event on flush")
    func plainChunkHasNoStray() throws {
        let store = store(bootId: "boot")
        store.sendInput(Data([0x61]), to: "w1:p1")
        let key = key(for: "w1:p1", in: store)
        var decoder = try #require(store.inputDecoders[key])
        #expect(decoder.flushEscape().isEmpty)
    }

    /// Two machines that both have a pane called `w1:p1` must not share a decoder.
    ///
    /// The key carries the daemon's boot id for exactly this reason. Sharing one
    /// decoder let a half-parsed escape sequence from one machine be completed by the
    /// other machine's bytes.
    @Test("the same pane id on two machines gets two decoders")
    func machinesDoNotShareDecoders() {
        let first = store(bootId: "machine-a")
        first.sendInput(Data([0x61]), to: "w1:p1")
        let firstKey = key(for: "w1:p1", in: first)

        let second = store(bootId: "machine-b")
        second.sendInput(Data([0x62]), to: "w1:p1")
        let secondKey = key(for: "w1:p1", in: second)

        #expect(firstKey != secondKey,
                "the decoder key ignores the machine, so two daemons would share state")
    }

    /// Each terminal keeps its own decoder: a popup's escape sequence must not be
    /// completed against a pane's buffer.
    @Test("two terminals get two decoders")
    func terminalsDoNotShareDecoders() {
        let store = store(bootId: "boot")
        store.sendInput(Data([0x1B]), to: "w1:p1")
        store.sendInput(Data([0x61]), to: "w1:p2")
        #expect(key(for: "w1:p1", in: store) != key(for: "w1:p2", in: store))
        #expect(store.inputDecoders.count == 2,
                "two terminals collapsed into one decoder")
    }

    /// Before the first snapshot there is no boot id. That must collapse into a single
    /// "unknown machine" bucket rather than crash or produce a per-call key.
    @Test("no surface yet still yields one stable key")
    func missingBootIdStillKeys() {
        let store = AppStore(target: .local)
        store.endpoints = [EndpointState(id: .local, label: "Local", settings: .local)]
        store.activeEndpointID = .local
        #expect(store.surface == nil)

        store.sendInput(Data([0x61]), to: "w1:p1")
        store.sendInput(Data([0x62]), to: "w1:p1")
        #expect(store.inputDecoders.count == 1,
                "the same terminal produced more than one decoder before the first snapshot")
    }
}
