// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The settings dialog: the official 880 × 620 card, one 190pt rail and six
// pages (Look, Keyboard, Machines, Alerts, Updates, Privacy).
//
// Two rules decide what is in here. First, a page only offers what Kraal can
// actually do: there is no chrome-layout switch, no feedback endpoint and no
// updater, so those places say so instead of drawing a control that does
// nothing. Second, every color is an `HcTheme` token and every control comes
// from `HcThemeControls`: a system `Form`, `Toggle` or segmented picker paints
// itself white in a dark window (`docs/audits/2026-11-ui-round1.md` F1/F2).
//
// Sizes and copy follow `app/defaults/frame/settings/main.js`; where Kraal has
// no equivalent (layout switch, fonts, telemetry) the page stops at what it
// supports rather than reproducing a dead control.

import KraalHC
import SwiftUI

public struct HcSettingsView: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    public init(model: HcWorkspaceModel) {
        self.model = model
    }

    /// The tokens come from the model, not `@Environment`: this view injects
    /// `.hcTheme` on its own body, and a view cannot read a value it injects
    /// itself. Everything below it reads the environment.
    private var theme: HcTheme { model.resolvedTheme }

    public var body: some View {
        HcDialogCard {
            HStack(spacing: 0) {
                HcSettingsRail(model: model)
                page
            }
            .frame(width: 880, height: 620)
        }
        // The sheet's own window corners are the card's corners; painting them
        // the same color keeps a white sliver out of a dark window.
        .background(theme.popover.color)
        .hcTheme(theme)
        .onExitCommand { dismiss() }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch model.settingsSection {
                case .look: HcLookPage(model: model)
                case .keyboard: HcKeyboardPage(model: model)
                case .machines: HcMachinesPage(model: model)
                case .alerts: HcAlertsPage(model: model)
                case .updates: HcUpdatesPage(model: model)
                case .privacy: HcPrivacyPage(model: model)
                }
            }
            // Padding inside the scroll area, not on it: outside, it counts as
            // content and a page that fits still shows a scroll bar.
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rail

