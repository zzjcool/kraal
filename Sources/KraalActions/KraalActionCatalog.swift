// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Source order follows herdr-app `src/commands.rs`: what exists, what you see,
// then the app. Keep names and argument order identical; `commands` is a wire
// contract, even though the `about` text is ours.

import Foundation

private func a(_ name: String, _ required: Bool = false) -> KraalActionArgument {
    KraalActionArgument(name, required: required)
}

private func native(_ name: String, _ args: [KraalActionArgument], _ about: String) -> KraalAction {
    KraalAction(name, args, about)
}

private func unsupportedAction(
    _ name: String,
    _ args: [KraalActionArgument],
    _ about: String,
    _ reason: String
) -> KraalAction {
    KraalAction(name, args, about, support: .unsupported(reason))
}

extension KraalActions {
    public static let all: [KraalAction] = [
        // What exists.
        native(
            "space.new",
            [a("name"), a("folder"), a("tab"), a("argv"), a("task"), a("machine")],
            "Make a space with a first tab and terminal."
        ),
        native(
            "space.close",
            [a("id"), a("confirmed")],
            "Close a space and end its terminals; scripts must pass confirmed: true."
        ),
        native(
            "space.rename",
            [a("id"), a("name")],
            "Rename a space; an empty name goes back to its folder."
        ),
        native(
            "space.move",
            [a("id", true), a("index", true)],
            "Move a space to a 1-based position."
        ),
        native(
            "tab.new",
            [a("name"), a("space"), a("folder"), a("argv"), a("task"), a("mod"), a("props")],
            "Make a tab and terminal; mod/props are rejected because Kraal has no mods."
        ),
        native(
            "tab.close",
            [a("id"), a("confirmed")],
            "Close a tab and end its terminals."
        ),
        native(
            "tab.rename",
            [a("id"), a("name")],
            "Rename a tab; an empty name returns to its number."
        ),
        native(
            "tab.move",
            [a("id", true), a("index", true)],
            "Move a tab to a 1-based position in its space."
        ),
        native(
            "pane.split",
            [a("direction", true), a("pane"), a("argv"), a("mod"), a("props")],
            "Split a pane right or down with a new terminal; mod/props are rejected."
        ),
        native(
            "pane.close",
            [a("pane")],
            "Close a pane and end its terminal."
        ),
        native(
            "terminal.open",
            [a("argv"), a("folder"), a("place"), a("name")],
            "Start a terminal in a new tab or beside the focused pane."
        ),
        native(
            "terminal.keep",
            [a("terminal", true), a("place")],
            "Give a running terminal a pane: a new tab, or right/down."
        ),
        native(
            "terminal.park",
            [a("terminal", true)],
            "Take a terminal out of the layout and let it keep running."
        ),
        native(
            "terminal.right_click",
            [a("to", true), a("terminal")],
            "Send right-clicks to the program or to Kraal's menu."
        ),
        native(
            "terminal.pin",
            [a("terminal", true), a("pinned", true)],
            "Pin or unpin an agent through the shared herdr.pinned label."
        ),
        native(
            "terminal.kill",
            [a("terminal", true)],
            "End a terminal and its sub-agents."
        ),

        // What you see.
        native(
            "space.select",
            [a("index"), a("id")],
            "Show a space by 1-based position or id."
        ),
        native("space.next", [], "Show the next space."),
        native("space.prev", [], "Show the previous space."),
        native(
            "tab.select",
            [a("index"), a("id")],
            "Show a tab by 1-based position or id."
        ),
        native("tab.settle", [a("id")], "Put a tab away until it is shown again."),
        native("tab.unsettle", [a("id")], "Bring a settled tab back."),
        native("tab.next", [], "Show the next tab."),
        native("tab.prev", [], "Show the previous tab."),
        native("pane.zoom", [a("pane")], "Show only this pane, or all panes again."),
        native(
            "pane.focus",
            [a("pane"), a("terminal")],
            "Focus a pane, or the pane showing a terminal."
        ),
        native("pane.go", [a("direction", true)], "Focus the pane left, right, up or down."),
        native("pane.swap", [a("direction", true)], "Swap with the pane left, right, up or down."),
        native("terminal.peek", [a("terminal", true)], "Peek at a running terminal over the tab."),
        native(
            "terminal.show",
            [a("terminal"), a("pane")],
            "Show a terminal in a pane for now; no terminal goes back."
        ),
        native("terminal.copy", [], "Copy the focused terminal's selection."),
        native("terminal.paste", [], "Paste text into the focused terminal."),
        unsupportedAction(
            "terminal.paste_image",
            [],
            "Paste the clipboard image as a file on the terminal's machine.",
            "Clipboard images land with the Ghostty UX work (#232)."
        ),
        native(
            "agent.focus",
            [a("terminal", true)],
            "Show an agent, including a sub-agent."
        ),
        native("agent.next", [], "Show the next agent in sidebar order."),
        native("agent.prev", [], "Show the previous agent in sidebar order."),

        // herdr-app's chrome layout is a mod system; Kraal's layout is the
        // space/tab/pane model and these actions have no equivalent.
        unsupportedAction(
            "layout.switch",
            [a("name")],
            "Show a herdr-app chrome layout.",
            "Kraal has no mod/chrome layout files."
        ),
        unsupportedAction(
            "layout.clone",
            [a("name", true), a("as")],
            "Duplicate a herdr-app chrome layout.",
            "Kraal has no mod/chrome layout files."
        ),
        unsupportedAction(
            "mod.clone",
            [a("name", true), a("as")],
            "Duplicate a mod.",
            "Kraal deliberately does not run JS mods."
        ),
        unsupportedAction(
            "layout.set",
            [a("layout", true)],
            "Replace a personal chrome layout tree.",
            "Kraal has no mod/chrome layout files."
        ),
        native(
            "layout.toggle",
            [a("id", true)],
            "Hide or show a chrome panel; Kraal handles the sidebar only."
        ),
        unsupportedAction(
            "layout.show",
            [a("id", true)],
            "Show a chrome layout node.",
            "Kraal has no mod/chrome layout files."
        ),
        unsupportedAction(
            "layout.hide",
            [a("id", true)],
            "Hide a chrome layout node.",
            "Kraal has no mod/chrome layout files."
        ),
        unsupportedAction(
            "layout.resize",
            [a("id", true), a("px"), a("weight")],
            "Size a chrome layout node.",
            "Kraal has no mod/chrome layout files."
        ),
        unsupportedAction(
            "layout.select",
            [a("stack", true), a("child", true)],
            "Show one child of a chrome stack.",
            "Kraal has no mod/chrome layout files."
        ),
        unsupportedAction(
            "layout.reset",
            [a("name")],
            "Reset a shipped chrome layout.",
            "Kraal has no mod/chrome layout files."
        ),
        unsupportedAction(
            "mod.open",
            [a("name", true)],
            "Open a mod overlay.",
            "Kraal deliberately does not run JS mods."
        ),
        unsupportedAction(
            "overlay.close",
            [a("id")],
            "Close an overlay.",
            "Kraal's native sheets and palette are not mod overlays."
        ),

        // The app.
        native("app.help", [], "Show the keys."),
        unsupportedAction(
            "app.welcome",
            [],
            "Show the welcome screen again.",
            "Kraal has no welcome mod; the empty window explains the next step."
        ),
        unsupportedAction(
            "app.whats_new",
            [],
            "Show what this release brought.",
            "Kraal has no whats-new mod."
        ),
        unsupportedAction(
            "app.feedback",
            [a("message"), a("from")],
            "Draft feedback.",
            "Kraal has no feedback endpoint."
        ),
        native("app.palette", [], "Toggle the command palette."),
        native(
            "app.settings",
            [a("section")],
            "Open settings; the section is look, keyboard, machines, alerts, privacy or updates."
        ),
        unsupportedAction(
            "app.check_updates",
            [],
            "Look for a newer app or core.",
            "Kraal has no updater; use `hc update` for the core."
        ),
        unsupportedAction(
            "app.update_core",
            [],
            "Update herdr-core.",
            "Use `hc update`; Kraal does not run an updater."
        ),
        unsupportedAction(
            "app.reset",
            [],
            "Set layouts and keys aside and return to the default screen.",
            "Kraal has no layout/key files to reset."
        ),
        native("app.theme", [a("name", true)], "Use a theme preset or theme file."),
        native("app.zoom_in", [], "Make everything bigger."),
        native("app.zoom_out", [], "Make everything smaller."),
        native("app.zoom_reset", [], "Back to normal size."),
        unsupportedAction(
            "app.update",
            [],
            "Restart into a downloaded update.",
            "Kraal has no updater."
        ),
        native("app.quit", [], "Quit Kraal."),
        native("app.hide", [], "Hide Kraal."),
        native("app.hide_others", [], "Hide other apps."),
        native("app.show_all", [], "Show all apps."),
        native("window.close", [], "Close the Kraal window."),
        native("window.minimize", [], "Minimize the Kraal window."),
        native("window.maximize", [], "Zoom the Kraal window."),
    ]
}
