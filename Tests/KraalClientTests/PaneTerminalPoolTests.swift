// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The pane pool must not let two machines share a terminal.
//
// Pane ids are scoped to one daemon. Upstream states it outright:
// "Workspace, tab, pane IDs, and agent names are scoped to one server. Two
// machines may both contain `w1:p1` or an agent named `reviewer`."
// (docs/next/website/src/content/docs/connecting-machines.mdx:118)
//
// Keying the pool on the pane id alone therefore made the two machines' `w1:p1`
// resolve to one `PaneTerminalModel` — and so to one Ghostty
// `InMemoryTerminalSession`, which carries the scrollback, the alternate-screen
// state and the cursor. Switching machines then handed the new machine a surface
// that still had the old machine's screen inside it. A full-screen program lives
// entirely in the alternate screen, so the leak showed up as its picture
// surviving into the other machine's pane.
//
// The pool now keys on `(machine, paneId)` and drops everything when the machine
// changes. These tests pin that down: identity is per machine, and a real switch
// retires the models instead of handing them over.

import Testing

@testable import KraalTerminalView

@Suite("Pane terminal pool")
@MainActor
struct PaneTerminalPoolTests {
    private func makePool() -> PaneTerminalPool {
        PaneTerminalPool { _, _ in }
    }

    /// Two machines naming the same pane is the case that caused the bug. They
    /// must get two models, not one.
    @Test("the same pane id on two machines is two terminals")
    func samePaneOnTwoMachinesIsTwoTerminals() {
        let pool = makePool()

        pool.selectMachine("machine-a")
        let fromA = pool.model(for: "w1:p1")

        pool.selectMachine("machine-b")
        let fromB = pool.model(for: "w1:p1")

        #expect(fromA !== fromB)
    }

    /// Switching machines drops the outgoing machine's terminals. This is the
    /// part that actually removes the stale screen state: the models hold the
    /// Ghostty sessions, so letting them go is what ends the leak.
    @Test("switching machines retires the previous machine's terminals")
    func switchingMachinesRetiresModels() {
        let pool = makePool()

        pool.selectMachine("machine-a")
        let first = pool.model(for: "w1:p1")

        pool.selectMachine("machine-a")
        // Staying put must not churn surfaces: this runs on every layout pass.
        #expect(pool.model(for: "w1:p1") === first)

        pool.selectMachine("machine-b")
        // Coming back to A is a fresh terminal, not the one from before the
        // switch — that session belonged to a machine we are no longer on.
        pool.selectMachine("machine-a")
        #expect(pool.model(for: "w1:p1") !== first)
    }

    /// Within one machine the pool still caches, which is what keeps a pane's
    /// surface alive across ordinary layout passes.
    @Test("panes are reused within one machine")
    func panesAreReusedWithinOneMachine() {
        let pool = makePool()
        pool.selectMachine("machine-a")

        let first = pool.model(for: "w1:p1")
        #expect(pool.model(for: "w1:p1") === first)
        #expect(pool.model(for: "w1:p2") !== first)
    }

    /// Pruning is about panes closing, and must not depend on the machine key:
    /// a pane that is gone from the surface is gone whatever machine it was on.
    @Test("pruning drops only the panes that are gone")
    func pruningDropsOnlyClosedPanes() {
        let pool = makePool()
        pool.selectMachine("machine-a")

        let kept = pool.model(for: "w1:p1")
        _ = pool.model(for: "w1:p2")

        pool.prune(keeping: ["w1:p1"])

        #expect(pool.model(for: "w1:p1") === kept)
    }
}
