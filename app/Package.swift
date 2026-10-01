// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// The app target (docs/ARCHITECTURE.md): the SwiftUI shell, the
// wine_host C ABI, the reference's Winios display driver and IOSDisplayShim,
// the host app's own I/O layer, and the Madeira unix-side archives linked
// statically. build/stages/stage-artifacts.py stage must run first (docs/BUILDING.md,
// "Staging"): it puts the guest files in
// Sources/S1Probe/Runtime/ (shipped at the app root by xtool.yml), the archives in Staged/lib/ and the driver source
// in Sources/WinIOS/ (all gitignored), checked against artifacts.tsv;
// build/stages/stikjit.sh puts StikJIT's framework in Staged/ for the JIT helper,
// build/stages/mesa.sh KosmicKrisp's for the Vulkan backend.
let lib = Context.packageDirectory + "/Staged/lib"

// The build variant (docs/BUILDING.md, "Variants"; decision 0009), from
// PLAYPORT_VARIANT, which pp build sets:
//   dev      (the default) the workstation's build: product and executable
//            S1Probe, with the UI driver and the scripted pad (Sources/S1Probe/Dev/)
//   release  what a player gets: product, module and executable Playport,
//            built with PLAYPORT_RELEASE, without Dev/; built
//            from the shadow package pp build makes in .release/
//            (xtool reads ./xtool.yml, which names the product)
let variant = Context.environment["PLAYPORT_VARIANT"] ?? "dev"
guard variant == "dev" || variant == "release" else {
    fatalError("PLAYPORT_VARIANT must be dev or release, not \(variant)")
}
let release = variant == "release"
let app = release ? "Playport" : "S1Probe"

