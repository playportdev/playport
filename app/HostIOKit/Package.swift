// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The decisions of the app's host I/O layer (docs/ARCHITECTURE.md, HostIO):
// which Windows key a
// hardware key is, where a touch lands in the client area, how a game
// controller becomes an XInput pad, and what the app does, in which order, on
// each lifecycle event. Foundation only, so `swift test` runs it on the Linux
// host; S1Probe's HostIO.swift wires it to UIKit, GameController and AVFAudio.
let package = Package(
    name: "HostIOKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HostIOKit", targets: ["HostIOKit"]),
    ],
    targets: [
        .target(name: "HostIOKit"),
        .testTarget(name: "HostIOKitTests", dependencies: ["HostIOKit"]),
    ]
)
