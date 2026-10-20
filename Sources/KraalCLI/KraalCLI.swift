// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `kraal` — a headless probe for the endpoint protocol.
//
// This exists because the protocol kernel must be verifiable without a UI: it
// connects, prints the handshake, the snapshot, and a surface projection, and
// optionally issues an API call. It is the tool the UI was built against, and
// it stays useful for diagnosing a host that the app cannot reach.

import Foundation
import KraalClient
import KraalProtocol
import KraalTransport

struct Options {
    var socketPath: String?
    var sshHost: String?
    var sshUser: String?
    var sshPort: UInt16?
    var session = HerdrDiscovery.defaultSession
    var cols: UInt16 = 120
    var rows: UInt16 = 40
    var command: Command = .probe
    var method: String?
    var params: [String: Any] = [:]
    var rawParams: String?
    var showMethods = false
    var paneId: String?
    var target: String?
    var text: String?
    var timeout: Double = 20

    enum Command {
        case probe
        case screenshot
        case snapshot
        case call
        case keys
        case sendText
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

extension Options {
    /// The object to send as the request's params.
    ///
    /// `--json` is parsed verbatim so non-string fields survive; `--param` falls
    /// back to strings, which is convenient for ids and the like.
    func requestParams() throws -> [String: Any] {
        guard let rawParams else { return params }
        guard let data = rawParams.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CLIError.invalidJSON(rawParams)
        }
        return object
    }
}

enum CLIError: Error, CustomStringConvertible {
    case invalidJSON(String)

    var description: String {
        switch self {
        case let .invalidJSON(raw): "--json is not a JSON object: \(raw)"
        }
    }
}

/// Flags that take one value.
private let valueFlags: [String: WritableKeyPath<Options, String?>] = [
    "--socket": \Options.socketPath,
    "--ssh": \Options.sshHost,
    "--user": \Options.sshUser,
    "--method": \Options.method,
    "--pane": \Options.paneId,
    "--target": \Options.target,
    "--text": \Options.text,
]

func parse() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else {
        printUsage()
        exit(0)
    }

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        index += 1

        func nextValue() -> String? {
            guard index < arguments.count else { return nil }
            defer { index += 1 }
            return arguments[index]
        }

        if let keyPath = valueFlags[argument] {
            options[keyPath: keyPath] = nextValue()
            continue
        }

        switch argument {
        case "--port":
            options.sshPort = nextValue().flatMap(UInt16.init)
        case "--session":
            options.session = nextValue() ?? options.session
        case "--cols":
            options.cols = nextValue().flatMap(UInt16.init) ?? options.cols
        case "--rows":
            options.rows = nextValue().flatMap(UInt16.init) ?? options.rows
        case "--timeout":
            options.timeout = nextValue().flatMap(Double.init) ?? options.timeout
        case "--param":
            let raw = nextValue() ?? ""
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                options.params[parts[0]] = parts[1]
            }
        case "--methods":
            options.showMethods = true
        case "--json":
            // A literal object, for the many requests whose fields are not
            // strings (splits take `[bool]` paths, ratios take `f32`).
            options.rawParams = nextValue()
        case "screenshot": options.command = .screenshot
        case "snapshot": options.command = .snapshot
        case "call": options.command = .call
        case "keys": options.command = .keys
        case "send-text": options.command = .sendText
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            break
        }
    }
    return options
}

func printUsage() {
    print("""
    kraal — Herdr endpoint protocol probe

    USAGE
      kraal [options]                  handshake + snapshot + surface text
      kraal [options] screenshot       print the whole surface as text
      kraal [options] snapshot         print only the sidebar snapshot
      kraal [options] call             issue an endpoint API call (needs --method)
      kraal [options] keys             send a keyed sequence to a pane
      kraal [options] send-text        send literal text to a pane

    TARGET
      --socket <path>     unix socket (default: this Mac's herdr-client.sock)
      --ssh <host>        connect over SSH instead
      --user <name>       SSH user
      --port <number>     SSH port
      --session <name>    named Herdr session (default: default)

    GEOMETRY
      --cols <n>          surface width in cells (default 120)
      --rows <n>          surface height in cells (default 40)

    ACTIONS
      --method <name>     endpoint method for `call`
      --param k=v         request parameter, repeatable
      --pane <pane_id>    target pane for `keys` / `send-text`
      --text <string>     text for `send-text`
      --json '{...}'      literal JSON object for `call`
      --timeout <seconds> overall wait (default 20)
    """)
}

