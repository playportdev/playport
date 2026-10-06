// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The product UI's non-UI logic (docs/ARCHITECTURE.md, "Product UI"): the
// catalogue of installed titles, its adoption of titles already in the
// prefix, the bundled cohort list, launch plans and file verification.
// Foundation plus SteamClientKit only, so `swift test` runs it on the Linux
// host; the SwiftUI views in Sources/S1Probe/UI/ wire it to the app.
// The cohort list (Titles/) ships at the app root through xtool.yml, not as a
// SwiftPM resource bundle.
let package = Package(
    name: "PlayportKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PlayportKit", targets: ["PlayportKit"]),
    ],
    dependencies: [
        .package(path: "../SteamClient"),
    ],
    targets: [
        .target(name: "PlayportKit", dependencies: [.product(name: "SteamClientKit", package: "SteamClient")]),
        .testTarget(name: "PlayportKitTests", dependencies: ["PlayportKit"], resources: [.copy("Fixtures")]),
    ]
)
