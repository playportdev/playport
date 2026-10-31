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
                                               "VKD3D_SHADER_CACHE_PATH": "0",
                                               "MESA_KK_EXPERIMENTAL": "cmd_retire,cmd_bo_classes"])
        let env = r.graphics.environment(graphicsOptions: r.graphicsEnvironment)
        XCTAssertEqual(env["DXVK_CONFIG"], "dxvk.tilerMode = False;dxvk.numCompilerThreads = 1")
        XCTAssertEqual(env["DXVK_SHADER_CACHE"], "0")
        XCTAssertEqual(env["VKD3D_SHADER_CACHE_PATH"], "0")
        // Decision 0173: RDR2's Play and the Open run KosmicKrisp's command-memory retire path.
        XCTAssertEqual(env["MESA_KK_EXPERIMENTAL"], "cmd_retire,cmd_bo_classes")
        XCTAssertEqual(GraphicsBackend.vulkan.runtimeEnvironment, ["DXVK_CONFIG": "dxvk.tilerMode = False"])
    }

    /// The Social Club key every Play of Rockstar's launcher runs with (decision 0169): the
    /// stock-CEF layout. Single-process needs no key: sc_single.h has it on by default.
    static let socialClub = ["env.PLAYPORT_SC_LAYOUT": "1"]
    static let rockstarRuntime = socialClub.merging(["env.FEX_SMCCHECKS": "none"]) { $1 }

    /// Decision 0116: the Rockstar launcher's Open runs with FEX's self-modifying-code checks off
    /// when nothing is saved, and a saved key of the same name replaces it.
    func testRockstarOpenTurnsSMCChecksOffUnlessASavedKeySaysOtherwise() {
        let r = PublisherLauncher.rockstar
        XCTAssertEqual(r.runtime, Self.rockstarRuntime)
        XCTAssertEqual(r.openSettings(saved: nil), .init(config: Self.rockstarRuntime))
        XCTAssertEqual(r.openSettings(saved: LaunchSettings()).config, Self.rockstarRuntime)
        let own = r.openSettings(saved: LaunchSettings(runtime: "env.FEX_SMCCHECKS=mtrack vram-mb=1024"))
        XCTAssertEqual(own.config, Self.socialClub.merging(["env.FEX_SMCCHECKS": "mtrack", "vram-mb": "1024"]) { $1 })
    }

    /// PLA-401: a game's Runtime keys can give Launcher.exe alone its SMC checks
    /// (patches/fex 0050): the value keeps its own `=`, and the launcher's session-wide
    /// key stays for every other process.
    func testRDR2PlayKeepsAnSMCChecksForValueBesideTheLaunchersKey() {
        let game = LaunchSettings(runtime: "env.FEX_SMCCHECKS_FOR=Launcher.exe=mtrack")
        XCTAssertEqual(LaunchSettings.runtimeKeys(game.runtime), ["env.FEX_SMCCHECKS_FOR": "Launcher.exe=mtrack"])
        let play = PublisherLauncher.rockstar.startingGame(LaunchSettings.resolve(game: game, global: LaunchSettings()))
        XCTAssertEqual(play.settings.runtime, Self.rockstarRuntime.merging(["env.FEX_SMCCHECKS_FOR": "Launcher.exe=mtrack"]) { $1 })
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
        XCTAssertEqual(open.config, Self.rockstarRuntime.merging(["vram-mb": "1024"]) { $1 })
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

    /// A game whose Play starts a launcher inherits its Open's grace, graphics environment and
    /// runtime keys, under the game's own (decision 0115).
    func testAGameStartedThroughALauncherInheritsItsOpenSettings() {
        XCTAssertEqual(PublisherLauncher.startedBy(game: "app-1174180"), .rockstar)
        XCTAssertNil(PublisherLauncher.startedBy(game: "app-367520"))
        let plain = LaunchSettings.resolve(game: nil, global: LaunchSettings())
        let (s, grace) = PublisherLauncher.rockstar.startingGame(plain)
        XCTAssertEqual(grace, PublisherLauncher.rockstar.exhaustionGrace)
        XCTAssertEqual(s.runtime, Self.rockstarRuntime)
        XCTAssertEqual(s.graphicsEnvironment, PublisherLauncher.rockstar.graphicsEnvironment)
        // The game's own keys win; DXVK_CONFIG's items join, the launcher's first.
        let own = LaunchSettings.resolve(game: LaunchSettings(runtime: "env.FEX_SMCCHECKS=mtrack env.X=1",
                                                               graphicsOptions: "dxvk.tilerMode=False"), global: LaunchSettings())
        let (t, _) = PublisherLauncher.rockstar.startingGame(own)
        XCTAssertEqual(t.runtime, Self.socialClub.merging(["env.FEX_SMCCHECKS": "mtrack", "env.X": "1"]) { $1 })
        XCTAssertEqual(t.graphicsEnvironment["DXVK_CONFIG"], "dxvk.numCompilerThreads = 1;" + (own.graphicsEnvironment["DXVK_CONFIG"] ?? ""))
        XCTAssertEqual(t.graphicsEnvironment["DXVK_SHADER_CACHE"], "0")
    }

    /// A game's Play config as LibraryModel builds it: a dev build's person's keys over the
    /// compatibility default over every game's; a release build's compatibility keys only
    /// (decision 0126); then the launcher it starts, if any (decision 0115).
    static func play(_ id: String, person: String, release: Bool) throws -> [String: String] {
        let compat = try CompatDefaults.load(directory: CompatDefaultsTests.shipped).entry(for: id)?.settings
        let base = LaunchSettings.overEveryGame(compat)
        var s = LaunchSettings.resolve(game: LaunchSettings(runtime: person).over(base), global: LaunchSettings())
        if release { s.runtime = LaunchSettings.releaseRuntime(compat: compat) }
        if let l = PublisherLauncher.startedBy(game: id) { s = l.startingGame(s).settings }
        return s.config(over: [:])
    }

    /// PLA-602 (decision 0169): every Play that runs Rockstar's launcher, RDR2's and the Open,
    /// runs the stock-CEF layout with no keys, in both builds; a release build ignores a person's
    /// keys but keeps the launcher's.
    func testRockstarPlaysRunTheSocialClubLayoutInBothBuilds() throws {
        let layout = { (c: [String: String]) in GameSocialClubEndPolicy.socialClubLayout(config: c, environment: nil) }
        for release in [false, true] {
            let rdr2 = try Self.play("app-1174180", person: "", release: release)
            XCTAssertEqual(rdr2["env.PLAYPORT_SC_LAYOUT"], "1")
            XCTAssertTrue(layout(rdr2))
        }
        let open = PublisherLauncher.rockstar.openSettings(saved: nil).config   // a release build's Open
        XCTAssertEqual(open["env.PLAYPORT_SC_LAYOUT"], "1")
        XCTAssertTrue(layout(open))
        // A person's =0 in a release build: dropped with every person's key, so single-process
        // stays at its default too.
        let release = try Self.play("app-1174180", person: "env.PLAYPORT_SC_LAYOUT=0 env.PLAYPORT_SC_SINGLE=0", release: true)
        XCTAssertEqual(release["env.PLAYPORT_SC_LAYOUT"], "1")
        XCTAssertNil(release["env.PLAYPORT_SC_SINGLE"])
    }

    /// Hollow Knight and every title that starts no Rockstar launcher get no layout key: the layout
    /// changes every process of the session (madeira-unix 0225).
    func testAPlayWithoutRockstarsLauncherGetsNoLayoutKey() throws {
        for release in [false, true] {
            let hk = try Self.play("app-367520", person: "", release: release)
            XCTAssertNil(hk["env.PLAYPORT_SC_LAYOUT"])
            XCTAssertFalse(GameSocialClubEndPolicy.socialClubLayout(config: hk, environment: nil))
        }
        XCTAssertNil(LaunchSettings.everyGameKeys["env.PLAYPORT_SC_LAYOUT"])
    }

    /// A dev build's `=0` key, the game's or the Open's saved one, wins over the launcher's.
    func testADevBuildsZeroKeyTurnsTheLayoutOff() throws {
        let rdr2 = try Self.play("app-1174180", person: "env.PLAYPORT_SC_LAYOUT=0 env.PLAYPORT_SC_SINGLE=0", release: false)
        XCTAssertEqual(rdr2["env.PLAYPORT_SC_LAYOUT"], "0")
        XCTAssertEqual(rdr2["env.PLAYPORT_SC_SINGLE"], "0")
        XCTAssertFalse(GameSocialClubEndPolicy.socialClubLayout(config: rdr2, environment: nil))
        let open = PublisherLauncher.rockstar.openSettings(saved: LaunchSettings(runtime: "env.PLAYPORT_SC_LAYOUT=0")).config
        XCTAssertEqual(open["env.PLAYPORT_SC_LAYOUT"], "0")
        XCTAssertFalse(GameSocialClubEndPolicy.socialClubLayout(config: open, environment: nil))
    }

    /// Forgetting the Rockstar launcher's window settings deletes settings_user.dat and nothing
    /// beside it; a second time there is nothing to delete.
    func testForgettingTheWindowSettingsDeletesOnlySettingsUser() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("pl-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        let folder = profile.appendingPathComponent("AppData/Local/Rockstar Games/Launcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["settings_user.dat", "launcher_online_config.dat", "firstrun.dat"] {
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name))
        }
        XCTAssertTrue(try PublisherLauncher.rockstar.forgetWindowSettings(profile: profile))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["firstrun.dat", "launcher_online_config.dat"])
        XCTAssertFalse(try PublisherLauncher.rockstar.forgetWindowSettings(profile: profile))
    }
}
