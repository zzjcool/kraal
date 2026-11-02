// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Per-screen choices: which space/tab is shown, each tab's focus history,
// zoom and settled time. These are private to this screen and never go into the
// shared `herdr-app` document; they are saved as `view.json`.

import Foundation

public struct KraalTabView: Codable, Equatable, Sendable {
    public var focused: String?
    public var before: [String]
    public var zoomed: String?
    public var settled: UInt64?

    public init(focused: String? = nil, before: [String] = [], zoomed: String? = nil, settled: UInt64? = nil) {
        self.focused = focused
        self.before = before
        self.zoomed = zoomed
        self.settled = settled
    }

    private enum CodingKeys: String, CodingKey {
        case focused
        case before
        case zoomed
        case settled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focused = try container.decodeIfPresent(String.self, forKey: .focused)
        before = try container.decodeIfPresent([String].self, forKey: .before) ?? []
        zoomed = try container.decodeIfPresent(String.self, forKey: .zoomed)
        settled = try container.decodeIfPresent(UInt64.self, forKey: .settled)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(focused, forKey: .focused)
        if !before.isEmpty { try container.encode(before, forKey: .before) }
        try container.encodeIfPresent(zoomed, forKey: .zoomed)
        try container.encodeIfPresent(settled, forKey: .settled)
    }
}

public struct KraalView: Codable, Equatable, Sendable {
    public var activeSpace: String?
    /// Space id → the tab it shows.
    public var activeTabs: [String: String]
    /// Tab id → focus history, zoom and settled time.
    public var tabs: [String: KraalTabView]
    /// Spaces closed on this screen, newest first; reopening one reuses it.
    public var recent: [KraalRecent]

    public init(
        activeSpace: String? = nil,
        activeTabs: [String: String] = [:],
        tabs: [String: KraalTabView] = [:],
        recent: [KraalRecent] = []
    ) {
        self.activeSpace = activeSpace
        self.activeTabs = activeTabs
        self.tabs = tabs
        self.recent = recent
    }

    private enum CodingKeys: String, CodingKey {
        case activeSpace = "active_space"
        case activeTabs = "active_tabs"
        case tabs
        case recent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeSpace = try container.decodeIfPresent(String.self, forKey: .activeSpace)
        activeTabs = try container.decodeIfPresent([String: String].self, forKey: .activeTabs) ?? [:]
        tabs = try container.decodeIfPresent([String: KraalTabView].self, forKey: .tabs) ?? [:]
        recent = try container.decodeIfPresent([KraalRecent].self, forKey: .recent) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(activeSpace, forKey: .activeSpace)
        if !activeTabs.isEmpty { try container.encode(activeTabs, forKey: .activeTabs) }
        if !tabs.isEmpty { try container.encode(tabs, forKey: .tabs) }
        if !recent.isEmpty { try container.encode(recent, forKey: .recent) }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(KraalView.self, from: data)
    }
}