let package = Package(
    name: app,
    platforms: [
        // The decided target is iOS 27.0; the pinned Xcode 26.6 SDK (iOS 26.5)
        // caps it here until the Xcode 27 re-pin (docs/BUILDING.md).
        .iOS("26.5"),
        .macOS(.v14),
    ],
    products: [
        // The app (xtool.yml `product`), and its JIT helper extension
        // (xtool.yml `extensions`, docs/ARCHITECTURE.md, "Built-in JIT").
        .library(
            name: app,
            targets: [app]
        ),
        .library(
            name: "PlayportJIT",
            targets: ["PlayportJIT"]
        ),
    ],
    dependencies: [
        // The host I/O decisions (key map, pads, lifecycle order), tested on the Linux host.
        .package(path: "HostIOKit"),
        // The native Steam protocol client (app/SteamClient). The app uses SteamClientKit only;
        // its Linux-only CCurlWS target is conditioned out on Apple platforms.
        .package(path: "SteamClient"),
        // The product UI's catalogue, adoption and launch options, tested on the Linux host.
        .package(path: "PlayportKit"),
    ],
    targets: [
        .target(
            name: "WineHost",
            linkerSettings: [
                // Every archive the reference app links (Madeira.xcodeproj),
                // in its order. libdxmt_combined.a is the DXMT unix slice plus
                // the LLVM 15 iOS libraries airconv needs (build/stages/dxmt-combined.sh).
                .unsafeFlags([
                    "-L\(lib)",
                    "-lwineserver", "-lntdll_unix", "-ldxmt_combined", "-lwin32u_unix",
                    "-lgnutls", "-lhogweed", "-lnettle", "-lgmp",
                    // winegstreamer's unix side with its static GStreamer plugin set
                    // (build/stages/gstreamer.sh): one prelinked object; these are what it imports.
                    "-lwinegstreamer_unix", "-liconv", "-lresolv",
                ]),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOSurface"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                // The DXMT unix slice's (winemetal_unix.o); the reference links them too.
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("MetalFX"),
                .linkedLibrary("sqlite3"),
                // libwinegstreamer_unix.a's (applemedia: the VideoToolbox decoder, its
                // GL context and asset source; build/stages/gstreamer.sh lists the imports).
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("OpenGLES"),
                .linkedFramework("AssetsLibrary"),
            ]
        ),
        // The reference's app-side Winios display driver (Madeira
        // app/Madeira/Winios/Winios.m and WiniosGamepad.c at the pin, plus patches/madeira-winios), staged
        // from artifacts.tsv. It defines the winios_* hooks libwin32u_unix.a
        // calls from load_display_driver() (docs/ARCHITECTURE.md, Winios hooks).
        // IOSDisplayShim.m (same revision, unmodified) exports macdrv_functions,
        // which DXMT's winemetal unix side finds with dlsym to get a CAMetalLayer.
        .target(
            name: "WinIOS",
            cSettings: [
                // Madeira.xcodeproj builds it with CLANG_ENABLE_OBJC_ARC = YES.
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Metal"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        // The host I/O C side: the controller writers over WinIOS's controller
        // snapshot (WiniosGamepad.c), which Wine's XInput reads through win32u,
        // and the declarations of the runtime extensions HostIO.swift calls
        // (docs/ARCHITECTURE.md, HostIO).
        .target(name: "HostIO", dependencies: ["WinIOS"]),
        // The JIT helper extension: StikJIT's prebuilt framework (MPL-2.0,
        // embedded unmodified in the extension's Frameworks/), the XPC contract
        // it shares with the app, and its entry point (PlayportJITEntry/entry.c).
        .binaryTarget(name: "StikJIT", path: "Staged/StikJIT.xcframework"),
        // KosmicKrisp, Mesa's Vulkan driver on Metal (build/stages/mesa.sh), for
        // the Vulkan Direct3D backend (decision 0014): embedded in the app's
        // Frameworks/ and loaded by win32u with dlopen.
        .binaryTarget(name: "KosmicKrisp", path: "Staged/KosmicKrisp.xcframework"),
        .target(name: "JITHelperXPC", swiftSettings: release ? [.define("PLAYPORT_RELEASE")] : []),
        .target(name: "PlayportJITEntry"),
        .target(
            name: "PlayportJIT",
            dependencies: ["StikJIT", "JITHelperXPC", "PlayportJITEntry"],
            swiftSettings: [.swiftLanguageMode(.v5)] + (release ? [.define("PLAYPORT_RELEASE")] : []),
            linkerSettings: [
                // Nothing references the principal class but the Objective-C
                // runtime, by name; without -ObjC the linker drops it, the
                // executable has no __text, and the signer cannot sign it.
                .unsafeFlags(["-Xlinker", "-ObjC"]),
            ]
        ),
        .target(
            name: app,
            dependencies: ["WineHost", "WinIOS", "HostIO", "JITHelperXPC", "KosmicKrisp",
                           .product(name: "HostIOKit", package: "HostIOKit"),
                           .product(name: "SteamClientKit", package: "SteamClient"),
                           .product(name: "PlayportKit", package: "PlayportKit")]
                + ["Relaunch"],
            path: "Sources/S1Probe",
            // Runtime/ ships at the app root through xtool.yml `resources`, not
            // as a SwiftPM resource bundle: ntdll resolves nls/ and <arch>-windows/
            // against the executable's directory. Dev/ is the UI driver and the scripted pad.
            exclude: ["Runtime"] + (release ? ["Dev"] : []),
            swiftSettings: release ? [.define("PLAYPORT_RELEASE")] : [],
            linkerSettings: [
                .linkedFramework("GameController"),
                .linkedFramework("AVFAudio"),
                // The Steam sign-in QR code (UI/SteamSupport.swift).
                .linkedFramework("CoreImage"),
            ]
        ),
        // How the app restarts itself after a game (decision 0029): idevice's C FFI,
        // built by build/stages/idevice.sh and staged as Staged/lib/libidevice_ffi.a.
        .target(
            name: "Relaunch",
            linkerSettings: [.unsafeFlags(["-L\(lib)", "-lidevice_ffi"])]
        ),
    ]
)
