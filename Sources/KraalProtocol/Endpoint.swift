// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `endpoint.hello.v1` / `endpoint.welcome.v1` and the compatibility rules
// between them.
//
// Adapted from `herdr-gpui/crates/herdr-protocol/src/endpoint.rs` (Apache-2.0).
// The payload of both messages is JSON *inside* an `EndpointControl` frame, so
// these are `Codable`, not bincode.

import Foundation

public enum EndpointProtocol {
    public static let generation: UInt32 = 1

    public static let helloKind = "endpoint.hello.v1"
    public static let welcomeKind = "endpoint.welcome.v1"
    public static let healthPingKind = "endpoint.health.ping.v1"
    public static let healthPongKind = "endpoint.health.pong.v1"
    public static let snapshotKind = "shell.snapshot.v1"
    public static let agentCompletionsKind = "endpoint.agent-completions.v1"

    public static let snapshotCodecV1 = "shell.snapshot.v1"
    public static let surfaceCodecV1 = "shell.surface.v1"
    public static let inputCodecV1 = "shell.input.semantic.v1"
    public static let blobCodecV1 = "shell.blob.v1"

    /// Capabilities the client needs to be able to ask for a surface at all.
    public static let requiredSurfaceCapabilities = ["surface_interest", "health_check"]

    /// The oldest daemon this client will drive.
    ///
    /// Not a guess: it is the first release whose `endpoint.welcome.v1` carries
    /// the codecs and methods this client uses. A daemon below it handshakes
    /// successfully and then fails later, in pieces — missing methods, absent
    /// capabilities, fields that decode as defaults — which is worse than a clear
    /// refusal at the door.
    ///
    /// Deliberately *not* bumped per release: only raise it when an older daemon
    /// genuinely cannot work.
    public static let minimumDaemonVersion = DaemonVersion(major: 0, minor: 9, patch: 0)
}

/// A daemon version string, parsed far enough to compare against a floor.
///
/// Accepts the shapes a real `server_version` takes: `0.9.4`, and the
/// fork/build suffixed `0.9.0-rootshell.0.1.2`, `1.0.0+build.7`. Only the
/// numeric prefix is compared — a fork's suffix says nothing about whether it
/// speaks this protocol, and rejecting it would lock out every downstream
/// build.
public struct DaemonVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: DaemonVersion, rhs: DaemonVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Parses a leading `major.minor.patch`, ignoring any `-fork` or `+build`
    /// suffix. Fails (rather than defaulting to 0.0.0) so the caller can refuse
    /// a daemon it cannot identify instead of trusting it.
    public static func parse(_ raw: String) -> Result<DaemonVersion, ParseFailure> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Stop at the first character that cannot belong to the numeric core.
        let core = trimmed.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 4 else {
            return .failure(.notAVersion(raw))
        }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, let value = Int(part), value >= 0 else {
                return .failure(.notAVersion(raw))
            }
            numbers.append(value)
        }
        return .success(
            DaemonVersion(
                major: numbers[0],
                minor: numbers[1],
                patch: numbers.count > 2 ? numbers[2] : 0
            )
        )
    }

    public enum ParseFailure: Error, Equatable, Sendable {
        case notAVersion(String)
    }
}

public struct EndpointClientHello: Codable, Equatable, Sendable {
    public var generation: UInt32
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32
    public var surfaceSize: Size
    public var pixelMouse: Bool
    public var directGraphics: Bool
    public var endpointKeybindings: Bool
    public var mouseCapture: Bool
    public var surfaceActive: Bool
    public var surfaceReuse: Bool
    public var surfaceDelta: Bool
    public var surfaceScroll: Bool
    public var snapshotCodecs: [String]
    public var surfaceCodecs: [String]
    public var inputCodecs: [String]
    public var blobCodecs: [String]

    public struct Size: Codable, Equatable, Sendable {
        public var cols: UInt16
        public var rows: UInt16

        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case cellWidthPx = "cell_width_px"
        case cellHeightPx = "cell_height_px"
        case surfaceSize = "surface_size"
        case pixelMouse = "pixel_mouse"
        case directGraphics = "direct_graphics"
        case endpointKeybindings = "endpoint_keybindings"
        case mouseCapture = "mouse_capture"
        case surfaceActive = "surface_active"
        case surfaceReuse = "surface_reuse"
        case surfaceDelta = "surface_delta"
        case surfaceScroll = "surface_scroll"
        case snapshotCodecs = "snapshot_codecs"
        case surfaceCodecs = "surface_codecs"
        case inputCodecs = "input_codecs"
        case blobCodecs = "blob_codecs"
    }

