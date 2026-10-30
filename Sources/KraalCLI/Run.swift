// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation

// `kraal run [--wait] -- CMD …` — Rex's `rex run --wait`, which is the one shape the
// herdr CLI cannot express: herdr can start a command and it can read a pane, but
// nothing returns the command's *exit status*, so a script cannot branch on pass/fail.
//
// The trick is not a trick: the command is typed into a shell with a printer appended
// that echoes `[kraal-exit:N]`, and `herdr pane wait-output --regex` waits for that
// marker. Everything in the pipeline already exists and is already tested; nothing
// here depends on the daemon growing a feature it does not have.

struct RunOptions {
    var label: String?
    var cwd: String?
    var split: String?
    var wait = false
    var timeout: Double = 120
    var output = "text"
    var command: [String] = []
}

/// Single-quotes one argv element for POSIX shells.
///
/// The command crosses exactly one shell (the pane's), so this is the whole escaping
/// story — unlike the test harness, where the arguments also cross `tart exec bash -lc`
/// and the quotes get eaten twice (`docs/DEBUGGING.md` §17).
func shellQuote(_ argument: String) -> String {
    "\u{27}" + argument.replacingOccurrences(of: "\u{27}", with: "\u{27}\\''") + "\u{27}"
}

func runCommand(_ options: Options) -> Never {
    let run = options.run

    guard !run.command.isEmpty else {
        fail("run needs a command after --, e.g. kraal run --wait -- npm test")
    }
    guard run.output == "text" || run.output == "json" else {
        fail("--output takes text or json; got '\(run.output)'")
    }

    let target: [String: Any]
    do {
        target = try createTarget(run)
    } catch {
        fail("\(error)")
    }
    // herdr wraps results (`{"id":"cli:tab:create","result":{…}}`) and the field is
    // `pane_id` for a split but a list for a new tab, so search instead of guessing.
    guard let pane = firstPaneId(in: target) else {
        fail("herdr did not report a pane id: \(target)")
    }

    let command = run.command.map(shellQuote).joined(separator: " ")
    let marker = "[kraal-exit:%s]"
    // `printf` and not `echo`: the marker must survive a shell that strips newlines,
    // and `$?` has to be read before anything else runs.
    let payload = "\(command); printf '\\n\(marker)\\n' \"$?\""

    do {
        try sendToShell(pane: pane, text: payload, cwd: run.cwd)
    } catch {
        fail("\(error)")
    }

    guard run.wait else {
        report(pane: pane, label: run.label, exit: nil, json: run.output == "json")
        exit(0)
    }

    let status: Int
    do {
        status = try waitForExit(pane: pane, timeout: run.timeout)
    } catch {
        fail("\(error)")
    }
    report(pane: pane, label: run.label, exit: status, json: run.output == "json")
    exit(Int32(max(0, min(status, 255))))
}

/// The first `pane_id` (or `pane_ids[0]`) anywhere in a herdr JSON response.
func firstPaneId(in object: Any) -> String? {
    if let dictionary = object as? [String: Any] {
        if let id = dictionary["pane_id"] as? String, !id.isEmpty { return id }
        if let ids = dictionary["pane_ids"] as? [String], let id = ids.first { return id }
        for value in dictionary.values {
            if let found = firstPaneId(in: value) { return found }
        }
        return nil
    }
    if let array = object as? [Any] {
        for value in array {
            if let found = firstPaneId(in: value) { return found }
        }
    }
    return nil
}

/// Creates the tab or split the command will live in, and returns its JSON result.
private func createTarget(_ run: RunOptions) throws -> [String: Any] {
    if let direction = run.split {
        guard direction == "right" || direction == "down" else {
            throw HerdrCLIError.failed(arguments: ["pane", "split"], status: -1,
                                       message: "--split takes right or down")
        }
        var arguments = ["pane", "split", "--direction", direction]
        if let label = run.label { arguments.append(contentsOf: ["--label", label]) }
        if let cwd = run.cwd { arguments.append(contentsOf: ["--cwd", cwd]) }
        return try runHerdrJSON(arguments)
    }
    var arguments = ["tab", "create", "--no-focus"]
    if let label = run.label { arguments.append(contentsOf: ["--label", label]) }
    if let cwd = run.cwd { arguments.append(contentsOf: ["--cwd", cwd]) }
    return try runHerdrJSON(arguments)
}

/// Waits until the pane's shell owns the foreground, then types the payload.
///
/// A freshly created tab has a pane before it has a shell; typing into that gap loses
/// the text (`gui.sh` has the same note about `pane run`). Waiting for a foreground
/// process is checked against the daemon rather than slept on.
private func sendToShell(pane: String, text: String, cwd: String?) throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let info = try? runHerdrJSON(["pane", "process-info", "--pane", pane]),
           let result = info["result"] as? [String: Any],
           let process = result["process_info"] as? [String: Any],
           let foreground = process["foreground_processes"] as? [[String: Any]],
           !foreground.isEmpty {
            break
        }
        usleep(100_000)
    }
    var text = text
    if let cwd {
        text = "cd \(shellQuote(cwd)) && " + text
    }
    _ = try runHerdr(["pane", "send-text", pane, text])
    _ = try runHerdr(["pane", "send-keys", pane, "return"])
}

/// Blocks until the pane prints the exit marker, and returns that number.
private func waitForExit(pane: String, timeout: Double) throws -> Int {
    let milliseconds = Int(timeout * 1000)
    _ = try runHerdr([
        "pane", "wait-output", pane,
        "--regex", "\\[kraal-exit:([0-9]+)\\]",
        "--source", "recent",
        "--timeout", String(milliseconds),
    ])
    // The wait only proves *a* marker appeared; the number comes from the screen, and
    // the last one wins so a re-run of the same command cannot report the old status.
    let data = try runHerdr(["pane", "read", pane, "--source", "recent", "--format", "text"])
    let text = String(data: data, encoding: .utf8) ?? ""
    let numbers = markerMatches(in: text)
    guard let last = numbers.last else {
        throw HerdrCLIError.failed(arguments: ["pane", "read"], status: 0,
                                   message: "the pane never printed [kraal-exit:N]")
    }
    return last
}

/// Every `[kraal-exit:N]` in the text, in order. Kept separate so the parsing can be
/// unit-tested without a daemon.
func markerMatches(in text: String) -> [Int] {
    var found: [Int] = []
    var rest = Substring(text)
    let prefix = "[kraal-exit:"
    while let start = rest.range(of: prefix) {
        rest = rest[start.upperBound...]
        guard let close = rest.firstIndex(of: "]") else { break }
        if let value = Int(rest[..<close]) { found.append(value) }
        rest = rest[rest.index(after: close)...]
    }
    return found
}

private func report(pane: String, label: String?, exit: Int?, json: Bool) {
    if json {
        var payload: [String: Any] = ["pane_id": pane]
        if let label { payload["label"] = label }
        if let exit { payload["exit_code"] = exit }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }
    if let exit {
        print("\(label ?? pane) exited \(exit) (pane \(pane))")
    } else {
        print((label.map { "\($0) " } ?? "") + "started in pane \(pane)")
    }
}
