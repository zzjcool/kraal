// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import PackageDescription

/// The Herdr 1 client (protocol/transport/client/UI) was removed; every target
/// below talks to herdr-core only. `KraalSupport` is the small Foundation-only
/// seam the app shares for logging and dev-session naming.
let package = Package(
    name: "Kraal",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KraalSupport", targets: ["KraalSupport"]),
        .library(name: "KraalHC", targets: ["KraalHC"]),
        .executable(name: "KraalMac", targets: ["KraalMac"]),
        .executable(name: "kraal", targets: ["KraalCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "1.6.20261003"),
    ],
    targets: [
        .target(
            name: "KraalSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalSocket",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // herdr-core (`hc`) client: JSON-RPC over the core socket, framed streams
        // after `hello`.
        .target(
            name: "KraalHC",
            dependencies: ["KraalSocket"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app action contract: names, arguments and validation. Shared by
        // the window (menus/palette) and by `kraal commands|do`.
        .target(
            name: "KraalActions",
            dependencies: ["KraalHC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The client's spaces/tabs/panes: pure values and tree operations, no
        // AppKit or Ghostty, so the rules are testable on their own.
        .target(
            name: "KraalModel",
            dependencies: ["KraalHC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalHCTerminal",
            dependencies: [
                "KraalActions",
                "KraalHC",
                "KraalModel",
                "KraalSocket",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KraalCLI",
            dependencies: ["KraalActions", "KraalHC"],
            path: "Sources/KraalCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Deliberately depends on nothing in this repo. It drives a running app
        // from the outside through AppKit + the Accessibility API, so it can be
        // built on any machine and pushed into a VM as a single binary. Sharing
        // code with the app would let the driver "pass" by agreeing with the
        // app's own bugs — see docs/AUTOMATION.md §4.
        .executableTarget(
            name: "KraalGUIDriver",
            path: "Sources/KraalGUIDriver",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KraalMac",
            dependencies: [
                "KraalHC", "KraalHCTerminal", "KraalSupport",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalSupportTests",
            dependencies: ["KraalSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalHCTerminalTests",
            dependencies: ["KraalHCTerminal", "KraalHC", "KraalModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalActionsTests",
            dependencies: ["KraalActions"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalModelTests",
            dependencies: ["KraalModel", "KraalHC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalHCTests",
            dependencies: ["KraalHC"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalCLITests",
            dependencies: ["KraalCLI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
