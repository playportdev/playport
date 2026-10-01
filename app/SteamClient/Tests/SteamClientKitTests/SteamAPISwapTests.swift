// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// A minimal PE image: the DOS header's e_lfanew, the PE signature and the
/// COFF machine, then a tag that tells copies apart.
func peImage(machine: UInt16, tag: String) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 0x40)
    b[0] = 0x4d; b[1] = 0x5a
    b[0x3c] = 0x40
    b += [0x50, 0x45, 0, 0, UInt8(machine & 0xff), UInt8(machine >> 8)]
    return b + Array(tag.utf8)
}

final class SteamAPISwapTests: XCTestCase {
    var dir: URL!
    var root: URL { dir.appendingPathComponent("Game", isDirectory: true) }
    var emulator: URL { dir.appendingPathComponent("steamapi", isDirectory: true) }
    let game64 = peImage(machine: 0x8664, tag: "game steam_api64")
    let game32 = peImage(machine: 0x14c, tag: "game steam_api")
    let emu64 = peImage(machine: 0x8664, tag: "emulator 64")
    let emu32 = peImage(machine: 0x14c, tag: "emulator 32")
    let settings = SteamAPISwap.Settings(appID: 367520, personaName: "Knight\nPlayer", steamID: 4242,
                                          dlc: [.init(appID: 20, name: "Second"), .init(appID: 10, name: "First")])