/// The left column: title, the six pages, and the one action the official rail
/// has at its foot. `model.settingsSection` is the current page, so
/// `app.settings:section` and a click land in the same place.
private struct HcSettingsRail: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.foreground.color)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 12)
            ForEach(HcSettingsSection.allCases, id: \.self) { section in
                row(section)
            }
            Spacer(minLength: 0)
            feedbackButton
        }
        .padding(10)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.border.color).frame(width: 1)
        }
    }

    private func row(_ section: HcSettingsSection) -> some View {
        let isOn = model.settingsSection == section
        return Button {
            model.settingsSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15))
                    .frame(width: 18)
                    .foregroundStyle((isOn ? theme.accent : theme.dim).color)
                Text(section.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle((isOn ? theme.foreground : theme.muted).color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isOn ? theme.raised.color : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// Kraal has nowhere to send feedback, so the button says so instead of
    /// opening an empty compose window.
    private var feedbackButton: some View {
        Button {
            model.showToast(
                title: "Feedback",
                detail: "Kraal has no feedback endpoint yet; file an issue at github.com/zzjcool/kraal.",
                level: .info
            )
        } label: {
            Text("Send feedback").frame(maxWidth: .infinity)
        }
        .buttonStyle(HcQuietButtonStyle())
        .focusable(false)
    }
}

// MARK: - Look

private struct HcLookPage: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var theme

    private var themeBorder: Color { theme.border.color }
    private var themeMuted: Color { theme.muted.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HcPanelHeading("Layout")
            HcSettingGap(14)
            HStack(spacing: 8) {
                ForEach(HcLayoutKind.allCases) { kind in
                    HcLayoutCard(kind: kind, selected: kind == .herdr) {
                        choose(kind)
                    }
                }
            }
            HcSettingGap(28)
            HcPanelHeading("Theme")
            HcSettingGap(30)
            HcSettingRow("Appearance", detail: "Light or dark, or as your system is now.") {
                HcSegmented(
                    items: HcAppearance.allCases.map { (value: $0, label: $0.title) },
                    selection: setting(\.appearance)
                )
            }
            HcSettingGap(12)
            Rectangle()
                .fill(themeBorder)
                .frame(height: 1)
            HcSettingGap(10)
            Text("For the layout you're in: each layout keeps its own light and dark theme.")
                .font(.system(size: 12))
                .foregroundStyle(themeMuted)
            HcSettingGap(12)
            HcSettingSubheading("Dark")
            HcSettingGap(6)
            HStack(spacing: 8) {
                ForEach(HcThemeName.presets(isLight: false), id: \.self) { name in
                    HcThemeSwatch(name: name, selected: name == model.settings.themeDark) {
                        model.settings.themeDark = name
                    }
                }
            }
            HcSettingGap(26)
            HcSettingSubheading("Light")
            HcSettingGap(6)
            HStack(spacing: 8) {
                ForEach(HcThemeName.presets(isLight: true), id: \.self) { name in
                    HcThemeSwatch(name: name, selected: name == model.settings.themeLight) {
                        model.settings.themeLight = name
                    }
                }
            }
            HcSettingGap(40)
            HcPanelHeading("Size and fonts")
            HcSettingGap(4)
            zoomRow
            fontRow
        }
    }

    /// Kraal builds its own window shell, so only the shipped look is real. The
    /// other two cards are drawn (the page would otherwise be wrong) but they
    /// say what is actually true instead of pretending to switch.
    private func choose(_ kind: HcLayoutKind) {
        guard kind != .herdr else { return }
        model.showToast(
            title: "Layout",
            detail: "Kraal has no chrome layouts; the window shell is built in.",
            level: .info
        )
    }

    /// Zoom is the shared action, so ⌘= and this stepper take the same path and
    /// persist the same value.
    private var zoomRow: some View {
        HcSettingRow("Zoom") {
            HStack(spacing: 8) {
                HcStepper(
                    value: "\(Int(model.settings.fontSize)) pt",
                    decrement: { run("app.zoom_out") },
                    increment: { run("app.zoom_in") }
                )
                Button("Reset") { run("app.zoom_reset") }
                    .buttonStyle(HcQuietButtonStyle())
            }
        }
    }

    private var fontRow: some View {
        HcSettingRow("Terminal font size") {
            HcStepper(
                value: "\(Int(model.settings.fontSize)) pt",
                decrement: { step(-1) },
                increment: { step(1) }
            )
        }
    }

    private func step(_ delta: Double) {
        model.settings.fontSize = HcFontZoom.next(model.settings.fontSize, by: delta)
    }

    private func run(_ action: String) {
        Task { @MainActor in
            let outcome = await model.performAction(action)
            if let error = outcome.error {
                model.showToast(title: action, detail: error, level: .error)
            }
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<HcTerminalSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }
}

/// The three looks the official Look page offers. Kraal ships the first one.
private enum HcLayoutKind: String, CaseIterable, Identifiable {
    case herdr
    case terminals
    case win98

    var id: String { rawValue }

    var title: String {
        switch self {
        case .herdr: "Herdr"
        case .terminals: "Terminals"
        case .win98: "Herdr 98"
        }
    }
}

/// One layout choice: a 124-wide card holding a 62-high miniature drawn from
/// tokens, the name, and a check on the one in use.
private struct HcLayoutCard: View {
    @Environment(\.hcTheme) private var theme
    let kind: HcLayoutKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HcLayoutPreview(kind: kind)
                    .frame(height: 62)
                HStack(spacing: 5) {
                    Text(kind.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle((selected ? theme.foreground : theme.muted).color)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                    }
                }
            }
            .padding(6)
            .frame(width: 124, alignment: .leading)
            .background(
                selected ? theme.raised.color : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? theme.accent.color : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A sidebar strip, a tab strip and two terminals: enough to tell the three
/// looks apart, and drawn from the same tokens as the real window.
private struct HcLayoutPreview: View {
    @Environment(\.hcTheme) private var theme
    let kind: HcLayoutKind

    var body: some View {
        Group {
            switch kind {
            case .herdr: herdr
            case .terminals: terminals
            case .win98: win98
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.canvas.color)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.border.color, lineWidth: 1)
        }
    }

    private var herdr: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                bar(14)
                bar(10)
                bar(12)
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(width: 32)
            .frame(maxHeight: .infinity)
            .background(theme.chrome.color)
            .overlay(alignment: .trailing) { hairline.frame(width: 1) }
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    pill(18, theme.accent)
                    pill(14, theme.selected)
                    Spacer(minLength: 0)
                }
                .padding(3)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) { hairline.frame(height: 1) }
                HStack(spacing: 3) {
                    terminalBox
                    terminalBox
                }
                .padding(4)
            }
        }
    }

    private var terminals: some View {
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                pill(24, theme.selected)
                pill(16, theme.selected)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                terminalCard
                terminalCard
            }
        }
        .padding(4)
    }

    private var win98: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(theme.accent.color).frame(width: 4, height: 4)
                bar(14)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 10)
            .background(theme.chrome.color)
            .overlay(alignment: .bottom) { hairline.frame(height: 1) }
            HStack(spacing: 0) { terminalBox }
                .padding(4)
        }
    }

    private func bar(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(theme.dim.color)
            .frame(width: width, height: 3)
    }

    /// The tab strips use `selected`, not `raised`: `raised` is a 3.5% step off
    /// the card color in light mode and disappears on the miniature's canvas.
    private func pill(_ width: CGFloat, _ color: HcColor) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.color)
            .frame(width: width, height: 6)
    }

    private var terminalBox: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(theme.background.color)
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(theme.border.color, lineWidth: 1)
            }
    }

    private var terminalCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                bar(10)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .frame(height: 8)
            .background(theme.selected.color)
            Spacer(minLength: 0)
        }
        .background(theme.background.color)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(theme.border.color, lineWidth: 1)
        }
    }

    private var hairline: some View {
        Rectangle().fill(theme.border.color)
    }
}

