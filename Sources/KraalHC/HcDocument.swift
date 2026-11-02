// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Documents are core-side named JSON values with compare-and-swap versions.
//
// The layout lives in one document (`herdr-app`) per machine, shared with the
// official app. Writes carry the version they were based on: a stale writer
// gets `conflict`, and the caller re-reads. There is no three-way merge — the
// latest document wins, as it does in herdr-app.

import Foundation

public struct HcDocument: Sendable, Equatable {
    public let name: String
    public let machine: String?
    /// `nil` for a name that was never written (or was deleted).
    public let value: JSONValue?
    public let version: UInt64

    public init(name: String, machine: String? = nil, value: JSONValue?, version: UInt64) {
        self.name = name
        self.machine = machine
        self.value = value
        self.version = version
    }

    public var isUnwritten: Bool { value == nil || value?.isNull == true }
}

public enum HcDocumentError: Error, Sendable, Equatable, CustomStringConvertible {
    case notLoaded
    /// The core rejects documents over 1 MiB; check before sending.
    case tooLarge(Int)
    case corrupt(String)
    /// Someone else wrote first. `latest` is what the core has now; the local
    /// edit is not merged.
    case conflict(latest: HcDocument)

    public var description: String {
        switch self {
        case .notLoaded:
            "the document has not been read yet"
        case let .tooLarge(bytes):
            "the document is \(bytes) bytes; the core accepts at most \(HcDocumentSync.limit)"
        case let .corrupt(reason):
            "the document is not valid: \(reason)"
        case let .conflict(latest):
            "the document changed elsewhere (now version \(latest.version))"
        }
    }
}

/// Reads and writes one document, keeping the last version it saw.
///
/// This is not an operation queue: a caller that edits must `load()` first and
/// then `save()`; a conflict reloads and reports the other writer's document.
public final class HcDocumentSync: @unchecked Sendable {
    public static let limit = 1 << 20

    public let name: String
    public let machine: String?

    private let client: HcClient
    private let lock = NSLock()
    private var stored: HcDocument?

    public init(client: HcClient, name: String, machine: String? = nil) {
        self.client = client
        self.name = name
        self.machine = machine
    }

    public func current() -> HcDocument? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    public func load() async throws -> HcDocument {
        let document = try await client.document(name, on: machine)
        lock.lock()
        stored = document
        lock.unlock()
        return document
    }

    /// Writes `value` using the version from the last `load()`/`save()`.
    ///
    /// On `conflict` the other writer's document is loaded, kept, and thrown as
    /// `.conflict` — the caller shows it instead of retrying the local edit.
    @discardableResult
    public func save(_ value: JSONValue) async throws -> HcDocument {
        let base = current()
        guard let base else { throw HcDocumentError.notLoaded }
        if let bytes = try? JSONEncoder().encode(value), bytes.count > Self.limit {
            throw HcDocumentError.tooLarge(bytes.count)
        }
        do {
            let document = try await client.setDocument(
                name,
                on: machine,
                value: value,
                version: base.version
            )
            lock.lock()
            stored = document
            lock.unlock()
            return document
        } catch let error as HcRPCError where error.kind == "conflict" {
            if let latest = try? await load() {
                throw HcDocumentError.conflict(latest: latest)
            }
            throw error
        }
    }

    /// A `doc` event carries only name/version. Returns true when it is this
    /// document and newer, so the caller knows to read it again.
    public func noteRemoteChange(_ event: HcEvent) -> Bool {
        guard event.type == "doc",
              event.data["name"]?.stringValue == name,
              event.machine == machine,
              let version = event.data["version"]?.uint64Value
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let stored else { return true }
        return version > stored.version
    }
}

extension HcClient {
    public func document(_ name: String, on machine: String? = nil) async throws -> HcDocument {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let machine { params["on"] = .string(machine) }
        let reply = try await call("doc.get", params: .object(params))
        guard let version = reply["version"]?.uint64Value else {
            throw HcConnectionError.protocolViolation("doc.get reply has no version")
        }
        return HcDocument(name: name, machine: machine, value: reply["value"], version: version)
    }

    @discardableResult
    public func setDocument(
        _ name: String,
        on machine: String? = nil,
        value: JSONValue?,
        version: UInt64
    ) async throws -> HcDocument {
        var params: [String: JSONValue] = [
            "name": .string(name),
            "value": value ?? .null,
            "version": .int(Int(version)),
        ]
        if let machine { params["on"] = .string(machine) }
        let reply = try await call("doc.set", params: .object(params))
        guard let newVersion = reply["version"]?.uint64Value else {
            throw HcConnectionError.protocolViolation("doc.set reply has no version")
        }
        return HcDocument(name: name, machine: machine, value: value ?? .null, version: newVersion)
    }
}
