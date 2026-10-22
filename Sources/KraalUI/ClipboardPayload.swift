// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  ClipboardPayload.swift
//  Kraal
//
//  Decodes the `ServerMessage::Clipboard` payload.
//
//  The payload is **base64**, not the raw text: `wire.rs:1421-1424` documents it
//  as "Base64-encoded clipboard data" and the upstream client decodes it before
//  writing (`client/clipboard_forwarding.rs:9-15`).
//
//  This cost a round trip. The first version wrote the string straight to
//  `NSPasteboard`, which type-checked, passed its unit tests, and produced a
//  clipboard containing `S1JBQUxfT1NDNTJfT0s=` instead of `KRAAL_OSC52_OK` — the
//  end-to-end probe caught it, the unit tests could not, because they asserted
//  the shape of my own value rather than the daemon's encoding. Recorded here
//  because it is precisely the failure `AGENTS.md` §0.2 is about.
//
//  Decoding is kept in its own type so the rule "what the daemon sends is base64"
//  is one assertable function instead of a `Data(base64Encoded:)` buried in an
//  AppKit callback.
//

import Foundation

public enum ClipboardPayload {
    /// The bytes a pane asked to place on the clipboard.
    ///
    /// `nil` when the payload is not valid base64, which means this client and
    /// the daemon disagree about the wire format. Returning `nil` rather than the
    /// raw string is deliberate: writing a base64 blob into the user's clipboard
    /// looks like it worked (the paste succeeds, with garbage), so a failure has
    /// to be visible as a failure.
    public static func decode(_ data: String) -> String? {
        guard let bytes = Data(base64Encoded: data) else { return nil }
        // A pasteboard string is textual by definition, so lossy decoding is
        // intentional: a valid UTF-8 clipboard is the overwhelmingly common case,
        // and refusing the whole write over one invalid byte would lose the rest
        // of the text. The failable `String(bytes:encoding:)` — which swiftlint
        // prefers — would turn a partially-corrupt payload into no clipboard at
        // all, which is strictly worse for the user than one replacement char.
        // The exception is stated here rather than silenced silently: rejecting
        // invalid UTF-8 outright would be a behavioural decision, not a style one.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether the payload is something the pasteboard can hold as text.
    ///
    /// An empty payload is legitimate (`pbcopy < /dev/null`) and decodes to `""`.
    public static func isUsable(_ data: String) -> Bool {
        decode(data) != nil
    }
}
