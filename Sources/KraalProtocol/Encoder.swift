// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Encoder for the client half of the wire: every `ClientMessage` the app can
// send. Split from `Decoder.swift` only for file size; the two halves are read
// together when checking a tag against `wire.rs`.

import Foundation

public enum ClientMessageEncoder {
    /// Encodes a `ClientMessage` (tag + body) into one bincode payload,
    /// without the length prefix; `FrameEncoder` adds that.
    public static func encode(_ message: ClientMessage) -> Data {
        var writer = BincodeWriter()
        writer.writeVarint(message.tag)
        switch message {
        // The byte-level terminal channel (tags 0...10).
        case .terminalHello, .input, .clipboardImage, .resize, .detach,
             .attachTerminal, .attachScroll, .observeTerminal, .controlTerminal,
             .graphicsTransmissionResult, .graphicsTransmissionStarted:
            encodeTerminalChannel(&writer, message)

        // Everything the endpoint/shell protocol adds (tags 11...20).
        default:
            encodeShellChannel(&writer, message)
        }
        return Data(writer.bytes)
    }

    private static func encodeTerminalChannel(
        _ writer: inout BincodeWriter,
        _ message: ClientMessage
    ) {
        switch message {
        case let .terminalHello(version, cols, rows, cellWidth, cellHeight, pixelMouse):
            writer.writeVarint(UInt64(version))
            writer.writeVarint(UInt64(cols))
            writer.writeVarint(UInt64(rows))
            writer.writeVarint(UInt64(cellWidth))
            writer.writeVarint(UInt64(cellHeight))
            writer.writeBool(pixelMouse)

        case let .input(data):
            writer.writeByteBuffer(data)

        case let .clipboardImage(target, ext, data):
            encodeClipboardTarget(&writer, target)
            writer.writeString(ext)
            writer.writeByteBuffer(data)

        case let .resize(cols, rows, cellWidth, cellHeight, pixelMouse):
            writer.writeVarint(UInt64(cols))
            writer.writeVarint(UInt64(rows))
            writer.writeVarint(UInt64(cellWidth))
            writer.writeVarint(UInt64(cellHeight))
            writer.writeBool(pixelMouse)

        case .detach:
            break

        case let .attachTerminal(terminalId, takeover):
            writer.writeString(terminalId)
            writer.writeBool(takeover)

        case let .attachScroll(source, direction, lines, column, row, modifiers):
            encodeScrollSource(&writer, source)
            writer.writeVarint(direction == .upward ? 0 : 1)
            writer.writeVarint(UInt64(lines))
            writer.writeOptional(column) { $0.writeVarint(UInt64($1)) }
            writer.writeOptional(row) { $0.writeVarint(UInt64($1)) }
            writer.writeU8(modifiers)

        case let .observeTerminal(target):
            writer.writeString(target)

        case let .controlTerminal(target, takeover):
            writer.writeString(target)
            writer.writeBool(takeover)

        case let .graphicsTransmissionResult(transferId, imageId, success):
            writer.writeVarint(transferId)
            writer.writeVarint(UInt64(imageId))
            writer.writeBool(success)

        case let .graphicsTransmissionStarted(transferId, imageId):
            writer.writeVarint(transferId)
            writer.writeVarint(UInt64(imageId))

        default:
            break
        }
    }

