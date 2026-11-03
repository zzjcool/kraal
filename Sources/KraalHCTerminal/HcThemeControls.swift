// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The small pieces every overlay shares: keycaps, the segmented control, the
// dialog card, section headings, theme swatches, buttons and text fields. All of
// them paint from `HcTheme` tokens, so there is nowhere for a white system
// segmented control or a hardcoded accent to leak into a dark window.

import SwiftUI

// MARK: - Keycaps

/// `"cmd-shift-]"` → `["cmd", "shift", "]"]`. A trailing `--` is the zoom-out
/// key, not an empty part (`ctrl--` → `["ctrl", "-"]`).
public enum HcKeyCapParts {
    public static func split(_ keys: String) -> [String] {
        if keys.hasSuffix("--") {
            return keys.dropLast(2).split(separator: "-").map(String.init) + ["-"]
        }
        return keys.split(separator: "-").map(String.init)
    }
}

/// One key, drawn as its own chip: the palette's and the keybinds dialog's
/// right-hand column.
public struct HcKeyCap: View {
    @Environment(\.hcTheme) private var theme
    public let label: String

    public init(_ label: String) {
        self.label = label
    }

    public var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(theme.dim.color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(theme.border.color, lineWidth: 1)
            }
    }
}

/// A whole combo: one chip per key, 3pt apart, like `cmd` `shift` `]`.
public struct HcKeyCaps: View {
    public let keys: String

    public init(_ keys: String) {
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(HcKeyCapParts.split(keys).enumerated()), id: \.offset) { _, part in
                HcKeyCap(part)
            }
        }
    }
}

// MARK: - Panel pieces

/// `LAYOUT`, `THEME`: 11pt, uppercase, letter-spaced, dim.
public struct HcPanelHeading: View {
    @Environment(\.hcTheme) private var theme
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .kerning(0.6)
            .foregroundStyle(theme.dim.color)
    }
}

/// A row: title, optional explanation, trailing control. Settings is built from
/// these, so every page has the same rhythm.
public struct HcSettingRow<Accessory: View>: View {
    @Environment(\.hcTheme) private var theme
    let title: String
    let detail: String?
    let accessory: Accessory

    public init(_ title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(theme.foreground.color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 7)
    }
}

/// The floating panel a dialog sits on: popover fill, hairline border, a shadow
/// that reads on both light and dark chrome.
public struct HcDialogCard<Content: View>: View {
    @Environment(\.hcTheme) private var theme
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(theme.popover.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.border.color, lineWidth: 1)
            }
            .shadow(color: .black.opacity(theme.isLight ? 0.16 : 0.42), radius: 24, y: 10)
    }
}

// MARK: - Segmented control

/// A segmented control that follows the theme. `Picker(.segmented)` draws the
/// system's white track in a dark window; this one cannot.
public struct HcSegmented<Value: Hashable>: View {
    @Environment(\.hcTheme) private var theme
    public let items: [(value: Value, label: String)]
    @Binding public var selection: Value

    public init(items: [(value: Value, label: String)], selection: Binding<Value>) {
        self.items = items
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let isOn = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(.system(size: 13))
                        .foregroundStyle(isOn ? theme.foreground.color : theme.muted.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isOn ? theme.raised.color : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isOn ? theme.border.color : Color.clear, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.background.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.border.color, lineWidth: 1)
        }
    }
}

/// `-` value `+`, as the welcome and the Look page use for sizes.
public struct HcStepper: View {
    @Environment(\.hcTheme) private var theme
    public let value: String
    public let decrement: () -> Void
    public let increment: () -> Void

    public init(value: String, decrement: @escaping () -> Void, increment: @escaping () -> Void) {
        self.value = value
        self.decrement = decrement
        self.increment = increment
    }

    public var body: some View {
        HStack(spacing: 0) {
            button("minus", action: decrement)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.foreground.color)
                .frame(minWidth: 46)
            button("plus", action: increment)
        }
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(theme.border.color, lineWidth: 1)
        }
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.muted.color)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Theme swatch

/// One theme in the Look page: a miniature of the theme in its own colors, its
/// name, and a check when it is the one in use.
public struct HcThemeSwatch: View {
    @Environment(\.hcTheme) private var theme
    public let name: HcThemeName
    public let selected: Bool
    public let action: () -> Void

    public init(name: HcThemeName, selected: Bool, action: @escaping () -> Void) {
        self.name = name
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        let shown = HcTheme.resolve(name)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(shown.terminalForeground.color)
                        .frame(width: 44, height: 4)
                    HStack(spacing: 4) {
                        ForEach(Array(shown.swatchDots.enumerated()), id: \.offset) { _, dot in
                            Circle().fill(dot.color).frame(width: 8, height: 8)
                        }
                    }
                }
                .padding(7)
                .frame(width: 112, height: 37, alignment: .topLeading)
                .background(shown.background.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.border.color, lineWidth: 1)
                }
                HStack(spacing: 5) {
                    Text(shown.name.displayName)
                        .font(.system(size: 12.5))
                        .foregroundStyle(selected ? theme.foreground.color : theme.muted.color)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                    }
                }
            }
            .padding(6)
            .frame(width: 124, alignment: .leading)
            .background(selected ? theme.raised.color : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? theme.accent.color : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Buttons and fields

/// A filled button (`solid`), used for the one primary action in a dialog.
public struct HcPrimaryButtonStyle: ButtonStyle {
    @Environment(\.hcTheme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(theme.solidForeground.color)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(theme.solid.color.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// A quiet button: raised fill, hairline border.
public struct HcQuietButtonStyle: ButtonStyle {
    @Environment(\.hcTheme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(theme.foreground.color)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(theme.raised.color.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(theme.border.color, lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}

/// A text field on the terminal background, with the accent ring when focused —
/// the palette's search row and every dialog input.
public struct HcField: View {
    @Environment(\.hcTheme) private var theme
    @FocusState private var focused: Bool
    private let prompt: String
    @Binding private var text: String
    private let onSubmit: (() -> Void)?

    public init(_ prompt: String, text: Binding<String>, onSubmit: (() -> Void)? = nil) {
        self.prompt = prompt
        _text = text
        self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundColor(theme.dim.color))
            .textFieldStyle(.plain)
            .font(.system(size: 12.8))
            .foregroundStyle(theme.foreground.color)
            .focused($focused)
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(theme.background.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(focused ? theme.accent.color : theme.input.color, lineWidth: 1)
            }
    }
}
