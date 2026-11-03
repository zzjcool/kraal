// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The work surface: the active tab's pane tree on the canvas. Every terminal
// block is a card — a 34pt header over its Ghostty surface — and containers are
// plain SwiftUI stacks, so a split is two frames, an 8pt gap and a 1pt line
// centred in it. Sizes come from `HcChromeMetrics`, colors from `HcChromeColors`.

import KraalHC
import KraalModel
import SwiftUI

public struct HcLayoutView: View {
    @ObservedObject private var model: HcWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: HcWorkspaceModel) {
        self.model = model
    }

    private var colors: HcChromeColors { HcChromeColors.forScheme(colorScheme) }

    public var body: some View {
        VStack(spacing: 0) {
            if let error = model.layoutError {
                errorBanner(error)
            }
            if let tab = model.workspace.activeTab {
                HcPaneTreeView(node: tab.shown, model: model)
                    .padding(HcChromeMetrics.workInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .background(colors.canvas)
    }

    /// A layout that failed to load is worth one line, not a dialog: it clears
    /// as soon as the machine reconnects.
    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error).lineLimit(1)
            Spacer(minLength: 4)
            Button("Dismiss") { model.layoutError = nil }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 12))
        .foregroundStyle(colors.blocked)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("This space has no tabs")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.muted)
            Button("New tab") { Task { await model.newTab() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HcSplitHandle: View {
    /// The gap between sibling panes; the 1pt line sits in its middle.
    static let thickness: CGFloat = HcChromeMetrics.paneGap

    @ObservedObject var model: HcWorkspaceModel
    let container: String
    let index: Int
    let axis: Axis
    let weights: [Double]
    let available: CGFloat
    @State private var startWeights: [Double]?
    @State private var lastWeights: [Double]?
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var colors: HcChromeColors { HcChromeColors.forScheme(colorScheme) }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                Rectangle()
                    .fill(hovering ? colors.accent : colors.border)
                    .frame(width: axis == .horizontal ? 1 : nil,
                           height: axis == .vertical ? 1 : nil)
            }
            .frame(width: axis == .horizontal ? Self.thickness : nil,
                   height: axis == .vertical ? Self.thickness : nil)
            // Upstream gives a divider a wide grab region even though its line
            // is one pixel; the overlap is what makes it possible to hit.
            .contentShape(Rectangle().inset(by: -16))
            .onHover { inside in
                let was = hovering
                hovering = inside
                guard inside != was else { return }
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if hovering { NSCursor.pop() }
            }
            .gesture(drag)
            .accessibilityLabel("Resize panes")
            .accessibilityValue("\(Int((weights[safe: index] ?? 0) * 100))%")
            .accessibilityAdjustableAction { direction in
                adjust(direction == .increment ? 0.05 : -0.05)
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard available > 0, weights.indices.contains(index + 1) else { return }
                let start = startWeights ?? weights
                startWeights = start
                let translation = axis == .horizontal ? value.translation.width : value.translation.height
                guard let next = HcSplitMath.resized(
                    start, index: index, translation: Double(translation), available: Double(available)
                ) else { return }
                lastWeights = next
                model.setSplitWeights(container, weights: next, persist: false)
            }
            .onEnded { _ in
                if let lastWeights {
                    model.setSplitWeights(container, weights: lastWeights, persist: true)
                }
                startWeights = nil
                lastWeights = nil
            }
    }

    private func adjust(_ delta: Double) {
        guard let next = HcSplitMath.adjusted(weights, index: index, delta: delta) else { return }
        model.setSplitWeights(container, weights: next, persist: true)
    }
}

enum HcSplitMath {
    static let minimumPoints: Double = 36

    /// New weights for the pair around a divider after a drag. The pair's total
    /// is what stays constant; the rest of the row/column is untouched.
    static func resized(
        _ start: [Double],
        index: Int,
        translation: Double,
        available: Double,
        minimumPoints: Double = minimumPoints
    ) -> [Double]? {
        guard start.indices.contains(index + 1), available > 0 else { return nil }
        let total = start.reduce(0, +)
        guard total > 0 else { return nil }
        let pair = start[index] + start[index + 1]
        let minimum = total * minimumPoints / available
        guard pair > minimum * 2 else { return nil }
        let left = min(max(start[index] + translation / available * total, minimum), pair - minimum)
        var next = start
        next[index] = left
        next[index + 1] = pair - left
        return next
    }

