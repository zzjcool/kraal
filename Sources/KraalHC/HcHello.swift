// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `hello` and the version gate.
//
// The core is 0.x: generation 1 is additive-only, but an old core can lack a
// method we need. Failing with a named reason ("core 0.1.9 is too old", "the
// core lacks doc.set") beats letting every later call fail one by one.

import Foundation

public struct HcHelloResult: Sendable, Equatable {
    public let generation: Int
    public let version: String
    public let coreID: String
    public let coreName: String
    public let framed: Bool
    public let methods: [String]
    public let features: [String]

    public init(json: JSONValue) throws {
        guard let generation = json["generation"]?.intValue,
              let version = json["version"]?.stringValue,
              let framed = json["framed"]?.boolValue
        else {
            throw HcConnectionError.protocolViolation("hello reply is missing generation/version/framed")
        }
        self.generation = generation
        self.version = version
        self.framed = framed
        coreID = json["core"]?["id"]?.stringValue ?? ""
        coreName = json["core"]?["name"]?.stringValue ?? ""
        methods = (json["methods"]?.arrayValue ?? []).compactMap(\.stringValue)
        features = (json["features"]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}

public enum HcCompatibility: Sendable, Equatable {
    case compatible
    case unsupportedGeneration(have: Int, expected: Int)
    case unreadableVersion(String)
    case tooOld(have: String, need: String)
    case missingMethods([String])

    public var isOK: Bool {
        if case .compatible = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .compatible:
            "compatible"
        case let .unsupportedGeneration(have, expected):
            "this core speaks protocol generation \(have); Kraal speaks \(expected)"
        case let .unreadableVersion(version):
            "can't read the core version \(quoted(version))"
        case let .tooOld(have, need):
            "core \(have) is older than the \(need) Kraal needs"
        case let .missingMethods(methods):
            "the core lacks \(methods.joined(separator: ", "))"
        }
    }

    private func quoted(_ value: String) -> String {
        "\"\(value)\""
    }
}

public enum HcProtocol {
    public static let generation = 1

    /// The oldest core this client is tested against (2026-11-02, hc 0.1.16).
    /// Raise it only after a release has been exercised end to end.
    public static let minimumVersion = "0.1.16"

    /// What the client calls today. A core missing one of these cannot serve it.
    public static let requiredMethods = [
        "terminal.run",
        "terminal.list",
        "terminal.kill",
        "terminal.label",
        "terminal.attach",
        "terminal.keep",
        "doc.get",
        "doc.set",
        "events.subscribe",
    ]

    public static func check(_ hello: HcHelloResult) -> HcCompatibility {
        guard hello.generation == generation else {
            return .unsupportedGeneration(have: hello.generation, expected: generation)
        }
        guard let have = HcVersion(hello.version) else {
            return .unreadableVersion(hello.version)
        }
        guard let need = HcVersion(minimumVersion) else {
            return .unreadableVersion(minimumVersion)
        }
        if have < need {
            return .tooOld(have: hello.version, need: minimumVersion)
        }
        let missing = requiredMethods.filter { !hello.methods.contains($0) }
        if !missing.isEmpty {
            return .missingMethods(missing)
        }
        return .compatible
    }
}

/// Semantic version with the prerelease suffix ignored: only the numeric triple
/// decides whether a core is old. `hc 0.1.16` and `0.1.16` parse the same.
public struct HcVersion: Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("hc ") {
            text = String(text.dropFirst(3))
        }
        let numbers = text.split(separator: "-", maxSplits: 1)[0].split(separator: ".")
        guard numbers.count >= 2,
              let major = Int(numbers[0]),
              let minor = Int(numbers[1]),
              major >= 0, minor >= 0
        else { return nil }
        let patch = numbers.count > 2 ? Int(numbers[2]) : 0
        guard let patch, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: HcVersion, rhs: HcVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