// MARK: - Keyboard

private struct HcKeyboardPage: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HcPanelHeading("Option key")
            HcSettingGap(6)
            HcSettingNote("Use Option for terminal shortcuts or to type accents and special characters.")
            HcSettingGap(8)
            radioRow("Alt", checked: model.settings.optionAsAlt) {
                model.settings.optionAsAlt = true
            }
            radioRow("Types characters", checked: !model.settings.optionAsAlt) {
                model.settings.optionAsAlt = false
            }
            HcSettingGap(22)
            HcPanelHeading("Keys")
            HcSettingGap(8)
            Text(HcKeymapController.defaultPath.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.muted.color)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HcSettingGap(10)
            HStack(spacing: 10) {
                Button("Keybindings…") {
                    // ⌘/ is the readable copy of keys.json; this sheet is the
                    // only place besides the key itself that points at it.
                    // AppKit drops a sheet asked for in the same run loop as the
                    // current one's dismissal, so the second half of the switch
                    // waits one turn (120 ms, below what a person can see).
                    model.showSettings = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        model.showHelp = true
                    }
                }
                .buttonStyle(HcQuietButtonStyle())
                Spacer(minLength: 0)
            }
            HcSettingGap(10)
            HcSettingNote("Press ctrl-alt-shift-escape in the window to restore the shipped keys.")
        }
    }

    /// The official page draws two radio rows rather than one switch: the two
    /// entries are behaviours, not on/off of a single one.
    private func radioRow(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(checked ? "◉" : "○")
                    .font(.system(size: 13))
                    .foregroundStyle((checked ? theme.accent : theme.muted).color)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Machines

private struct HcMachinesPage: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HcPanelHeading("Machines")
            HcSettingGap(6)
            HcSettingNote("Your computers, reached over ssh. Their terminals keep running when you disconnect.")
            HcSettingGap(6)
            HcSettingRow("This computer", detail: HcCoreStatusText.local(model.status)) {
                HcStateDot(color: theme.done)
            }
            HcHairline()
            ForEach(model.machines) { machine in
                machineRow(machine)
                HcHairline()
            }
            if model.machines.isEmpty {
                HcSettingGap(10)
                HcSettingNote("No other machines yet.")
            }
            // Rename and remove live on the sidebar's machine menu; this page
            // only lists and offers the way in, like the official one.
            HcSettingGap(16)
            HStack(spacing: 10) {
                Button("Add a machine") { model.machineSheet = .add }
                    .buttonStyle(HcPrimaryButtonStyle())
                Spacer(minLength: 0)
            }
        }
    }

    private func machineRow(_ machine: HcMachine) -> some View {
        HStack(spacing: 10) {
            HcStateDot(color: HcCoreStatusText.dot(machine.state, theme: theme))
            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground.color)
                Text(detail(machine))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.dim.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func detail(_ machine: HcMachine) -> String {
        let version = machine.version.isEmpty ? "hc version unknown" : "hc \(machine.version)"
        return "\(machine.target) · \(machine.state.label) · \(version)"
    }
}

// MARK: - Alerts

