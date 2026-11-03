// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Add a machine: the hosts in ~/.ssh/config to pick from, or a typed user@host.
// Still one `machine.add`, so a dialog cannot invent a connection the core does
// not support.
//
// The shape is the official mod's: 560pt card, the explanation, the ssh config
// list, then the typed field. A failed add keeps the sheet open with the reason
// under the field — a machine that did not connect must not look like it did.

import Foundation
import SwiftUI

struct HcAddMachineDialog: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// `nil` until the file has been read: the list says "Reading…" instead of
    /// claiming the config is empty.
    @State private var hosts: [HcSSHConfig.Host]?
    @State private var typed = ""
    /// Targets in flight. The row and the typed button both say "Adding…" while
    /// the RPC is out, so a click cannot be repeated.
    @State private var adding: Set<String> = []
    @State private var errors: [String: String] = [:]

    private var typedTarget: String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !typedTarget.isEmpty && !adding.contains(typedTarget)
    }

    var body: some View {
        HcDialogCard {
            VStack(alignment: .leading, spacing: 0) {
                title
                Text(explanation)
                    .font(.system(size: 12.8))
                    // The official sets a 19pt line height; SwiftUI only adds
                    // spacing on top of the font's own leading.
                    .lineSpacing(4)
                    .foregroundStyle(theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                heading(hostHeading)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                hostList
                heading("Or type how ssh reaches it")
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                typedRow
                errorLine
            }
            .padding(18)
            .frame(width: 560)
        }
        .onExitCommand { dismiss() }
        .task { hosts = await Self.readHosts() }
    }

    // MARK: - Pieces

    private var title: some View {
        HStack(spacing: 8) {
            Text("Add a machine")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.foreground.color)
            Spacer(minLength: 8)
            Text("Esc")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim.color)
        }
    }

    private var explanation: String {
        "A VPS, a Mac mini, a box at home: Kraal reaches it over ssh, "
            + "and agents there keep running while your laptop sleeps."
    }

    /// Before the file is read there is nothing to say about its contents, so the
    /// heading keeps the neutral one until the list is known to be empty.
    private var hostHeading: String {
        guard let hosts, hosts.isEmpty else { return "From your ssh config" }
        return "Your ssh config lists no hosts"
    }

    private var hostList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let hosts {
                    ForEach(hosts, id: \.alias) { host in
                        hostRow(host)
                    }
                } else {
                    Text("Reading ~/.ssh/config…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.dim.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
    }

    private var typedRow: some View {
        HStack(spacing: 8) {
            HcField("user@host", text: $typed, onSubmit: { add(typedTarget) })
            Button(adding.contains(typedTarget) ? "Adding…" : "Add") { add(typedTarget) }
                .buttonStyle(HcPrimaryButtonStyle())
                .opacity(canAdd ? 1 : 0.4)
                .disabled(!canAdd)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if !typedTarget.isEmpty, let error = errors[typedTarget] {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(theme.blocked.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.dim.color)
    }

    private func hostRow(_ host: HcSSHConfig.Host) -> some View {
        HcSSHHostRow(
            alias: host.alias,
            detail: Self.detail(of: host),
            adding: adding.contains(host.alias),
            error: errors[host.alias]
        ) {
            add(host.alias)
        }
    }

    // MARK: - Adding

    private func add(_ raw: String) {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !adding.contains(target) else { return }
        adding.insert(target)
        errors[target] = nil
        Task {
            do {
                _ = try await model.addMachine(
                    target: target,
                    via: nil,
                    name: nil,
                    session: nil,
                    temporary: false
                )
                adding.remove(target)
                if typedTarget == target { typed = "" }
                dismiss()
            } catch {
                adding.remove(target)
                errors[target] = HcWorkspaceModel.describe(error)
            }
        }
    }

    /// `<user>@<hostname>` when the block names them, otherwise the other names
    /// the same block answers to, which is what a person recognises.
    private static func detail(of host: HcSSHConfig.Host) -> String {
        let address = [host.user, host.hostname]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "@")
        guard address.isEmpty else { return address }
        return host.aliases.isEmpty ? "" : "also " + host.aliases.joined(separator: ", ")
    }

    /// `~/.ssh/config` is small, but it is still read off the main thread so the
    /// dialog paints its first frame at once. A missing file (a fresh Mac) has no
    /// hosts and is not an error.
    private static func readHosts() async -> [HcSSHConfig.Host] {
        await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/config")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return HcSSHConfig.parse(text)
        }.value
    }
}

/// One host: click anywhere on the row to add it.
private struct HcSSHHostRow: View {
    @Environment(\.hcTheme) private var theme
    let alias: String
    let detail: String
    let adding: Bool
    let error: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Text(alias)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground.color)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dim.color)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if adding {
                        Text("Adding…")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.muted.color)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(
                    hovering ? theme.hover.color : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(adding)
            .onHover { hovering = $0 }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.blocked.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// The pickable hosts of `~/.ssh/config`, read the way the official add-machine
/// mod reads them: the first name on a `Host` line is the alias and the rest are
/// alternatives, `Hostname`/`User` attach to the block above them, and a pattern
/// (`*`, `?`, `!`) is not a host a person can pick.
enum HcSSHConfig {
    /// `hostname`/`user` are the block's own keys and may each be absent.
    struct Host: Equatable {
        let alias: String
        let aliases: [String]
        let hostname: String?
        let user: String?
    }

    /// The block being read, before it is frozen into a `Host`.
    private struct Draft {
        let alias: String
        let aliases: [String]
        var hostname: String?
        var user: String?

        var host: Host {
            Host(alias: alias, aliases: aliases, hostname: hostname, user: user)
        }
    }

    static func parse(_ text: String) -> [Host] {
        var hosts: [Host] = []
        var open: Draft?
        func flush() {
            guard let draft = open else { return }
            hosts.append(draft.host)
            open = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (key, value) = keyword(in: String(raw)) else { continue }
            switch key {
            case "host":
                flush()
                let names = value.split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { !$0.isEmpty && !$0.contains(where: { "*?!".contains($0) }) }
                open = names.first.map { Draft(alias: $0, aliases: Array(names.dropFirst())) }
            case "match":
                // A `Match` holds conditions, not a host; the block before it ends.
                flush()
            case "hostname":
                guard !value.isEmpty else { continue }
                open?.hostname = value
            case "user":
                guard !value.isEmpty else { continue }
                open?.user = value
            default:
                continue
            }
        }
        flush()
        return hosts
    }

    /// `Host foo`, `Host=foo` and `HostName  10.0.0.7` split the same way: the
    /// keyword, an optional `=`, then the rest of the line. A `#` line is not a
    /// keyword at all.
    private static func keyword(in raw: String) -> (key: String, value: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first != "#" else { return nil }
        var rest = Substring(trimmed)
        var key = ""
        while let character = rest.first, !character.isWhitespace, character != "=" {
            key.append(character)
            rest = rest.dropFirst()
        }
        guard !key.isEmpty else { return nil }
        rest = rest.drop(while: { $0.isWhitespace || $0 == "=" })
        return (key.lowercased(), String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
