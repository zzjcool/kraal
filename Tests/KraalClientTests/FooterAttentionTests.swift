// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  FooterAttentionTests.swift
//  KraalClientTests
//
//  The sidebar footer shows a dot when the daemon has something the user should know.
//
//  Upstream's conditions are `update_available || integration_updates_available`
//  (`src/client/shell/global_menu.rs:9-11`); this client adds a config diagnostic,
//  which stops the daemon from honouring its own config file and would otherwise be
//  invisible from the sidebar.
//

import Foundation
import Testing

@testable import KraalProtocol
@testable import KraalUI

@Suite("Sidebar footer attention")
struct FooterAttentionTests {
    /// A snapshot carrying only the fields this decision reads. The rest default,
    /// which is what the decoder already does for a daemon that omits them.
    private func snapshot(
        update: String? = nil,
        integrations: Bool = false,
        diagnostic: String? = nil
    ) throws -> ClientShellSnapshot {
        var fields = ["\"server_keybindings_toml\": \"\""]
        if let update {
            fields.append("\"update_available\": \"\(update)\"")
        }
        if integrations {
            fields.append("\"integration_updates_available\": true")
        }
        if let diagnostic {
            fields.append("\"config_diagnostic\": \"\(diagnostic)\"")
        }
        let json = """
        {"boot_id": "boot", "revision": 1, "workspaces": [], "tabs": [], "panes": [],
         "agents": [], "agent_order": [], "commands": [], \(fields.joined(separator: ","))}
        """
        return try JSONDecoder().decode(ClientShellSnapshot.self, from: Data(json.utf8))
    }

    @Test("no snapshot means no dot")
    func noSnapshotNoDot() {
        #expect(FooterAttention.reason(for: nil) == nil)
    }

    @Test("a quiet snapshot means no dot")
    func quietSnapshotNoDot() throws {
        #expect(FooterAttention.reason(for: try snapshot()) == nil)
    }

    /// Upstream's first condition, and the one a user is most likely to see.
    @Test("an available update raises the dot")
    func updateRaisesDot() throws {
        let reason = FooterAttention.reason(for: try snapshot(update: "0.9.6"))
        #expect(reason == "herdr 0.9.6 available")
    }

    /// Upstream's second condition.
    @Test("pending integration updates raise the dot")
    func integrationsRaiseDot() throws {
        let reason = FooterAttention.reason(for: try snapshot(integrations: true))
        #expect(reason == "integration updates available")
    }

    /// A config diagnostic outranks an update: the daemon is not doing what its
    /// config says, which is more urgent than "there is a newer version".
    @Test("a config diagnostic outranks an update")
    func diagnosticOutranksUpdate() throws {
        let reason = FooterAttention.reason(
            for: try snapshot(update: "0.9.6", integrations: true, diagnostic: "bad key")
        )
        #expect(reason == "config: bad key")
    }

    /// An empty or whitespace-only value is not news. The daemon sends
    /// `update_available` as an optional string, and an empty one would otherwise
    /// produce a dot with a tooltip reading "herdr  available".
    @Test("a blank value raises nothing")
    func blankValuesRaiseNothing() throws {
        #expect(FooterAttention.reason(for: try snapshot(update: "")) == nil)
        #expect(FooterAttention.reason(for: try snapshot(diagnostic: "   ")) == nil)
    }

    /// A trimmed value is what the tooltip shows.
    @Test("the reason is trimmed")
    func reasonIsTrimmed() throws {
        // A newline has to survive JSON, so it goes in as the escape sequence.
        let reason = FooterAttention.reason(for: try snapshot(diagnostic: "  bad key \\n"))
        #expect(reason == "config: bad key")
    }
}
