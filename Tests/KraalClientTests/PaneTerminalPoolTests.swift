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

    /// A popup is not a pane, so `prune(keeping:)` must leave it alone: its id is
    /// never in `paneIds`, and a key that compared against `paneIds` would drop the
    /// popup's Ghostty surface every time any pane opened or closed — throwing away
    /// its image cache mid-display.
    @Test("pruning panes keeps popups alive")
    func pruningPanesKeepsPopups() {
        let pool = makePool()

        pool.selectMachine("m")
        let popup = pool.model(for: "term-1", isPopup: true)
        _ = pool.model(for: "w1:p1")

        pool.prune(keeping: [])

        #expect(pool.model(for: "term-1", isPopup: true) === popup,
                "pruning panes dropped the popup's terminal")
    }

    /// The other half: a closed popup's terminal has to be released, or every popup
    /// ever opened leaves a Ghostty surface behind. This is the leak that a
    /// `"popup:<id>"` key caused — it never matched `paneIds`, so nothing ever
    /// removed it.
    @Test("a closed popup's terminal is released")
    func closedPopupIsReleased() {
        let pool = makePool()

        pool.selectMachine("m")
        let popup = pool.model(for: "term-1", isPopup: true)

        pool.prunePopups(keeping: [])

        #expect(pool.model(for: "term-1", isPopup: true) !== popup,
                "a closed popup left its terminal (and its surface) behind")
    }

    /// And a pane's id must not collide with a popup's: sharing one model would give
    /// them one image-id space, where one side's delete removes the other's picture.
    @Test("a popup and a pane with the same id are two terminals")
    func popupAndPaneWithSameIdAreTwoTerminals() {
        let pool = makePool()

        pool.selectMachine("m")
        let pane = pool.model(for: "term-1")
        let popup = pool.model(for: "term-1", isPopup: true)

        #expect(pane !== popup)
    }
}