    static func adjusted(_ weights: [Double], index: Int, delta: Double) -> [Double]? {
        guard weights.indices.contains(index + 1) else { return nil }
        var next = weights
        let pair = next[index] + next[index + 1]
        guard pair > 0.1 else { return nil }
        next[index] = min(max(next[index] + delta, 0.05), pair - 0.05)
        next[index + 1] = pair - next[index]
        return next
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct HcPaneTreeView: View {
    let node: KraalNode
    @ObservedObject var model: HcWorkspaceModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: HcChromeColors { HcChromeColors.forScheme(colorScheme) }

    /// The tab's focused pane: the card outline follows it, and so does the
    /// terminal's first responder.
    private var isFocused: Bool {
        model.workspace.activeTab?.focusedPane == node.id
    }

    private var terminalRecord: HcTerminal? {
        guard let address = node.terminal else { return nil }
        return model.terminals.first { $0.address == address }
    }

    var body: some View {
        switch node.type {
        case "row":
            split(axis: .horizontal)
        case "column":
            split(axis: .vertical)
        case "stack":
            stack
        default:
            block
        }
    }

    private func split(axis: Axis) -> some View {
        GeometryReader { geometry in
            let weights = node.children.map { child in
                max(child.raw["size"]?["weight"]?.doubleValue ?? 1, 0.01)
            }
            let total = weights.reduce(0, +)
            let gaps = CGFloat(max(node.children.count - 1, 0)) * HcSplitHandle.thickness
            let length = max((axis == .horizontal ? geometry.size.width : geometry.size.height) - gaps, 0)
            let sizes = weights.map { length * CGFloat($0 / total) }
            if axis == .horizontal {
                HStack(spacing: 0) {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        HcPaneTreeView(node: child, model: model)
                            .frame(width: sizes[index])
                        if index < node.children.count - 1 {
                            HcSplitHandle(
                                model: model, container: node.id, index: index,
                                axis: axis, weights: weights, available: length
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        HcPaneTreeView(node: child, model: model)
                            .frame(height: sizes[index])
                        if index < node.children.count - 1 {
                            HcSplitHandle(
                                model: model, container: node.id, index: index,
                                axis: axis, weights: weights, available: length
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var stack: some View {
        let children = node.children
        let active = node.raw["active"]?.stringValue
        if let child = children.first(where: { $0.id == active }) ?? children.first {
            HcPaneTreeView(node: child, model: model)
                .overlay(alignment: .topLeading) {
                    Menu {
                        ForEach(children) { child in
                            Button(child.id) {
                                model.selectStackChild(stack: node.id, child: child.id)
                            }
                        }
                    } label: {
                        Image(systemName: "square.stack")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.muted)
                            .padding(4)
                            .background(colors.raised, in: RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(colors.border, lineWidth: 1)
                            }
                    }
                    .menuStyle(.borderlessButton)
                    .padding(6)
                }
        }
    }

    @ViewBuilder
    private var block: some View {
        if let terminal = node.terminal {
            if let session = model.paneSessions[node.id] {
                card {
                    HcTerminalPaneView(
                        session: session,
                        isFocused: model.terminalFocusAllowed && isFocused
                    )
                    .padding(.horizontal, HcChromeMetrics.terminalInsetX)
                    .padding(.vertical, HcChromeMetrics.terminalInsetY)
                }
            } else {
                card {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text(terminal).font(.caption).foregroundStyle(colors.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            card {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle").font(.title2)
                    Text(node.raw["content"]?["mod"]?.stringValue ?? "Pane")
                        .font(.callout)
                    Text("This block is not a terminal; Kraal keeps it as it is.")
                        .font(.caption)
                        .foregroundStyle(colors.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The pane as the official app frames it: a rounded surface, its own
    /// header, and a 1pt outline that turns accent while the pane has focus.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HcPaneHeader(model: model, node: node, terminal: terminalRecord)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: HcChromeMetrics.paneRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HcChromeMetrics.paneRadius)
                .strokeBorder(isFocused ? colors.accent : colors.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: HcChromeMetrics.paneRadius))
        .onTapGesture { model.focusPane(node.id) }
    }
}

/// One pane's header: program icon, title, folder, the agent's status and — on
/// hover — split, zoom and close for the pane. The official mod draws the same
/// four groups at 34pt; this one reads Kraal's tokens.
private struct HcPaneHeader: View {
    @ObservedObject var model: HcWorkspaceModel
    let node: KraalNode
    let terminal: HcTerminal?

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    /// The programs the official app draws with its plain shell glyph.
    private static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "nu", "pwsh", "powershell",
        "cmd", "elvish", "xonsh", "tcsh", "csh", "ksh", "ion",
    ]

    private var colors: HcChromeColors { HcChromeColors.forScheme(colorScheme) }

    /// The agent reporting from this pane, when one does. Parents come before
    /// their children, so the first match is the one the pane belongs to.
    private var agent: HcAgent? {
        model.agents.first { $0.pane == node.id }
    }

    /// The word the icon table knows: the agent's own app, then whatever the
    /// terminal reports, then its foreground program. Shells stay `terminal`.
    private var iconWord: String? {
        if let app = agent?.app, !app.isEmpty { return app }
        if let reported = terminal?.status?["app"]?.stringValue, !reported.isEmpty { return reported }
        guard let foreground = terminal?.foreground?.name, !foreground.isEmpty else { return nil }
        let program = foreground.split(separator: "/").last.map { String($0) } ?? foreground
        return Self.shellNames.contains(program.lowercased()) ? nil : program
    }

    private var title: String {
        if let agent {
            let tab = agent.tabName
            if !tab.isEmpty, tab.first?.isNumber != true { return tab }
            if !agent.name.isEmpty { return agent.name }
        }
        if let title = Self.cleaned(terminal?.title ?? "") { return title }
        if let foreground = terminal?.foreground?.name, !foreground.isEmpty { return foreground }
        return fallbackTitle
    }

    /// A block without a terminal is a mod Kraal keeps as it is: name it after
    /// the mod rather than calling it a shell.
    private var fallbackTitle: String {
        guard node.terminal == nil else { return "shell" }
        return node.raw["content"]?["mod"]?.stringValue ?? "Pane"
    }

    private var folder: String {
        HcChromeFormat.folder(terminal?.cwd ?? "", home: model.workspace.home)
    }

    /// Titles arrive with a spinner or a prompt glyph in front; drop it the same
    /// way the agent rows drop their own decoration. A bare `~` and the like
    /// become empty, which is what the fallbacks are for.
    private static func cleaned(_ raw: String) -> String? {
        let text = String(raw.drop(while: { !$0.isLetter && !$0.isNumber }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: HcAgentAppIcon.symbol(for: iconWord))
                    .font(.system(size: 14))
                    .foregroundStyle(colors.dim)
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(folder)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                status
                if hovering { actions }
            }
            .padding(.horizontal, 10)
            .frame(height: HcChromeMetrics.paneHeaderHeight)
            .background(colors.surface)
            // The header is 34pt of content over a 1pt line, like the titlebar.
            Rectangle().fill(colors.border).frame(height: 1)
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var status: some View {
        if let state = agent?.status {
            switch state {
            case .blocked:
                Text("Needs you")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(colors.blocked)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(colors.blocked.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            case .working:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(colors.working)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            case .done:
                Circle().fill(colors.done).frame(width: 7, height: 7)
            case .idle:
                EmptyView()
            }
        }
    }

    /// The four controls live inside each pane's chrome, so each one first
    /// makes its own pane the focused one. Without that, hovering pane B and
    /// pressing close would close pane A (the model's APIs are focus-based).
    private var actions: some View {
        HStack(spacing: 2) {
            actionButton("rectangle.split.2x1", help: "Split right") {
                model.focusPane(node.id)
                Task { await model.splitFocusedPane(.row) }
            }
            actionButton("rectangle.split.1x2", help: "Split down") {
                model.focusPane(node.id)
                Task { await model.splitFocusedPane(.column) }
            }
            actionButton(
                model.workspace.activeTab?.zoomed == nil
                    ? "arrow.up.left.and.arrow.down.right"
                    : "arrow.down.right.and.arrow.up.left",
                help: "Zoom pane"
            ) {
                model.focusPane(node.id)
                model.toggleZoom()
            }
            actionButton("xmark", help: "Close pane") {
                model.focusPane(node.id)
                Task { await model.closeFocusedPane() }
            }
        }
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(colors.dim)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}
