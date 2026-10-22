// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Byte-to-semantic input translation.
//
// Ghostty hands back encoded key bytes (its `write` callback), while the endpoint
// protocol wants semantic events (`ClientPaneInputEvent`). This class bridges
// them: printable text becomes `TextCommit`, control characters and VT escape
// sequences become `Key` events with the right code and modifiers.
//
// Why not send the raw bytes instead: `ClientMessage::Input` belongs to a
// `terminal attach` channel, which this client deliberately does not open (it
// would need a second SSH channel per pane and would fight the desktop client
// over `takeover`). The semantic events travel on the endpoint connection we
// already have, and the daemon applies its own key handling to them.
//
// Escape sequences are consumed incrementally: a key press arrives as one write,
// but a slow paste or an IME commit can split a sequence across writes, so the
// decoder holds an incomplete tail until the next call.

import Foundation

public struct TerminalInputDecoder {
    /// Bytes at the end of the previous chunk that may still grow into a
    /// complete escape sequence.
    private var pending: [UInt8] = []

    /// Whether the focused program asked for every key event
    /// (`ServerMessage::ClientShellKeyboardReportAll`).
    ///
    /// Recorded so the mode is observable rather than dropped (issue #20), but it
    /// must **not** be wired to `tracksRelease`: those are two different things.
    /// `tracksRelease` means "a release for this key is coming", and the daemon
    /// acts on it by *holding the press* until the release arrives
    /// (`server/clients.rs:275-311`). Kraal never emits release events, so
    /// claiming to track them would make every key disappear for a program in
    /// this mode — worse than ignoring the message.
    ///
    /// Upstream derives the field from the key itself — `generated_text.is_none()
    /// || has_physical_identity()` (`protocol/wire.rs:315`) — not from this flag.
    /// Applying that rule needs `ClientKeyKind.release` events, which is a change
    /// to the key pipeline, not to this decoder.
    public var reportsAllKeys = false

    public init() {}

    /// Maximum bytes buffered while waiting for a sequence to complete. A real
    /// sequence is a handful of bytes; this only guards against unbounded growth
    /// if the peer never completes one.
    private static let maxPending = 32

    /// Translates raw terminal input bytes into semantic events.
    public mutating func decode(_ data: Data) -> [ClientPaneInputEvent] {
        pending.append(contentsOf: data)
        var events: [ClientPaneInputEvent] = []
        var index = 0

        while index < pending.count {
            let byte = pending[index]

            if byte == 0x1B {
                // Escape: either a lone ESC or the start of a CSI/SS3 sequence.
                guard index + 1 < pending.count else {
                    // Cannot tell yet; wait for more bytes. A lone ESC that never
                    // grows is flushed by `flushEscape`.
                    break
                }
                let next = pending[index + 1]
                if next == 0x5B || next == 0x4F { // '[' or 'O'
                    guard let (consumed, event) = parseCSI(pending, from: index) else {
                        // Incomplete sequence; keep it for the next call.
                        break
                    }
                    index += consumed
                    if let event { events.append(event) }
                    continue
                }
                // ESC followed by something else: an Alt-modified key.
                events.append(.key(
                    code: keyCode(for: next),
                    modifiers: InputModifiers.alt.rawValue,
                    kind: .press,
                    repeatCount: 1,
                    shiftedCodepoint: nil,
                    generatedText: nil,
                    tracksRelease: false,
                    physicalKeyId: nil,
                    windowsRecord: nil
                ))
                index += 2
                continue
            }

            if let event = controlEvent(for: byte) {
                events.append(event)
                index += 1
                continue
            }

            // Printable text: take the longest valid UTF-8 run.
            let (text, consumed) = consumeText(pending, from: index)
            if consumed > 0 {
                if !text.isEmpty {
                    events.append(.textCommit(text))
                }
                index += consumed
            } else {
                // An incomplete multi-byte scalar at the end of the buffer.
                break
            }
        }

        pending.removeFirst(min(index, pending.count))
        if pending.count > Self.maxPending {
            pending.removeAll()
        }
        return events
    }

    /// Emits a pending lone ESC. Call when the input stream goes idle, since a
    /// bare Esc key press produces exactly one byte and no follow-up.
    public mutating func flushEscape() -> ClientPaneInputEvent? {
        guard pending == [0x1B] else { return nil }
        pending.removeAll()
        return .key(
            code: .esc,
            modifiers: 0,
            kind: .press,
            repeatCount: 1,
            shiftedCodepoint: nil,
            generatedText: nil,
            tracksRelease: false,
            physicalKeyId: nil,
            windowsRecord: nil
        )
    }

