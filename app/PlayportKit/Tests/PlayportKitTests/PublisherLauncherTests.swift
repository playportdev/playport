// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// A publisher's launcher opened from Settings › Launchers: its play settings and where the
/// prefix's registry says it is installed.
final class PublisherLauncherTests: XCTestCase {
    /// The 32-bit view's key as wineserver saves system.reg, with the installer's spelling.
    static let hive = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to \\Machine

    [Software\\Wow6432Node\\Rockstar Games\\Launcher] 1760572800
    #time=1dc3e1f2a3b4c5d
    "InstallFolder"="C:\\Program Files\\Rockstar Games\\Launcher"
    "Language"="en-US"

    [Software\\Wow6432Node\\Rockstar Games\\Other] 1760572800
    "InstallFolder"="C:\\Elsewhere"
    """#

    func testRockstarOpensStandaloneWithServicesTheLargerPoolAndVulkan() {
        let r = PublisherLauncher.rockstar
        XCTAssertEqual(PublisherLauncher.named("rockstar"), r)
        XCTAssertNil(PublisherLauncher.named("ubisoft"))
        XCTAssertEqual(r.titleID, "launcher-rockstar")
        XCTAssertEqual(r.arguments, [])   // no -steamAppId: Steam mode wants a Steam client
        XCTAssertTrue(r.windowsServices)
        XCTAssertEqual(r.jitPoolMB, 896)
        XCTAssertEqual(r.graphics, .vulkan)
        XCTAssertEqual(JitPool.size(limitMB: 8191, gameMB: r.jitPoolMB).mb, 896)
    }

    /// Decision 0112: the Rockstar launcher's Open alone goes on 240 s after the pool ran out;
    /// a game's launch keeps 0022's 10 s.
    func testRockstarOpenGetsTheLongerExhaustionGraceAndAGameKeepsTen() {
        XCTAssertEqual(PublisherLauncher.rockstar.exhaustionGrace, 240)
        XCTAssertEqual(JitPool.exhaustionGrace, 10)
    }

    /// Decision 0114: the Rockstar launcher's Open runs one DXVK compiler thread and no DXVK or
    /// vkd3d-proton disk cache, over Vulkan's own DXVK_CONFIG; a game's backend keeps DXVK's own.
    func testRockstarOpenRunsOneDXVKCompilerThreadAndNoShaderCacheThreads() {
        let r = PublisherLauncher.rockstar
        XCTAssertEqual(r.graphicsEnvironment, ["DXVK_CONFIG": "dxvk.numCompilerThreads = 1", "DXVK_SHADER_CACHE": "0",
                                               "VKD3D_SHADER_CACHE_PATH": "0"])
        let env = r.graphics.environment(graphicsOptions: r.graphicsEnvironment)
        XCTAssertEqual(env["DXVK_CONFIG"], "dxvk.tilerMode = False;dxvk.numCompilerThreads = 1")
        XCTAssertEqual(env["DXVK_SHADER_CACHE"], "0")
        XCTAssertEqual(env["VKD3D_SHADER_CACHE_PATH"], "0")
        XCTAssertEqual(GraphicsBackend.vulkan.runtimeEnvironment, ["DXVK_CONFIG": "dxvk.tilerMode = False"])
    }

    /// Decision 0116: the Rockstar launcher's Open runs with FEX's self-modifying-code checks off
    /// when nothing is saved, and a saved key of the same name replaces it.
    func testRockstarOpenTurnsSMCChecksOffUnlessASavedKeySaysOtherwise() {
        let r = PublisherLauncher.rockstar
        XCTAssertEqual(r.runtime, ["env.FEX_SMCCHECKS": "none"])
        XCTAssertEqual(r.openSettings(saved: nil), .init(config: ["env.FEX_SMCCHECKS": "none"]))
        XCTAssertEqual(r.openSettings(saved: LaunchSettings()).config, ["env.FEX_SMCCHECKS": "none"])
        let own = r.openSettings(saved: LaunchSettings(runtime: "env.FEX_SMCCHECKS=mtrack vram-mb=1024"))
        XCTAssertEqual(own.config, ["env.FEX_SMCCHECKS": "mtrack", "vram-mb": "1024"])
    }

    func testOpenTakesTheSavedRuntimeKeysAndFEXInputsOnly() {
        let launcher = PublisherLauncher.rockstar
        XCTAssertEqual(launcher.openSettings(saved: nil).config, launcher.runtime)
        var ordering = MemoryOrdering()
        ordering[.tso] = false
        let saved = LaunchSettings(screen: "1080", graphics: .dxmt, ordering: ordering, maxInst: 100, x87Reduced: true,
                                   diskCache: false, runtime: "env.FEX_SMCCHECKS=none vram-mb=1024",
                                   windowsServices: false, jitPoolMB: 512)
        let open = launcher.openSettings(saved: saved)
        XCTAssertEqual(open.config, ["env.FEX_SMCCHECKS": "none", "vram-mb": "1024"])
        XCTAssertEqual(open.ordering, ordering)
        XCTAssertEqual(open.maxInst, 100)
        XCTAssertEqual(open.x87Reduced, true)
        XCTAssertEqual(open.diskCache, false)
        // Keys that are not key=value items and a block size FEX cannot take are unset, as for a game.
        let bad = launcher.openSettings(saved: LaunchSettings(maxInst: 0, runtime: "FEX_SMCCHECKS"))
        XCTAssertEqual(bad.config, launcher.runtime)
        XCTAssertNil(bad.maxInst)
    }

    func testTheExecutableComesFromTheInstallFolderTheInstallerRecorded() {
        let r = PublisherLauncher.rockstar
        XCTAssertEqual(r.executablePath(systemHive: Self.hive), #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#)
        // A trailing separator is dropped; the key matches in any case.
        let trailing = Self.hive.replacingOccurrences(of: #"Launcher""#, with: #"Launcher\\""#)
            .replacingOccurrences(of: "Wow6432Node", with: "WOW6432NODE")
        XCTAssertEqual(r.executablePath(systemHive: trailing), #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#)
    }

    func testNoInstallFolderOrOneOffDriveCIsNotInstalled() {
        let r = PublisherLauncher.rockstar
        XCTAssertNil(r.executablePath(systemHive: ""))
        XCTAssertNil(r.executablePath(systemHive: Self.hive.replacingOccurrences(of: "\"InstallFolder\"", with: "\"Folder\"")))
        XCTAssertNil(r.executablePath(systemHive: Self.hive.replacingOccurrences(of: #"="C:\\Program"#, with: #"="D:\\Program"#)))
        XCTAssertNil(r.executablePath(systemHive: Self.hive.replacingOccurrences(of: #"="C:\\Program Files\\Rockstar Games\\Launcher""#, with: #"="C:\\""#)))
    }

    func testAStringValueIsReadUnescapedFromItsOwnKeyOnly() {
        XCTAssertEqual(PrefixRegistryFile.string(inHive: Self.hive, key: #"Software\Wow6432Node\Rockstar Games\Other"#, name: "InstallFolder"),
                       #"C:\Elsewhere"#)
        XCTAssertEqual(PrefixRegistryFile.string(inHive: Self.hive, key: #"Software\Wow6432Node\Rockstar Games\Launcher"#, name: "language"), "en-US")
        XCTAssertNil(PrefixRegistryFile.string(inHive: Self.hive, key: #"Software\Rockstar Games\Launcher"#, name: "InstallFolder"))
    }
}