func resolveTarget(_ options: Options) throws -> HerdrTarget {
    if let path = options.socketPath {
        return .unixSocket(path: path)
    }
    if let host = options.sshHost {
        return .sshShell(
            user: options.sshUser,
            host: host,
            port: options.sshPort,
            session: options.session
        )
    }
    // Honours `HERDR_CLIENT_SOCKET_PATH` / `HERDR_SOCKET_PATH`, so a probe can be
    // pointed at a sandbox without typing the path every time.
    return try HerdrDiscovery.resolve(
        ConnectionSettings(name: "local", transport: .local, session: options.session)
    )
}

/// Collects events from the connection until the run is finished.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _welcome: EndpointServerWelcome?
    private var _snapshot: ClientShellSnapshot?
    private var _surface: PaneSurfaceFrame?
    private var _response: Data?
    private var _disconnect: String?
    private var _error: String?

    var welcome: EndpointServerWelcome? { lock.withLock { _welcome } }
    var snapshot: ClientShellSnapshot? { lock.withLock { _snapshot } }
    var surface: PaneSurfaceFrame? { lock.withLock { _surface } }
    var response: Data? { lock.withLock { _response } }
    var disconnectReason: String? { lock.withLock { _disconnect } }
    var errorMessage: String? { lock.withLock { _error } }

    func apply(_ event: ConnectionEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .connected(welcome): _welcome = welcome
        case let .snapshot(snapshot): _snapshot = snapshot
        case let .surface(surface): _surface = surface
        case let .response(_, _, data, finalChunk):
            if finalChunk { _response = data }
        case let .disconnected(reason): _disconnect = reason
        case let .error(message): _error = message
        default: break
        }
    }
}

