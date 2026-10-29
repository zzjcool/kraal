// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Extracted from `AppStore.swift` when that file reached its length ceiling; the type is
// still the store's own, and lives here only to keep both files readable.

import Foundation

/// Coalescing state for a divider drag.
///
/// A `DragGesture` emits a change per mouse move — hundreds per second on a
/// trackpad — while a request round-trip is milliseconds and the connection
/// serves exactly one command at a time. Sending them all would spend the whole
/// drag being refused with `endpoint_busy`, and the divider would follow only the
/// few that happened to win.
///
/// `pending` holds the newest position the pointer reported; the looping sender in
/// `dragSplitRatio` keeps consuming it, so the requests that do go out always
/// carry where the pointer is *now*, never a stale position queued behind them.
/// Because ratios are absolute positions rather than increments, dropping the
/// intermediate ones loses nothing.
final class SplitDragState {
    struct Target {
        var path: [Bool]
        var ratio: Double
    }

    /// The newest position not yet sent.
    var pending: Target?
    /// Whether a sender loop is already draining `pending`.
    var inFlight = false
    /// The tab the drag started on, named on every request.
    ///
    /// Without it the daemon falls back to "the current tab of the current
    /// workspace", which is the tab this client is showing only for as long as it
    /// keeps showing it. A drag that lands just after a focus change then resizes
    /// a tab nobody is looking at, with no error on either side. `herdr-gpui`
    /// snapshots the same id at press (`SplitDrag.tab`) and names it in every
    /// `layout.set_split_ratio`.
    var tabId: String?
    /// The layout's structure when the drag began, or `nil` when it could not be
    /// read. Every send is fenced against the current one.
    ///
    /// A `path` names a divider by its place in the tree, so a pane closing or
    /// splitting mid-drag can leave the same path naming a different border — the
    /// ratio would be applied to a divider the user never touched, silently.
    var fence: PaneSplitFence?
    /// Whether the drag this state belongs to is still the live one.
    ///
    /// A fence mismatch ends the drag: the rest of `pending` is dropped rather
    /// than retried against a layout it no longer describes.
    var alive = true

    /// Records a new pointer position and drains it, coalescing while one request
    /// is on the wire.
    ///
    /// Kept here rather than in `AppStore` because the loop is all state machine —
    /// the store owns none of it beyond handing over `call`. `AppStore`'s body is
    /// already at swiftlint's limit, and the limit is the thing that noticed the
    /// loop did not belong there.
    @MainActor
    func drive(
        path: [Bool],
        ratio: Double,
        fence: PaneSplitFence?,
        of store: AppStore
    ) async {
        // A new drag (no sender running, nothing pending) adopts the caller's
        // fence; the rest of the same drag keeps the one it started with. Comparing
        // against a fence captured mid-drag would let a structure change slip
        // through between two changes of the same gesture.
        if !inFlight && pending == nil {
            tabId = store.snapshot?.focusedTabId
            self.fence = fence
            alive = true
        }
        pending = Target(path: path, ratio: ratio)
        guard !inFlight else { return }
        inFlight = true
        // Loop rather than recurse: each iteration drains the newest value that
        // arrived while the previous request was on the wire.
        //
        // `defer` and not a trailing statement: `drive` suspends at every `call`,
        // and a second caller reaches the `guard` above while this one is held
        // there, so the flag has to be cleared on every exit path.
        defer { inFlight = false }
        while let next = pending {
            pending = nil
            guard alive else { continue }
            // The live layout must still be the one the drag was grabbed from,
            // checked per send rather than once per drag: the answer that cleared
            // the previous request is exactly where a structure change arrives.
            if let grabbed = fence, store.surface?.splitFence != grabbed {
                alive = false
                continue
            }
            await store.call("layout.set_split_ratio", AppStore.splitRatioParams(
                path: next.path,
                ratio: next.ratio,
                tabId: tabId
            ))
        }
    }
}
