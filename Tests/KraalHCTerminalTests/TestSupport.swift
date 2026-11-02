// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation

@testable import KraalHC

/// Opens a connection off Swift's cooperative pool; see the copy in
/// `KraalHCTests` for why the blocking handshake must not run there.
func openTestConnection(path: String) async throws -> HcConnection {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            do {
                continuation.resume(returning: try HcConnection.open(path: path))
            } catch {
                continuation.resume(throwing: error)
            }
        }
        thread.name = "kraal.test.connect"
        thread.stackSize = 512 * 1024
        thread.start()
    }
}
