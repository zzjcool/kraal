// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Regression tests for "the pane action must act on the pane the menu was
// raised over".
//
// The bug: right-clicking a pane and choosing Split Right / Split Down / Close
// Pane did nothing visible. The menu *did* carry the pane id (`NSMenu.paneId`,
// set in `PaneContextMenuBar`), and `runCommand` did try to adopt it:
//
//     if let paneId = sender.menu?.owningPaneId, command.isPaneScoped {
//         store.focus(paneId: paneId)          // <- asynchronous
//     }
//     KraalUI.perform(command, on: store, env: commandEnvironment())
//
// `focus(paneId:)` only *sends* a request on a `Task`. `perform` then ran
// synchronously, and `actionPaneId` reads `snapshot.focusedPaneId` — still the
// previous value, because the focus round-trip had not completed. So every
// pane-scoped command aimed at whichever pane was focused *before* the click.
//
// With several machines connected the symptom gets worse, not better: the pane
// the user clicked and the pane the command hit can belong to different
// daemons, so the action is not merely wrong, it is invisible. That is how it
// was reported: split and close in an `iherdr` workspace appeared dead.
//
// The fix is to stop treating focus as a pre-command side effect and pass the
// pane id through `CommandEnvironment.targetPaneId`, which `perform` reads
// synchronously. These tests pin the resolution rule, which is the part that
// can silently regress: the precedence between the menu's pane and the
// focused one.

import Testing

import KraalProtocol
@testable import KraalUI

@Suite("Context menu pane targeting")
struct ContextMenuTargetingTests {
    /// The case the bug was reported against: a context menu always wins over
    /// the focused pane, because a right-click names its target.
    @Test("a menu's own pane beats the focused pane")
    func menuPaneWins() {
        let resolved = AppCommands.resolveTargetPane(
            contextPaneId: "wS:p1",
            focusedPaneId: "wT:p1"
        )

        #expect(resolved == "wS:p1")
    }

    /// The menu bar has no pane of its own, so its commands mean "the focused
    /// one" — the behaviour that was already right.
    @Test("without a context pane the focused pane is used")
    func fallsBackToFocusedPane() {
        let resolved = AppCommands.resolveTargetPane(
            contextPaneId: nil,
            focusedPaneId: "wT:p1"
        )

        #expect(resolved == "wT:p1")
    }

    /// Nothing focused, nothing named: the command has no target and must be
    /// skipped rather than guessing.
    @Test("no context pane and no focus resolves to nothing")
    func resolvesToNil() {
        #expect(AppCommands.resolveTargetPane(contextPaneId: nil, focusedPaneId: nil) == nil)
    }

    /// An empty string is what `NSMenu.paneId` yields for a menu that was never
    /// given a pane; it must not be treated as a real id, or the request goes
    /// out naming a pane that cannot exist.
    @Test("an empty context pane is treated as absent")
    func emptyContextPaneIsAbsent() {
        let resolved = AppCommands.resolveTargetPane(
            contextPaneId: "",
            focusedPaneId: "wT:p1"
        )

        #expect(resolved == "wT:p1")
    }

    /// The command list the resolution applies to. If a pane command is missing
    /// here, `runCommand` never passes its context pane and the bug returns for
    /// that one command only — the hardest kind to notice again.
    @Test("the pane-scoped command list covers split, close, zoom, clear and rename")
    func paneScopedListIsComplete() {
        let scoped: Set<AppCommand> = [
            .splitRight, .splitDown, .closePane, .toggleZoom, .clearPane, .renamePane,
        ]

        for command in scoped {
            #expect(AppCommand.paneScopedCommands.contains(command))
        }
    }

    /// And symmetrically: a tab or workspace command must not be pane-scoped, or
    /// it would carry a pane id into an action that does not take one.
    @Test("tab and workspace commands are not pane-scoped")
    func nonPaneCommandsAreExcluded() {
        let notScoped: Set<AppCommand> = [
            .newTab, .closeTab, .renameTab, .newWorkspace, .closeWorkspace,
            .renameWorkspace, .settings, .commandPalette,
        ]

        for command in notScoped {
            #expect(!AppCommand.paneScopedCommands.contains(command))
        }
    }
}
