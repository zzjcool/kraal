// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
@testable import KraalClient
@testable import KraalProtocol
@testable import KraalTransport
import Testing

/// The handshake carries a cell size, and the daemon divides pane pixel rects by it.
///
/// Connections are built before any Ghostty surface exists, so the only value available
/// at handshake time is the `(10, 20)` default — see `EndpointConnection.init`. The real
/// font measures `17x37` in device pixels, so every pixel rect the daemon derived was off
/// by that factor for the whole session: `cellSize` was a `let` and nothing corrected it.
///
/// The correction has to survive `sendResize`'s early return, which is the subtle half:
/// that guard fires on an unchanged *grid*, and a corrected cell size is exactly the case
/// where the grid did not change.
@Suite("Cell size on the wire")
struct CellSizeWireTests {
    @Test("a corrected cell size is marked for resend")
    func correctionMarksForResend() async {
        let connection = EndpointConnection(
            target: .unixSocket(path: "/tmp/kraal-cell-size-test.sock"),
            surfaceSize: ClientSurfaceSize(cols: 120, rows: 40)
        ) { _ in }
        await connection.updateCellSize(width: 17, height: 37)
        // Read back through the same accessor the wire uses. `cellSizeIsStale` is private,
        // so the observable effect is asserted instead: a resize at the *same* grid must
        // still reach the encoder rather than being dropped by the dedupe.
        let stale = await connection.needsCellSizeResendForTesting
        #expect(stale, "the correction must not be swallowed by the unchanged-grid guard")
    }

    @Test("an unchanged cell size does not mark a resend")
    func noCorrectionNoResend() async {
        let connection = EndpointConnection(
            target: .unixSocket(path: "/tmp/kraal-cell-size-test.sock"),
            surfaceSize: ClientSurfaceSize(cols: 120, rows: 40),
            cellSize: (17, 37)
        ) { _ in }
        await connection.updateCellSize(width: 17, height: 37)
        let stale = await connection.needsCellSizeResendForTesting
        #expect(!stale, "re-sending an identical size would re-render the surface for nothing")
    }

    @Test("a zero cell size is refused")
    func zeroRefused() async {
        let connection = EndpointConnection(
            target: .unixSocket(path: "/tmp/kraal-cell-size-test.sock"),
            surfaceSize: ClientSurfaceSize(cols: 120, rows: 40)
        ) { _ in }
        await connection.updateCellSize(width: 0, height: 37)
        let stale = await connection.needsCellSizeResendForTesting
        #expect(!stale, "a zero divided the daemon's pixel rects by nothing")
    }
}
