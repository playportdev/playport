// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The Battle.net store client (README.md, decision 0174): Blizzard's public version and CDN
// endpoints, the build, CDN and product configs, BLTE, and the encoding, install and size
// manifests, for a fixed list of World of Warcraft products. No Battle.net session. Foundation
// only, so its tests run on the Linux host.
let package = Package(
    name: "BattleNetClient",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "BattleNetClientKit", targets: ["BattleNetClientKit"]),
    ],
    dependencies: [
        .package(path: "../ContentKit"),
    ],
    targets: [
        .target(
            name: "BattleNetClientKit",
            dependencies: [.product(name: "ContentKit", package: "ContentKit")],
            // Always optimised, as SteamClient: at -Onone the per-block MD5, zlib and Salsa20
            // and the manifest tag masks are CPU-bound on the phone.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "BattleNetClientKitTests",
            dependencies: ["BattleNetClientKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
