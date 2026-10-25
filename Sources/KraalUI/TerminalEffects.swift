// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  TerminalEffects.swift
//  Kraal
//
//  Consumers for the four "the pane is telling you something" events.
//
//  All four arrive on the endpoint connection and were previously thrown away:
//  `windowTitle`, `notification` and `bell` fell into a `default: break` in
//  `applyEndpointEvent`, and `clipboard` did not even get that far — the decoder
//  dropped it. The effect is that a remote `pbcopy` did nothing, a TUI's bell was
//  silent, and the window title never followed the pane.
//
//  The split here is deliberate and is what makes any of this testable:
//
//    * `TerminalEffects` is a plain value type that records *what should happen*.
//      No AppKit, no side effects, fully assertable in `swift test`.
//    * `TerminalEffectsApplier` is the only thing that touches `NSWindow`,
//      `NSPasteboard` and `NSSound`, and it does so from what the value says.
//
//  Upstream also has `ui.toast`, notification policy, and per-sound configuration.
//  Those are policy decisions (when to suppress, where to place) and are left out
//  on purpose; see the issue for why.
//

import Foundation
import KraalClient
import KraalProtocol

// MARK: - What to do

/// The effects a batch of terminal events implies.
///
/// A value, not an object with side effects, so the reduction can be pinned by
/// tests. `TerminalEffectsApplier` consumes it.
public struct TerminalEffects: Equatable, Sendable {
    /// Text a pane asked this machine to put on the clipboard (OSC 52).
    ///
    /// Only the most recent one is kept: two clipboard writes that arrive in the
    /// same batch leave the clipboard holding the last one anyway, and modelling
    /// that explicitly stops a consumer from believing it can replay them.
    public var clipboard: String?
    /// The title the window should show, already rendered.
    public var windowTitle: String?
    /// The title the daemon reported, before rendering. `nil` and blank both mean
    /// "the pane has no title" — kept in the same normalised form so a switch
    /// between them is not mistaken for a change.
    public var reportedTitle: String?
    /// How many bell characters to sound, as a terminal would.
    ///
    /// Upstream sends a count rather than a flag because a program can ring
    /// several times between frames; `NSSound` plays one sound per call, and
    /// playing N of them for N bells in the same frame is indistinguishable from
    /// the user's point of view except in the pathological case. Capped.
    public var bells: UInt16
    /// The most recent notification worth showing, if any.
    public var notification: SemanticNotification?
    /// Which machine the notification is about, when more than one is known.
    ///
    /// Carried alongside rather than looked up at post time: the user can switch
    /// machines between the effect being queued and the desktop draining it, and the
    /// notice would then name the wrong one.
    public var notificationMachine: String?

    public static let none = TerminalEffects(
        clipboard: nil,
        windowTitle: nil,
        reportedTitle: nil,
        bells: 0,
        notification: nil,
        notificationMachine: nil
    )

    /// Nothing to do.
    public var isEmpty: Bool {
        clipboard == nil && windowTitle == nil && bells == 0 && notification == nil
    }

    public init(
        clipboard: String?,
        windowTitle: String?,
        reportedTitle: String?,
        bells: UInt16,
        notification: SemanticNotification?,
        notificationMachine: String? = nil
    ) {
        self.clipboard = clipboard
        self.windowTitle = windowTitle
        self.reportedTitle = reportedTitle
        self.bells = bells
        self.notification = notification
        self.notificationMachine = notificationMachine
    }
}

// MARK: - Turning events into effects

public enum TerminalEffectsReducer {
    /// Bells beyond this are treated as one.
    ///
    /// A pane in a loop can emit thousands per frame. `NSSound.beep()` is
    /// synchronous-ish and queues, so honouring the exact count turns a runaway
    /// program into a hang. Upstream's own default coalesces per frame.
    public static let maxBells: UInt16 = 1

    /// Folds one connection event into the pending effects.
    ///
    /// Pure: the same event sequence always produces the same effects, which is
    /// the property the tests pin.
    public static func reduce(
        _ effects: TerminalEffects,
        event: ConnectionEvent,
        fallbackTitle: String,
        sessionSuffix: String
    ) -> TerminalEffects {
        var next = effects
        switch event {
        case let .clipboard(data):
            // The wire payload is base64 (`wire.rs:1421-1424`), so decode here
            // rather than at the pasteboard: everything downstream deals in the
            // text a pane actually wrote. An undecodable payload is dropped
            // instead of written verbatim — a pasteboard holding `S1JBQUw=` looks
            // like success and pastes garbage.
            guard let text = ClipboardPayload.decode(data) else {
                return effects
            }
            next.clipboard = text
        case let .windowTitle(reported):
            let normalised = reported?.trimmingCharacters(in: .whitespacesAndNewlines)
            let empty = (normalised ?? "").isEmpty
            // Blank and nil are the same state, so both are stored as `nil` and
            // handed on as `nil`. Passing the raw blank string through here made
            // `reportedTitle` and `windowTitle` disagree about what the pane had
            // said — `reportedTitle` claimed blank while the rendered title was
            // the fallback — which is exactly the kind of half-normalised state
            // the next person would misread as "the pane set its title to spaces".
            let value = empty ? nil : normalised
            // The change test alone is not enough here: the batch starts with no
            // title *and* no rendered title, so `nil -> nil` would look
            // unchanged and return early, leaving the window with no title at
            // all. The first event has to establish the fallback even when the
            // pane reported nothing.
            let isFirst = next.windowTitle == nil
            guard isFirst || WindowTitleTemplate.isChange(from: next.reportedTitle, to: value)
            else {
                return next
            }
            next.reportedTitle = value
            next.windowTitle = WindowTitleTemplate.title(
                reported: value,
                fallback: fallbackTitle,
                sessionSuffix: sessionSuffix
            )
        case let .bell(count):
            guard count > 0 else { return next }
            next.bells = min(maxBells, next.bells &+ count)
        case let .notification(notification):
            // `updateInstalled` is not something the user needs a toast for on
            // this machine: it describes the daemon's own binary. Dropping it
            // here (rather than in the UI) keeps the rule testable.
            guard notification.kind != .updateInstalled else { return next }
            next.notification = notification
        default:
            break
        }
        return next
    }
}
