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
            name: "KraalTransport",
            dependencies: ["KraalProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KraalClient",
            dependencies: ["KraalProtocol", "KraalTransport"],
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
            dependencies: ["KraalProtocol", "KraalTransport", "KraalClient"],
            path: "Sources/KraalCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KraalMac",
            dependencies: ["KraalClient", "KraalSidebar", "KraalUI", "KraalTerminalView"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalProtocolTests",
            dependencies: ["KraalProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalTransportTests",
            dependencies: ["KraalTransport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KraalClientTests",
            dependencies: ["KraalClient", "KraalSidebar", "KraalUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
