// SPDX-License-Identifier: GPL-3.0-or-later
import BattleNetClientKit
import Foundation
import XCTest
@testable import PlayportKit

final class CompatDefaultsTests: XCTestCase {
    /// The table the app ships (app/PlayportKit/Titles).
    static let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Titles", isDirectory: true).standardizedFileURL

    func parse(_ json: String) throws -> CompatDefaults { try CompatDefaults.parse(Data(json.utf8)) }

    func testTheShippedTableReadsAndGivesSuperMeatBoy16x9() throws {
        let table = try CompatDefaults.load(directory: Self.shipped)
        let smb = try XCTUnwrap(table.entry(for: "epic-Buffalo"))
        // The shape only: the resolution stays the person's or Settings' choice.
        XCTAssertEqual(smb.settings, LaunchSettings(aspect: "16:9"))
        XCTAssertNil(smb.settings.screen)
        XCTAssertNil(table.entry(for: "epic-buffalo"))   // ids are case-sensitive
        XCTAssertNil(table.entry(for: "app-367520"))
    }

    /// Every game is served by Playport's Steam client since decision 0153 (0115 was RDR2's alone);
    /// RDR2's entry keeps the backend the Rockstar launcher it starts draws with.
    func testEveryGameGetsPlayportsSteamClientAndRDR2KeepsVulkan() throws {
        let table = try CompatDefaults.load(directory: Self.shipped)
        let rdr2 = try XCTUnwrap(table.entry(for: "app-1174180"))
        XCTAssertNil(rdr2.settings.steamAPI)
        XCTAssertEqual(rdr2.settings.graphics, PublisherLauncher.rockstar.graphics)
        XCTAssertEqual(LaunchSettings().over(LaunchSettings.overEveryGame(rdr2.settings)).steamAPI, .client)
        XCTAssertEqual(LaunchSettings(steamAPI: .emulated).over(LaunchSettings.overEveryGame(nil)).steamAPI, .emulated)
    }

    /// Every game's runtime keys (decision 0153, from RDR2's of decisions 0126, 0142, 0152, plus
    /// the crash-reporter refusal): the address-space holdback, a 3,072 MiB heap, the x64
    /// critical-section stubs and FEX's batch 2; and FEX without AFP, with FPCR.FIZ from
    /// MXCSR.DAZ (decision 0154, from RDR2's of 0142). Its fastsync semaphores went with fastsync
    /// (decision 0157): ppsync takes every semaphore in process. Social Club's helper is told
    /// 300 MB of available memory (decision 0168).
    static let everyGameRuntime = "jumbo-mb=8960 env.PLAYPORT_VK_HEAP_MB=3072 "
        + "env.MADEIRA_X64_CS_FASTPATH=1 env.MADEIRA_FEX_BATCH2=1 env.PLAYPORT_SC_BLOCK_CRASHPAD=1 "
        + "env.FEX_HOSTFEATURES=disableafp env.MADEIRA_FEX_AFPOFF_FPCR=fiz avail-phys-cef-mb=300"