    // MARK: - Control characters

    private func controlEvent(for byte: UInt8) -> ClientPaneInputEvent? {
        switch byte {
        case 0x0D: // CR
            return key(.enter)
        case 0x09: // HT
            return key(.tab)
        case 0x7F, 0x08: // DEL, BS
            return key(.backspace)
        case 0x01 ... 0x1A:
            // Ctrl-A ... Ctrl-Z are transmitted as 0x01...0x1A.
            let scalarValue = UInt32(byte - 1) + UInt32(Character("a").asciiValue ?? 97)
            let scalar = Unicode.Scalar(scalarValue) ?? "a"
            return .key(
                code: .char(scalar),
                modifiers: InputModifiers.control.rawValue,
                kind: .press,
                repeatCount: 1,
                shiftedCodepoint: nil,
                generatedText: nil,
                tracksRelease: false,
                physicalKeyId: nil,
                windowsRecord: nil
            )
        default:
            return nil
        }
    }

    private func key(_ code: ClientKeyCode, modifiers: UInt8 = 0) -> ClientPaneInputEvent {
        .key(
            code: code,
            modifiers: modifiers,
            kind: .press,
            repeatCount: 1,
            shiftedCodepoint: nil,
            generatedText: nil,
            tracksRelease: false,
            physicalKeyId: nil,
            windowsRecord: nil
        )
    }

    // MARK: - Escape sequences

