// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalProtocol
import KraalTransport

// `kraal capture` — Rex's `rex capture --format=text|ansi|html`.
//
// herdr already prints a pane's screen and scrollback (`herdr pane read`), so this
// command deliberately does not reimplement that: it is a formatter on top. The one
// format herdr cannot produce is HTML, and it is the interesting one — a plain-text
// capture throws away precisely what a bug report needs (which row is highlighted,
// which word is red).

struct CaptureOptions {
    var source = "visible"
    var lines: Int?
    var format = "text"
    var trim = false
    var background = "#282828"
    var foreground = "#ebdbb2"
}

func runCapture(_ options: Options) -> Never {
    let capture = options.capture

    var pane = options.paneId
    if pane == nil {
        let environment = ProcessInfo.processInfo.environment
        // herdr exports this inside every pane it runs, so "capture me" works
        // without the caller knowing an id.
        if let inherited = environment["HERDR_PANE_ID"], !inherited.isEmpty {
            pane = inherited
        }
    }
    guard let pane else {
        fail("capture needs --pane <id> (or run it inside a herdr pane, where HERDR_PANE_ID is set)")
    }

    switch capture.format {
    case "text", "ansi", "html":
        break
    default:
        fail("--format takes text, ansi or html; got '\(capture.format)'")
    }

    guard let executable = HerdrMachineClient.resolveExecutable() else {
        fail("cannot find the herdr binary; set KRAAL_HERDR_BIN or put herdr on PATH")
    }

    // Always ask for ANSI: text is ANSI with the escapes stripped, and one code path
    // that gets exercised by every format cannot drift from the formats it feeds.
    var arguments = [
        "pane", "read", pane,
        "--source", capture.source,
        "--format", "ansi",
    ]
    if let lines = capture.lines {
        arguments.append(contentsOf: ["--lines", String(lines)])
    }

    let output = runHerdr(executable, arguments)
    guard let text = String(data: output, encoding: .utf8) else {
        fail("herdr pane read returned output that is not UTF-8")
    }

    let visible = capture.trim ? trimCapture(text) : text
    switch capture.format {
    case "ansi":
        emit(visible)
    case "html":
        emit(ANSIToHTML.render(
            visible,
            background: capture.background,
            foreground: capture.foreground
        ) + "\n")
    default:
        emit(stripANSI(visible))
    }
    exit(0)
}

/// Runs `herdr …` and returns stdout, folding stderr into the failure message so a
/// refusal ("no such pane") is not reduced to "exit 1".
private func runHerdr(_ executable: URL, _ arguments: [String]) -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        fail("cannot run \(executable.path): \(error.localizedDescription)")
    }
    // Both pipes are read to EOF before waiting: a child that fills a pipe buffer
    // while the parent sits in `waitUntilExit` deadlocks.
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errors, encoding: .utf8) ?? ""
        fail("herdr \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): "
            + message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output
}

/// Drops trailing spaces per line and trailing blank lines.
private func trimCapture(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        var line = String(line)
        while line.hasSuffix("\r") || line.hasSuffix(" ") || line.hasSuffix("\t") {
            line.removeLast()
        }
        return line
    }
    while let last = lines.last, stripANSI(last).trimmingCharacters(in: .whitespaces).isEmpty,
          !lines.isEmpty {
        lines.removeLast()
    }
    return lines.joined(separator: "\n")
}

/// The ANSI state machine that matters for plain text: SGR is dropped, everything
/// else in a CSI/OSC sequence is dropped with it, and the characters stay.
func stripANSI(_ text: String) -> String {
    var result = ""
    // Scalars, not Characters: a CRLF pair is one Character in Swift, so a
    // Character-based loop silently keeps `\r` (measured — see `ANSIToHTML`).
    let scalars = text.unicodeScalars
    var index = scalars.startIndex
    while index < scalars.endIndex {
        let scalar = scalars[index]
        guard scalar == "\u{1B}" else {
            result.unicodeScalars.append(scalar)
            index = scalars.index(after: index)
            continue
        }
        index = scalars.index(after: index)
        guard index < scalars.endIndex else { break }
        switch scalars[index] {
        case "[":
            index = scalars.index(after: index)
            while index < scalars.endIndex {
                let ending = scalars[index]
                index = scalars.index(after: index)
                if ending.value >= 0x40, ending.value <= 0x7E { break }
            }
        case "]":
            index = scalars.index(after: index)
            while index < scalars.endIndex {
                let ending = scalars[index]
                index = scalars.index(after: index)
                if ending == "\u{07}" { break }
                if ending == "\u{1B}", index < scalars.endIndex, scalars[index] == "\\" {
                    index = scalars.index(after: index)
                    break
                }
            }
        default:
            index = scalars.index(after: index)
        }
    }
    return result
}

private func emit(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}
