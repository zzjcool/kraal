// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `kraal-gui key`, split out of `main.swift` to keep that file under the 900-line
// lint limit. The command is here rather than only in `SyntheticInput` because its
// value is entirely in what it *refuses*: a key that is silently wrong is how
// issue #92 happened.

import AppKit
import Foundation

/// Sends one key chord.
///
/// Two channels, and they refuse rather than guess:
///
/// - `--name escape` — a named key. Named keys are the only way to express ESC,
///   Tab, the arrows and the rest as *keys*; `--char` takes the first character of
///   its argument, so `--char escape` used to post the letter `e` and exit 0
///   (issue #92).
/// - `--char a` — exactly one character from the US layout table.
///
/// An unknown name is an error listing the names that work. A multi-character
/// `--char` is an error pointing at `--name`. Neither silently degrades: a wrong
/// key that reports success is how a case ends up green while testing something
/// else.
func commandKey(_ args: Arguments) -> Never {
    guard let app = TargetApp.find(name: args.string("app") ?? "Kraal") else {
        fail(.harness, "no running app matching '\(args.string("app") ?? "Kraal")'")
    }
    let name = args.string("name")
    let char = args.string("char")
    if name != nil, char != nil {
        fail(.harness, "key takes --name or --char, not both — which key did you mean?")
    }
    guard name != nil || char != nil else {
        fail(.harness, "key needs --name (e.g. escape) or --char (e.g. a)")
    }
    let modifiers = CGEventFlags.parse(args.string("mod"))
    guard activateAndConfirm(app) else {
        fail(.harness, "could not bring '\(app.name)' to the front for a key event")
    }
    let described: String
    if let name {
        guard SyntheticInput.key(name: name, modifiers: modifiers) else {
            fail(.harness, "no key named '\(name)'. supported: "
                + SyntheticInput.supportedKeyNames.joined(separator: ", "))
        }
        described = "\(name)"
    } else if let char {
        switch SyntheticInput.key(char: char, modifiers: modifiers) {
        case let .sent(code):
            described = "'\(char)' (keycode \(code))"
        case .refused:
            // The most likely mistake by far, and the one that used to pass: a key
            // *name* passed to `--char`. Say so instead of "no key code".
            if char.count > 1 {
                fail(.harness, "--char takes one character, got '\(char)'. "
                    + "For a named key use --name \(char.lowercased()) "
                    + "(supported: \(SyntheticInput.supportedKeyNames.joined(separator: ", ")))")
            }
            fail(.harness, "no virtual key code for '\(char)' on a US layout")
        }
    } else {
        fail(.harness, "key needs --name or --char")
    }
    print("sent key \(described) mods=\(modifiers.rawValue)")
    requireAlive(app, context: "key")
    exit(Exit.success.rawValue)
}
