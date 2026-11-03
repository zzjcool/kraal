// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import PackageDescription

/// Kraal is split so that the protocol kernel stays dependency-free: the
/// `KraalProtocol`/`KraalTransport`/`KraalClient` targets build and test on any
/// machine, while only `KraalTerminalView` pulls the (large) Ghostty
/// xcframework.
let package = Package(
    name: "Kraal",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KraalProtocol", targets: ["KraalProtocol"]),
        .library(name: "KraalTransport", targets: ["KraalTransport"]),
        .library(name: "KraalClient", targets: ["KraalClient"]),
        .library(name: "KraalSidebar", targets: ["KraalSidebar"]),
        .library(name: "KraalUI", targets: ["KraalUI"]),
        .library(name: "KraalTerminalView", targets: ["KraalTerminalView"]),
        .executable(name: "KraalMac", targets: ["KraalMac"]),
        .executable(name: "kraal", targets: ["KraalCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "1.6.20261003"),
    ],
    targets: [
        .target(
            name: "KraalProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalSocket",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalTransport",
            dependencies: ["KraalProtocol", "KraalSocket"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalClient",
            dependencies: ["KraalProtocol", "KraalTransport", "KraalSocket"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // herdr-core (`hc`) client: JSON-RPC over the core socket, framed streams
        // after `hello`. Deliberately independent of the Herdr 1 modules above;
        // they are deleted once the migration lands (docs/HERDR2.md).
        .target(
            name: "KraalHC",
            dependencies: ["KraalSocket"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalSidebar",
            dependencies: ["KraalProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalUI",
            dependencies: ["KraalProtocol", "KraalTransport", "KraalClient", "KraalSidebar"],
            // Ghostty's theme files, copied verbatim (see Resources/themes/ATTRIBUTION.md).
            // Resources rather than a generated table: 51 files of six lines each are
            // easier to diff against upstream than 51 structs of 23 hex literals.
            resources: [.copy("Resources/themes")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The client's spaces/tabs/panes: pure values and tree operations, no
        // AppKit or Ghostty, so the rules are testable on their own.
        // The app action contract: names, arguments and validation. Shared by
        // the window (menus/palette) and by `kraal commands|do`.
        .target(
            name: "KraalActions",
            dependencies: ["KraalHC"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
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
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalTerminalView",
            dependencies: [
                "KraalClient",
                "KraalSidebar",
                "KraalUI",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KraalCLI",
            dependencies: ["KraalActions", "KraalProtocol", "KraalTransport", "KraalClient"],
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
                "KraalClient", "KraalSidebar", "KraalUI", "KraalTerminalView", "KraalHC", "KraalHCTerminal",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalProtocolTests",
            dependencies: ["KraalProtocol"],
            resources: [.copy("Fixtures")],
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
        .testTarget(
            name: "KraalTransportTests",
            dependencies: ["KraalTransport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalClientTests",
            dependencies: ["KraalClient", "KraalSidebar", "KraalUI", "KraalTerminalView"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