    private static func encodeShellChannel(
        _ writer: inout BincodeWriter,
        _ message: ClientMessage
    ) {
        switch message {
        case let .clientShellHello(version, cellWidth, cellHeight, size, pixelMouse,
                                   directGraphics, endpointKeybindings, mouseCapture):
            writer.writeVarint(UInt64(version))
            writer.writeVarint(UInt64(cellWidth))
            writer.writeVarint(UInt64(cellHeight))
            writer.writeVarint(UInt64(size.cols))
            writer.writeVarint(UInt64(size.rows))
            writer.writeBool(pixelMouse)
            writer.writeBool(directGraphics)
            writer.writeBool(endpointKeybindings)
            writer.writeBool(mouseCapture)

        case let .clientShellResize(cellWidth, cellHeight, size, pixelMouse):
            writer.writeVarint(UInt64(cellWidth))
            writer.writeVarint(UInt64(cellHeight))
            writer.writeVarint(UInt64(size.cols))
            writer.writeVarint(UInt64(size.rows))
            writer.writeBool(pixelMouse)

        case let .clientShellPaneInput(paneId, events):
            writer.writeString(paneId)
            writer.writeArray(events) { writer, event in
                encodePaneInputEvent(&writer, event)
            }

        case let .clientShellPopupInput(terminalId, events):
            writer.writeString(terminalId)
            writer.writeArray(events) { writer, event in
                encodePaneInputEvent(&writer, event)
            }

        case let .clientShellEndpointRequest(bootId, request):
            writer.writeString(bootId)
            writer.writeString(request)

        case let .attachMouse(kind, position, geometry, modifiers, lines):
            encodeMouse(&writer, kind: kind, position: position)
            encodeMouseGeometry(&writer, geometry)
            writer.writeU8(modifiers)
            writer.writeVarint(UInt64(lines))

        case let .clientShellHostTheme(update):
            encodeHostTheme(&writer, update)

        case let .clientShellFocus(focused):
            writer.writeBool(focused)

        case let .clientShellMouseCapture(enabled):
            writer.writeBool(enabled)

        case let .endpointControl(kind, data):
            writer.writeString(kind)
            writer.writeString(data)

        default:
            break
        }
    }

    // MARK: Building blocks

    private static func encodeClipboardTarget(
        _ writer: inout BincodeWriter,
        _ target: ClientClipboardImageTarget
    ) {
        switch target {
        case .directTerminal:
            writer.writeVarint(0)
        case let .pane(paneId):
            writer.writeVarint(1)
            writer.writeString(paneId)
        case let .popup(terminalId):
            writer.writeVarint(2)
            writer.writeString(terminalId)
        }
    }

    private static func encodeScrollSource(
        _ writer: inout BincodeWriter,
        _ source: AttachScrollSource
    ) {
        switch source {
        case .wheel:
            writer.writeVarint(0)
        case let .pageKey(input):
            writer.writeVarint(1)
            writer.writeArray(input) { writer, byte in
                writer.writeU8(byte)
            }
        }
    }

    private static func encodeHostTheme(
        _ writer: inout BincodeWriter,
        _ update: ClientHostThemeUpdate
    ) {
        switch update {
        case let .defaultColor(kind, color):
            writer.writeVarint(0)
            writer.writeVarint(kind == .foreground ? 0 : 1)
            writer.writeU8(color.red)
            writer.writeU8(color.green)
            writer.writeU8(color.blue)
        case let .paletteColors(colors):
            writer.writeVarint(1)
            writer.writeArray(colors) { writer, entry in
                writer.writeU8(entry.index)
                writer.writeU8(entry.color.red)
                writer.writeU8(entry.color.green)
                writer.writeU8(entry.color.blue)
            }
        case let .appearance(appearance):
            writer.writeVarint(2)
            writer.writeVarint(appearance == .dark ? 0 : 1)
        }
    }

    private static func encodeMouseGeometry(
        _ writer: inout BincodeWriter,
        _ geometry: ClientMouseGeometry?
    ) {
        writer.writeOptional(geometry) { writer, geometry in
            writer.writeVarint(UInt64(geometry.cols))
            writer.writeVarint(UInt64(geometry.rows))
            writer.writeVarint(UInt64(geometry.widthPx))
            writer.writeVarint(UInt64(geometry.heightPx))
        }
    }