private struct HcAlertsPage: View {
    @ObservedObject var model: HcWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HcPanelHeading("Sounds")
            HcSettingGap(6)
            HcSettingRow(
                "Play sounds",
                detail: "Kraal plays a sound when an agent needs you, and shows a note in the corner "
                    + "either way."
            ) {
                HcThemedSwitch(isOn: model.settings.soundEnabled) {
                    model.settings.soundEnabled.toggle()
                }
            }
        }
    }
}

/// A switch the theme draws itself. `Toggle` keeps AppKit's control, which is
/// the wrong blue on a graphite window and the wrong size beside a 13.5pt row.
private struct HcThemedSwitch: View {
    @Environment(\.hcTheme) private var theme
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if isOn { Spacer(minLength: 0) }
                Circle()
                    .fill((isOn ? theme.accentForeground : theme.muted).color)
                    .frame(width: 16, height: 16)
                if !isOn { Spacer(minLength: 0) }
            }
            .padding(2)
            .frame(width: 36, height: 20)
            // `hover` is a 5% wash on `popover` and vanishes there; `input` is
            // the token that stays visible for an off track on both halves.
            .background((isOn ? theme.accent : theme.input).color, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

// MARK: - Updates

private struct HcUpdatesPage: View {
    @ObservedObject var model: HcWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HcPanelHeading("Updates")
            HcSettingGap(6)
            HcSettingRow(
                HcCoreStatusText.version(model.status),
                detail: HcCoreStatusText.link(model.status, stale: model.heartbeatStale)
            ) {
                EmptyView()
            }
            HcSettingGap(12)
            HcSettingNote("Kraal has no updater. Update the core with `hc update`.")
        }
    }
}

// MARK: - Privacy

private struct HcPrivacyPage: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HcPanelHeading("Privacy")
            HcSettingGap(6)
            HcSettingNote("Kraal sends nothing: no telemetry, no analytics, no crash reports.")
            HcSettingGap(12)
            HcSettingSubheading("Core socket")
            HcSettingGap(4)
            Text(model.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.muted.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared pieces

/// The core's version and link, worded once so Machines and Updates say the
/// same thing about the same state.
private enum HcCoreStatusText {
    static func version(_ status: HcWorkspaceModel.Status) -> String {
        if case let .ready(version) = status { return "herdr-core \(version)" }
        return "herdr-core (version unknown)"
    }

    static func local(_ status: HcWorkspaceModel.Status) -> String {
        switch status {
        case let .ready(version): "Connected · herdr-core \(version)"
        case .idle: "Idle · herdr-core unknown"
        case .connecting: "Connecting · herdr-core unknown"
        case let .incompatible(reason): "Incompatible · \(reason)"
        case let .failed(error): "Failed · \(error)"
        }
    }

    static func link(_ status: HcWorkspaceModel.Status, stale: Bool) -> String {
        if stale { return "Linked, but the core has sent no heartbeat for 30 s." }
        switch status {
        case .idle: return "Not connected yet."
        case .connecting: return "Connecting to the core…"
        case .ready: return "Connected; heartbeats every 15 s."
        case let .incompatible(reason): return "Incompatible core · \(reason)"
        case let .failed(error): return "Connection failed · \(error)"
        }
    }

    /// Upstream's colors: connected is `done`, connecting `working`, and
    /// anything that needs a person is `blocked`.
    static func dot(_ state: HcMachineState, theme: HcTheme) -> HcColor {
        switch state {
        case .connected: theme.done
        case .connecting: theme.working
        default: theme.blocked
        }
    }
}

/// A dim line of explanation under a heading.
private struct HcSettingNote: View {
    @Environment(\.hcTheme) private var theme
    private let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.dim.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `Dark` / `Light` above a row of swatches.
private struct HcSettingSubheading: View {
    @Environment(\.hcTheme) private var theme
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.muted.color)
    }
}

/// The vertical rhythm between a page's sections.
private struct HcSettingGap: View {
    let height: CGFloat

    init(_ height: CGFloat) {
        self.height = height
    }

    var body: some View {
        Color.clear.frame(height: height)
    }
}

private struct HcHairline: View {
    @Environment(\.hcTheme) private var theme

    var body: some View {
        Rectangle().fill(theme.border.color).frame(height: 1)
    }
}

/// The 7pt state dot the Machines page uses.
private struct HcStateDot: View {
    let color: HcColor

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: 7, height: 7)
    }
}