    /// Each default is a madeira.cfg key at the lowest level of a launch's config (Effective.config):
    /// a title's cohort keys, then its compatibility entry's and a person's Runtime keys override it
    /// by key and keep the rest (decisions 0091, 0153).
    func testEveryGamesDefaultsAreTheLowestRuntimeKeys() throws {
        XCTAssertEqual(LaunchSettings.everyGame.runtime, Self.everyGameRuntime)
        let every: [String: String] = ["jumbo-mb": "8960", "env.PLAYPORT_VK_HEAP_MB": "3072",
                                       "env.MADEIRA_X64_CS_FASTPATH": "1", "env.MADEIRA_FEX_BATCH2": "1",
                                       "env.PLAYPORT_SC_BLOCK_CRASHPAD": "1", "env.FEX_HOSTFEATURES": "disableafp",
                                       "env.MADEIRA_FEX_AFPOFF_FPCR": "fiz", "avail-phys-cef-mb": "300"]
        XCTAssertEqual(LaunchSettings.everyGameKeys, every)
        let plain = LaunchSettings.resolve(game: LaunchSettings.overEveryGame(nil), global: LaunchSettings())
        XCTAssertEqual(plain.runtime, [:])
        XCTAssertEqual(plain.config(over: [:]), every)
        // A cohort title's own key (The Witcher 3's address-space hold) wins over everyGame's.
        XCTAssertEqual(plain.config(over: ["jumbo-mb": "32768", "cage-hold": "1"])["jumbo-mb"], "32768")
        // A person's key wins over all; everyGame's other keys stay.
        let own = LaunchSettings(runtime: "inproc-sync=0 env.PLAYPORT_VK_HEAP_MB=0 env.MADEIRA_FEX_BATCH2=0")
            .over(LaunchSettings.overEveryGame(nil))
        let config = LaunchSettings.resolve(game: own, global: LaunchSettings()).config(over: ["jumbo-mb": "32768"])
        XCTAssertEqual(config, ["jumbo-mb": "32768", "env.PLAYPORT_VK_HEAP_MB": "0", "inproc-sync": "0",
                                "env.MADEIRA_X64_CS_FASTPATH": "1", "env.MADEIRA_FEX_BATCH2": "0",
                                "env.PLAYPORT_SC_BLOCK_CRASHPAD": "1", "env.FEX_HOSTFEATURES": "disableafp",
                                "env.MADEIRA_FEX_AFPOFF_FPCR": "fiz", "avail-phys-cef-mb": "300"])
        // A title's entry keeps its own runtime keys and takes everyGame's other settings.
        let titled = LaunchSettings.overEveryGame(LaunchSettings(runtime: "jumbo-mb=4096"))
        XCTAssertEqual(titled.runtime, "jumbo-mb=4096")
        XCTAssertEqual(LaunchSettings.resolve(game: titled, global: LaunchSettings()).config(over: [:])["jumbo-mb"], "4096")
        XCTAssertEqual(titled.jitPoolMB, 896)
        XCTAssertEqual(LaunchSettings.overEveryGame(LaunchSettings(endLauncherAfterSignIn: false)).endLauncherAfterSignIn, false)
    }

    /// RDR2 is told 2,304 MiB of video memory, not 3,072 (decisions 0142 and 0153 as amended
    /// 2026-10-30): its heap size and the plan's video figure (DXVK's DXGI, KosmicKrisp's budget) by
    /// its entry's keys over everyGame's; every other game keeps everyGame's 3,072 heap.
    func testRDR2IsTold2304MiBOfVideoMemory() throws {
        let rdr2 = try XCTUnwrap(CompatDefaults.load(directory: Self.shipped).entry(for: "app-1174180"))
        let config = LaunchSettings.resolve(game: LaunchSettings.overEveryGame(rdr2.settings), global: LaunchSettings())
            .config(over: [:])
        XCTAssertEqual(config["env.PLAYPORT_VK_HEAP_MB"], "2304")
        XCTAssertEqual(config["vram-mb"], "2304")
        XCTAssertEqual(config["jumbo-mb"], "8960")   // everyGame's other keys stay
        let overrides = MemoryPlan.Overrides.read(value: { config[$0] }, environment: [:])
        let plan = MemoryPlan(MemoryPlan.Inputs(limitMB: 8192, physicalMB: 11734, poolMB: 4096), overrides: overrides)
        XCTAssertEqual(plan.videoMB, 2304)
        XCTAssertEqual(plan.dxvkOption, "dxgi.maxDeviceMemory = 2304")
        XCTAssertEqual(plan.vulkanEnvironment[MemoryPlan.vulkanBudgetVariable], "2304")
        // A person's Runtime keys still win (a dev build's row).
        let own = LaunchSettings(runtime: "vram-mb=3072 env.PLAYPORT_VK_HEAP_MB=3072")
            .over(LaunchSettings.overEveryGame(rdr2.settings))
        let mine = LaunchSettings.resolve(game: own, global: LaunchSettings()).config(over: [:])
        XCTAssertEqual(mine["vram-mb"], "3072")
        XCTAssertEqual(mine["env.PLAYPORT_VK_HEAP_MB"], "3072")
        let plain = LaunchSettings.resolve(game: LaunchSettings.overEveryGame(nil), global: LaunchSettings()).config(over: [:])
        XCTAssertEqual(plain["env.PLAYPORT_VK_HEAP_MB"], "3072")
        XCTAssertNil(plain["vram-mb"])
    }

