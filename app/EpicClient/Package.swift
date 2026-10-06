// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The Epic Games client (README.md): sign-in with the launcher's desktop-client
// identity (decision 0058), the owned library with the catalogue's names, art and
// attributes, and content (the binary manifest, chunk slices from the CDN) planned
// for ContentKit's install engine. Foundation only, so its tests run on the Linux host.
let package = Package(
    name: "EpicClient",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "EpicClientKit", targets: ["EpicClientKit"]),
    ],
    dependencies: [
        .package(path: "../ContentKit"),
    ],
    targets: [
        .target(
            name: "EpicClientKit",
            dependencies: [.product(name: "ContentKit", package: "ContentKit")],
            // Optimised in every configuration, as ContentKit (zlib and SHA-1 per chunk).
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "EpicClientKitTests",
            dependencies: ["EpicClientKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
