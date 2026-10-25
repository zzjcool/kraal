// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  SystemNotifier.swift
//  KraalUI
//
//  Posts the daemon's semantic notifications to Notification Centre.
//
//  The protocol is explicit that presentation is the client's call
//  (`src/protocol/wire.rs:1357-1366`): "The server reports the semantic event; each
//  connected shell client chooses how (or whether) to present it." The daemon has
//  already decided *that* something is worth interrupting for, so nothing here
//  re-derives policy from snapshot diffs.
//
//  ## Why the machine label is in the body
//
//  `SemanticNotification` carries `workspace_id` / `tab_id` / `pane_id` but no
//  machine: ids are unique per daemon, not across the fleet. Two machines both
//  report `w1:p1`, so a body of "pane w1:p1 needs attention" cannot be acted on.
//  The caller supplies the endpoint label and it is what makes the notice useful.
//
//  ## Authorisation
//
//  `UNUserNotificationCenter` only works for a bundled app with a stable bundle
//  identifier; the same code under `swift test` is a no-op rather than a crash.
//  A denial is logged once and never retried in a loop — a client that keeps
//  asking after "don't allow" is the behaviour that made people distrust
//  notification prompts in the first place.
//

import AppKit
import Foundation
import KraalProtocol
import UserNotifications

/// Posts terminal notifications to the system notification centre.
///
/// `@MainActor` because `UNUserNotificationCenter.current()` is a per-application
/// singleton and the queueing is UI-adjacent; keeping it on the main actor means
/// the authorisation state has one owner.
@MainActor
public final class SystemNotifier {
    /// What happened to the last attempt, for the log.
    public enum Outcome: Equatable, Sendable {
        /// Queued for delivery.
        case posted
        /// The user has not granted permission.
        case denied
        /// No bundle identifier — this is running outside an app bundle (tests).
        case unavailable
    }

    /// Whether the user has been asked already, so a denial is not re-prompted on
    /// every notification.
    private var askedForAuthorisation = false
    private var authorised = false

    public init() {}

    /// Whether this process can post at all.
    ///
    /// `swift test` links this package into an xctest host without the app's bundle
    /// identifier, where `UNUserNotificationCenter.current()` traps. Checking first
    /// keeps the unit tests able to exercise the *decision* without standing up a
    /// notification centre.
    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Posts one notification. Returns what happened so the caller can log it —
    /// `AGENTS.md` §0.2 is a list of features that had tests and still did nothing.
    public func post(_ notification: SemanticNotification, machine: String?) async -> Outcome {
        guard Self.isAvailable else {
            kraalLog("notification: no bundle identifier; not posting")
            return .unavailable
        }

        // Awaited, not fired-and-forgotten. The first version started a `Task` and
        // then read `authorised` synchronously, so the read always happened before the
        // request could resolve and *every* first notification reported `denied` even
        // when permission was about to be granted.
        await requestAuthorisationIfNeeded()
        guard authorised else {
            kraalLog("notification: not authorised; falling back to the bell")
            return .denied
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        // The machine goes first: with several machines the "which one" question is
        // what makes a notice actionable.
        let body = [machine.map { "[\($0)]" }, notification.body]
            .compactMap { $0 }
            .joined(separator: " ")
        if !body.isEmpty { content.body = body }
        content.sound = notification.sound == .done ? nil : .default
        // Grouped per pane so a chatty agent does not stack N separate banners.
        content.threadIdentifier = [
            machine ?? "", notification.workspaceId ?? "", notification.paneId ?? "",
        ].joined(separator: "/")

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                kraalLog("notification: post failed: \(error.localizedDescription)")
            }
        }
        // Logged here rather than by the caller: this line is the only evidence that
        // the system API was actually reached, and it is what the GUI case asserts.
        kraalLog("notification: posted \(notification.title)")
        return .posted
    }

    /// Asks once. A denied result is remembered, not retried.
    private func requestAuthorisationIfNeeded() async {
        guard !askedForAuthorisation else { return }
        askedForAuthorisation = true
        do {
            authorised = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            if !authorised {
                kraalLog("notification: not authorised; notices stay in-app")
            }
        } catch {
            kraalLog("notification: authorisation failed: \(error.localizedDescription)")
        }
    }
}
