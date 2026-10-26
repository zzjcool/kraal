// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// What a divider drag has to re-check before every send.
//
// Ported from `herdr-gpui/crates/herdr-gpui/src/terminal/splits.rs` (`topology`)
// and the guards in `window/mouse.rs` (`flush_split`). Rebuilt on the wire type
// this client already decodes, `KraalProtocol.PaneSurfaceFrame`.
//
// Why this exists at all: `layout.set_split_ratio` names a divider by `path`,
// and a path is a *position in a tree*, not an identity. Closing one pane or
// splitting another moves every path below it, so a path captured when the drag
// began can name a different border by the time the next request goes out. The
// daemon accepts it — it is a valid path — and the ratio is then applied to a
// divider the user never touched, with `ok` on both sides. There is no error to
// catch, which is why the check has to be here rather than in a failure path.

import Foundation
import KraalProtocol

/// A layout's structure, with every position and size left out.
///
/// Deliberately excludes `position`, `area`, `hitRect` and the pane rectangles:
/// a drag that succeeds changes all of them, so including any one would end the
/// drag at its own first request. What is kept is only "which panes exist" and
/// "which paths hold which direction" — the things a close or a split changes.
///
/// Both collections are sorted, so a daemon that reorders its arrays without
/// changing the layout does not read as a change.
///
/// `herdr-gpui` hashes the same two sorted collections (`splits::topology`).
/// This is a value rather than a hash: comparing it costs one pass, it cannot
/// collide, and a test failure prints the layout instead of a 64-bit number.
public struct PaneSplitFence: Equatable, Sendable {
    /// A divider as structure alone: where it sits in the tree, and which way it
    /// faces. `vertical` is `direction == .vertical`, which is the wire's
    /// spelling of "a horizontal line between stacked panes".
    struct Divider: Hashable, Sendable {
        let path: [Bool]
        let vertical: Bool
    }

    let panes: [String]
    let dividers: [Divider]

    /// The fence for a layout, or `nil` when there is no divider to drag.
    ///
    /// `nil` rather than an empty value: a frame with no dividers cannot be the
    /// fence of a drag, and expressing that as a value would let a caller compare
    /// two "nothing to drag" layouts as if they matched.
    public init?(_ frame: PaneSurfaceFrame) {
        guard !frame.splits.isEmpty else { return nil }
        panes = frame.panes.map(\.paneId).sorted()
        dividers = frame.splits
            .map { Divider(path: $0.path, vertical: $0.direction == .vertical) }
            .sorted(by: PaneSplitFence.order)
    }

    init(panes: [String], dividers: [Divider]) {
        self.panes = panes
        self.dividers = dividers
    }

    /// Total order over dividers, so the sorted form is canonical.
    ///
    /// Paths are compared element by element — a prefix sorts before its
    /// extensions, which is the folder-before-contents order a tree wants — and
    /// two dividers that share a path are separated by direction so the result
    /// does not depend on the input order.
    static func order(_ lhs: Divider, _ rhs: Divider) -> Bool {
        let shared = min(lhs.path.count, rhs.path.count)
        for index in 0..<shared where lhs.path[index] != rhs.path[index] {
            // `false` is the first side of a split, so it sorts first.
            return !lhs.path[index]
        }
        if lhs.path.count != rhs.path.count {
            return lhs.path.count < rhs.path.count
        }
        return !lhs.vertical && rhs.vertical
    }
}

extension PaneSurfaceFrame {
    /// Structure-only identity of this layout, or `nil` without dividers.
    public var splitFence: PaneSplitFence? {
        PaneSplitFence(self)
    }
}