    /// The hello this client sends.
    ///
    /// The three optional surface codecs are requested only when the caller
    /// opts in; generation 1 of the client supports the baseline
    /// `PaneSurface`/`PaneSurfacePatch` pair, so they default to `false` and
    /// the daemon sends unencoded frames.
    public init(
        cols: UInt16,
        rows: UInt16,
        cellWidthPx: UInt32 = 10,
        cellHeightPx: UInt32 = 20,
        pixelMouse: Bool = false,
        surfaceActive: Bool = true,
        optionalCodecs: Bool = false
    ) {
        generation = EndpointProtocol.generation
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        surfaceSize = Size(cols: cols, rows: rows)
        self.pixelMouse = pixelMouse
        directGraphics = false
        endpointKeybindings = false
        mouseCapture = false
        self.surfaceActive = surfaceActive
        surfaceReuse = optionalCodecs
        surfaceDelta = optionalCodecs
        surfaceScroll = optionalCodecs
        snapshotCodecs = [EndpointProtocol.snapshotCodecV1]
        surfaceCodecs = [EndpointProtocol.surfaceCodecV1]
        inputCodecs = [EndpointProtocol.inputCodecV1]
        blobCodecs = [EndpointProtocol.blobCodecV1]
    }

    /// Decodes a hello the way the wire contract allows it to arrive.
    ///
    /// Kraal only *sends* a hello today, so nothing in the app depends on this.
    /// It exists because the type claims to describe the wire contract, and that
    /// contract has `serde(default)` on nine fields (`endpoint.rs:20-38`): a peer
    /// may omit them, and a type that demands them is wrong about the protocol it
    /// names.
    ///
    /// The one that matters most is `surface_active`, whose serde default is
    /// `true` — an absent value means *active*, not *inactive*. Getting that
    /// backwards would silently suppress the surface stream.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(UInt32.self, forKey: .generation)
        cellWidthPx = try container.decode(UInt32.self, forKey: .cellWidthPx)
        cellHeightPx = try container.decode(UInt32.self, forKey: .cellHeightPx)
        surfaceSize = try container.decode(Size.self, forKey: .surfaceSize)
        pixelMouse = try container.decode(Bool.self, forKey: .pixelMouse)
        directGraphics = try container.decode(Bool.self, forKey: .directGraphics)
        endpointKeybindings = try container.decode(Bool.self, forKey: .endpointKeybindings)
        mouseCapture = try container.decode(Bool.self, forKey: .mouseCapture)
        // `serde(default = "default_true")` upstream: absent means active.
        surfaceActive = try container.decodeIfPresent(Bool.self, forKey: .surfaceActive) ?? true
        surfaceReuse = try container.decodeIfPresent(Bool.self, forKey: .surfaceReuse) ?? false
        surfaceDelta = try container.decodeIfPresent(Bool.self, forKey: .surfaceDelta) ?? false
        surfaceScroll = try container.decodeIfPresent(Bool.self, forKey: .surfaceScroll) ?? false
        snapshotCodecs = try container.decodeIfPresent(
            [String].self,
            forKey: .snapshotCodecs
        ) ?? []
        surfaceCodecs = try container.decodeIfPresent([String].self, forKey: .surfaceCodecs) ?? []
        inputCodecs = try container.decodeIfPresent([String].self, forKey: .inputCodecs) ?? []
        blobCodecs = try container.decodeIfPresent([String].self, forKey: .blobCodecs) ?? []
    }
}

public struct EndpointHandshakeError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
}

public struct EndpointServerWelcome: Codable, Equatable, Sendable {
    public var generation: UInt32
    public var serverVersion: String
    public var snapshotCodec: String
    public var surfaceCodec: String
    public var inputCodec: String
    public var blobCodec: String
    public var methods: [String]
    public var capabilities: [String]
    public var error: EndpointHandshakeError?

    enum CodingKeys: String, CodingKey {
        case generation
        case serverVersion = "server_version"
        case snapshotCodec = "snapshot_codec"
        case surfaceCodec = "surface_codec"
        case inputCodec = "input_codec"
        case blobCodec = "blob_codec"
        case methods
        case capabilities
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(UInt32.self, forKey: .generation)
        serverVersion = try container.decodeIfPresent(
            String.self,
            forKey: .serverVersion
        ) ?? "unknown"
        snapshotCodec = try container.decodeIfPresent(
            String.self,
            forKey: .snapshotCodec
        ) ?? ""
        surfaceCodec = try container.decodeIfPresent(
            String.self,
            forKey: .surfaceCodec
        ) ?? ""
        inputCodec = try container.decodeIfPresent(String.self, forKey: .inputCodec) ?? ""
        blobCodec = try container.decodeIfPresent(String.self, forKey: .blobCodec) ?? ""
        methods = try container.decodeIfPresent([String].self, forKey: .methods) ?? []
        capabilities = try container.decodeIfPresent(
            [String].self,
            forKey: .capabilities
        ) ?? []
        error = try container.decodeIfPresent(EndpointHandshakeError.self, forKey: .error)
    }

    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    public func advertises(_ method: String) -> Bool {
        methods.contains(method)
    }

