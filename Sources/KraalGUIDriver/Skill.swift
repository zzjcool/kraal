// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import AppKit
import ApplicationServices
import Foundation

// `clients` and `skill`: the two commands Rex has that make a CLI self-teaching
// (`rex client ls`, `rex __internal skill`).
//
// `skill` is generated from `commandSpecs` rather than written by hand. The day a
// command is added, the guide an agent reads gains it for free; the day one is
// removed, the guide stops advertising it. Prose that describes a tool goes stale
// exactly when the tool changes, and a stale guide is worse than no guide because it
// reads like a specification.

/// `kraal-gui clients [--json]`
///
/// Several instances can be running at once (a dev build, a VM build, one launched by
/// `make run`); `find` silently picks the one with the most windows, which is wrong
/// when the caller meant a specific one. `--client PID` is the escape hatch, and this
/// command is how a caller learns the pids.
func commandClients(_ args: Arguments) -> Never {
    let name = args.string("app") ?? "Kraal"
    let clients = TargetApp.all(name: name)
    guard !clients.isEmpty else {
        fail(.harness, "no running app matching '\(name)'")
    }

    let rows = clients.map { client -> (TargetApp, Int) in
        (client, windows(of: client.pid).count)
    }
    if args.has("json") {
        let payload: [String: Any] = [
            "app": name,
            "count": rows.count,
            "clients": rows.map { ["pid": Int($0.0.pid), "name": $0.0.name, "windows": $0.1] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { fail(.harness, "cannot serialise the client list") }
        print(json)
        exit(Exit.success.rawValue)
    }

    for (client, count) in rows {
        print("\(client.pid)\t\(count) window\(count == 1 ? "" : "s")\t\(client.name)")
    }
    exit(Exit.success.rawValue)
}

/// Resolves the app to act on: `--client PID` when given, otherwise the usual
/// best-candidate match.
func resolveClient(_ args: Arguments) -> TargetApp {
    guard let raw = args.string("client") else {
        return actionApp(args)
    }
    guard let pid = pid_t(raw) else {
        fail(.harness, "--client takes a pid; list them with `clients`")
    }
    let name = args.string("app") ?? "Kraal"
    guard let match = TargetApp.all(name: name).first(where: { $0.pid == pid }) else {
        let known = TargetApp.all(name: name).map { String($0.pid) }.joined(separator: ", ")
        fail(.harness, "no instance with pid \(pid); running: \(known.isEmpty ? "none" : known)")
    }
    return match
}

/// The rules that make a GUI run worth believing, distilled from `AGENTS.md` and
/// `docs/DEBUGGING.md`. Short on purpose: a guide an agent skims beats a guide it
/// skips, and every line here corresponds to a failure that actually happened.
private let honestyRules = """
1. "It printed ok" is not evidence. Assert daemon state before and after
   (`herdr pane list`, `herdr pane layout`); a command that returns 0 while nothing
   changed is the most expensive kind of bug in this repo. (AGENTS.md §0.2)
2. A gate that cannot fail is not a gate. Inject the defect, watch the assertion go
   red, then restore it. (AGENTS.md §0.3)
3. Two coordinate spaces, never mixed: `--at` is window-relative, `--at-screen` is
   screen points (the space `window` and `ax --json` print).
4. `AXPress` works without the app being frontmost; synthetic clicks and key events
   do not. When the screen is locked nothing can be frontmost — that is an
   environment problem, not a product bug (exit 2).
5. Screenshots are colour-managed: a theme colour logged as `F2E5BC` can capture as
   `F2E4BC`. Compare with a tolerance, never exactly.
6. For mouse/keyboard work, the program's own report is the truth. `Scripts/tui-mouse-probe.py`
   echoes what a TUI was told; pixels only show what it drew.
"""

/// `kraal-gui skill [--actions]`
///
/// `--actions` asks the running app for its live catalog, which is the only part of
/// the guide that depends on the app; without it the guide still works (there is no
/// Kraal running on a build machine), and says so instead of pretending.
func commandSkill(_ args: Arguments) -> Never {
    var lines: [String] = []
    lines.append("# Kraal — driving it from an agent")
    lines.append("")
    lines.append("Kraal is a macOS client for the **herdr** daemon. Two targets, two tools:")
    lines.append("")
    lines.append("- **server state** (sessions, tabs, panes, their text): the `herdr` CLI.")
    lines.append("  `herdr --help`, `herdr pane --help`, `herdr pane read --format ansi`,")
    lines.append("  `herdr pane wait-output --regex`, `herdr api snapshot`.")
    lines.append("- **the app's own interface** (window, menus, focus): this binary. It speaks only")
    lines.append("  AppKit + the Accessibility API, so it can only do what a human could do.")
    lines.append("")
    lines.append("## Discover actions instead of guessing")
    lines.append("")
    lines.append("The app's menu bar *is* the action catalog; `actions` reads it.")
    lines.append("")
    lines.append("```sh")
    lines.append("kraal-gui actions --json              # 71+ items with path + enabled")
    lines.append("kraal-gui do --item \"Split Right\"     # press one, by name")
    lines.append("kraal-gui do --path \"View > Split Right\"")
    lines.append("```")
    lines.append("")
    lines.append("Actions that open a sheet (`Rename Pane…`) stay open afterwards: follow with")
    lines.append("`type --text` and `key --name return`.")
    lines.append("")
    if let report = liveActionReport(args) {
        lines.append(report)
        lines.append("")
    }
    lines.append("## Commands this binary provides")
    lines.append("")
    lines.append("```")
    lines.append(usageText())
    lines.append("```")
    lines.append("")
    lines.append("## Rules that keep a run honest")
    lines.append("")
    lines.append(honestyRules)
    lines.append("## Where to read more")
    lines.append("")
    lines.append("- `docs/RUNNING.md` — from clone to a verified UI change")
    lines.append("- `docs/AUTOMATION.md` — the GUI verification loop and its measurements")
    lines.append("- `docs/DEBUGGING.md` — ten ways a \"verified\" fix turned out not to be")
    lines.append("- `docs/CLI.md` — what was borrowed from Rex and what is still missing")
    print(lines.joined(separator: "\n"))
    exit(Exit.success.rawValue)
}

/// The live part of the guide, or `nil` when no app is running.
private func liveActionReport(_ args: Arguments) -> String? {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        return "## Live actions\n\n(no Kraal is running, so the live catalog was not read; `actions` needs one)"
    }
    let catalog = menuActions(app, timeout: 2)
    guard !catalog.isEmpty else {
        return "## Live actions\n\n(pid \(app.pid) answered with an empty menu; try `actions --json` directly)"
    }
    let enabled = catalog.filter(\.enabled).count
    let sample = catalog.prefix(6).map { "- `\($0.path)`" }.joined(separator: "\n")
    return """
    ## Live actions

    Kraal pid \(app.pid) offers \(catalog.count) menu items, \(enabled) enabled. For example:

    \(sample)
    """
}