    private static func encodeMouse(
        _ writer: inout BincodeWriter,
        kind: ClientMouseKind,
        position: ClientMousePosition
    ) {
        switch kind {
        case let .press(button):
            writer.writeVarint(0)
            writer.writeVarint(button.rawValue)
        case let .release(button):
            writer.writeVarint(1)
            writer.writeVarint(button.rawValue)
        case let .drag(button):
            writer.writeVarint(2)
            writer.writeVarint(button.rawValue)
        case .moved:
            writer.writeVarint(3)
        case .scrollUp:
            writer.writeVarint(4)
        case .scrollDown:
            writer.writeVarint(5)
        case .scrollLeft:
            writer.writeVarint(6)
        case .scrollRight:
            writer.writeVarint(7)
        }

        switch position {
        case let .cell(column, row):
            writer.writeVarint(0)
            writer.writeVarint(UInt64(column))
            writer.writeVarint(UInt64(row))
        case let .pixels(pixelX, pixelY, column, row):
            writer.writeVarint(1)
            writer.writeVarint(UInt64(pixelX))
            writer.writeVarint(UInt64(pixelY))
            writer.writeVarint(UInt64(column))
            writer.writeVarint(UInt64(row))
        }
    }

    // MARK: Input events

    private static func encodePaneInputEvent(
        _ writer: inout BincodeWriter,
        _ event: ClientPaneInputEvent
    ) {
        switch event {
        case let .key(code, modifiers, kind, repeatCount, shiftedCodepoint,
                      generatedText, tracksRelease, physicalKeyId, windowsRecord):
            writer.writeVarint(0)
            encodeKeyCode(&writer, code)
            writer.writeU8(modifiers)
            writer.writeVarint(kind.rawValue)
            writer.writeVarint(UInt64(repeatCount))
            writer.writeOptional(shiftedCodepoint) { $0.writeVarint(UInt64($1)) }
            writer.writeOptional(generatedText) { $0.writeString($1) }
            writer.writeBool(tracksRelease)
            writer.writeOptional(physicalKeyId) { $0.writeVarint(UInt64($1)) }
            writer.writeOptional(windowsRecord) { writer, record in
                writer.writeBool(record.keyDown)
                writer.writeVarint(UInt64(record.repeatCount))
                writer.writeVarint(UInt64(record.virtualKeyCode))
                writer.writeVarint(UInt64(record.virtualScanCode))
                writer.writeVarint(UInt64(record.unicode))
                writer.writeVarint(UInt64(record.controlKeyState))
            }

        case let .textCommit(text):
            writer.writeVarint(1)
            writer.writeString(text)

        case let .mouse(kind, position, geometry, modifiers, lines):
            writer.writeVarint(2)
            encodeMouse(&writer, kind: kind, position: position)
            encodeMouseGeometry(&writer, geometry)
            writer.writeU8(modifiers)
            writer.writeVarint(UInt64(lines))

        case let .paste(text):
            writer.writeVarint(3)
            writer.writeString(text)
        }
    }

    private static func encodeKeyCode(_ writer: inout BincodeWriter, _ code: ClientKeyCode) {
        switch code {
        case .backspace: writer.writeVarint(0)
        case .enter: writer.writeVarint(1)
        case .arrowLeft: writer.writeVarint(2)
        case .arrowRight: writer.writeVarint(3)
        case .arrowUp: writer.writeVarint(4)
        case .arrowDown: writer.writeVarint(5)
        case .home: writer.writeVarint(6)
        case .end: writer.writeVarint(7)
        case .pageUp: writer.writeVarint(8)
        case .pageDown: writer.writeVarint(9)
        case .tab: writer.writeVarint(10)
        case .backTab: writer.writeVarint(11)
        case .delete: writer.writeVarint(12)
        case .insert: writer.writeVarint(13)
        case .esc: writer.writeVarint(14)
        case let .char(scalar):
            writer.writeVarint(15)
            writer.writeVarint(UInt64(scalar.value))
        case let .function(index):
            writer.writeVarint(16)
            writer.writeU8(index)
        case .null: writer.writeVarint(17)
        }
    }
}
