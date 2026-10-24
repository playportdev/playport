// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "JITKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "JITKit", targets: ["JITKit"])],
    targets: [
        .target(name: "JITKit"),
        .testTarget(name: "JITKitTests", dependencies: ["JITKit"]),
    ]
)
