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
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(tab.id == model.workspace.activeSpace?.activeTab
                        ? Color.accentColor.opacity(0.22)
                        : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(tab.name.isEmpty ? "Tab \(tab.displayName)" : tab.name)
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
            let spacing = CGFloat(max(node.children.count - 1, 0))
            let length = axis == .horizontal
                ? max(geometry.size.width - spacing, 0)
                : max(geometry.size.height - spacing, 0)
            let sizes = weights.map { length * CGFloat($0 / total) }
            if axis == .horizontal {
                HStack(spacing: 1) {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        HcPaneTreeView(node: child, model: model)
                            .frame(width: sizes[index])
                    }
                }
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        HcPaneTreeView(node: child, model: model)
                            .frame(height: sizes[index])
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
                HcTerminalPaneView(session: session)
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