    /// The optional surface encodings this connection negotiated.
    public var encodings: SurfaceEncodings {
        SurfaceEncodings(
            reuse: supports("surface_reuse"),
            delta: supports("surface_delta"),
            scroll: supports("surface_scroll")
        )
    }
}

public struct SurfaceEncodings: Equatable, Sendable {
    public var reuse: Bool
    public var delta: Bool
    public var scroll: Bool

    public static let none = SurfaceEncodings(reuse: false, delta: false, scroll: false)
}

public enum Compatibility: Equatable, Sendable {
    case compatible
    case serverTooOld(String?)
    case clientTooOld(serverVersion: String, generation: UInt32)
    case unusableVersion(String)
    case incompatibleCodecs(String)
    case missingCapability(String)
    case rejected(code: String, message: String)

    public var isOK: Bool { self == .compatible }

    /// A short, user-facing explanation for the connection banner.
    public var userMessage: String? {
        switch self {
        case .compatible:
            nil
        case let .serverTooOld(version):
            "This Herdr daemon (\(version ?? "unknown version")) predates the "
                + "client protocol Kraal needs. Update Herdr to 0.9.0 or newer."
        case let .clientTooOld(serverVersion, generation):
            "The daemon (\(serverVersion)) speaks endpoint generation \(generation); "
                + "Kraal speaks generation \(EndpointProtocol.generation). Update Kraal."
        case let .unusableVersion(version):
            "The daemon reports an unreadable version string (\"\(version)\"), so its "
                + "protocol support cannot be checked. Update Herdr to "
                + "\(EndpointProtocol.minimumDaemonVersion) or newer."
        case let .incompatibleCodecs(detail):
            "No shared wire codec: \(detail)"
        case let .missingCapability(capability):
            "The daemon does not advertise the \"\(capability)\" capability, which "
                + "this client requires."
        case let .rejected(code, message):
            "The daemon rejected the handshake (\(code)): \(message)"
        }
    }

    /// Mirrors the checks `herdr-client/src/session.rs` performs, in the same
    /// order, so both clients accept and reject the same daemons.
    ///
    /// Order matters: generation first, error second. Upstream decides which side
    /// is outdated from the generation *even when the welcome also carries an
    /// error* (`version_mismatch.rs:40`
    /// `generation_says_which_side_is_older_even_in_a_rejection`). A daemon that
    /// refuses an unsupported generation attaches `{"code":
    /// "unsupported_generation"}`, so checking `error` first reports a generic
    /// rejection and tells the user to update the wrong side.
    public static func evaluate(_ welcome: EndpointServerWelcome) -> Compatibility {
        if welcome.generation != EndpointProtocol.generation {
            // A higher generation means this client is the outdated one; a lower
            // one means the daemon is.
            if welcome.generation > EndpointProtocol.generation {
                return .clientTooOld(
                    serverVersion: welcome.serverVersion,
                    generation: welcome.generation
                )
            }
            return .serverTooOld(welcome.serverVersion)
        }
        // Same generation, so an error is a real rejection of something else.
        if let error = welcome.error {
            return .rejected(code: error.code, message: error.message)
        }
        // The generation matches but the daemon may still predate what this
        // client needs (`rootshell testVersionsBelowMinimumAreRefused`). An
        // unparseable version is refused rather than trusted: a daemon that
        // cannot say what it is cannot be checked against a floor.
        switch DaemonVersion.parse(welcome.serverVersion) {
        case .success(let version):
            guard version >= EndpointProtocol.minimumDaemonVersion else {
                return .serverTooOld(welcome.serverVersion)
            }
        case .failure:
            return .unusableVersion(welcome.serverVersion)
        }
        guard welcome.snapshotCodec == EndpointProtocol.snapshotCodecV1,
              welcome.surfaceCodec == EndpointProtocol.surfaceCodecV1,
              welcome.inputCodec == EndpointProtocol.inputCodecV1,
              welcome.blobCodec == EndpointProtocol.blobCodecV1
        else {
            let detail = [
                welcome.snapshotCodec,
                welcome.surfaceCodec,
                welcome.inputCodec,
                welcome.blobCodec
            ].joined(separator: "/")
            return .incompatibleCodecs(detail)
        }
        for capability in EndpointProtocol.requiredSurfaceCapabilities
        where !welcome.supports(capability) {
            return .missingCapability(capability)
        }
        return .compatible
    }
}
