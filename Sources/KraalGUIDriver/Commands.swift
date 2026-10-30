// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation

// The command table, in one place.
//
// It used to be a hand-written block of text in `main.swift`, which meant the help
// text, this binary's own `--help`, and anything else that wanted to describe the
// tool could drift apart. Rex's lesson (`rex actions`, `rex __internal skill`) is that
// the machine-readable inventory should be the *source* of the prose, not a copy of
// it — an agent that lists the commands must be reading the same table the CLI runs.

struct CommandSpec {
    /// Command name as typed.
    let name: String
    /// The whole signature line, e.g. `do --path "M > I" | --item I [--json]`.
    let signature: String
    /// One line, present tense, what it does to what.
    let summary: String
}

let commandSpecs: [CommandSpec] = [
    CommandSpec(
        name: "probe",
        signature: "probe",
        summary: "check AX + Screen Recording; exit 2 if not ready"
    ),
    CommandSpec(
        name: "ax",
        signature: "ax [--out FILE] [--depth N]",
        summary: "dump the accessibility tree"
    ),
    CommandSpec(
        name: "press",
        signature: "press --title|--desc|--id|--value X",
        summary: "AXPress an element (does NOT activate the app)"
    ),
    CommandSpec(
        name: "wait",
        signature: "wait --title X [--timeout S]",
        summary: "poll until the element exists"
    ),
    CommandSpec(
        name: "window",
        signature: "window",
        summary: "print window frame + window number"
    ),
    CommandSpec(
        name: "clients",
        signature: "clients [--json]",
        summary: "list running instances (pid, windows) for --client"
    ),
    CommandSpec(
        name: "shot",
        signature: "shot -o FILE [--full]",
        summary: "screenshot one window"
    ),
    CommandSpec(
        name: "type",
        signature: "type --text S",
        summary: "type text (AX first with a read-back check, then CGEvent)"
    ),
    CommandSpec(
        name: "click",
        signature: "click --at X,Y | --at-screen X,Y [--right] [--clicks N]",
        summary: "synthetic click; --at is window-relative, --at-screen is absolute"
    ),
    CommandSpec(
        name: "drag",
        signature: "drag --from X,Y --to X,Y [--steps N]",
        summary: "synthetic drag, both points window-relative"
    ),
    CommandSpec(
        name: "scroll",
        signature: "scroll --at X,Y | --at-screen X,Y [--lines N]",
        summary: "synthetic wheel at a point; the app decides which pane is under it"
    ),
    CommandSpec(
        name: "key",
        signature: "key --name N | --char C [--mod cmd,shift]",
        summary: "key chord (needs the app frontmost); escape|return|tab|arrows|f1..f12"
    ),
    CommandSpec(
        name: "menu",
        signature: "menu --menu T --item T [--index N]",
        summary: "open a menu bar menu, then press an item"
    ),
    CommandSpec(
        name: "actions",
        signature: "actions [--json] [--client PID]",
        summary: "list the menu items the app offers"
    ),
    CommandSpec(
        name: "do",
        signature: "do --path \"M > I\" | --item I [--json] [--client PID]",
        summary: "press one of them (rex: `rex -C CLIENT do`)"
    ),
    CommandSpec(
        name: "help",
        signature: "help [--json] [--command NAME]",
        summary: "this table, as text or JSON"
    ),
    CommandSpec(
        name: "skill",
        signature: "skill [--actions]",
        summary: "print the agent guide, generated from this table"
    ),
    CommandSpec(
        name: "launch",
        signature: "launch --app PATH [--env K=V] [--wait-window T] [--match NAME]",
        summary: "start the app under test"
    ),
    CommandSpec(
        name: "quit",
        signature: "quit",
        summary: "terminate the app under test"
    ),
]

/// Width of the signature column before the summary moves to its own line.
private let signatureColumn = 46

func usageText() -> String {
    var lines = ["usage: kraal-gui <command> [options]", ""]
    for spec in commandSpecs {
        let pad = signatureColumn - spec.signature.count
        if pad > 2 {
            lines.append("  " + spec.signature + String(repeating: " ", count: pad) + spec.summary)
        } else {
            lines.append("  " + spec.signature)
            lines.append("  " + String(repeating: " ", count: signatureColumn) + spec.summary)
        }
    }
    lines.append("")
    lines.append("  coordinates: `window`, `ax --json` and `--at-screen` are screen points;")
    lines.append("  `--at` and `drag` offsets are relative to the window's top-left corner. A point")
    lines.append("  outside the window is refused (exit 2) instead of being clamped to its edge.")
    lines.append("")
    lines.append("  exit codes: 0 ok · 1 assertion · 2 harness · 3 crash")
    return lines.joined(separator: "\n")
}

func exitCodeTable() -> [(String, String)] {
    [
        ("0", "success"),
        ("1", "assertion — the product behaves wrongly; fix code"),
        ("2", "harness — could not drive the app; report a blocker"),
        ("3", "crash — the app under test died"),
    ]
}

/// `kraal-gui help [--json] [--command NAME]`
func commandHelp(_ args: Arguments) -> Never {
    if let name = args.string("command") {
        guard let spec = commandSpecs.first(where: { $0.name == name }) else {
            fail(.harness, "no such command '\(name)'; try `help`")
        }
        print("kraal-gui \(spec.signature)\n\n\(spec.summary)")
        exit(Exit.success.rawValue)
    }

    if args.has("json") {
        let commands = commandSpecs.map {
            ["name": $0.name, "signature": $0.signature, "summary": $0.summary] as [String: Any]
        }
        let payload: [String: Any] = [
            "tool": "kraal-gui",
            "count": commandSpecs.count,
            "commands": commands,
            "exit_codes": Dictionary(uniqueKeysWithValues: exitCodeTable()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { fail(.harness, "cannot serialise the command table") }
        print(json)
        exit(Exit.success.rawValue)
    }

    print(usageText())
    exit(Exit.success.rawValue)
}
