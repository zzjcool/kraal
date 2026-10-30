// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Darwin
import Foundation

// `kraal events --type pane.created` — Rex's `rex events --json`.
//
// herdr's socket protocol is newline-delimited JSON and already defines the
// subscriptions (`events.subscribe`, and an `event`/`data` frame per event), but the
// `herdr` CLI exposes only `api snapshot` / `api schema`, so there is no way to watch
// a daemon from a script. This speaks the protocol directly: one request line, then
// every line the daemon sends is printed as it arrives.
//
// Measured against herdr 0.9.5 (2026-10-30):
//     → {"id":"…","method":"events.subscribe","params":{"subscriptions":[{"type":"workspace.updated"}]}}
//     ← {"id":"…","result":{"type":"subscription_started"}}

struct EventOptions {
    var types: [String] = []
    var list = false
    /// Stop after this many event frames. Makes tests deterministic instead of
    /// racing a timer; `nil` streams until the timeout or Ctrl-C.
    var count: Int?
    /// Stop after this many seconds (0 = never).
    var timeout: Double = 0
    var socketPath: String?
    var includeAck = true
}

func runEvents(_ options: Options) -> Never {
    let events = options.events

    if events.list {
        do {
            print(try subscriptionKinds().joined(separator: "\n"))
        } catch {
            fail("\(error)")
        }
        exit(0)
    }

    guard !events.types.isEmpty else {
        fail("""
        events needs at least one --type; `kraal events --list` prints the kinds the \
        running herdr offers
        """)
    }

    let path: String
    do {
        path = try events.socketPath ?? herdrSocketPath()
    } catch {
        fail("\(error)")
    }

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        fail("socket(): \(String(cString: strerror(errno)))")
    }
    defer { close(descriptor) }

    do {
        try connect(descriptor, to: path)
    } catch {
        fail("\(error)")
    }

    let subscriptions = events.types.map { "{\"type\":\(jsonString($0))}" }.joined(separator: ",")
    let request = "{\"id\":\"kraal-events\",\"method\":\"events.subscribe\","
        + "\"params\":{\"subscriptions\":[\(subscriptions)]}}\n"
    guard writeAll(descriptor, request) else {
        fail("could not send the subscribe request to \(path)")
    }

    stream(descriptor, options: events)
    exit(0)
}

/// Every subscription kind the running herdr knows, straight from its schema.
///
/// Asked for rather than hardcoded: herdr adds event kinds between releases, and a
/// list baked into this binary would start lying to whoever runs `--list`.
func subscriptionKinds() throws -> [String] {
    let data = try runHerdr(["api", "schema", "--json"])
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let schemas = root["schemas"] as? [String: Any],
          let request = schemas["request"] as? [String: Any],
          let definitions = request["$defs"] as? [String: Any],
          let subscription = definitions["Subscription"] as? [String: Any],
          let variants = subscription["oneOf"] as? [[String: Any]]
    else {
        throw HerdrCLIError.failed(arguments: ["api", "schema"], status: 0,
                                  message: "the schema has no Subscription definition")
    }
    return variants.compactMap {
        (($0["properties"] as? [String: Any])?["type"] as? [String: Any])?["const"] as? String
    }.sorted()
}

/// The JSON API socket: the environment first (a sandbox or a remote daemon), then
/// whatever the running server reports.
func herdrSocketPath() throws -> String {
    let environment = ProcessInfo.processInfo.environment
    for key in ["HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH"] {
        if let value = environment[key], !value.isEmpty { return value }
    }
    let data = try runHerdr(["status", "--json"])
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let server = root["server"] as? [String: Any],
          let socket = server["socket"] as? String, !socket.isEmpty
    else {
        throw HerdrCLIError.failed(arguments: ["status"], status: 0,
                                  message: "no running server reports a socket")
    }
    return socket
}

func jsonString(_ text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

func connect(_ descriptor: Int32, to path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
        throw HerdrCLIError.failed(arguments: ["connect"], status: -1,
                                  message: "socket path is too long for sockaddr_un")
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { characters in
            for (offset, byte) in pathBytes.enumerated() {
                characters[offset] = CChar(bitPattern: byte)
            }
            characters[pathBytes.count] = 0
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, size)
        }
    }
    guard result == 0 else {
        throw HerdrCLIError.failed(arguments: ["connect"], status: -1,
                                  message: "\(path): \(String(cString: strerror(errno)))")
    }
}

func writeAll(_ descriptor: Int32, _ text: String) -> Bool {
    var bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(descriptor, base + offset, bytes.count - offset)
        }
        if written <= 0 { return false }
        offset += written
    }
    return true
}

/// Reads until `--count` events, `--timeout`, or EOF, printing each line as it comes.
private func stream(_ descriptor: Int32, options: EventOptions) {
    let deadline = options.timeout > 0 ? Date().addingTimeInterval(options.timeout) : nil
    var pending = Data()
    var seen = 0
    var buffer = [UInt8](repeating: 0, count: 65536)

    while true {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let wait: Int32 = deadline.map { remaining -> Int32 in
            let seconds = remaining.timeIntervalSinceNow
            return seconds <= 0 ? 0 : Int32(min(seconds * 1000, 60_000))
        } ?? 60_000
        let ready = poll(&pollDescriptor, 1, wait)
        if ready == 0 {
            if let deadline, Date() >= deadline { return }
            continue
        }
        if ready < 0 { return }

        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 65536) }
        if count <= 0 { return }   // EOF: the daemon went away
        pending.append(contentsOf: buffer[0 ..< count])

        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex ..< newline]
            pending = pending[pending.index(after: newline)...]
            guard let text = String(data: Data(line), encoding: .utf8), !text.isEmpty else { continue }
            let isEvent = text.contains("\"event\"")
            if isEvent || options.includeAck {
                print(text)
                fflush(stdout)
            }
            if isEvent {
                seen += 1
                if let limit = options.count, seen >= limit { return }
            }
        }
        if let deadline, Date() >= deadline { return }
    }
}
