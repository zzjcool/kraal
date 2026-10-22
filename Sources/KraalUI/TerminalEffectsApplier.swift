// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  TerminalEffectsApplier.swift
//  Kraal
//
//  The only place terminal events turn into something the user can see or hear.
//
//  Kept apart from `TerminalEffectsReducer` so the *decision* (what should
//  happen) is covered by `swift test` while the *act* (NSPasteboard, NSWindow,
//  NSSound) is a thin, boring translation. Anything clever belongs in the
//  reducer, where it can be asserted.
//
//  In particular, this is where the AppKit calls that do not work headlessly are
//  isolated: the VM GUI gate can then assert the reducer's output without
//  pretending it verified a notification appeared on screen.
//

import AppKit
import KraalProtocol

@MainActor
public final class TerminalEffectsApplier {
    /// The window whose title follows the pane.
    ///
    /// Weak on purpose: Kraal can tear the window down while a connection is
    /// still live, and a strong reference here would keep AppKit's window (and
    /// its whole view tree) alive past `stop_app`.
    private weak var window: NSWindow?

    /// Deduplicates so a redrawn frame does not post the same paste twice.
    private var lastClipboard: String?
    private var lastNotification: String?

    public init() {}

    public func attach(window: NSWindow) {
        self.window = window
    }

    /// Applies a batch. Returns a short description of what it did, for the log.
    ///
    /// Logging the outcome rather than the intent is deliberate: `AGENTS.md` §0.2
    /// is a list of features that had tests and still did nothing, and every one
    /// of them would have been caught by "does the log say it happened".
    @discardableResult
    public func apply(_ effects: TerminalEffects) -> [String] {
        guard !effects.isEmpty else { return [] }
        var done: [String] = []

        if let text = effects.clipboard, text != lastClipboard {
            // Upstream sends the payload already decoded. An empty string is a
            // legitimate "copy nothing": clear rather than skip, otherwise the
            // clipboard keeps whatever was there before and looks stuck.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !text.isEmpty {
                pasteboard.setString(text, forType: .string)
            }
            lastClipboard = text
            done.append("clipboard=\(text.count)B")
        }

        if let title = effects.windowTitle, let window, window.title != title {
            window.title = title
            done.append("title=\(title)")
        }

        // Bells were already coalesced by the reducer; one sound per batch.
        if effects.bells > 0 {
            NSSound.beep()
            done.append("bell")
        }

        if let notification = effects.notification {
            let key = "\(notification.kind)|\(notification.title)|\(notification.body ?? "")"
            if key != lastNotification {
                lastNotification = key
                // A bell is the only channel this client has for
                // `needsAttention`. Deliberately not a notification-centre
                // post: that needs a bundle identifier and a user grant, and
                // pretending to have posted one is worse than ringing.
                if notification.kind == .needsAttention || notification.sound != nil {
                    NSSound.beep()
                    done.append("bell(notification)")
                }
                done.append("notification=\(notification.title)")
            }
        }

        return done
    }
}