    override func setUpWithError() throws {
        dir = try scratchDir("swap")
        try write("Game/Game.exe", Array("exe".utf8))
        try write("Game/Game_Data/Plugins/x86_64/steam_api64.dll", game64)
        try write("Game/tools/steam_api.dll", game32)
        try write("steamapi/x86_64-windows/steam_api64.dll", emu64)
        try write("steamapi/i386-windows/steam_api.dll", emu32)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ path: String, _ content: [UInt8]) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content).write(to: url)
    }

    func read(_ path: String) -> [UInt8]? { (try? Data(contentsOf: root.appendingPathComponent(path))).map(Array.init) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    func testApplyKeepsTheOriginalsAndWritesSettings() throws {
        XCTAssertEqual(SteamAPISwap.state(in: root), .original)
        XCTAssertEqual(SteamAPISwap.sites(in: root).map(\.path), ["Game_Data/Plugins/x86_64/steam_api64.dll", "tools/steam_api.dll"])
        let done = try SteamAPISwap.apply(in: root, emulator: emulator, settings: settings)
        XCTAssertEqual(done.map(\.arch), ["x86_64", "i386"])
        XCTAssertEqual(SteamAPISwap.state(in: root), .emulated)
        XCTAssertEqual(read("Game_Data/Plugins/x86_64/steam_api64.dll"), emu64)
        XCTAssertEqual(read("Game_Data/Plugins/x86_64/steam_api64.dll.orig"), game64)
        XCTAssertEqual(read("tools/steam_api.dll"), emu32)
        XCTAssertEqual(read("tools/steam_api.dll.orig"), game32)

        let s = "Game_Data/Plugins/x86_64/steam_settings/"
        XCTAssertEqual(read(s + "steam_appid.txt"), Array("367520\n".utf8))
        let user = String(decoding: read(s + "configs.user.ini") ?? [], as: UTF8.self)
        XCTAssertEqual(user, "[user::general]\naccount_name=Knight Player\naccount_steamid=4242\nlanguage=english\n")
        let app = String(decoding: read(s + "configs.app.ini") ?? [], as: UTF8.self)
        XCTAssertEqual(app, "[app::dlcs]\nunlock_all=0\n10=First\n20=Second\n")
        let main = String(decoding: read(s + "configs.main.ini") ?? [], as: UTF8.self)
        XCTAssertTrue(main.contains("disable_networking=1"))
        XCTAssertTrue(exists("tools/steam_settings/playport.txt"))
        XCTAssertFalse(exists("steam_settings"), "settings go beside each DLL, not at the root")
    }

    func testApplyIsIdempotentAndRefreshesSettings() throws {
        try SteamAPISwap.apply(in: root, emulator: emulator, settings: settings)
        var other = settings
        other.dlc = []
        other.personaName = nil
        try SteamAPISwap.apply(in: root, emulator: emulator, settings: other)
        XCTAssertEqual(read("Game_Data/Plugins/x86_64/steam_api64.dll.orig"), game64, "a second apply never keeps the emulator as the original")
        XCTAssertFalse(exists("Game_Data/Plugins/x86_64/steam_api64.dll.orig.orig"))
        let user = String(decoding: read("tools/steam_settings/configs.user.ini") ?? [], as: UTF8.self)
        XCTAssertFalse(user.contains("account_name"))
        XCTAssertEqual(String(decoding: read("tools/steam_settings/configs.app.ini") ?? [], as: UTF8.self), "[app::dlcs]\nunlock_all=0\n")
    }

    func testRestorePutsTheGameBackAndRemovesOnlyPlayportSettings() throws {
        try write("Game/own/steam_settings/force_language.txt", Array("german".utf8))
        try SteamAPISwap.apply(in: root, emulator: emulator, settings: settings)
        XCTAssertEqual(try SteamAPISwap.restore(in: root), 2)
        XCTAssertEqual(SteamAPISwap.state(in: root), .original)
        XCTAssertEqual(read("Game_Data/Plugins/x86_64/steam_api64.dll"), game64)
        XCTAssertEqual(read("tools/steam_api.dll"), game32)
        XCTAssertFalse(exists("Game_Data/Plugins/x86_64/steam_api64.dll.orig"))
        XCTAssertFalse(exists("Game_Data/Plugins/x86_64/steam_settings"))
        XCTAssertFalse(exists("tools/steam_settings"))
        XCTAssertTrue(exists("own/steam_settings/force_language.txt"), "a folder Playport did not write stays")
        XCTAssertEqual(try SteamAPISwap.restore(in: root), 0)
    }

    func testAKillBetweenTheRenameAndTheCopyIsFinishedEitherWay() throws {
        // Only the .orig: the rename out happened, the copy did not.
        let dll = root.appendingPathComponent("Game_Data/Plugins/x86_64/steam_api64.dll")
        XCTAssertEqual(rename(dll.path, dll.path + ".orig"), 0)
        XCTAssertEqual(SteamAPISwap.state(in: root), .mixed)
        try SteamAPISwap.apply(in: root, emulator: emulator, settings: settings)
        XCTAssertEqual(read("Game_Data/Plugins/x86_64/steam_api64.dll"), emu64)
        XCTAssertEqual(read("Game_Data/Plugins/x86_64/steam_api64.dll.orig"), game64)

        try FileManager.default.removeItem(at: dll)
        XCTAssertEqual(try SteamAPISwap.restore(in: root), 2)
        XCTAssertEqual(read("Game_Data/Plugins/x86_64/steam_api64.dll"), game64)
    }

    func testADLLOfTheWrongMachineIsLeftAlone() throws {
        try write("Game/odd/steam_api.dll", peImage(machine: 0x8664, tag: "64-bit under the 32-bit name"))
        try write("Game/notpe/steam_api64.dll", Array("not a PE".utf8))
        let done = try SteamAPISwap.apply(in: root, emulator: emulator, settings: settings)
        XCTAssertEqual(done.count, 2)
        XCTAssertFalse(exists("odd/steam_api.dll.orig"))
        XCTAssertFalse(exists("notpe/steam_api64.dll.orig"))
        XCTAssertEqual(SteamAPISwap.state(in: root), .mixed)
    }

    func testAMissingEmulatorStopsTheSwapWithTheGameDLLKept() throws {
        try FileManager.default.removeItem(at: emulator.appendingPathComponent("i386-windows"))
        XCTAssertThrowsError(try SteamAPISwap.apply(in: root, emulator: emulator, settings: settings))
        // Whatever was done can be undone.
        try SteamAPISwap.restore(in: root)
        XCTAssertEqual(read("tools/steam_api.dll"), game32)
        XCTAssertEqual(SteamAPISwap.state(in: root), .original)
    }

    func testEnsureFollowsTheMode() throws {
        XCTAssertEqual(try SteamAPISwap.ensure(.emulated, in: root, emulator: emulator, settings: settings), .emulated)
        XCTAssertEqual(try SteamAPISwap.ensure(.original, in: root, emulator: emulator, settings: settings), .original)
        try FileManager.default.removeItem(at: root.appendingPathComponent("tools"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Game_Data"))
        XCTAssertEqual(try SteamAPISwap.ensure(.emulated, in: root, emulator: emulator, settings: settings), .none)
    }

    func testASHA256ListVerifiesTheKeptOriginal() async throws {
        let list = dir.appendingPathComponent("sums")
        try """
        \(SHA256Stream.hash(Array("exe".utf8)).hex)  Game.exe
        \(SHA256Stream.hash(game64).hex)  Game_Data/Plugins/x86_64/steam_api64.dll
        \(SHA256Stream.hash(game32).hex)  tools/steam_api.dll

        """.write(to: list, atomically: true, encoding: .utf8)
        try SteamAPISwap.apply(in: root, emulator: emulator, settings: settings)
        let r = try await TitleInstaller.verifySHA256List(dir: root, list: list)
        XCTAssertEqual(r.bad, [])
        XCTAssertEqual(r.unlisted, [])
    }

    func testOwnedDLCIsTheListIntersectedWithTheLicences() {
        let app = KeyValue(name: "367520", children: [
            KeyValue(name: "extended", children: [KeyValue(name: "listofdlc", value: "30, 10,20,x")]),
        ])
        XCTAssertEqual(SteamGameProfile.ownedDLC(app: app, owned: [10, 30, 99]), [10, 30])
        XCTAssertEqual(SteamGameProfile.ownedDLC(app: KeyValue(name: "1"), owned: [10]), [])
    }
}

final class SteamAPISwapVerifyTests: XCTestCase {
    /// An install whose steam_api64.dll is swapped verifies against the kept
    /// original; a damaged original is repaired in place and the emulator stays.
    func testVerifyAndRepairSeeThroughTheSwap() async throws {
        let dir = try scratchDir("swapverify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = Fixture()
        let game64 = peImage(machine: 0x8664, tag: "game steam_api64")
        let m = try DepotManifest(depotID: 1, gid: 1, files: [
            fx.file("Game.exe", bytes("EXE!")), fx.file("bin/steam_api64.dll", game64),
        ])
        let layout = InstallLayout.root(dir)
        let installer = TitleInstaller(layout: layout, session: nil, log: .silent)
        let plan = try InstallPlan.make(appID: 9, buildID: 3, manifests: [m])
        let tree = layout.stagingTree(appID: 9, buildID: 3)
        var e = InstallEngine(tree: tree, journal: layout.journal(appID: 9, buildID: 3), source: fx.source, log: .silent)
        e.freeSpace = { _ in 1 << 40 }
        _ = try await e.run(plan)
        let (final, _) = try installer.destination("Title", appID: 9)
        try installer.commit(tree, to: final, replacing: false,
                             receipt: InstallReceipt(appID: 9, name: "T", installDir: "Title", buildID: 3, depots: [DepotRef(depotID: 1, gid: 1)],
                                                     files: 2, bytes: UInt64(4 + game64.count), skippedDepots: [], skippedSymlinks: 0, installedAt: "-"))
        try RetainedManifest.save(m, to: layout.manifestFile(DepotRef(depotID: 1, gid: 1)))

        let emulator = dir.appendingPathComponent("steamapi")
        let emu64 = peImage(machine: 0x8664, tag: "emulator 64")
        try FileManager.default.createDirectory(at: emulator.appendingPathComponent("x86_64-windows"), withIntermediateDirectories: true)
        try Data(emu64).write(to: emulator.appendingPathComponent("x86_64-windows/steam_api64.dll"))
        try SteamAPISwap.apply(in: final, emulator: emulator, settings: .init(appID: 9))

        var report = try await installer.verify(appID: 9)
        XCTAssertEqual(report.bad, [], "the kept original is what the manifest describes")
        XCTAssertEqual(report.unlisted, [], "the .orig and Playport's steam_settings are not the player's files")

        let orig = final.appendingPathComponent("bin/steam_api64.dll.orig")
        var damaged = game64
        damaged[damaged.count - 1] ^= 1
        try Data(damaged).write(to: orig)
        report = try await installer.verify(appID: 9)
        XCTAssertEqual(report.bad, ["bin/steam_api64.dll"])

        let v = try await installer.verifyPlan(appID: 9, concurrency: 2)
        let fixed = try await installer.replace(v.report, plan: v.plan.restricted(to: Set(v.report.bad)), receipt: v.receipt,
                                                root: v.root, source: fx.source, options: .init(), say: { _ in })
        XCTAssertEqual(fixed.repaired, 1)
        XCTAssertEqual(Array(try Data(contentsOf: orig)), game64, "repair writes the original's place")
        XCTAssertEqual(Array(try Data(contentsOf: final.appendingPathComponent("bin/steam_api64.dll"))), emu64, "the emulator stays")
        XCTAssertEqual(SteamAPISwap.state(in: final), .emulated)

        // Restored, the install is the manifest's again with nothing left over.
        try SteamAPISwap.restore(in: final)
        report = try await installer.verify(appID: 9)
        XCTAssertEqual(report.bad, [])
        XCTAssertEqual(report.unlisted, [])
    }
}
