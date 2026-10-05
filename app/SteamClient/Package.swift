// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The smallest separable native Steam protocol client (README.md). It talks
// to Steam's CM servers over a WebSocket and to the content CDN over HTTPS, with every message schema pinned by hand in
// Sources/SteamClientKit/Wire/Schemas.swift. Foundation only, so its offline
// tests run on the Linux host (`swift test`); the platform-specific pieces are
// two seams: the credential store (Auth/SecretStore.swift; the iOS Keychain)
// and the CM WebSocket transport (Net/WebSocketTransport.swift;
// URLSessionWebSocketTask), which exist only on Apple platforms.
let package = Package(
    name: "SteamClient",
    // iOS 18 / macOS 15: String(validating:as:), used by the manifest and
    // proto readers, first ships there (the app target is iOS 26.0 anyway).
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SteamClientKit", targets: ["SteamClientKit"]),
    ],
    targets: [
        .target(
            name: "SteamClientKit",
            // Always optimised: the app is built with xtool's default debug
            // configuration, and at -Onone the pure-Swift chunk pipeline (AES,
            // LZMA, SHA-1) is CPU-bound on the phone at about 0.2 MB/s.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "SteamClientKitTests",
            dependencies: ["SteamClientKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
