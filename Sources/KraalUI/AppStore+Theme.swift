// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
//  AppStore+Theme.swift
//  KraalUI
//
//  The store's handle on the palette owner.
//
//  In an extension rather than the class body, where it pushed `AppStore` past
//  swiftlint's 400-line limit. Swift extensions cannot hold stored properties, so the
//  storage lives here as a small boxed holder — `nonisolated(unsafe)` is not needed
//  because the whole store is `@MainActor`.
//

import Foundation

/// Storage for `AppStore.themeStore`.
///
/// A reference box because an extension cannot add a stored property to a class. The
/// store is `@MainActor`, so there is one owner and no locking to get wrong.
@MainActor
final class ThemeStoreBox {
    /// One per process: Kraal runs a single store, and a static holder keeps the
    /// property out of `AppStore`'s body, which is at swiftlint's limit.
    static let shared = ThemeStoreBox()
    var store: ThemeStore?
}

public extension AppStore {
    /// The client's palette owner, set once at launch.
    ///
    /// Held by the store so `reloadServerConfig` can refresh the colours alongside the
    /// daemon's own reload. Not `@Observable`: the palette reaches views through the
    /// SwiftUI environment, not through this store.
    var themeStore: ThemeStore? {
        get { ThemeStoreBox.shared.store }
        set { ThemeStoreBox.shared.store = newValue }
    }
}

public extension AppStore {
    /// Re-reads config.toml on the daemon side (theme, keybindings, sidebar).
    ///
    /// The client's own palette is re-read too. The daemon cannot deliver it — the
    /// palette is not in the protocol — so a reload that only told the daemon would
    /// update keybindings and leave the colours stale until the next launch.
    public func reloadServerConfig() {
        themeStore?.reloadFromDisk()
        Task { await call("server.reload_config", [:]) }
    }
}
