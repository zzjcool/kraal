// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// The engine's mode-2048 size report is host traffic, not program input.
//
// Ghostty writes `ESC [ 48 ; rows ; columns ; heightPx ; widthPx t` to its host
// when the grid settles. Forwarded to the core it would be typed into the
// program; the old renderer had the same filter (`EngineScreenReport`). The
// engine emits each report as one callback of its own, so a whole-chunk match is
// the right test — and stricter than scanning, which would eat a paste.

import Foundation

enum HcEngineSizeReport {
    private static let prefix: [UInt8] = [0x1B, 0x5B, 0x34, 0x38, 0x3B] // ESC [ 4 8 ;
    private static let terminator: UInt8 = 0x74 // t
    private static let separator: UInt8 = 0x3B // ;
    private static let digits: ClosedRange<UInt8> = 0x30 ... 0x39

    static func isReport(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.starts(with: prefix) else { return false }

        var fields = 0
        var digitsInField = 0
        var index = prefix.count
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if digits.contains(byte) {
                digitsInField += 1
            } else if byte == separator || byte == terminator {
                guard digitsInField > 0 else { return false }
                fields += 1
                digitsInField = 0
                if byte == terminator {
                    // rows, columns, height, width
                    return fields == 4 && index == bytes.count
                }
            } else {
                return false
            }
        }
        return false
    }
}
