// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import KraalTransport

// `herdr …` as a plain subprocess: one place that finds the binary, one place that
// reads both pipes without deadlocking, one place that turns a refusal into an error
// carrying herdr's own words.

enum HerdrCLIError: Error, CustomStringConvertible {
    case notFound
    case failed(arguments: [String], status: Int32, message: String)

    var description: String {
        switch self {
        case .notFound:
            "cannot find the herdr binary; set KRAAL_HERDR_BIN or put herdr on PATH"
        case let .failed(arguments, status, message):
            "herdr \(arguments.joined(separator: " ")) failed (\(status)): \(message)"
        }
    }
}

func herdrExecutable() throws -> URL {
    guard let url = HerdrMachineClient.resolveExecutable() else {
        throw HerdrCLIError.notFound
    }
    return url
}

/// Runs `herdr` and returns stdout. A non-zero exit throws, because every caller here
/// wants herdr's message rather than a bare status.
func runHerdr(_ arguments: [String]) throws -> Data {
    let executable = try herdrExecutable()
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
        throw HerdrCLIError.failed(
            arguments: arguments, status: -1, message: error.localizedDescription
        )
    }
    // Both pipes are read to EOF before waiting: a child that fills a pipe buffer
    // while the parent sits in `waitUntilExit` deadlocks.
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errors, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw HerdrCLIError.failed(
            arguments: arguments, status: process.terminationStatus, message: message
        )
    }
    return output
}

/// Runs `herdr` and decodes its JSON result object.
func runHerdrJSON(_ arguments: [String]) throws -> [String: Any] {
    let data = try runHerdr(arguments)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw HerdrCLIError.failed(arguments: arguments, status: 0, message: "output is not JSON")
    }
    return object
}
