// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalHC
import Testing

@testable import KraalHCTerminal

@Suite("Credit gate")
struct HcCreditGateTests {
    private final class FakeStream: HcByteStream, @unchecked Sendable {
        private let lock = NSLock()
        private var credits: [Int] = []
        func credit(_ bytes: Int) {
            lock.lock()
            credits.append(bytes)
            lock.unlock()
        }

        func resize(columns _: Int, rows _: Int) {}
        func focus(_: Bool) {}
        func close() {}
        var isClosed: Bool { false }

        var credited: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return credits
        }
    }

    @Test("holds credit until the pane has a surface")
    func waitsForSurface() {
        let stream = FakeStream()
        let gate = HcCreditGate()
        gate.connect(stream)

        gate.received(100)
        gate.received(28)
        #expect(stream.credited.isEmpty)
        #expect(gate.outstanding == 128)

        gate.surfaceReady()
        #expect(stream.credited == [128])
        #expect(gate.outstanding == 0)
    }

    @Test("stops crediting while the parser is backlogged")
    func holdsWhileBacklogged() {
        let stream = FakeStream()
        let gate = HcCreditGate()
        gate.connect(stream)
        gate.surfaceReady()

        gate.setBacklogged(true)
        gate.received(4096)
        #expect(stream.credited.isEmpty)

        gate.setBacklogged(false)
        #expect(stream.credited == [4096])
    }

    @Test("credits one sum, not one frame per chunk")
    func batches() {
        let stream = FakeStream()
        let gate = HcCreditGate()
        gate.connect(stream)
        gate.surfaceReady()
        gate.setBacklogged(true)

        gate.received(10)
        gate.received(20)
        gate.received(30)
        gate.setBacklogged(false)

        #expect(stream.credited == [60])
    }

    @Test("ignores empty and negative acknowledgements")
    func ignoresEmpty() {
        let stream = FakeStream()
        let gate = HcCreditGate()
        gate.connect(stream)
        gate.surfaceReady()

        gate.received(0)
        gate.received(-5)
        #expect(stream.credited.isEmpty)
    }
}
