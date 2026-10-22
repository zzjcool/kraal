// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// A small debug sheet for active development.
//
// Opened from Help ▸ Debug ▸ Show Debug Info… (F12). Surfaces window chrome
// flags, connection phase, pane counts, and the log path — things that are
// awkward to inspect without attaching a debugger.

import AppKit
import KraalProtocol
import SwiftUI

struct DebugInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debug Info")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(KraalTheme.Space.loose)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Application", rows: appRows)
                    section("Window", rows: windowRows)
                    section("Connection", rows: connectionRows)
                    section("Daemon", rows: daemonRows)
                    section("Logging", rows: loggingRows)
                }
                .padding(KraalTheme.Space.loose)
            }
        }
        .frame(width: 480, height: 420)
        .glassChrome(.sheet, rim: false)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: KraalTheme.Space.snug) {
            Text(title.uppercased())
                .font(KraalTheme.Font.sectionHeader)
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0)
                        .frame(width: 160, alignment: .leading)
                    Text(row.1)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(KraalTheme.Font.rowTitle)
            }
        }
    }

    private var appRows: [(String, String)] {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let identifier = bundle.bundleIdentifier ?? "—"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return [
            ("Version", "\(version) (\(build))"),
            ("Bundle ID", identifier),
            ("macOS", osVersion),
        ]
    }

    private var windowRows: [(String, String)] {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return [("Window", "none")]
        }
        return [
            ("isOpaque", "\(window.isOpaque)"),
            ("titlebarTransparent", "\(window.titlebarAppearsTransparent)"),
            ("fullSizeContentView", "\(window.styleMask.contains(.fullSizeContentView))"),
            ("background alpha", String(format: "%.2f", window.backgroundColor.alphaComponent)),
            ("frame", "\(Int(window.frame.width))×\(Int(window.frame.height))"),
        ]
    }

    private var connectionRows: [(String, String)] {
        [
            ("Phase", phaseLabel(store.phase)),
            ("Panes", "\(store.visiblePanes.count)"),
            ("Tabs", "\(store.visibleTabs.count)"),
            ("Surface stale", "\(store.surfaceIsStale)"),
        ]
    }

    /// Everything the daemon reports about itself.
    ///
    /// These eleven snapshot fields used to be decoded and dropped. They are not
    /// all worth a status bar, but they are exactly what someone opening this
    /// sheet is looking for when a config file "does nothing" or an agent list
    /// looks wrong — and having them here is what turns "unused field" into
    /// "inspectable state" without inventing banners for each one.
    ///
    /// `releaseNotes.body` and `productAnnouncement.body` are shown by their
    /// summary here rather than inline: this sheet is a table, and a markdown
    /// document squeezed into a 320pt column is unreadable.
    private var daemonRows: [(String, String)] {
        let snapshot = store.snapshot
        let notices = SnapshotNotices.notices(in: snapshot)
        let keybindings = SnapshotNotices.serverKeybindings(in: snapshot)
        var rows: [(String, String)] = [
            ("Notices", notices.isEmpty
                ? "(none)"
                : notices.map(\.summary).joined(separator: ", ")),
            ("Config diagnostic", nonEmpty(snapshot?.configDiagnostic) ?? "(none)"),
            ("Update available", nonEmpty(snapshot?.updateAvailable) ?? "(none)"),
            ("Install command", nonEmpty(snapshot?.updateInstallCommand) ?? "(none)"),
            ("Release notes", snapshot?.releaseNotes.map { "\($0.version) (\($0.body.count) chars)" }
                ?? "(none)"),
            ("Announcement", snapshot?.productAnnouncement?.title ?? "(none)"),
            ("Integration updates", (snapshot?.integrationUpdatesAvailable ?? false) ? "available" : "none"),
            ("Worktree directory", SnapshotNotices.worktreeDirectory(in: snapshot) ?? "(not configured)"),
            ("Server keybindings", keybindings.map { "\($0.count) chars" } ?? "(none)"),
            ("Agent view filter", SnapshotNotices.agentViewFilterLabel(in: snapshot) ?? "(off)"),
            // No force-unwrap: `agentOrder` is read once and rendered, so an
            // `if let` inside a closure would only make the row builder harder to
            // scan. An empty list is a legitimate state, not an error.
            ("Agent order", orderedAgents(snapshot)),
        ]
        let agentRows = SnapshotNotices.agentRows(in: snapshot)
            .map { "\($0.label)@\($0.paneId)" }
            .joined(separator: ", ")
        rows.append(("Agent rows", agentRows.isEmpty ? "(none)" : agentRows))
        return rows
    }

    private func orderedAgents(_ snapshot: ClientShellSnapshot?) -> String {
        guard let order = snapshot?.agentOrder, !order.isEmpty else { return "(empty)" }
        return order.joined(separator: ", ")
    }

    /// `nil` for a missing or blank value, so a defaulted-to-`""` field reads as
    /// "not set" rather than "set to nothing".
    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var loggingRows: [(String, String)] {
        let log = KraalLog.shared
        return [
            ("Verbose logging", log.isEnabled ? "on" : "off"),
            ("Log file", log.fileURL.path),
            ("KRAAL_LOG env", ProcessInfo.processInfo.environment["KRAAL_LOG"] ?? "(unset)"),
        ]
    }

    private func phaseLabel(_ phase: AppStore.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .live: return "live"
        case .reconnecting(let attempt, _): return "reconnecting (#\(attempt))"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}
