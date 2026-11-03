// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The layout surface: space and tab bars over the tree the shared document
// describes. Every terminal block is its own Ghostty surface; containers are
// plain SwiftUI stacks, so a split is just two frames with the stored weights.

import KraalModel
import SwiftUI

public struct HcLayoutView: View {
    @ObservedObject private var model: HcWorkspaceModel

    public init(model: HcWorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let error = model.layoutError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).lineLimit(1)
                    Spacer()
                    Button("Dismiss") { model.layoutError = nil }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.08))
            }
            HcLayoutToolbar(model: model)
            Divider()
            if let tab = model.workspace.activeTab {
                HcPaneTreeView(node: tab.shown, model: model)
            } else {
                VStack(spacing: 6) {
                    Text("This space has no tabs").font(.headline)
                    Button("New tab") { Task { await model.newTab() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct HcLayoutToolbar: View {
    @ObservedObject var model: HcWorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            spaceMenu
            Divider().frame(height: 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.workspace.activeSpace?.tabs ?? []) { tab in
                        tabButton(tab)
                    }
                    Button {
                        Task { await model.newTab() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New tab")
                }
            }
            Spacer(minLength: 4)
            Button {
                Task { await model.splitFocusedPane(.row) }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split right")
            Button {
                Task { await model.splitFocusedPane(.column) }
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split down")
            Button {
                model.toggleZoom()
            } label: {
                Image(systemName: model.workspace.activeTab?.zoomed == nil
                    ? "arrow.up.left.and.arrow.down.right"
                    : "arrow.down.right.and.arrow.up.left")
            }
            .help("Zoom pane")
            Button {
                Task { await model.closeFocusedPane() }
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close pane")
            Button {
                Task { await model.closeRequestedSpace() }
            } label: {
                Image(systemName: "trash")
            }
            .help("Close space")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var spaceMenu: some View {
        Menu {
            ForEach(model.workspace.spaces) { space in
                Button {
                    model.selectSpace(space.id)
                } label: {
                    if space.id == model.workspace.activeSpace?.id {
                        Label(space.displayName, systemImage: "checkmark")
                    } else {
                        Text(space.displayName)
                    }
                }
            }
            Divider()
            Button("New tab") { Task { await model.newTab() } }
            Button("Next space") { model.nextSpace() }
        } label: {
            Label(model.workspace.activeSpace?.displayName ?? "No space", systemImage: "square.stack.3d.up")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 180)
    }

    private func tabButton(_ tab: KraalTab) -> some View {
        Button {
            model.selectTab(tab.id)
        } label: {
            HStack(spacing: 3) {
                if tab.settled != nil {
                    Image(systemName: "archivebox").font(.caption2)
                }
                Text(tab.displayName).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, model.settings.density.tabPadding)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(tab.id == model.workspace.activeSpace?.activeTab
                        ? Color.accentColor.opacity(0.22)
                        : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(tab.name.isEmpty ? "Tab \(tab.displayName)" : tab.name)
        .draggable(tab.id)
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first, source != tab.id else { return false }
            let destination = (model.workspace.activeSpace?.tabs.firstIndex { $0.id == tab.id } ?? 0) + 1
            Task { await model.moveTab(source, index: destination) }
            return true
        }
    }
}

private struct HcSplitHandle: View {
    static let thickness: CGFloat = 7

    @ObservedObject var model: HcWorkspaceModel
    let container: String
    let index: Int
    let axis: Axis
    let weights: [Double]
    let available: CGFloat
    @State private var startWeights: [Double]?
    @State private var lastWeights: [Double]?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                Rectangle()
                    .fill(hovering ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25))
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
                            .padding(4)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .padding(4)
                }
        }
    }

    @ViewBuilder
    private var block: some View {
        if let terminal = node.terminal {
            if let session = model.paneSessions[node.id] {
                HcTerminalPaneView(
                    session: session,
                    isFocused: model.terminalFocusAllowed
                        && model.workspace.activeTab?.focusedPane == node.id
                )
                .overlay(focusBorder)
                    .onTapGesture { model.focusPane(node.id) }
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    Text(terminal).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(focusBorder)
                .onTapGesture { model.focusPane(node.id) }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle").font(.title2)
                Text(node.raw["content"]?["mod"]?.stringValue ?? "Pane")
                    .font(.callout)
                Text("This block is not a terminal; Kraal keeps it as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.08))
            .overlay(focusBorder)
            .onTapGesture { model.focusPane(node.id) }
        }
    }

    private var focusBorder: some View {
        Rectangle()
            .strokeBorder(
                model.workspace.activeTab?.focusedPane == node.id ? Color.accentColor : Color.clear,
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }
}
