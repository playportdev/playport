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

    func testOpenTakesTheSavedRuntimeKeysAndFEXInputsOnly() {
        XCTAssertEqual(PublisherLauncher.openSettings(saved: nil), .init())
        var ordering = MemoryOrdering()
        ordering[.tso] = false
        let saved = LaunchSettings(screen: "1080", graphics: .dxmt, ordering: ordering, maxInst: 100, x87Reduced: true,
                                   diskCache: false, runtime: "env.FEX_SMCCHECKS=none vram-mb=1024",
                                   windowsServices: false, jitPoolMB: 512)
        let open = PublisherLauncher.openSettings(saved: saved)
        XCTAssertEqual(open.config, ["env.FEX_SMCCHECKS": "none", "vram-mb": "1024"])
        XCTAssertEqual(open.ordering, ordering)
        XCTAssertEqual(open.maxInst, 100)
        XCTAssertEqual(open.x87Reduced, true)
        XCTAssertEqual(open.diskCache, false)
        // Keys that are not key=value items and a block size FEX cannot take are unset, as for a game.
        let bad = PublisherLauncher.openSettings(saved: LaunchSettings(maxInst: 0, runtime: "FEX_SMCCHECKS"))
        XCTAssertEqual(bad.config, [:])
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
