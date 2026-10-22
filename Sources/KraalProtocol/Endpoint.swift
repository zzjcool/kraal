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
    public static func evaluate(_ welcome: EndpointServerWelcome) -> Compatibility {
        if let error = welcome.error {
            return .rejected(code: error.code, message: error.message)
        }
        guard welcome.generation == EndpointProtocol.generation else {
            return .clientTooOld(
                serverVersion: welcome.serverVersion,
                generation: welcome.generation
            )
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