    /// Every World of Warcraft product runs FEX without AVX (patches/fex 0088): its entry's
    /// FEX_HOSTFEATURES replaces everyGame's by key, so it names disableafp again; everyGame's
    /// other keys stay, in the dev build's config and in the release build's runtime keys.
    func testWorldOfWarcraftRunsWithoutAVXAndKeepsEveryGamesKeys() throws {
        let table = try CompatDefaults.load(directory: Self.shipped)
        for product in BattleNetProduct.allCases {
            let wow = try XCTUnwrap(table.entry(for: "bnet-\(product.code)"), product.code)
            let config = LaunchSettings.resolve(game: LaunchSettings.overEveryGame(wow.settings), global: LaunchSettings())
                .config(over: [:])
            XCTAssertEqual(config["env.FEX_HOSTFEATURES"], "disableafp,disableavx", product.code)
            XCTAssertEqual(config["env.MADEIRA_FEX_AFPOFF_FPCR"], "fiz", product.code)
            XCTAssertEqual(LaunchSettings.releaseRuntime(compat: wow.settings)["env.FEX_HOSTFEATURES"], "disableafp,disableavx")
        }
    }

    /// The Witcher 3's current build gets short reservations (patches/madeira-unix 0222) and keeps
    /// FEX's PAUSE (decision 0163 withdrew 0162's WFE); its classic branch's cohort hold (jumbo-mb=32768) stays, since the entry names no jumbo-mb.
    func testTheWitcher3GetsShortReservationsAndKeepsItsCohortHold() throws {
        let entry = try XCTUnwrap(CompatDefaults.load(directory: Self.shipped).entry(for: "app-292030"))
        XCTAssertEqual(entry.settings.runtime, "short-reserve-mb=6144")
        let game = LaunchSettings.overEveryGame(entry.settings)
        let effective = LaunchSettings.resolve(game: game, global: LaunchSettings())
        XCTAssertEqual(effective.config(over: [:])["short-reserve-mb"], "6144")
        XCTAssertNil(effective.config(over: [:])["env.MADEIRA_FEX_PAUSE"])
        XCTAssertEqual(effective.config(over: [:])["jumbo-mb"], "8960")
        let classic = effective.config(over: ["jumbo-mb": "32768", "cage-hold": "1"])
        XCTAssertEqual(classic["jumbo-mb"], "32768")
        XCTAssertEqual(classic["cage-hold"], "1")
    }

    /// The table reaches players: no issue id or tracker address anywhere in it.
    func testTheShippedTableNamesNothingInternal() throws {
        let text = try String(contentsOf: Self.shipped.appendingPathComponent(CompatDefaults.fileName), encoding: .utf8)
        XCTAssertFalse(CompatDefaults.containsInternalReference(text))
        XCTAssertFalse(text.contains("PLA-"))
        XCTAssertTrue(CompatDefaults.containsInternalReference("see pla-108"))
        XCTAssertTrue(CompatDefaults.containsInternalReference("https://linear.app/x"))
        XCTAssertFalse(CompatDefaults.containsInternalReference("This game draws nothing on a screen wider than 16:9."))
    }

