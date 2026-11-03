// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// First launch: three pages that say what Kraal is, pick the look and offer the
// way in. Overlay, not a sheet, so the (empty) window stays visible behind it.
//
// The sizes are the official welcome's: a 660×600 card with a 52pt header, a
// scrolling body padded 22, and a footer with the page dots on the left and the
// two buttons on the right. Every way out — Esc, the scrim (the presenter owns
// that click), Back/Next and the last page's primary button — ends in
// `dismissWelcome()`, so the first thing a new person sees can never trap them.

import SwiftUI

struct HcWelcomeView: View {
    @ObservedObject var model: HcWorkspaceModel
    @Environment(\.hcTheme) private var theme
    @State private var page = 1
    /// The dialog owns the keyboard while it is up. Without focus its own Esc
    /// and arrow handling never sees a key event, and the terminal behind it
    /// takes the keystrokes instead.
    @FocusState private var focused: Bool

    private static let pageCount = 3

    var body: some View {
        HcDialogCard {
            VStack(spacing: 0) {
                header
                HcWelcomeHairline()
                ScrollView {
                    pageBody
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HcWelcomeHairline()
                footer
            }
            .frame(width: 660, height: 600)
            // The card rounds its own corners; the scroll area inside must not
            // paint over them when a page is taller than the body.
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .task {
            // The overlay exists before AppKit hands the window a first
            // responder; without this, Esc and the arrows reach the terminal and
            // the tour cannot be left from the keyboard (caught in the Tart VM).
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
        .onExitCommand { model.dismissWelcome() }
        .onKeyPress(.escape) {
            model.dismissWelcome()
            return .handled
        }
        // Nothing on these pages takes text, so the arrows are always free.
        .onKeyPress(.leftArrow) {
            turn(to: page - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            turn(to: page + 1)
            return .handled
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent.color)
            Text("Welcome to Kraal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.foreground.color)
            Text("EARLY")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.muted.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 0.5)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(theme.border.color, lineWidth: 1)
                }
            Spacer(minLength: 8)
            Text("Esc")
                .font(.system(size: 11))
                .foregroundStyle(theme.dim.color)
            Button {
                model.dismissWelcome()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.muted.color)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            dots
                .padding(.leading, 6)
            Spacer(minLength: 12)
            if page > 1 {
                Button("Back") { turn(to: page - 1) }
                    .buttonStyle(HcQuietButtonStyle())
            }
            Button(page < Self.pageCount ? "Next" : "Open a space") {
                if page < Self.pageCount {
                    turn(to: page + 1)
                } else {
                    openSpace()
                }
            }
            .buttonStyle(HcPrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(1...Self.pageCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == page ? theme.foreground.color : theme.input.color)
                    .frame(width: index == page ? 16 : 6, height: 6)
            }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case 1: pageOne
        case 2: pageTwo
        default: pageThree
        }
    }

    /// Page 1 answers "what am I looking at" before the three cards do their work.
    private var pageOne: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("Kraal runs your terminals in the background")
            Text(
                "The terminals and agents you open here do not live in this window. "
                    + "They run in herdr-core, a small program on your computer: close Kraal, "
                    + "and they keep working."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(theme.muted.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
            card(
                icon: "command",
                title: "One key opens everything",
                detail: "⇧⌘P lists every command, with its key on the right."
            )
            card(
                icon: "server.rack",
                title: "Your terminals live on their machines",
                detail: "Close the window and they keep running; add a machine over ssh."
            )
            card(
                icon: "rectangle.on.rectangle",
                title: "Kraal is the window; herdr-core does the work",
                detail: "Spaces, tabs and panes come from the core, so an agent sees the same layout."
            )
            HcWelcomeHairline()
                .padding(.vertical, 2)
            HStack(spacing: 12) {
                rowLabel("Appearance")
                HcSegmented(
                    items: HcAppearance.allCases.map { (value: $0, label: $0.title) },
                    selection: $model.settings.appearance
                )
            }
            HStack(spacing: 12) {
                rowLabel("Size")
                HcStepper(
                    value: "\(Int(model.settings.fontSize)) pt",
                    decrement: { zoom(by: -1) },
                    increment: { zoom(by: 1) }
                )
            }
        }
    }

    /// Both controls write `model.settings`, whose didSet saves and applies, so
    /// the window behind the dialog changes while the person is still on it.
    private var pageTwo: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("Make it yours")
            HStack(spacing: 12) {
                rowLabel("Appearance")
                HcSegmented(
                    items: HcAppearance.allCases.map { (value: $0, label: $0.title) },
                    selection: $model.settings.appearance
                )
            }
            HStack(spacing: 12) {
                rowLabel("Size")
                HcStepper(
                    value: "\(Int(model.settings.fontSize)) pt",
                    decrement: { zoom(by: -1) },
                    increment: { zoom(by: 1) }
                )
            }
        }
    }

    private var pageThree: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("Where to go next")
            hint(
                keys: "cmd-shift-p",
                title: "Commands",
                detail: "Every action by name, with its key on the right."
            )
            hint(
                keys: "cmd-p",
                title: "Go somewhere",
                detail: "Jump to a space or a tab without reaching for the mouse."
            )
            hint(
                keys: "cmd-/",
                title: "Keys",
                detail: "The whole keymap on one page, when you want the full list."
            )
            hint(
                keys: "cmd-,",
                title: "Settings",
                detail: "Look and keyboard, machines and alerts."
            )
        }
    }

    // MARK: - Pieces

    private func card(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(theme.accent.color)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.foreground.color)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pageTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(theme.foreground.color)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.muted.color)
            .frame(width: 84, alignment: .leading)
    }

    private func hint(keys: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HcKeyCaps(keys)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.foreground.color)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func turn(to target: Int) {
        page = min(max(target, 1), Self.pageCount)
    }

    private func zoom(by delta: Double) {
        model.settings.fontSize = HcFontZoom.next(model.settings.fontSize, by: delta)
    }

    /// The last page's button: make the space this window is for, then get out
    /// of the way. `space.new` failing still dismisses — an empty window with
    /// "No live terminal" is a better place to debug than a modal.
    private func openSpace() {
        Task {
            _ = await model.performAction("space.new")
            model.dismissWelcome()
        }
    }
}

/// The one-pixel line between the header, the body and the footer.
private struct HcWelcomeHairline: View {
    @Environment(\.hcTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.border.color)
            .frame(height: 1)
    }
}