    /// Parses a CSI (`ESC [`) or SS3 (`ESC O`) sequence starting at `start`.
    /// Returns the bytes consumed and the event, or nil when the sequence is
    /// still incomplete.
    private func parseCSI(
        _ bytes: [UInt8],
        from start: Int
    ) -> (consumed: Int, event: ClientPaneInputEvent?)? {
        guard start + 2 < bytes.count else { return nil }
        let introducer = bytes[start + 1]
        let bodyStart = start + 2

        // Both forms are "parameters then a final byte in 0x40...0x7E". SS3 was
        // special-cased as exactly three bytes with no parameters, which dropped
        // the modifier parameter: `ESC O 1;5 P` (F1+Ctrl, what xterm sends when
        // modifyOtherKeys is on) decoded the `1` as the final and left `;5 P` to
        // be typed into the pane as text. Reading the shape once for both means
        // there is no second code path to forget.
        var cursor = bodyStart
        var parameters = ""
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte >= 0x40, byte <= 0x7E {
                let event = introducer == 0x4F
                    ? ss3Event(byte, parameters: parameters)
                    : csiEvent(final: byte, parameters: parameters, modifiers: 0)
                return (cursor - start + 1, event)
            }
            parameters.append(Character(UnicodeScalar(byte)))
            cursor += 1
            if cursor - bodyStart > 16 { return (0, nil) }
        }
        return nil
    }

    private func ss3Event(
        _ final: UInt8,
        parameters: String
    ) -> ClientPaneInputEvent? {
        // `ESC O` takes the same `;N` modifier parameter as the CSI form, so the
        // rule lives in one place. A bare `ESC O P` has no parameter at all and
        // must stay unmodified rather than be treated as malformed.
        let parts = parameters.split(separator: ";").compactMap { Int($0) }
        let modifiers: UInt8 = parts.count >= 2
            ? TerminalInputDecoder.modifiers(fromXterm: parts[1])
            : 0
        switch final {
        case 0x41: return key(.arrowUp, modifiers: modifiers)
        case 0x42: return key(.arrowDown, modifiers: modifiers)
        case 0x43: return key(.arrowRight, modifiers: modifiers)
        case 0x44: return key(.arrowLeft, modifiers: modifiers)
        case 0x48: return key(.home, modifiers: modifiers)
        case 0x46: return key(.end, modifiers: modifiers)
        case 0x50 ... 0x53:
            // F1...F4.
            return .key(
                code: .function(final - 0x50 + 1),
                modifiers: modifiers,
                kind: .press,
                repeatCount: 1,
                shiftedCodepoint: nil,
                generatedText: nil,
                tracksRelease: false,
                physicalKeyId: nil,
                windowsRecord: nil
            )
        default:
            return nil
        }
    }

    private func csiEvent(
        final: UInt8,
        parameters: String,
        modifiers: UInt8
    ) -> ClientPaneInputEvent? {
        // A parameter of the form "1;N" carries a modifier bitmask in xterm.
        let parts = parameters.split(separator: ";").compactMap { Int($0) }
        let xtermModifiers: UInt8 = parts.count >= 2
            ? TerminalInputDecoder.modifiers(fromXterm: parts[1])
            : modifiers

        switch final {
        case 0x41: return key(.arrowUp, modifiers: xtermModifiers)
        case 0x42: return key(.arrowDown, modifiers: xtermModifiers)
        case 0x43: return key(.arrowRight, modifiers: xtermModifiers)
        case 0x44: return key(.arrowLeft, modifiers: xtermModifiers)
        case 0x48: return key(.home, modifiers: xtermModifiers)
        case 0x46: return key(.end, modifiers: xtermModifiers)
        case 0x5A: return key(.backTab, modifiers: xtermModifiers)
        case 0x7E: // ESC [ <n> ~
            guard let value = parts.first else { return nil }
            switch value {
            case 1, 7: return key(.home, modifiers: xtermModifiers)
            case 2: return key(.insert, modifiers: xtermModifiers)
            case 3: return key(.delete, modifiers: xtermModifiers)
            case 4, 8: return key(.end, modifiers: xtermModifiers)
            case 5: return key(.pageUp, modifiers: xtermModifiers)
            case 6: return key(.pageDown, modifiers: xtermModifiers)
            case 11 ... 15:
                return .key(
                    code: .function(UInt8(value - 10)),
                    modifiers: xtermModifiers,
                    kind: .press,
                    repeatCount: 1,
                    shiftedCodepoint: nil,
                    generatedText: nil,
                    tracksRelease: false,
                    physicalKeyId: nil,
                    windowsRecord: nil
                )
            case 17 ... 21:
                return .key(
                    code: .function(UInt8(value - 11)),
                    modifiers: xtermModifiers,
                    kind: .press,
                    repeatCount: 1,
                    shiftedCodepoint: nil,
                    generatedText: nil,
                    tracksRelease: false,
                    physicalKeyId: nil,
                    windowsRecord: nil
                )
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// xterm encodes modifiers as `1 + bitmask` where the bits are shift = 1,
    /// alt = 2, ctrl = 4. A reported value of 1 therefore means "no modifier".
    ///
    /// The wire wants shift = 1, control = 2, alt = 4 — so the bits must be
    /// remapped, not passed through.
    static func modifiers(fromXterm value: Int) -> UInt8 {
        guard value > 1 else { return 0 }
        let raw = value - 1
        var result: UInt8 = 0
        if raw & 1 != 0 { result |= InputModifiers.shift.rawValue }
        if raw & 2 != 0 { result |= InputModifiers.alt.rawValue }
        if raw & 4 != 0 { result |= InputModifiers.control.rawValue }
        return result
    }

    // MARK: - Text

    /// Consumes the longest valid UTF-8 prefix at `start`.
    private func consumeText(_ bytes: [UInt8], from start: Int) -> (String, Int) {
        var end = start
        while end < bytes.count {
            let byte = bytes[end]
            let length = utf8Length(for: byte)
            guard length > 0, end + length <= bytes.count else { break }
            // Every byte after the lead must be a continuation byte.
            if length > 1 {
                let continuations = bytes[(end + 1) ..< (end + length)]
                guard continuations.allSatisfy({ $0 & 0xC0 == 0x80 }) else { break }
            }
            end += length
        }
        guard end > start else {
            // Not a valid lead byte at all: consume it so the loop cannot stall
            // on one bad byte forever.
            return ("", utf8Length(for: bytes[start]) == 0 ? 1 : 0)
        }
        let slice = Array(bytes[start ..< end])
        guard let text = String(bytes: slice, encoding: .utf8) else {
            // Not valid UTF-8; drop one byte so the decoder cannot stall.
            return ("", 1)
        }
        return (text, end - start)
    }

    private func utf8Length(for byte: UInt8) -> Int {
        switch byte {
        case 0x00 ... 0x7F: 1
        case 0xC2 ... 0xDF: 2
        case 0xE0 ... 0xEF: 3
        case 0xF0 ... 0xF4: 4
        default: 0
        }
    }

    private func keyCode(for byte: UInt8) -> ClientKeyCode {
        switch byte {
        case 0x0D: .enter
        case 0x09: .tab
        case 0x7F: .backspace
        default:
            if let scalar = Unicode.Scalar(UInt32(byte)), byte >= 0x20 {
                .char(scalar)
            } else {
                .null
            }
        }
    }
}