    func testTheTableRefusesWhatItDoesNotKnow() {
        let entry = #""settings":{"screen":"1280x720"},"reason":"Why.""#
        let bad: [(String, CompatDefaultsError)] = [
            (#"[]"#, .notAnObject("the file")),
            (#"{"titles":{},"comment":"x"}"#, .unknownKey("comment")),
            (#"{"titles":{"Epic-Buffalo":{\#(entry)}}}"#, .badTitle("Epic-Buffalo")),
            (#"{"titles":{"epic-A":{\#(entry),"ref":"x"}}}"#, .unknownKey("epic-A.ref")),
            (#"{"titles":{"epic-A":{"settings":{"screen":"1280x720"}}}}"#, .noReason("epic-A")),
            (#"{"titles":{"epic-A":{"settings":{"screen":"1280x720"},"reason":"PLA-108"}}}"#, .internalReference("epic-A")),
            (#"{"titles":{"epic-A":{"settings":{"shape":"16:9"},"reason":"Why."}}}"#, .badSetting("epic-A.shape")),
            (#"{"titles":{"epic-A":{"settings":{"aspect":"21:9"},"reason":"Why."}}}"#, .badSetting("epic-A.aspect")),
            (#"{"titles":{"epic-A":{"settings":{"graphics":"metal"},"reason":"Why."}}}"#, .badSetting("epic-A.graphics")),
            (#"{"titles":{"epic-A":{"settings":{"screen":"wide"},"reason":"Why."}}}"#, .badSetting("epic-A.screen")),
            (#"{"titles":{"epic-A":{"settings":{"frameLimit":-1},"reason":"Why."}}}"#, .badSetting("epic-A.frameLimit")),
            (#"{"titles":{"epic-A":{"settings":{},"reason":"Why."}}}"#, .notAnObject("epic-A.settings")),
            (#"{"titles":{"epic-A":{"reason":"Why."}}}"#, .notAnObject("epic-A.settings")),
            (#"{"titles":{"epic-A":{"controls":"mouse","reason":"Why."}}}"#, .badSetting("epic-A.controls")),
            (#"{"titles":{"epic-A":{"controls":["keyboardMouse"],"reason":"Why."}}}"#, .badSetting("epic-A.controls")),
        ]
        for (json, error) in bad {
            XCTAssertThrowsError(try parse(json), json) { XCTAssertEqual($0 as? CompatDefaultsError, error, json) }
        }
        // Any launch setting may be a default, in the --settings JSON form.
        XCTAssertEqual(try parse(#"{"titles":{"app-1":{"settings":{"frameLimit":30,"graphics":"vulkan","arguments":"-dx9"},"reason":"Why."}}}"#)
            .entry(for: "app-1")?.settings, LaunchSettings(frameLimit: 30, graphics: .vulkan, arguments: "-dx9"))
    }

    /// An entry may set the game's starting on-screen layout (`controls`), with or without launch
    /// settings (touch controls phase 4).
    func testAnEntryMaySetTheStartingLayout() throws {
        let only = try XCTUnwrap(parse(#"{"titles":{"app-1":{"controls":"keyboardMouse","reason":"Why."}}}"#).entry(for: "app-1"))
        XCTAssertEqual(only.controls, .keyboardMouse)
        XCTAssertEqual(only.settings, LaunchSettings())
        let both = try XCTUnwrap(parse(#"{"titles":{"app-1":{"settings":{"frameLimit":30},"controls":"pointClick","reason":"Why."}}}"#)
            .entry(for: "app-1"))
        XCTAssertEqual(both.controls, .pointClick)
        XCTAssertEqual(both.settings, LaunchSettings(frameLimit: 30))
        XCTAssertNil(try XCTUnwrap(parse(#"{"titles":{"app-1":{"settings":{"frameLimit":30},"reason":"Why."}}}"#).entry(for: "app-1")).controls)
    }

    /// Assassin's Creed takes no controller without a third-party fix (its Options list only keyboard
    /// layouts): it starts on Keyboard & mouse, and its launch settings are Playport's.
    func testTheShippedTableStartsAssassinsCreedOnKeyboardAndMouse() throws {
        let table = try CompatDefaults.load(directory: Self.shipped)
        let ac = try XCTUnwrap(table.entry(for: "app-15100"))
        XCTAssertEqual(ac.controls, .keyboardMouse)
        XCTAssertEqual(ac.settings, LaunchSettings())
        XCTAssertNil(table.entry(for: "epic-Buffalo")?.controls)
    }

    /// The person's own choice, then the compatibility default, then Settings, then Playport's.
    func testSuperMeatBoysShapeKeepsTheChosenResolution() throws {
        let compat = try XCTUnwrap(CompatDefaults.load(directory: Self.shipped).entry(for: "epic-Buffalo")).settings
        let global = LaunchSettings(screen: "1080")
        XCTAssertEqual(LaunchSettings.resolve(game: compat, global: LaunchSettings()).guestScreen, "16:9@720")
        XCTAssertEqual(LaunchSettings.resolve(game: compat, global: global).guestScreen, "16:9@1080")
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(screen: "540").over(compat), global: global).guestScreen, "16:9@540")
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(aspect: "phone").over(compat), global: global).guestScreen, "1080")
    }

    func testPrecedenceAndReset() {
        let compat = LaunchSettings(screen: "1280x720", frameLimit: 30)
        let global = LaunchSettings(screen: "1080", frameLimit: 40, graphics: .vulkan)
        func effective(_ own: LaunchSettings?) -> LaunchSettings.Effective {
            LaunchSettings.resolve(game: own.map { $0.over(compat) } ?? compat, global: global)
        }
        XCTAssertEqual(effective(nil).screen, "1280x720")                                   // compat over Settings
        XCTAssertEqual(effective(nil).frameLimit, 30)
        XCTAssertEqual(effective(nil).graphics, .vulkan)                                   // Settings where compat is silent
        XCTAssertEqual(effective(LaunchSettings(screen: "720")).screen, "720")              // the person's own wins
        XCTAssertEqual(effective(LaunchSettings(screen: "720")).frameLimit, 30)
        // Reset (the row's value back to nil) returns to the compatibility default, not Settings'.
        var own = LaunchSettings(screen: "720")
        own.screen = nil
        XCTAssertEqual(effective(own).screen, "1280x720")
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings().over(nil), global: LaunchSettings()).screen, "720")
        XCTAssertEqual(LaunchSettings(arguments: "-a").over(LaunchSettings(arguments: "-b")).arguments, "-a")
        XCTAssertEqual(LaunchSettings().over(LaunchSettings(arguments: "-b", runtime: "vram-mb=1")),
                       LaunchSettings(arguments: "-b", runtime: "vram-mb=1"))
    }

    /// A person's own Runtime keys or Graphics options merge with the default's by key
    /// (decision 0091): typing another key keeps the default's (Duck Paradox's SMC tracking,
    /// its default until 2026-10-13); naming the default's key overrides it. Arguments, with
    /// no keys, are the person's alone.
    func testOwnKeysMergeWithTheCompatibilityDefaultsPerKey() throws {
        let duck = try XCTUnwrap(try parse(#"{"titles":{"gog-1816031813":{"settings":{"runtime":"env.MADEIRA_KEEP_SMC=1"},"reason":"Why."}}}"#)
            .entry(for: "gog-1816031813")).settings
        let merged = LaunchSettings(runtime: "env.FOO=1").over(duck)
        XCTAssertEqual(merged.runtime, "env.MADEIRA_KEEP_SMC=1 env.FOO=1")
        XCTAssertEqual(LaunchSettings.runtimeKeys(merged.runtime), ["env.MADEIRA_KEEP_SMC": "1", "env.FOO": "1"])
        XCTAssertEqual(LaunchSettings.resolve(game: merged, global: LaunchSettings()).runtime,
                       ["env.MADEIRA_KEEP_SMC": "1", "env.FOO": "1"])
        let off = LaunchSettings(runtime: "env.MADEIRA_KEEP_SMC=0").over(duck)
        XCTAssertEqual(LaunchSettings.runtimeKeys(off.runtime), ["env.MADEIRA_KEEP_SMC": "0"])
        XCTAssertEqual(LaunchSettings(runtime: "  ").over(duck).runtime, duck.runtime)

        let base = LaunchSettings(graphicsOptions: #"dxvk.tilerMode=False VKD3D_CONFIG="a b""#)
        XCTAssertEqual(LaunchSettings(graphicsOptions: "VKD3D_CONFIG=c").over(base).graphicsOptions, "dxvk.tilerMode=False VKD3D_CONFIG=c")
        let kept = LaunchSettings(graphicsOptions: "MESA_KK_DEBUG=x").over(base).graphicsOptions
        XCTAssertEqual(LaunchSettings.graphicsEnvironment(kept),
                       ["DXVK_CONFIG": "dxvk.tilerMode = False", "VKD3D_CONFIG": "a b", "MESA_KK_DEBUG": "x"])
        XCTAssertEqual(LaunchSettings(arguments: "-gl").over(LaunchSettings(arguments: "-b")).arguments, "-gl")
    }

    /// The marker shows only while the compatibility value is the effective one.
    func testTheMarkerShowsOnlyForAnEffectiveCompatibilityValue() {
        let name: (String?) -> String = { $0 ?? "-" }
        let compat = OptionValue.of(own: nil, compat: Optional("1280x720"), inherited: "720", name: name)
        XCTAssertTrue(compat.compat)
        XCTAssertFalse(compat.changed)
        XCTAssertEqual(compat.text, "\(OptionValue.compatMarker) For this game · 1280x720")
        let own = OptionValue.of(own: Optional("720"), compat: Optional("1280x720"), inherited: "720", name: name)
        XCTAssertFalse(own.compat)
        XCTAssertTrue(own.changed)
        let none = OptionValue.of(own: String??.none, inherited: "720", name: name)
        XCTAssertFalse(none.compat)
        XCTAssertEqual(none.text, "Default · 720")
    }
}
