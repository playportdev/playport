// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

// XboxClientKit (README.md), on ContentKit. Foundation only; the same offline
// response tests run on Linux and the phone. App entry points are dev-only (0181).
let package = Package(
    name: "XboxClient",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "XboxClientKit", targets: ["XboxClientKit"])],
    dependencies: [.package(path: "../ContentKit")],
    targets: [
        .target(name: "XboxClientKit", dependencies: [.product(name: "ContentKit", package: "ContentKit")],
                // RSA and the package crypto are CPU-bound at -Onone, as ContentKit's chunks.
                swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "XboxClientKitTests", dependencies: ["XboxClientKit"], resources: [.copy("Fixtures")]),
    ]
)
