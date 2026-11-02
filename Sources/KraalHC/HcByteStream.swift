// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// What a renderer needs from an attached stream, without knowing about sockets.

import Foundation

/// The stream controls a pane uses: flow control, size, focus, detach.
///
/// `HcAttachStream` is the wire implementation; tests and the credit gate use
/// this protocol so the rendering policy can be exercised without a core.
public protocol HcByteStream: AnyObject, Sendable {
    /// Returns credit for bytes already handed to the renderer.
    func credit(_ bytes: Int)
    func resize(columns: Int, rows: Int)
    func focus(_ focused: Bool)
    func close()
    var isClosed: Bool { get }
}

extension HcAttachStream: HcByteStream {}