/// Polls the collector on a small interval; the CLI prints as data arrives and
/// exits on its own deadline, so a hung host cannot wedge the terminal.
func wait(
    until condition: @escaping @Sendable () -> Bool,
    timeout: Double
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@main
struct KraalCLI {
    static func main() async {
        let options = parse()
        let target: HerdrTarget
        do {
            target = try resolveTarget(options)
        } catch {
            fail("cannot resolve target: \(error)")
        }

        print("target: \(target.displayName)")
        let collector = Collector()
        let connection = EndpointConnection(
            target: target,
            surfaceSize: ClientSurfaceSize(cols: options.cols, rows: options.rows)
        ) { event in
            collector.apply(event)
        }

        do {
            try await connection.start()
        } catch {
            fail("connect failed: \(error)")
        }

        guard let welcome = collector.welcome else {
            fail("no welcome received")
        }
        printHandshake(welcome)

        guard await reachSnapshot(collector, options: options) else {
            fail("no snapshot received")
        }

        await run(options: options, collector: collector, connection: connection)

        await connection.stop()
        if let error = collector.errorMessage {
            print("daemon error: \(error)")
        }
        if let reason = collector.disconnectReason {
            print("disconnected: \(reason)")
        }
    }

    private static func printHandshake(_ welcome: EndpointServerWelcome) {
        print("daemon: \(welcome.serverVersion)  generation: \(welcome.generation)")
        print("codecs: \(welcome.snapshotCodec) / \(welcome.surfaceCodec)")
        print("capabilities: \(welcome.capabilities.joined(separator: ", "))")
    }

    /// Waits for the snapshot and prints it, except for the commands that only
    /// want the surface or the daemon's answer.
    private static func reachSnapshot(
        _ collector: Collector,
        options: Options
    ) async -> Bool {
        if collector.snapshot == nil {
            _ = await wait(until: { collector.snapshot != nil }, timeout: options.timeout)
        }
        guard let snapshot = collector.snapshot else { return false }
        if options.command != .snapshot {
            printSnapshot(snapshot)
        }
        return true
    }

    private static func run(
        options: Options,
        collector: Collector,
        connection: EndpointConnection
    ) async {
        switch options.command {
        case .snapshot, .probe:
            if options.command == .snapshot { return }
            await runSurfaceStep(options: options, collector: collector)

        case .screenshot:
            await runSurfaceStep(options: options, collector: collector, allRows: true)

        case .call:
            await runCall(options: options, connection: connection)

        case .keys, .sendText:
            await runInput(options: options, connection: connection)
        }
    }

    private static func runSurfaceStep(
        options: Options,
        collector: Collector,
        allRows: Bool = false
    ) async {
        _ = await wait(until: { collector.surface != nil }, timeout: options.timeout)
        guard let surface = collector.surface else {
            fail("no surface received")
        }
        printSurface(surface, allRows: allRows)
    }

    private static func runCall(
        options: Options,
        connection: EndpointConnection
    ) async {
        guard let method = options.method else {
            fail("--method is required for `call`")
        }
        do {
            let params = try options.requestParams()
            let response = try await connection.request(method, params: params)
            if let text = String(bytes: response, encoding: .utf8) {
                print(text)
            } else {
                print("<\(response.count) bytes>")
            }
        } catch {
            fail("request failed: \(error)")
        }
    }

    private static func runInput(
        options: Options,
        connection: EndpointConnection
    ) async {
        guard let paneId = options.paneId else {
            fail("--pane is required for `keys` / `send-text`")
        }
        let text: String
        switch options.command {
        case .sendText:
            guard let provided = options.text else {
                fail("--text is required for `send-text`")
            }
            text = provided
        default:
            text = options.text ?? "\r"
        }
        // Let the daemon finish sending its first surface before injecting input,
        // so the CLI's own surface read does not race the echo.
        try? await Task.sleep(nanoseconds: 200_000_000)
        do {
            try await connection.sendPaneInput(paneId, events: [.textCommit(text)])
            print("sent \(text.count) characters to \(paneId)")
        } catch {
            fail("send failed: \(error)")
        }
    }

    static func printSnapshot(_ snapshot: ClientShellSnapshot) {
        print("")
        print("boot \(snapshot.bootId)  revision \(snapshot.revision)")
        print("workspaces (\(snapshot.workspaces.count))")
        for workspace in snapshot.workspaces {
            let mark = workspace.focused ? "▸" : " "
            let branch = workspace.branch.map { " [\($0)]" } ?? ""
            print("  \(mark) w\(workspace.number) \(workspace.label)\(branch)"
                + "  \(statusGlyph(workspace.agentStatus))")
        }
        print("tabs (\(snapshot.tabs.count))")
        for tab in snapshot.tabs {
            let mark = tab.focused ? "▸" : " "
            print("  \(mark) \(tab.tabId) #\(tab.number) \(tab.label)"
                + "  \(statusGlyph(tab.agentStatus))")
        }
        print("panes (\(snapshot.panes.count))")
        for pane in snapshot.panes {
            let mark = pane.focused ? "▸" : " "
            print("  \(mark) \(pane.paneId) \(pane.cwd ?? "")")
        }
        if !snapshot.agents.isEmpty {
            print("agents (\(snapshot.agents.count))")
            for agent in snapshot.agents {
                let mark = agent.focused ? "▸" : " "
                print("  \(mark) \(agent.paneId) \(agent.label)"
                    + "  \(statusGlyph(agent.agentStatus))  \(agent.bestTitle)")
            }
        }
        if !snapshot.commands.isEmpty {
            print("commands (\(snapshot.commands.count))")
            for command in snapshot.commands {
                print("  \(command.bindingLabel)  \(command.description ?? "")")
            }
        }
    }

    static func printSurface(_ surface: PaneSurfaceFrame, allRows: Bool) {
        print("")
        print("surface \(surface.frame.width)×\(surface.frame.height)"
            + "  cells \(surface.frame.cells.count)"
            + "  revision \(surface.surfaceRevision)")
        for pane in surface.panes {
            let inner = pane.innerRect
            print("  pane \(pane.paneId) inner=(\(inner.originX),\(inner.originY))"
                + " \(inner.width)×\(inner.height)"
                + (pane.mouseReporting ? "  mouse" : "")
                + (pane.sgrPixelMouse ? "+px" : "")
                + (pane.focused ? "  focused" : ""))
        }
        print("")
        let lines = SurfaceText.lines(surface.frame)
        let limit = allRows ? lines.count : min(12, lines.count)
        for (index, line) in lines.prefix(limit).enumerated() {
            print(String(format: "%2d|", index) + line)
        }
        if limit < lines.count {
            print("   ... \(lines.count - limit) more rows")
        }
    }

    static func statusGlyph(_ status: AgentStatus) -> String {
        switch status {
        case .idle: "idle"
        case .working: "working"
        case .blocked: "blocked"
        case .done: "done"
        case .unknown: "unknown"
        }
    }
}
