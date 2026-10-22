// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The settings window: one place for everything that configures Kraal rather
// than driving a terminal.
//
// Why a tabbed panel instead of a File-menu dialog
// ------------------------------------------------
// Machine management used to live under File ▸ Machines…, which is where a
// *document* action belongs. But adding, renaming and disabling machines is
// configuration — the kind of thing you do once and then forget — and it sat in
// the menu next to New Workspace and Close Tab, competing with the actions
// people use every minute.
//
// Upstream Herdr keeps its settings in a tabbed overlay reached by `prefix+s`
// (`/tmp/herdr-src/src/client/shell/settings.rs:35-46`) and puts machines in the
// sidebar instead of a dialog. Kraal has no overlay system and no modal
// settings, so the closest equivalent is a standard macOS settings window with
// tabs, opened by ⌘, — the chord every Mac user already tries.
//
// Machines stays a *list with controls* rather than dissolving into the sidebar:
// the sidebar is for navigating workspaces, and it has no room for an SSH target
// or a rename field. What moves is the entry point, not the content.

import SwiftUI

import KraalTransport

/// Which settings tab is showing.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case machines
    case terminal
    case effects

    public var id: String { rawValue }

    /// The label under the toolbar/segmented control.
    public var title: String {
        switch self {
        case .machines: "Machines"
        case .terminal: "Terminal"
        case .effects: "Clipboard & Bell"
        }
    }

    public var symbol: String {
        switch self {
        case .machines: "server.rack"
        case .terminal: "terminal"
        case .effects: "bell.badge"
        }
    }

    /// Whether this page is tall enough to need the machines list's room.
    ///
    /// Kept on the tab rather than at the call site: a new page silently getting
    /// the wrong height is the kind of thing nobody notices until a row is
    /// clipped.
    public var wantsTallSheet: Bool { self == .machines }
}

public struct SettingsView: View {
    @State private var tab: SettingsTab
    private let target: ConnectionSettings
    private let onDismiss: () -> Void
    /// Re-reads the saved profiles after a write. Machines are configuration
    /// stored by the herdr CLI, so editing one here has to be pushed into the
    /// store that owns the sidebar's machine list — otherwise the sidebar keeps
    /// drawing the roster it read at launch.
    private let onProfilesChanged: () -> Void

    /// `tab` starts on machines: it is the only tab that does anything today, and
    /// landing on an empty tab would look like the window failed to load.
    public init(
        tab: SettingsTab = .machines,
        target: ConnectionSettings = .local,
        onDismiss: @escaping () -> Void,
        onProfilesChanged: @escaping () -> Void = {}
    ) {
        _tab = State(initialValue: tab)
        self.target = target
        self.onDismiss = onDismiss
        self.onProfilesChanged = onProfilesChanged
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            // The machines tab reuses `MachinesPanel` rather than duplicating its
            // roster, forms and alerts. That view carries its own fixed frame and
            // sheet chrome, both of which are wrong inside a settings window, so
            // `embedded` switches them off instead of forking the whole file.
            switch tab {
            case .machines:
                MachinesPanel(
                    target: target,
                    embedded: true,
                    onClose: onDismiss,
                    onProfilesChanged: onProfilesChanged
                )
            case .terminal:
                TerminalSettingsPane()
            case .effects:
                EffectsSettingsPane()
            }
        }
        .frame(width: 640)
        // Height follows the tab: the machines list needs the room it always had,
        // while terminal settings is a short stack of rows. A fixed height would
        // leave the second tab padded with emptiness.
        .frame(height: tab.wantsTallSheet ? 460 : 330)
        .glassChrome(.sheet, rim: false)
    }

    private var tabBar: some View {
        HStack(spacing: KraalTheme.Space.base) {
            ForEach(SettingsTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    Label(candidate.title, systemImage: candidate.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: tab == candidate ? .semibold : .regular))
                        .foregroundStyle(tab == candidate ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab == candidate
                                    ? Color.primary.opacity(0.10)
                                    : Color.clear)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.base)
    }
}

/// Terminal-side preferences.
///
/// Kept deliberately short: these are the switches that already exist elsewhere
/// in the app and were reachable only through a menu or an environment variable.
/// Moving them here does not add new behaviour — it makes what exists findable.
/// The four things a pane can ask the desktop to do, and which of them are
/// allowed to interrupt.
///
/// These correspond one-for-one to `TerminalEffects` (#34): before those were
/// wired up there was nothing to configure, and a settings page for a feature
/// that does not work is worse than no page. The toggles are `@AppStorage`, so
/// they are read by `TerminalEffectsApplier` through the same keys rather than
/// being written into a config file this app does not own.
private struct EffectsSettingsPane: View {
    @AppStorage(KraalEffectSettings.clipboardEnabled) private var clipboardEnabled = true
    @AppStorage(KraalEffectSettings.bellEnabled) private var bellEnabled = true
    @AppStorage(KraalEffectSettings.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(KraalEffectSettings.windowTitleEnabled) private var windowTitleEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(
                title: "Remote clipboard (OSC 52)",
                detail: "Lets a program in a pane put text on this Mac's clipboard "
                    + "— how `pbcopy` and tmux copy work over SSH."
            ) {
                Toggle("", isOn: $clipboardEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Divider()
            row(
                title: "Window title follows the pane",
                detail: "Use the focused pane's reported title as the window title."
            ) {
                Toggle("", isOn: $windowTitleEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Divider()
            row(
                title: "Bell",
                detail: "Sound the system alert when a program in a pane rings."
            ) {
                Toggle("", isOn: $bellEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Divider()
            row(
                title: "Notifications",
                detail: "Show the daemon's own notices (updates, announcements). "
                    + "These never become Notification Center banners."
            ) {
                Toggle("", isOn: $notificationsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.base)
    }

    private func row(
        title: String,
        detail: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: KraalTheme.Space.base) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(KraalTheme.Font.rowTitle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: KraalTheme.Space.base)
            control()
        }
        .padding(.vertical, KraalTheme.Space.snug)
    }
}

private struct TerminalSettingsPane: View {
    @AppStorage("kraal.verboseLogging") private var verboseLogging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(
                title: "Verbose logging",
                detail: "Records protocol traffic to the session log. Useful when "
                    + "reporting a bug; noisy otherwise."
            ) {
                Toggle("", isOn: $verboseLogging)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Divider()
            row(
                title: "Log file",
                detail: KraalLog.shared.fileURL.path
            ) {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([KraalLog.shared.fileURL])
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, KraalTheme.Space.roomy)
        .padding(.vertical, KraalTheme.Space.base)
    }

    private func row(
        title: String,
        detail: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: KraalTheme.Space.roomy) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, KraalTheme.Space.base)
    }
}
