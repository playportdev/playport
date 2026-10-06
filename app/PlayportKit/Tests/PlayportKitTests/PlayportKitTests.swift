// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SteamClientKit
import XCTest
@testable import PlayportKit

/// app/PlayportKit/Titles, the directory the app ships as Titles/.
private let titlesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Titles")

final class CohortTests: XCTestCase {
    func testTheBundledCohortCarriesTheHollowKnightPin() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        let hk = try XCTUnwrap(cohort.title(installDir: "hollow knight"))
        // Decision 0005's pin.
        XCTAssertEqual(hk.appID, 367520)
        XCTAssertEqual(hk.depots, [.init(depotID: 367521, manifestGID: "257781644874438846")])
        XCTAssertEqual(hk.buildID, 22529139)
        XCTAssertEqual(hk.executable, "hollow_knight.exe")
        XCTAssertEqual(hk.installedSize, 5_231_995_691)
        XCTAssertEqual(hk.files, 1785)
        let list = try XCTUnwrap(cohort.checksumList(named: hk.checksums))
        XCTAssertEqual(try String(contentsOf: list, encoding: .utf8).split(separator: "\n").count, 1785)
    }

    func testTheBundledCohortCarriesTheWitcher3PinWithItsHoldback() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        let w3 = try XCTUnwrap(cohort.title(installDir: "The Witcher 3"))
        XCTAssertEqual(w3.appID, 292030)
        XCTAssertEqual(w3.buildID, 3280809)
        XCTAssertEqual(w3.depots.count, 23)
        XCTAssertEqual(w3.executable, #"bin\x64\witcher3.exe"#)
        XCTAssertEqual(w3.installedSize, 41_585_389_035)
        // docs/evidence/2026-09-25-witcher3-setup.md: the 32 GB reservation needs the boot-time hold.
        XCTAssertEqual(w3.config, ["jumbo-mb": "32768"])
        XCTAssertNoThrow(try TitleConfig.validate(w3.config ?? [:]))
        XCTAssertEqual(w3.screen, "720")   // 1.32 has no render scale; the guest's desktop sets its size
        let list = try XCTUnwrap(cohort.checksumList(named: w3.checksums))
        let lines = try String(contentsOf: list, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2459)
        XCTAssertTrue(lines.contains { $0.hasSuffix("  bin/x64/witcher3.exe") })
    }

    /// Every cohort title names a checksum list that ships beside titles.json.
    func testEveryTitleHasItsChecksumList() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        for t in cohort.titles {
            let name = try XCTUnwrap(t.checksums)
            let url = try XCTUnwrap(cohort.checksumList(named: name))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) is not in Titles/")
        }
    }
}

final class LaunchPlanTests: XCTestCase {
    func testPlanIsTheDOSPathTitleModeTakes() throws {
        let plan = try LaunchPlan.make(installDir: "Hollow Knight", executable: "hollow_knight.exe",
                                       arguments: ["-logFile", #"C:\hollow_knight-player.log"#])
        XCTAssertEqual(plan.exe, #"Games\Hollow Knight\hollow_knight.exe"#)
        XCTAssertEqual(plan.args, ["-logFile", #"C:\hollow_knight-player.log"#])

        let nested = try LaunchPlan.make(installDir: "G", executable: "bin/g.exe", arguments: [])
        XCTAssertEqual(nested.exe, #"Games\G\bin\g.exe"#)
        XCTAssertEqual(nested.args, [])
    }

    func testPlanRefusesPathsOutsideGames() {
        for (dir, exe) in [("..", "x.exe"), ("G", "../x.exe"), ("", "x.exe"), ("G", ""), ("a/b", "x.exe"), ("G", #"a\\x.exe"#)] {
            XCTAssertThrowsError(try LaunchPlan.make(installDir: dir, executable: exe, arguments: []), "\(dir) \(exe)")
        }
    }

    func testScreenSpecsAreCheckedBeforeTheLaunch() throws {
        for ok in ["720", "native", "NATIVE", "4:3", "1280x720", "200", "4320", "320x200"] {
            XCTAssertTrue(LaunchPlan.validScreen(ok), ok)
        }
        for bad in ["", "199", "4321", "-720", "720p", "1280x", "x720", "1280x720x1", "319x720", "1280x199", "１２８０"] {
            XCTAssertFalse(LaunchPlan.validScreen(bad), bad)
        }
        XCTAssertEqual(try LaunchPlan.make(installDir: "T", executable: "t.exe", arguments: [], screen: "540").screen, "540")
        XCTAssertThrowsError(try LaunchPlan.make(installDir: "T", executable: "t.exe", arguments: [], screen: "big")) {
            XCTAssertEqual($0 as? LaunchPlanError, .badScreen("big"))
        }
    }
}

final class TitleConfigTests: XCTestCase {
    func testMergedFileKeepsTheSharedKeysAndPutsTheTitleKeysLast() {
        let text = TitleConfig.merged(shared: "inproc-sync = 1\njumbo-mb = 0", config: ["jumbo-mb": "32768", "arena-mb": "64"],
                                      title: "W3")
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "inproc-sync = 1")
        // The reader keeps the last line for a key.
        XCTAssertEqual(Array(lines.suffix(2)), ["arena-mb = 64", "jumbo-mb = 32768"])
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertEqual(TitleConfig.merged(shared: nil, config: ["a": "1"], title: "T").split(separator: "\n").last, "a = 1")
    }

    func testDirectoryNameIsTheInstallFolder() {
        XCTAssertEqual(TitleConfig.directoryName(exe: #"Games\The Witcher 3\bin\x64\witcher3.exe"#), "The Witcher 3")
        XCTAssertEqual(TitleConfig.directoryName(exe: "C:/Games/Hollow Knight/hollow_knight.exe"), "Hollow Knight")
        XCTAssertEqual(TitleConfig.directoryName(exe: #"C:\tools\a:b.exe"#), "a_b.exe")
        XCTAssertEqual(TitleConfig.directoryName(exe: ".."), "title")
    }

    func testPrepareWritesTheMergedFileUnderTheDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("titlecfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("pool = 896\n".utf8).write(to: root.appendingPathComponent("madeira.cfg"))
        let dir = try TitleConfig.prepare(shared: root, documents: root, exe: #"Games\The Witcher 3\bin\x64\witcher3.exe"#,
                                          config: ["jumbo-mb": "32768"], title: "W3")
        XCTAssertEqual(dir.path, root.appendingPathComponent("title-cfg/The Witcher 3").path)
        let text = try String(contentsOf: dir.appendingPathComponent("madeira.cfg"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("pool = 896\n"))
        XCTAssertTrue(text.hasSuffix("jumbo-mb = 32768\n"))
        // The shared file is untouched.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("madeira.cfg"), encoding: .utf8), "pool = 896\n")
    }

    func testDrivenItemsParseAndBadOnesAreRefused() {
        XCTAssertEqual(TitleConfig.parse(nil), [:])
        XCTAssertEqual(TitleConfig.parse("jumbo-mb=32768,env.WINEDEBUG=%2Bvirtual%2Cerr"),
                       ["jumbo-mb": "32768", "env.WINEDEBUG": "+virtual,err"])
        XCTAssertNil(TitleConfig.parse("jumbo-mb"))
        XCTAssertNil(TitleConfig.parse("a b=1"))
        XCTAssertNil(TitleConfig.parse("a=1%0A"))
        XCTAssertThrowsError(try LaunchPlan.make(installDir: "G", executable: "g.exe", arguments: [], config: ["=": "1"]))
    }
}

final class CatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("playportkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var games: URL { root.appendingPathComponent("Games") }

    private func file(_ rel: String, _ text: String = "x") throws {
        let url = games.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func receipt(app: UInt32, dir: String) throws -> InstallReceipt {
        let json = """
        {"appID":\(app),"name":"Server \(app)","installDir":"\(dir)","buildID":7,"depots":[{"depotID":\(app + 1),"gid":42}],
         "files":2,"bytes":1234,"skippedDepots":[],"skippedSymlinks":0,"installedAt":"2026-09-24T00:00:00Z"}
        """
        return try JSONDecoder().decode(InstallReceipt.self, from: Data(json.utf8))
    }

    func testAdoptionDetectsDX12AndRefreshesItAfterAnUpdate() throws {
        try file("DX Game/game/Binaries/Win64/game-Win64-Shipping.exe")
        let exe = games.appendingPathComponent("DX Game/game/Binaries/Win64/game-Win64-Shipping.exe")
        try Direct3D12Tests.pe(delay: true).write(to: exe)
        let cohort = Cohort(titles: [])
        let first = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: Catalog())
        XCTAssertEqual(first.titles.first?.importsDirect3D12, true)
        let round = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(round.titles.first?.importsDirect3D12, true)
        XCTAssertEqual(round.titles.first?.direct3D, first.titles.first?.direct3D)
        XCTAssertEqual(round.titles.first?.detectsDirect3D12, true)
        try Direct3D12Tests.pe(name: "d3d11.dll").write(to: exe)
        let next = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: first)
        XCTAssertEqual(next.titles.first?.importsDirect3D12, false)
        XCTAssertEqual(next.titles.first?.direct3D?.apis, [.d3d11])
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        var titles = try XCTUnwrap(oldJSON["titles"] as? [[String: Any]])
        titles[0].removeValue(forKey: "direct3D")
        oldJSON["titles"] = titles
        let legacy = try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertEqual(legacy.titles.first?.detectsDirect3D12, true)
        titles[0].removeValue(forKey: "importsDirect3D12")
        oldJSON["titles"] = titles
        let old = try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(old.titles.first?.importsDirect3D12)
        XCTAssertNil(old.titles.first?.direct3D)
        XCTAssertEqual(old.titles.first?.detectsDirect3D12, false)
    }

    func testAdoptionRecordsTheExecutableMachine() throws {
        try file("Old Game/game.exe")
        try file("New Game/game.exe")
        for (dir, machine) in [("Old Game", 0x14c), ("New Game", 0x8664)] {
            var pe = Direct3D12Tests.pe(plus: machine != 0x14c, name: "d3d9.dll")
            pe[0x84] = UInt8(machine & 0xff)
            pe[0x85] = UInt8(machine >> 8)
            try pe.write(to: games.appendingPathComponent("\(dir)/game.exe"))
        }
        let scanned = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], previous: Catalog())
        let old = try XCTUnwrap(scanned.titles.first { $0.installDir == "Old Game" })
        let new = try XCTUnwrap(scanned.titles.first { $0.installDir == "New Game" })
        XCTAssertEqual(old.executableMachine, 0x14c)
        XCTAssertTrue(old.isI386)
        XCTAssertEqual(new.executableMachine, 0x8664)
        XCTAssertFalse(new.isI386)
        let round = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(scanned))
        XCTAssertEqual(round.titles.map(\.executableMachine), scanned.titles.map(\.executableMachine))
    }

    func testAdoptionFindsTheStagedCohortTitleReady() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        try file("Hollow Knight/hollow_knight.exe")
        try file("Hollow Knight/UnityCrashHandler64.exe")
        try file("Hollow Knight/hollow_knight_Data/x.assets")
        let c = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: Catalog())
        XCTAssertEqual(c.titles.count, 1)
        let hk = c.titles[0]
        XCTAssertEqual(hk.id, "app-367520")
        XCTAssertEqual(hk.name, "Hollow Knight")
        XCTAssertEqual(hk.executable, "hollow_knight.exe")
        XCTAssertEqual(hk.sizeBytes, 5_231_995_691)
        XCTAssertEqual(hk.source, .cohort)
        XCTAssertEqual(hk.badge, .ready)
        var steamReceipt = try receipt(app: 367520, dir: hk.installDir)
        steamReceipt.buildID = hk.buildID
        let installed = try XCTUnwrap(Adoption.scan(games: games, cohort: cohort, receipts: [steamReceipt], previous: c)
            .title(id: hk.id))
        XCTAssertEqual(installed.source, .installed)
        XCTAssertNil(installed.checksums)
        XCTAssertEqual(try installed.launchPlan(cohort: cohort), try hk.launchPlan(cohort: cohort))
        XCTAssertEqual(try hk.launchPlan(cohort: cohort).exe, #"Games\Hollow Knight\hollow_knight.exe"#)
        XCTAssertEqual(try hk.launchPlan(cohort: cohort).args, ["-logFile", #"C:\hollow_knight-player.log"#])
        XCTAssertNil(try hk.launchPlan(cohort: cohort).screen)   // native pixels
    }

    func testAdoptionFindsANestedCohortExecutableAndCarriesItsConfig() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        try file("The Witcher 3/REDprelauncher.exe")
        try file("The Witcher 3/bin/x64/Witcher3.EXE")
        let c = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: Catalog())
        let w3 = try XCTUnwrap(c.title(id: "app-292030"))
        XCTAssertEqual(w3.source, .cohort)
        XCTAssertEqual(w3.executable, #"bin\x64\Witcher3.EXE"#)   // as on disk, matched without case
        XCTAssertEqual(w3.badge, .ready)
        let plan = try w3.launchPlan(cohort: cohort)
        XCTAssertEqual(plan.exe, #"Games\The Witcher 3\bin\x64\Witcher3.EXE"#)
        XCTAssertEqual(plan.args, [])
        XCTAssertEqual(plan.config, ["jumbo-mb": "32768"])
        XCTAssertEqual(plan.screen, "720")

        // Without the nested file the pin has no executable, and a directory is not one.
        try FileManager.default.removeItem(at: games.appendingPathComponent("The Witcher 3/bin/x64/Witcher3.EXE"))
        try FileManager.default.createDirectory(at: games.appendingPathComponent("The Witcher 3/bin/x64/witcher3.exe"),
                                                withIntermediateDirectories: true)
        let again = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: c)
        XCTAssertNil(again.title(id: "app-292030")?.executable)
        XCTAssertEqual(again.title(id: "app-292030")?.badge, .incomplete)
    }

    func testSteamReceiptOverridesTheCohortPinAndBypassesREDprelauncher() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        try file("The Witcher 3/REDprelauncher.exe")
        try file("The Witcher 3/bin/x64/witcher3.exe")
        var previous = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: Catalog(),
                                     now: Date(timeIntervalSince1970: 1))
        let played = Date(timeIntervalSince1970: 50)
        previous.update("app-292030") {
            $0.lastPlayed = played
            $0.playSeconds = 120
            $0.lastVerification = .init(date: played, files: 2459, bad: 0, unlisted: 0)
        }
        try FileManager.default.removeItem(at: games.appendingPathComponent("The Witcher 3/bin/x64"))
        try file("The Witcher 3/bin/x64_dx12/Witcher3.EXE")
        // Match the installed EXE's actual import shape, not a fake d3d12.dll import.
        try Direct3DTests.pe([("sl.interposer.dll", ["D3D12CreateDevice"])])
            .write(to: games.appendingPathComponent("The Witcher 3/bin/x64_dx12/Witcher3.EXE"))
        var r = try receipt(app: 292030, dir: "the witcher 3")
        r.name = "The Witcher 3: Wild Hunt — Remastered"
        r.buildID = 25646871
        r.executable = "redprelauncher.exe"
        r.branch = "public"
        let c = Adoption.scan(games: games, cohort: cohort, receipts: [r], previous: previous)
        let w3 = try XCTUnwrap(c.title(id: "app-292030"))
        XCTAssertEqual(w3.source, .installed)
        XCTAssertEqual(w3.name, r.name)
        XCTAssertEqual(w3.buildID, r.buildID)
        XCTAssertEqual(w3.branch, r.branch)
        XCTAssertEqual(w3.depots, [.init(depotID: 292031, manifestGID: "42")])
        XCTAssertEqual(w3.sizeBytes, r.bytes)
        XCTAssertNil(w3.checksums, "never verify a newer build against the classic pin")
        XCTAssertNil(w3.note)
        XCTAssertNil(w3.lastVerification)
        XCTAssertEqual(w3.addedAt, previous.title(id: w3.id)?.addedAt)
        XCTAssertEqual(w3.lastPlayed, played)
        XCTAssertEqual(w3.playSeconds, 120)
        XCTAssertEqual(w3.executable, #"bin\x64_dx12\Witcher3.EXE"#)
        XCTAssertEqual(w3.badge, .ready)
        XCTAssertEqual(w3.importsDirect3D12, true)
        XCTAssertEqual(w3.direct3D?.apis, [.d3d12])
        XCTAssertEqual(w3.direct3D?.evidence.first?.name, "sl.interposer.dll!D3D12CreateDevice")
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(),
                                             importsDirect3D12: w3.importsDirect3D12 == true).graphics, .vulkan)
        let plan = try w3.launchPlan(cohort: cohort)
        XCTAssertEqual(plan.exe, #"Games\The Witcher 3\bin\x64_dx12\Witcher3.EXE"#)
        XCTAssertTrue(plan.config.isEmpty, "classic's runtime keys do not belong to the new build")
        XCTAssertTrue(plan.args.isEmpty)
        XCTAssertNil(plan.screen)

        // Old receipts with no executable also bypass the launcher, and a launcher
        // alone never makes a missing game playable.
        r.executable = nil
        XCTAssertEqual(Adoption.scan(games: games, cohort: cohort, receipts: [r], previous: c)
            .title(id: w3.id)?.executable, w3.executable)
        try FileManager.default.removeItem(at: games.appendingPathComponent("The Witcher 3/bin/x64_dx12"))
        r.executable = #".\REDprelauncher.EXE"#
        let missing = Adoption.scan(games: games, cohort: cohort, receipts: [r], previous: c)
        XCTAssertEqual(missing.title(id: w3.id)?.badge, .incomplete)

        // The classic branch installed by Steam is still a Steam install, with its
        // own receipt and manifests; without a receipt it is the staged cohort pin.
        try file("The Witcher 3/bin/x64/witcher3.exe")
        r.branch = "classic"
        r.buildID = 3280809
        let classic = Adoption.scan(games: games, cohort: cohort, receipts: [r], previous: c)
        XCTAssertEqual(classic.title(id: w3.id)?.source, .installed)
        XCTAssertEqual(classic.title(id: w3.id)?.branch, "classic")
        XCTAssertEqual(classic.title(id: w3.id)?.executable, #"bin\x64\witcher3.exe"#)
        XCTAssertNil(classic.title(id: w3.id)?.checksums)
        let classicPlan = try XCTUnwrap(classic.title(id: w3.id)).launchPlan(cohort: cohort)
        XCTAssertEqual(classicPlan.config, ["jumbo-mb": "32768"], "keep the exact pinned build's launch requirements")
        XCTAssertEqual(classicPlan.screen, "720")
        XCTAssertEqual(Adoption.scan(games: games, cohort: cohort, receipts: [], previous: classic)
            .title(id: w3.id)?.source, .cohort)
    }

    func testAdoptionClassifiesInstalledFoundAndIncompleteFolders() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        try file("GMod DS/srcds.exe")
        try file("GMod DS/srcds_win64.exe")
        try file("My Game/tool.exe")
        try file("My Game/my_game.exe")
        try file("Empty/readme.txt")
        try file(".staging/x.exe")
        let c = Adoption.scan(games: games, cohort: cohort, receipts: [try receipt(app: 4020, dir: "GMod DS")], previous: Catalog())
        XCTAssertEqual(c.titles.map(\.name), ["Empty", "My Game", "Server 4020"])
        let byName = Dictionary(uniqueKeysWithValues: c.titles.map { ($0.name, $0) })
        XCTAssertEqual(byName["Server 4020"]?.source, .installed)
        XCTAssertEqual(byName["Server 4020"]?.id, "app-4020")
        XCTAssertEqual(byName["Server 4020"]?.sizeBytes, 1234)
        XCTAssertEqual(byName["Server 4020"]?.executable, "srcds.exe")
        XCTAssertEqual(byName["Server 4020"]?.badge, .ready)
        XCTAssertEqual(byName["My Game"]?.executable, "my_game.exe")   // named like the folder
        XCTAssertEqual(byName["My Game"]?.badge, .ready, "a copied-in game reads Ready like any other")
        XCTAssertEqual(byName["My Game"]?.sizeBytes, 2)
        XCTAssertEqual(byName["Empty"]?.badge, .incomplete)
        XCTAssertFalse(byName["Empty"]!.canPlay)
        XCTAssertThrowsError(try byName["Empty"]!.launchPlan(cohort: cohort))
        XCTAssertEqual(try byName["Server 4020"]?.launchPlan(cohort: cohort).args, [])
        XCTAssertEqual(try byName["My Game"]?.launchPlan(cohort: cohort),
                       LaunchPlan(exe: #"Games\My Game\my_game.exe"#, args: []))
    }

    func testAdoptionFindsANestedExecutable() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        // An install record from before the launch executable was kept: a search below the folder.
        try file("KingdomComeDeliverance/Bin/Win64/KingdomCome.exe")
        try file("KingdomComeDeliverance/Bin/Win64/CrashReporter.exe")
        try file("KingdomComeDeliverance/Tools/Editor.exe")
        try file("KingdomComeDeliverance/_CommonRedist/vcredist/vc_redist.x64.exe")
        // A record with Steam's launch executable: that one, matched without case.
        try file("Other/Game/Bin/Launcher.exe")
        try file("Other/Game/Bin/Real.exe")
        var withExe = try receipt(app: 500, dir: "Other")
        withExe.executable = "game/bin/real.exe"
        // A copied-in folder: the 64-bit one over a shallower one.
        try file("Copied/bin32/a.exe")
        try file("Copied/bin/x64/b.exe")
        let c = Adoption.scan(games: games, cohort: cohort,
                              receipts: [try receipt(app: 379430, dir: "KingdomComeDeliverance"), withExe], previous: Catalog())
        XCTAssertEqual(c.title(id: "app-379430")?.executable, #"Bin\Win64\KingdomCome.exe"#)
        XCTAssertEqual(c.title(id: "app-379430")?.badge, .ready)
        XCTAssertEqual(c.title(id: "app-500")?.executable, #"Game\Bin\Real.exe"#)
        XCTAssertEqual(c.title(id: "dir-copied")?.executable, #"bin\x64\b.exe"#)
    }

    func testAdoptionPicksAnUnrealGamesShippingExecutableOverItsBootstrap() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        try file("EnGarde/EnGarde.exe")
        try file("EnGarde/EnGarde/Binaries/Win64/EnGarde-Win64-Shipping.exe")
        try file("Plain/Plain.exe")
        try file("Plain/Plain/Binaries/Win64/Other-Win64-Shipping.exe")
        let c = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: Catalog())
        XCTAssertEqual(c.titles.first { $0.installDir == "EnGarde" }?.executable, "EnGarde\\Binaries\\Win64\\EnGarde-Win64-Shipping.exe")
        XCTAssertEqual(c.titles.first { $0.installDir == "Plain" }?.executable, "Plain.exe", "only the project's own shipping executable")
    }

    func testAdoptionKeepsSettingsAndDropsVanishedTitles() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        try file("Hollow Knight/hollow_knight.exe")
        try file("Other/other.exe")
        var first = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: Catalog(),
                                  now: Date(timeIntervalSince1970: 1))
        let played = Date(timeIntervalSince1970: 50)
        first.update("app-367520") {
            $0.lastPlayed = played
            $0.playSeconds = 3600
            $0.lastVerification = .init(date: played, files: 1785, bad: 3, unlisted: 0)
        }
        try FileManager.default.removeItem(at: games.appendingPathComponent("Other"))
        let second = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: first,
                                   now: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(second.titles.map(\.id), ["app-367520"])
        let hk = second.titles[0]
        XCTAssertEqual(hk.addedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(hk.lastPlayed, played)
        XCTAssertEqual(hk.playSeconds, 3600)
        XCTAssertEqual(hk.badge, .needsRepair)
    }

    func testStoreRoundTripsAndSetsAsideAnUnreadableFile() throws {
        let store = CatalogStore(url: root.appendingPathComponent("state/catalog.json"))
        XCTAssertEqual(store.load(), Catalog())
        try file("Hollow Knight/hollow_knight.exe")
        let c = Adoption.scan(games: games, cohort: try Cohort.load(directory: titlesDir), receipts: [], previous: Catalog(),
                              now: Date(timeIntervalSince1970: 1_790_000_000))
        try store.save(c)
        XCTAssertEqual(store.load(), c)
        try Data("{not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), Catalog())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path + ".unreadable"))
    }

    func testReceiptsAreReadFromTheInstallsDirectory() throws {
        let paths = PlayportPaths.container(home: root)
        XCTAssertEqual(paths.catalog.path, root.appendingPathComponent("Library/Application Support/Playport/catalog.json").path)
        XCTAssertEqual(paths.games.path, root.appendingPathComponent("Documents/prefix/drive_c/Games").path)
        try FileManager.default.createDirectory(at: paths.layout.installsDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(try receipt(app: 4020, dir: "GMod DS"))
            .write(to: paths.layout.receiptFile(appID: 4020))
        try Data("junk".utf8).write(to: paths.layout.installsDir.appendingPathComponent("bad.json"))
        XCTAssertEqual(Adoption.receipts(in: paths.layout.installsDir).map(\.appID), [4020])
    }

    func testVerifyCountsBadAndUnlistedFiles() async throws {
        try file("T/t.exe", "game")
        try file("T/data.bin", "data")
        try file("T/extra.txt", "extra")
        let sums = [("t.exe", "game"), ("data.bin", "DATA")].map { name, content in
            SHA256Stream.hash(Array(content.utf8)).map { String(format: "%02x", $0) }.joined() + "  " + name
        }.joined(separator: "\n") + "\n"
        let dir = root.appendingPathComponent("cohort")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(sums.utf8).write(to: dir.appendingPathComponent("t.sha256"))
        let cohort = Cohort(titles: [], directory: dir)
        var title = Adoption.scan(games: games, cohort: cohort, receipts: [], previous: Catalog()).titles[0]
        await XCTAssertThrowsErrorAsync(try await TitleVerifier.verify(title, games: games, cohort: cohort))
        title.checksums = "t.sha256"
        let (v, report) = try await TitleVerifier.verify(title, games: games, cohort: cohort)
        XCTAssertEqual(v.files, 2)
        XCTAssertEqual(v.bad, 1)
        XCTAssertEqual(v.unlisted, 1)
        XCTAssertFalse(v.ok)
        XCTAssertEqual(report.bad, ["data.bin"])
    }

    func testByteCountUsesDecimalUnits() {
        XCTAssertEqual(ByteCount.format(512), "512 B")
        XCTAssertEqual(ByteCount.format(5_231_995_691), "5.23 GB")
        XCTAssertEqual(ByteCount.format(243_438_208), "243 MB")
        XCTAssertEqual(ByteCount.format(12_500), "12.5 KB")
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ body: @autoclosure () async throws -> T, file: StaticString = #filePath,
                                          line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("no error thrown", file: file, line: line)
    } catch {}
}

final class LaunchSettingsTests: XCTestCase {
    func testAGameWinsOverGlobalWhichWinsOverTheDefaults() {
        let global = LaunchSettings(screen: "1080", frameLimit: 60)
        let game = LaunchSettings(screen: "540", frameLimit: 30)
        XCTAssertEqual(LaunchSettings.resolve(game: game, global: global),
                       .init(screen: "540", frameLimit: 30))
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(), global: global),
                       .init(screen: "1080", frameLimit: 60))
        // A cohort title's screen no longer comes in (decision 0034): nothing set is 720p.
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings()),
                       .init(screen: "720", frameLimit: 60))
    }

    func testNothingSetMeans720At60() {
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings()),
                       .init(screen: "720", frameLimit: 60))
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(), global: LaunchSettings()),
                       .init(screen: "720", frameLimit: 60))
        // Native and no limit are a choice, globally or for one game.
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(screen: "native", frameLimit: 0)), .init(screen: "native", frameLimit: 0))
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(screen: "native", frameLimit: 0), global: LaunchSettings()), .init(screen: "native", frameLimit: 0))
        // A game's explicit "no limit" wins over a global limit.
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(frameLimit: 0), global: LaunchSettings(frameLimit: 30)).frameLimit, 0)
    }

    func testInvalidValuesAreSkipped() {
        let game = LaunchSettings(screen: "huge", frameLimit: -1)
        let e = LaunchSettings.resolve(game: game, global: LaunchSettings(screen: "900"))
        XCTAssertEqual(e, .init(screen: "900", frameLimit: 60))
    }

    func testGraphicsBackendIsInheritedLikeTheOtherSettings() {
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings()).graphics, .dxmt)
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(graphics: .vulkan)).graphics, .vulkan)
        // A game's own choice wins either way.
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(graphics: .dxmt), global: LaunchSettings(graphics: .vulkan)).graphics, .dxmt)
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(graphics: .vulkan), global: LaunchSettings()).graphics, .vulkan)
        XCTAssertFalse(LaunchSettings(graphics: .dxmt).isEmpty)
        XCTAssertNil(GraphicsBackend.dxmt.runtimeOverlay)
        XCTAssertEqual(GraphicsBackend.vulkan.runtimeOverlay, "vulkan")
        XCTAssertEqual(GraphicsBackend.dxmt.runtimeEnvironment, [:])
        // DXVK picks its own compiler thread count (decision 0024).
        XCTAssertEqual(GraphicsBackend.vulkan.runtimeEnvironment, [:])
    }

    func testASteamGameRunsWithItsAppIDAsSteamsGameID() {
        // As Steam sets them for a game it starts, and Proton passes them on to Wine.
        XCTAssertEqual(SteamGameID.environment(appID: 367520),
                       ["SteamAppId": "367520", "SteamGameId": "367520", "STEAM_COMPAT_APP_ID": "367520"])
        XCTAssertEqual(SteamGameID.environment(appID: nil), [:], "a title with no Steam app ID gets none")
        // The backend's variables win over Steam's.
        let env = SteamGameID.launchEnvironment(appID: 367520, backend: ["DXVK_CONFIG": "x", "SteamAppId": "1"])
        XCTAssertEqual(env, ["SteamAppId": "1", "SteamGameId": "367520", "STEAM_COMPAT_APP_ID": "367520", "DXVK_CONFIG": "x"])
        XCTAssertEqual(SteamGameID.launchEnvironment(appID: nil, backend: ["A": "b"]), ["A": "b"])
    }

    func testSteamAPIIsTheEmulatorUnlessTheGameSaysOtherwise() throws {
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings()).steamAPI, .emulated)
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(steamAPI: .original)).steamAPI, .emulated, "per game only")
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(steamAPI: .original), global: LaunchSettings()).steamAPI, .original)
        XCTAssertFalse(LaunchSettings(steamAPI: .emulated).isEmpty)
        // As `pp ui --settings` and the game's page save it; an unknown mode inherits.
        let s = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"steamAPI":"original"}"#.utf8))
        XCTAssertEqual(s.steamAPI, .original)
        let unknown = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"steamAPI":"proxy","frameLimit":30}"#.utf8))
        XCTAssertEqual(unknown, LaunchSettings(frameLimit: 30))
    }

    func testCloudSyncIsOnUnlessTheGameTurnsItOff() throws {
        XCTAssertTrue(LaunchSettings().isEmpty)
        XCTAssertFalse(LaunchSettings(cloudSync: false).isEmpty)
        let s = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"cloudSync":false}"#.utf8))
        XCTAssertEqual(s.cloudSync, false)
        XCTAssertNil(try JSONDecoder().decode(LaunchSettings.self, from: Data("{}".utf8)).cloudSync)
    }

    func testArgumentsSplitLikeACommandLineAndArePerGame() {
        XCTAssertEqual(LaunchSettings.splitArguments(" -DX12  -window-mode \"exclusive full\" \"\" "),
                       ["-DX12", "-window-mode", "exclusive full", ""])
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(arguments: "-force-d3d12"), global: LaunchSettings()).arguments, ["-force-d3d12"])
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: LaunchSettings(arguments: "-x")).arguments, [])
        XCTAssertTrue(LaunchSettings(arguments: "   ").isEmpty)
    }

    func testAGraphicsBackendThisBuildDoesNotKnowInheritsAndKeepsTheRest() throws {
        let s = try JSONDecoder().decode(LaunchSettings.self,
                                         from: Data(#"{"screen":"720","graphics":"metal5","frameLimit":30}"#.utf8))
        XCTAssertEqual(s, LaunchSettings(screen: "720", frameLimit: 30))
        let round = try JSONDecoder().decode(LaunchSettings.self,
                                             from: JSONEncoder().encode(LaunchSettings(graphics: .vulkan)))
        XCTAssertEqual(round.graphics, .vulkan)
    }

    func testSettingsSavedWithEnvironmentVariablesStillLoad() throws {
        // Saved before a game's page lost its environment variables: those are dropped, the rest kept.
        let s = try JSONDecoder().decode(LaunchSettings.self,
                                         from: Data(#"{"screen":"720","environment":[{"name":"A","value":"1"}]}"#.utf8))
        XCTAssertEqual(s, LaunchSettings(screen: "720"))
        XCTAssertTrue(try JSONDecoder().decode(LaunchSettings.self,
                                               from: Data(#"{"environment":[{"name":"A","value":"1"}]}"#.utf8)).isEmpty)
    }

    func testLimitsDivideThePanelsRate() {
        XCTAssertEqual(LaunchSettings.frameLimits(maxRate: 120), [30, 40, 60])
        XCTAssertEqual(LaunchSettings.frameLimits(maxRate: 60), [30])
    }

    func testOrderingIsPerGameAndRoundTrips() throws {
        let s = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"ordering":{"vector":true}}"#.utf8))
        XCTAssertEqual(s.ordering, MemoryOrdering(vector: true))
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(LaunchSettings(ordering: MemoryOrdering()).isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(s)), s)
        XCTAssertEqual(LaunchSettings.resolve(game: s, global: LaunchSettings()).ordering, s.ordering)
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: s).ordering, MemoryOrdering(),
                       "per game only")
        XCTAssertEqual(try JSONDecoder().decode(LaunchSettings.self, from: Data("{}".utf8)).ordering, MemoryOrdering())
    }
}

final class FEXProfileTests: XCTestCase {
    func testWildcardMatchesAsFEXDoes() {
        XCTAssertTrue(FEXProfile.matches("setup*", "setup.exe"))
        XCTAssertTrue(FEXProfile.matches("setup*", "setup"))
        XCTAssertTrue(FEXProfile.matches("*.exe", "witcher3.exe"))
        XCTAssertTrue(FEXProfile.matches("a*b*c", "aXbYYc"))
        XCTAssertFalse(FEXProfile.matches("setup*", "Setup.exe"), "case-sensitive")
        XCTAssertFalse(FEXProfile.matches("setup*", "witcher3.exe"))
        XCTAssertFalse(FEXProfile.matches("a?c", "abc"), "only * is special")
        XCTAssertEqual(FEXProfile.baseName(#"C:\Games\The Witcher 3\bin\x64\witcher3.exe"#), "witcher3.exe")
        XCTAssertEqual(FEXProfile.baseName("/a/b.exe"), "b.exe")
        XCTAssertEqual(FEXProfile.baseName("b.exe"), "b.exe")
    }

    func testProtonsDefaultsAreScalarOrderingWithHalfBarriers() {
        let l = FEXProfile.launch(appID: 367520, exe: #"C:\Games\Hollow Knight\hollow_knight.exe"#, ordering: MemoryOrdering())
        XCTAssertEqual(l.ordering, [.tso: true, .halfBarrier: true, .vector: false, .memcpySet: false])
        XCTAssertEqual(l.environment, ["FEX_TSOENABLED": "1", "FEX_HALFBARRIERTSOENABLED": "1",
                                       "FEX_VECTORTSOENABLED": "0", "FEX_MEMCPYSETTSOENABLED": "0",
                                       "FEX_X87REDUCEDPRECISION": "1", "FEX_MAXINST": "500"])
        XCTAssertNil(l.override)
        XCTAssertEqual(l.summary, "tso=1 halfbar=1 vector=0 memcpyset=0")
        // A title with no Steam app ID gets the same.
        XCTAssertEqual(FEXProfile.launch(appID: nil, exe: "game.exe", ordering: MemoryOrdering()).environment, l.environment)
    }

    func testTheGamesPageOverridesEachSwitch() {
        let l = FEXProfile.launch(appID: 367520, exe: "hollow_knight.exe", ordering: MemoryOrdering(vector: true, halfBarrier: false))
        XCTAssertEqual(l.environment["FEX_VECTORTSOENABLED"], "1")
        XCTAssertEqual(l.environment["FEX_HALFBARRIERTSOENABLED"], "0")
        XCTAssertEqual(l.environment["FEX_TSOENABLED"], "1")
        XCTAssertEqual(l.chosen, [.vector, .halfBarrier])
        XCTAssertEqual(l.summary, "tso=1 halfbar=0* vector=1* memcpyset=0")
    }

    func testAGamesProfileAppliesToTheExecutablesItNames() {
        // Proton's Witcher 3 entry is for its setup programs, not the game.
        let game = FEXProfile.launch(appID: 292030, exe: #"C:\Games\The Witcher 3\bin\x64\witcher3.exe"#, ordering: MemoryOrdering())
        XCTAssertNil(game.override)
        XCTAssertEqual(game.environment["FEX_X87REDUCEDPRECISION"], "1")   // Proton's global value
        let setup = FEXProfile.launch(appID: 292030, exe: #"C:\Games\The Witcher 3\setup.exe"#, ordering: MemoryOrdering())
        XCTAssertEqual(setup.override?.pattern, "setup*")
        XCTAssertEqual(setup.environment["FEX_X87REDUCEDPRECISION"], "0")
        XCTAssertEqual(setup.ordering, game.ordering)
        // Only the keys this build honours are passed on, with Proton's global block size.
        XCTAssertNil(game.environment["FEX_PROFILESTATS"])
        XCTAssertEqual(game.environment["FEX_MAXINST"], "500")
        XCTAssertTrue(FEXProfile.honoured.isSuperset(of: FEXProfile.protonApps.values.flatMap { $0.flatMap(\.config.keys) }))
    }

    func testX87RunsAt64BitsAsProtonsGlobalValue() {
        // Proton's global X87ReducedPrecision=1 (decision 0048), for every game and a title without an app ID.
        let exe = #"C:\Games\Portal 2\portal2.exe"#
        let p2 = FEXProfile.launch(appID: 620, exe: exe, ordering: MemoryOrdering())
        XCTAssertEqual(p2.environment["FEX_X87REDUCEDPRECISION"], "1")
        XCTAssertTrue(p2.x87Reduced)
        XCTAssertFalse(p2.x87Chosen)
        XCTAssertEqual(FEXProfile.launch(appID: 367520, exe: "hollow_knight.exe", ordering: MemoryOrdering())
                       .environment["FEX_X87REDUCEDPRECISION"], "1")
        XCTAssertTrue(FEXProfile.defaultX87Reduced(appID: nil, exe: "game.exe"))
        // A profile entry goes over it: Proton's Witcher 3 setup programs keep 80 bits.
        XCTAssertFalse(FEXProfile.defaultX87Reduced(appID: 292030, exe: "setup.exe"))
        // The game's page overrides either way.
        let full = FEXProfile.launch(appID: 620, exe: exe, ordering: MemoryOrdering(), x87Reduced: false)
        XCTAssertEqual(full.environment["FEX_X87REDUCEDPRECISION"], "0")
        XCTAssertFalse(full.x87Reduced)
        XCTAssertTrue(full.x87Chosen)
        XCTAssertEqual(FEXProfile.launch(appID: 292030, exe: "setup.exe", ordering: MemoryOrdering(),
                                         x87Reduced: true).environment["FEX_X87REDUCEDPRECISION"], "1")
        // Per game only, saved and resolved like the block size.
        let s = try! JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"x87Reduced":false}"#.utf8))
        XCTAssertEqual(s.x87Reduced, false)
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(LaunchSettings.resolve(game: s, global: LaunchSettings()).x87Reduced, false)
        XCTAssertNil(LaunchSettings.resolve(game: nil, global: s).x87Reduced)
        XCTAssertNil(try! JSONDecoder().decode(LaunchSettings.self, from: Data("{}".utf8)).x87Reduced)
    }

    func testTheGamesPageSetsTheBlockSize() {
        let exe = #"C:\Games\Hollow Knight\hollow_knight.exe"#
        let none = FEXProfile.launch(appID: 367520, exe: exe, ordering: MemoryOrdering())
        XCTAssertEqual(none.environment["FEX_MAXINST"], "500")   // Proton's global value (decision 0055)
        XCTAssertEqual(none.maxInst, 500)
        XCTAssertFalse(none.maxInstChosen)
        XCTAssertEqual(FEXProfile.defaultBlockSize(appID: nil, exe: "game.exe"), 500)
        let large = FEXProfile.launch(appID: 367520, exe: exe, ordering: MemoryOrdering(), maxInst: 5000)
        XCTAssertEqual(large.environment["FEX_MAXINST"], "5000")
        XCTAssertEqual(large.maxInst, 5000)
        XCTAssertTrue(large.maxInstChosen)
        XCTAssertEqual(large.environment.filter { $0.key != "FEX_MAXINST" }, none.environment.filter { $0.key != "FEX_MAXINST" })
        // An invalid choice falls back to the default.
        XCTAssertEqual(FEXProfile.launch(appID: 367520, exe: exe, ordering: MemoryOrdering(), maxInst: 0).environment["FEX_MAXINST"], "500")
        // Per game only, saved and resolved like the ordering.
        let s = try! JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"maxInst":1000}"#.utf8))
        XCTAssertEqual(s.maxInst, 1000)
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(LaunchSettings.resolve(game: s, global: LaunchSettings()).maxInst, 1000)
        XCTAssertNil(LaunchSettings.resolve(game: nil, global: s).maxInst)
        XCTAssertNil(LaunchSettings.resolve(game: LaunchSettings(maxInst: -3), global: LaunchSettings()).maxInst)
        XCTAssertNil(try! JSONDecoder().decode(LaunchSettings.self, from: Data("{}".utf8)).maxInst)

        // Runtime keys: the game's own only, over the title's cohort keys; a bad line is not used.
        let keys = try! JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"runtime":"vram-mb=1024 inproc-sync=1 vram-mb=768"}"#.utf8))
        XCTAssertFalse(keys.isEmpty)
        let on = LaunchSettings.resolve(game: keys, global: LaunchSettings())
        XCTAssertEqual(on.runtime, ["vram-mb": "768", "inproc-sync": "1"])
        XCTAssertEqual(on.config(over: ["jumbo-mb": "32768", "vram-mb": "2048"]),
                       ["jumbo-mb": "32768", "vram-mb": "768", "inproc-sync": "1"])
        XCTAssertEqual(LaunchSettings.resolve(game: nil, global: keys).runtime, [:])
        XCTAssertNil(LaunchSettings.runtimeKeys("vram-mb"))
        XCTAssertNil(LaunchSettings.runtimeKeys("a b=1"))
        XCTAssertEqual(LaunchSettings.resolve(game: LaunchSettings(runtime: "oops"), global: LaunchSettings()).runtime, [:])
        XCTAssertEqual(LaunchSettings.runtimeKeys(""), [:])
    }

    func testHostFeaturesAddLRCPC2ToThePlayersOwn() {
        XCTAssertEqual(FEXProfile.hostFeatures(player: nil, lrcpc2: true), "enablelrcpc2")
        XCTAssertEqual(FEXProfile.hostFeatures(player: "disableafp", lrcpc2: true), "disableafp,enablelrcpc2")
        XCTAssertEqual(FEXProfile.hostFeatures(player: "disableafp, disablelrcpc2", lrcpc2: true), "disableafp, disablelrcpc2")
        XCTAssertEqual(FEXProfile.hostFeatures(player: "ENABLELRCPC2", lrcpc2: true), "ENABLELRCPC2")
        XCTAssertEqual(FEXProfile.hostFeatures(player: "4096", lrcpc2: true), "4096", "a bitmask is left alone")
        XCTAssertNil(FEXProfile.hostFeatures(player: nil, lrcpc2: false))
        XCTAssertEqual(FEXProfile.hostFeatures(player: "disableafp", lrcpc2: false), "disableafp")
    }
}

final class MemoryNeedTests: XCTestCase {
    private func title(app: UInt32?, dir: String, source: InstalledTitle.Source) -> InstalledTitle {
        InstalledTitle(id: app.map { "app-\($0)" } ?? "dir-\(dir.lowercased())", appID: app, name: dir, installDir: dir,
                       executable: "game.exe", depots: [], source: source, addedAt: Date(timeIntervalSince1970: 0))
    }

    /// A tested title's need is its measured footprint, however it was installed.
    func testATestedTitleNeedsWhatItReachedOnThePhone() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        for source in [InstalledTitle.Source.cohort, .installed] {
            let hk = MemoryNeed.of(title(app: 367520, dir: "Hollow Knight", source: source), cohort: cohort)
            XCTAssertEqual(hk, MemoryNeed(minimumMB: 3200, recommendedMB: 4000, measured: true))
        }
        // Found by its folder, with no app ID.
        XCTAssertEqual(MemoryNeed.of(title(app: nil, dir: "the witcher 3", source: .found), cohort: cohort).minimumMB, 6246)
        // Every cohort title is measured.
        XCTAssertTrue(cohort.titles.allSatisfy { ($0.memoryMB ?? 0) > MemoryNeed.runtimeFloorMB })
    }

    func testAnUntestedTitleNeedsTheRuntimeFloor() {
        let need = MemoryNeed.of(title(app: 70, dir: "Half-Life", source: .installed), cohort: Cohort(titles: []))
        XCTAssertEqual(need, MemoryNeed(minimumMB: 2048, recommendedMB: 4096, measured: false))
    }

    /// The reference phone's 8 GB plays every cohort title; a re-signed IPA's 3.3 GB
    /// warns for Hollow Knight and refuses The Witcher 3; a limit not read never refuses.
    func testVerdicts() throws {
        let cohort = try Cohort.load(directory: titlesDir)
        let hk = MemoryNeed.of(title(app: 367520, dir: "Hollow Knight", source: .cohort), cohort: cohort)
        let w3 = MemoryNeed.of(title(app: 292030, dir: "The Witcher 3", source: .cohort), cohort: cohort)
        XCTAssertEqual(hk.verdict(limitMB: 8192), .fits)
        XCTAssertEqual(w3.verdict(limitMB: 8192), .fits)
        XCTAssertEqual(hk.verdict(limitMB: 3379), .tight)
        XCTAssertEqual(w3.verdict(limitMB: 3379), .tooLow)
        XCTAssertEqual(hk.verdict(limitMB: 2048), .tooLow)
        XCTAssertEqual(hk.verdict(limitMB: 3200), .tight)
        XCTAssertEqual(hk.verdict(limitMB: 3199), .tooLow)
        XCTAssertEqual(hk.verdict(limitMB: 4000), .fits)
        XCTAssertEqual(hk.verdict(limitMB: nil), .fits)
        XCTAssertEqual(hk.verdict(limitMB: 0), .fits)
    }

    func testTheRefusalLineRoundTrips() throws {
        let line = MemoryNeed.refusalLine(limitMB: 2048, needMB: 3200)
        XCTAssertEqual(line, "launch=refused memory=2048 need=3200")
        let parsed = try XCTUnwrap(MemoryNeed.parseRefusal(line))
        XCTAssertEqual(parsed.limitMB, 2048)
        XCTAssertEqual(parsed.needMB, 3200)
        XCTAssertNil(MemoryNeed.parseRefusal("launch=refused graphics=vulkan reason=not-in-this-build"))
        XCTAssertNil(MemoryNeed.parseRefusal("exit=0x00000000 after_s=12"))
    }

    func testFormat() {
        XCTAssertEqual(MemoryNeed.format(mb: 8192), "8.0 GB")
        XCTAssertEqual(MemoryNeed.format(mb: 3379), "3.3 GB")
        XCTAssertEqual(MemoryNeed.format(mb: 896), "896 MB")
    }
}

final class JitPoolTests: XCTestCase {
    func testEveryPlayGetsTheSamePool() {
        // One size for every Play (decision 0036), whatever the limit.
        XCTAssertEqual(JitPool.sizeMB(limitMB: 8192), 512)       // the reference phone with Game Mode
        XCTAssertEqual(JitPool.sizeMB(limitMB: 6144), 512)       // before Game Mode raises it
        XCTAssertEqual(JitPool.sizeMB(limitMB: 3379), 512)       // signed without the entitlement
        XCTAssertEqual(JitPool.sizeMB(limitMB: nil), 512)
        XCTAssertEqual(JitPool.sizeMB(limitMB: 0), 512)
        for limit in stride(from: 1024, through: 16384, by: 7) {
            XCTAssertEqual(JitPool.sizeMB(limitMB: limit), JitPool.minimumMB)
        }
        XCTAssertLessThanOrEqual(JitPool.minimumMB, JitPool.maximumMB)   // it fits the executable's reservation
    }

    func testTheLineCarriesEveryFieldAndWhatRanOut() {
        let mib: UInt64 = 1 << 20
        var use = JitPool.Use(size: 896 * mib, head: 153 * mib - 4096, headLive: 150 * mib, tail: 144 * mib,
                              tailLive: 128 * mib, aliasLive: 5, aliasSlots: 6, aliasCap: 4096, images: 50)
        XCTAssertEqual(use.line, "pool: size_mb=896 head_mb=153 head_live_mb=150 head_free_mb=0 tail_mb=144 "
                       + "tail_live_mb=128 room_mb=599 alias=5 alias_slots=6 alias_cap=4096 images=50 children=0 "
                       + "children_mb=0 head_exhausted=0 tail_refused=0 tail_fatal=0 alias_full=0 exhausted=none")
        XCTAssertNil(use.exhaustion)
        use.tailRefused = 3   // FEX asks again for half: not exhausted
        XCTAssertNil(use.exhaustion)
        use.tailFatal = 1
        XCTAssertEqual(use.exhaustion, .tail)
        use.headExhausted = 1
        XCTAssertEqual(use.exhaustion, .head)
        XCTAssertTrue(use.line.hasSuffix(" exhausted=head"))
        XCTAssertEqual(JitPool.Use(size: 1, head: 0, tail: 0, aliasFull: 1).exhaustion, .alias)
        XCTAssertEqual(JitPool.Use(size: 10 * mib, head: 8 * mib, tail: 4 * mib).room, 0)
    }

    func testANewLineOnlyWhenTheUseMoved() {
        let mib: UInt64 = 1 << 20
        let a = JitPool.Use(size: 896 * mib, head: 100 * mib, tail: 16 * mib, aliasSlots: 10)
        XCTAssertTrue(a.worthLogging(after: nil))
        var b = a
        b.head += 4 * mib
        b.aliasSlots += 63
        XCTAssertFalse(b.worthLogging(after: a))
        b.head += 4 * mib
        XCTAssertTrue(b.worthLogging(after: a))
        var c = a
        c.childCopies = 1
        XCTAssertTrue(c.worthLogging(after: a))
        var d = a
        d.tailRefused = 1
        XCTAssertTrue(d.worthLogging(after: a))
    }

    func testTheResultLineNamesWhatRanOut() {
        let line = JitPool.resultField(.tail) + " exit=0xc0000005 after_s=40"
        XCTAssertEqual(line, "pool=exhausted:tail exit=0xc0000005 after_s=40")
        XCTAssertEqual(JitPool.parseExhaustion(line), .tail)
        XCTAssertNil(JitPool.parseExhaustion("exit=0x00000000 after_s=40"))
    }
}

final class RuntimeLimitsTests: XCTestCase {
    func testTheLineCarriesEveryCount() {
        let none = RuntimeLimits.Counts()
        XCTAssertEqual(none.line, "limits: wx_dropped=0 x18_images=0 x18_sites=0 split_lock=0")
        let some = RuntimeLimits.Counts(wxDropped: 1, x18Images: 2, x18Sites: 30, splitLock: 4)
        XCTAssertEqual(some.line, "limits: wx_dropped=1 x18_images=2 x18_sites=30 split_lock=4")
    }

    func testANewLineOnlyWhenACountMoved() {
        let a = RuntimeLimits.Counts()
        XCTAssertTrue(a.worthLogging(after: nil))
        XCTAssertFalse(a.worthLogging(after: a))
        var b = a
        b.splitLock = 1
        XCTAssertTrue(b.worthLogging(after: a))
    }
}

final class FexBandTests: XCTestCase {
    func testTheLineCarriesEveryField() {
        let u = FexBand.Use(size: 16 << 30, used: (5 << 30) + 1, peak: 6 << 30, views: 300,
                            largestFree: (4 << 30) + 5, spanSlots: 256, spans: 120, callret: 54, l1: 54,
                            other: 3 << 20, refused: 0)
        XCTAssertEqual(u.line, "band: size_mb=16384 used_mb=5121 peak_mb=6144 free_mb=11263 largest_free_mb=4096 "
                             + "span_slots=256 threads=54 spans=120 l1=54 other_mb=3 views=300 refused=0")
    }

    func testANewLineWhenTheUseMovedOrARequestWasRefused() {
        let a = FexBand.Use(size: 16 << 30, used: 1 << 30, callret: 10)
        XCTAssertTrue(a.worthLogging(after: nil))
        XCTAssertFalse(a.worthLogging(after: a))
        var b = a
        b.used += 255 << 20
        b.callret += 3
        XCTAssertFalse(b.worthLogging(after: a))
        b.used += 1 << 20
        XCTAssertTrue(b.worthLogging(after: a))
        var c = a
        c.callret += 4
        XCTAssertTrue(c.worthLogging(after: a))
        var d = a
        d.refused = 1
        XCTAssertTrue(d.worthLogging(after: a))
    }
}

final class FocusMoveTests: XCTestCase {
    // Home's layout: a wide card, two small cards beside it, a row of tiles under both.
    private let home: [String: CGRect] = [
        "hero": CGRect(x: 0, y: 0, width: 500, height: 170),
        "download": CGRect(x: 514, y: 0, width: 250, height: 80),
        "next": CGRect(x: 514, y: 90, width: 250, height: 80),
        "t0": CGRect(x: 0, y: 200, width: 140, height: 70),
        "t1": CGRect(x: 152, y: 200, width: 140, height: 70),
        "t2": CGRect(x: 304, y: 200, width: 140, height: 70),
        "t3": CGRect(x: 456, y: 200, width: 140, height: 70),
        "t4": CGRect(x: 608, y: 200, width: 140, height: 70),
    ]

    private func move(_ id: String, _ d: FocusDirection) -> String? { FocusMove.next(from: home[id]!, d, among: home) }

    func testARowMovesSideways() {
        XCTAssertEqual(move("t1", .right), "t2")
        XCTAssertEqual(move("t1", .left), "t0")
        XCTAssertNil(move("t0", .left))
        XCTAssertNil(move("t4", .right))
    }

    func testDownFromAWideCardTakesTheFirstTileUnderIt() {
        XCTAssertEqual(move("hero", .down), "t0")
    }

    func testDownInAGridKeepsTheColumn() {
        let grid: [String: CGRect] = [
            "a0": CGRect(x: 0, y: 0, width: 100, height: 60), "a1": CGRect(x: 110, y: 0, width: 100, height: 60),
            "b0": CGRect(x: 0, y: 70, width: 100, height: 60), "b1": CGRect(x: 110, y: 70, width: 100, height: 60),
        ]
        XCTAssertEqual(FocusMove.next(from: grid["a1"]!, .down, among: grid), "b1")
        XCTAssertEqual(FocusMove.next(from: grid["b0"]!, .up, among: grid), "a0")
    }

    func testUpFromATileTakesTheCardAboveIt() {
        XCTAssertEqual(move("t0", .up), "hero")
        XCTAssertEqual(move("t4", .up), "next")
        XCTAssertEqual(move("next", .up), "download")
    }

    func testSidewaysIntoAColumnOfCards() {
        XCTAssertEqual(move("download", .left), "hero")
        XCTAssertEqual(move("next", .down), "t4")
    }

    func testTheFirstItemIsTopLeft() {
        XCTAssertEqual(FocusMove.first(among: home), "hero")
        XCTAssertNil(FocusMove.first(among: [:]))
    }
}

final class LibraryListTests: XCTestCase {
    private func title(_ name: String, app: UInt32?, played: TimeInterval? = nil, size: UInt64? = nil) -> InstalledTitle {
        var t = InstalledTitle(id: app.map { "app-\($0)" } ?? "dir-\(name.lowercased())", appID: app, name: name, installDir: name,
                               executable: "game.exe", depots: [], source: app == nil ? .found : .installed,
                               addedAt: Date(timeIntervalSince1970: 0))
        t.lastPlayed = played.map { Date(timeIntervalSince1970: $0) }
        t.sizeBytes = size
        return t
    }

    private let owned = [
        LibraryList.Owned(appID: 367520, name: "Hollow Knight", installSize: 9_000),
        LibraryList.Owned(appID: 504230, name: "Celeste", installSize: 1_200),
        LibraryList.Owned(appID: 588650, name: "Dead Cells", installSize: 1_800),
    ]

    private var entries: [LibraryEntry] {
        LibraryList.entries(titles: [title("Hollow Knight", app: 367520, played: 200, size: 8_000),
                                     title("My Game", app: nil, played: 100)],
                            owned: owned)
    }

    func testAnInstalledOwnedGameIsOneTile() {
        let e = entries
        XCTAssertEqual(e.map(\.id), ["app-367520", "dir-my game", "app-504230", "app-588650"])
        XCTAssertEqual(e[0].installed, true)
        XCTAssertEqual(e[0].owned, true)
        XCTAssertEqual(e[0].sizeBytes, 8_000, "the size on the phone wins over Steam's")
        XCTAssertEqual(e[1].owned, false)
        XCTAssertEqual(e[2].installed, false)
        XCTAssertEqual(e[2].sizeBytes, 1_200)
        XCTAssertEqual(e.map(\.source), [.steam, .local, .steam, .steam])
        XCTAssertEqual(LibrarySource.steam.label, "Steam")
        XCTAssertEqual(LibrarySource.local.label, "Local")
    }

    func testChipsFilter() {
        func ids(_ f: LibraryFilter, downloading: Set<UInt32> = []) -> [String] {
            LibraryList.shown(entries, filter: f, sort: .name, downloading: downloading).map(\.id)
        }
        XCTAssertEqual(ids(.installed), ["app-367520", "dir-my game"])
        XCTAssertEqual(ids(.installed, downloading: [588650]), ["app-588650", "app-367520", "dir-my game"],
                       "a download counts as installed")
        XCTAssertEqual(ids(.steam), ["app-504230", "app-588650", "app-367520"])
        XCTAssertEqual(ids(.all), ["app-504230", "app-588650", "app-367520", "dir-my game"])
        XCTAssertEqual(LibraryFilter.allCases, [.all, .installed, .steam])
        XCTAssertEqual(LibraryFilter.allCases.map(\.label), ["All", "Installed", "Steam"])
        XCTAssertEqual(LibraryFilter.all.next, .installed)
        XCTAssertEqual(LibraryFilter.installed.next, .steam)
        XCTAssertEqual(LibraryFilter.steam.next, .all)
    }

    func testSameNameFromDifferentSourcesStaysSeparate() {
        let e = LibraryList.entries(titles: [title("Celeste", app: nil)], owned: owned)
        let copies = LibraryList.shown(e, filter: .all, sort: .name, search: "Celeste")
        XCTAssertEqual(copies.map(\.id), ["app-504230", "dir-celeste"])
        XCTAssertEqual(copies.map(\.source), [.steam, .local])
        XCTAssertFalse(copies[0].installed, "the local copy does not mark the Steam copy installed")
        XCTAssertFalse(copies[1].owned, "the local copy does not inherit Steam ownership")
        XCTAssertEqual(LibraryList.shown(e, filter: .installed, sort: .name).map(\.id), ["dir-celeste"])
        XCTAssertEqual(LibraryList.shown(e, filter: .steam, sort: .name, search: "Celeste").map(\.id), ["app-504230"])
    }

    func testSourceBadgesOnlyForDuplicatesInMixedSourceFilters() {
        let e = LibraryList.entries(titles: [title("Celeste", app: nil)], owned: owned)
        let duplicates = LibraryList.duplicateSourceIDs(e)
        XCTAssertEqual(duplicates, ["app-504230", "dir-celeste"])
        for entry in e {
            XCTAssertEqual(LibraryList.showsSourceBadge(entry, filter: .all, duplicateIDs: duplicates),
                           duplicates.contains(entry.id))
            XCTAssertEqual(LibraryList.showsSourceBadge(entry, filter: .installed, duplicateIDs: duplicates),
                           duplicates.contains(entry.id))
            XCTAssertFalse(LibraryList.showsSourceBadge(entry, filter: .steam, duplicateIDs: duplicates))
        }
        let installed = LibraryList.shown(e, filter: .installed, sort: .name)
        XCTAssertEqual(installed.map(\.id), ["dir-celeste"])
        XCTAssertTrue(LibraryList.showsSourceBadge(installed[0], filter: .installed, duplicateIDs: duplicates),
                      "the other copy need not be visible or installed")
        XCTAssertEqual(LibraryList.duplicateSourceIDs(entries), [], "an installed/owned Steam merge is not a duplicate")
    }

    func testDuplicateNameMatchingIgnoresCaseAccentsAndEdgeWhitespace() {
        let e = LibraryList.entries(titles: [title("  CÉLESTE\n", app: nil)], owned: owned)
        XCTAssertEqual(LibraryList.duplicateSourceIDs(e), ["app-504230", "dir-  céleste\n"])
    }

    func testSameSourceOrEmptyNamesDoNotNeedBadges() {
        let sameStore = [
            LibraryEntry(id: "app-1", name: "Game", appID: 1, installed: true, owned: true),
            LibraryEntry(id: "app-2", name: "Game", appID: 2, installed: false, owned: true),
        ]
        XCTAssertEqual(LibraryList.duplicateSourceIDs(sameStore), [])
        let empty = [
            LibraryEntry(id: "app-1", name: "", appID: 1, installed: true, owned: true),
            LibraryEntry(id: "dir-empty", name: "  ", appID: nil, installed: true, owned: false),
        ]
        XCTAssertEqual(LibraryList.duplicateSourceIDs(empty), [])
    }

    func testSteamFilterIncludesInstalledCopyWithoutOwnership() {
        let e = LibraryList.entries(titles: [title("Offline Steam game", app: 1)], owned: [LibraryList.Owned]())
        XCTAssertFalse(e[0].owned)
        XCTAssertEqual(e[0].source, .steam)
        XCTAssertEqual(LibraryList.shown(e, filter: .steam, sort: .name), e)
    }

    func testSortsAndSearch() {
        XCTAssertEqual(LibraryList.shown(entries, filter: .steam, sort: .recent).map(\.id),
                       ["app-367520", "app-504230", "app-588650"], "played, then installed, then by name")
        XCTAssertEqual(LibraryList.shown(entries, filter: .steam, sort: .size).map(\.id),
                       ["app-367520", "app-588650", "app-504230"])
        XCTAssertEqual(LibraryList.shown(entries, filter: .steam, sort: .name, search: " CELES").map(\.id), ["app-504230"])
        XCTAssertEqual(LibraryList.shown(entries, filter: .steam, sort: .name, search: "céleste").map(\.id), ["app-504230"])
    }

    func testHomeRecentRow() {
        let e = LibraryList.entries(titles: [title("Hollow Knight", app: 367520, played: 100),
                                             title("My Game", app: nil, played: 200),
                                             title("Zeta", app: 1, played: nil)],
                                    owned: owned)
        XCTAssertEqual(LibraryList.recent(e, count: 4).map(\.id),
                       ["dir-my game", "app-367520", "app-1", "app-504230"],
                       "played newest first, then installed by name, then the rest by name")
        XCTAssertEqual(LibraryList.recent(e, count: 9).last?.id, "app-588650")
        XCTAssertEqual(LibraryList.recent(e, count: 4, excluding: "dir-my game").map(\.id),
                       ["app-367520", "app-1", "app-504230", "app-588650"],
                       "exclude the local hero before limiting, filling all four tiles")
        XCTAssertEqual(LibraryList.recent(e, count: 4, excluding: "app-367520").map(\.id),
                       ["dir-my game", "app-1", "app-504230", "app-588650"],
                       "exclude the Steam hero, including its merged owned entry")
        XCTAssertEqual(LibraryList.recent(e, count: 4, excluding: nil), LibraryList.recent(e, count: 4))
        XCTAssertEqual(LibraryList.recent(e, count: 0, excluding: "dir-my game"), [])
    }

    func testTileFramesAreRowByRow() {
        let f = LibraryList.tileFrames(count: 5, columns: 4, tile: CGSize(width: 100, height: 60),
                                       spacing: CGSize(width: 10, height: 20), origin: CGPoint(x: 5, y: 7))
        XCTAssertEqual(f.count, 5)
        XCTAssertEqual(f[3], CGRect(x: 335, y: 7, width: 100, height: 60))
        XCTAssertEqual(f[4], CGRect(x: 5, y: 87, width: 100, height: 60))
        XCTAssertEqual(FocusMove.next(from: f[4], .up, among: Dictionary(uniqueKeysWithValues: f.enumerated().map { ("\($0)", $1) })), "0")
    }
}

final class PadKeyboardTests: XCTestCase {
    func testEveryLayerIsTenUnitsWideInFiveRows() {
        for layer in [PadKeyboard.Layer.lower, .upper, .symbols] {
            let rows = PadKeyboard.layout(layer)
            XCTAssertEqual(rows.count, 5)
            for r in rows { XCTAssertEqual(r.reduce(0) { $0 + $1.width }, 10) }
        }
    }

    func testEveryPrintableASCIICharacterIsOnALayer() {
        // A Steam password may hold any of them.
        var keys = Set<Character>([" "])
        for layer in [PadKeyboard.Layer.lower, .upper, .symbols] {
            for row in PadKeyboard.layout(layer) { for cell in row { if case .char(let c) = cell.key { keys.insert(c) } } }
        }
        let missing = (0x20...0x7e).map { Character(UnicodeScalar(UInt8($0))) }.filter { !keys.contains($0) }
        XCTAssertEqual(missing, [])
    }

    func testTheCursorStartsOnQAndTypesWithA() {
        var k = PadKeyboard()
        XCTAssertEqual(k.key, .char("q"))
        // q → h: down to `a`, five right.
        k.move(.down)
        for _ in 0..<5 { k.move(.right) }
        XCTAssertEqual(k.key, .char("h"))
        XCTAssertEqual(k.press(), .edited)
        XCTAssertEqual(k.string, "h")
    }

    func testSidewaysWrapsAndUpDownStop() {
        var k = PadKeyboard()
        k.move(.left)
        XCTAssertEqual(k.key, .char("p"))
        k.move(.right)
        XCTAssertEqual(k.key, .char("q"))
        k.move(.up)
        k.move(.up)
        XCTAssertEqual(k.key, .char("1"))
        for _ in 0..<6 { k.move(.down) }
        XCTAssertEqual(k.row, 4)
    }

    func testDownAndBackUpReturnsToTheSameKey() {
        var k = PadKeyboard()
        k.move(.down)
        for _ in 0..<4 { k.move(.right) }   // g
        k.move(.down)                        // row 3: ⇧(1.5) z x c v …, x = 4.5 → v
        XCTAssertEqual(k.key, .char("v"))
        k.move(.down)                        // the space bar spans 2.5..7
        XCTAssertEqual(k.key, .space)
        k.move(.up)
        k.move(.up)
        XCTAssertEqual(k.key, .char("g"))
    }

    func testShiftTypesOneCapitalAndSymbolsKeepTheCursor() {
        var k = PadKeyboard()
        k.press(.shift)
        XCTAssertEqual(k.key, .char("Q"))
        k.press()
        k.press()
        XCTAssertEqual(k.string, "Qq")
        k.press(.symbols)
        XCTAssertEqual(k.key, .char("!"))
        k.press(.symbols)
        XCTAssertEqual(k.key, .char("q"))
        XCTAssertEqual(k.press(.done), .done)
    }

    func testTheCaretEditsInTheMiddle() {
        var k = PadKeyboard(text: "hk")
        k.moveCaret(by: -1)
        k.insert("o")
        XCTAssertEqual(k.string, "hok")
        XCTAssertTrue(k.backspace())
        XCTAssertTrue(k.backspace())
        XCTAssertFalse(k.backspace())
        XCTAssertEqual(k.string, "k")
        k.moveCaret(by: 9)
        XCTAssertEqual(k.caret, 1)
        k.clear()
        XCTAssertEqual(k.string, "")
    }

    func testTheLengthIsCapped() {
        var k = PadKeyboard(text: "abc", maxLength: 3)
        k.press(.space)
        XCTAssertEqual(k.string, "abc")
    }
}

final class PickerIndexTests: XCTestCase {
    func testClampStopsAtTheEnds() {
        XCTAssertEqual(PickerIndex.step(0, by: -1, count: 4, wrap: false), 0)
        XCTAssertEqual(PickerIndex.step(3, by: 1, count: 4, wrap: false), 3)
        XCTAssertEqual(PickerIndex.step(1, by: 1, count: 4, wrap: false), 2)
    }

    func testWrapGoesAround() {
        XCTAssertEqual(PickerIndex.step(0, by: -1, count: 4, wrap: true), 3)
        XCTAssertEqual(PickerIndex.step(3, by: 1, count: 4, wrap: true), 0)
        XCTAssertEqual(PickerIndex.step(2, by: -6, count: 4, wrap: true), 0)
    }

    func testNothingToPick() {
        XCTAssertEqual(PickerIndex.step(5, by: 1, count: 0, wrap: true), 0)
        XCTAssertEqual(PickerIndex.step(9, by: 0, count: 3, wrap: false), 2)
    }
}

final class OptionValueTests: XCTestCase {
    func testARowShowsItsDefaultUntilChanged() {
        let inherited = LaunchSettings.resolve(game: nil, global: LaunchSettings())
        XCTAssertEqual(OptionValue.of(own: LaunchSettings().screen, inherited: inherited.screen ?? "native") { "\($0)p" },
                       OptionValue(text: "Default · 720p", changed: false))
        XCTAssertEqual(OptionValue.of(own: Int?.none, inherited: inherited.frameLimit) { "\($0) fps" },
                       OptionValue(text: "Default · 60 fps", changed: false))
        XCTAssertEqual(OptionValue.of(own: GraphicsBackend?.none, inherited: inherited.graphics) { $0.rawValue.uppercased() },
                       OptionValue(text: "Default · DXMT", changed: false))
        // Set for the game: its value alone, marked. Setting it to the default's value still marks it.
        XCTAssertEqual(OptionValue.of(own: 30, inherited: 60) { "\($0) fps" }, OptionValue(text: "30 fps", changed: true))
        XCTAssertEqual(OptionValue.of(own: 60, inherited: 60) { "\($0) fps" }, OptionValue(text: "60 fps", changed: true))
        // The default follows Settings.
        let global = LaunchSettings.resolve(game: nil, global: LaunchSettings(screen: "1080"))
        XCTAssertEqual(OptionValue.of(own: String?.none, inherited: global.screen ?? "native") { "\($0)p" }.text, "Default · 1080p")
    }
}

final class SettingsModelTests: XCTestCase {
    func testTheSectionsAndTheirOldNames() {
        XCTAssertEqual(SettingsSection.all(developer: false).map(\.title),
                       ["Steam account", "Graphics", "Downloads", "Controllers", "Storage", "Setup check", "About"])
        XCTAssertEqual(SettingsSection.all(developer: true).last, .developer)
        XCTAssertEqual(SettingsSection.named("account"), .steam)
        XCTAssertEqual(SettingsSection.named("diagnostics"), .developer)
        XCTAssertEqual(SettingsSection.named("pairing"), .developer)
        XCTAssertEqual(SettingsSection.named("jit"), .setup)
        XCTAssertEqual(SettingsSection.named("graphics"), .graphics)
        XCTAssertNil(SettingsSection.named("nope"))
        // Up and down stop at the ends; a release build never steps onto Developer.
        XCTAssertEqual(SettingsSection.steam.step(-1, developer: true), .steam)
        XCTAssertEqual(SettingsSection.about.step(1, developer: false), .about)
        XCTAssertEqual(SettingsSection.about.step(1, developer: true), .developer)
        XCTAssertEqual(SettingsSection.graphics.step(1, developer: false), .downloads)
    }

    func testAValueRowStoresNilForItsDefault() {
        let screen = SettingSteps(values: ["540", "720", "900", "1080", "native"], defaultValue: LaunchSettings.defaultScreen)
        XCTAssertEqual(screen.labels { $0 == "native" ? "Native" : "\($0)p" },
                       ["540p", "Default · 720p", "900p", "1080p", "Native"])
        XCTAssertEqual(screen.index(of: nil), 1)
        XCTAssertEqual(screen.index(of: "720"), 1)        // the default's own value, stored before
        XCTAssertEqual(screen.index(of: "1080"), 3)
        XCTAssertEqual(screen.index(of: "2160"), 1)       // no longer offered: the default
        XCTAssertNil(screen.stored(at: 1))
        XCTAssertEqual(screen.stored(at: 0), "540")
        XCTAssertNil(screen.stored(at: 9))
        // A default missing from the values goes first.
        let limit = SettingSteps(values: [30, 40, 0], defaultValue: LaunchSettings.defaultFrameLimit)
        XCTAssertEqual(limit.values, [60, 30, 40, 0])
        XCTAssertEqual(limit.index(of: nil), 0)
    }

    func testDownloadPreferencesAndTheNetwork() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsModelTests-\(UUID().uuidString)"))
        XCTAssertEqual(DownloadPreferences(defaults), DownloadPreferences(autoUpdate: true, cellular: false, dim: true))
        defaults.set(false, forKey: DownloadPreferences.autoUpdateKey)
        defaults.set(true, forKey: DownloadPreferences.cellularKey)
        defaults.set(false, forKey: DownloadPreferences.dimKey)
        XCTAssertEqual(DownloadPreferences(defaults), DownloadPreferences(autoUpdate: false, cellular: true, dim: false))
        let wifiOnly = DownloadPreferences()
        XCTAssertTrue(wifiOnly.mayDownload(connected: true, expensive: false))
        XCTAssertFalse(wifiOnly.mayDownload(connected: true, expensive: true))
        XCTAssertFalse(wifiOnly.mayDownload(connected: false, expensive: false))
        XCTAssertTrue(DownloadPreferences(cellular: true).mayDownload(connected: true, expensive: true))
    }
}

final class DownloadQueueTests: XCTestCase {
    private func job(_ id: UInt32, _ kind: DownloadJob.Kind = .install, hold: DownloadJob.Hold? = nil) -> DownloadJob {
        DownloadJob(appID: id, name: "Game \(id)", kind: kind, hold: hold)
    }

    func testJobsRunInOrderAndHeldOnesWait() {
        var q = DownloadQueue()
        XCTAssertTrue(q.add(job(1)))
        XCTAssertTrue(q.add(job(2)))
        XCTAssertFalse(q.add(job(2)), "a game has one job")
        q.hold(1, .player)
        XCTAssertEqual(q.next?.appID, 2)
        // Resume: adding it again lets go of the hold, in its place.
        XCTAssertTrue(q.add(job(1)))
        XCTAssertEqual(q.next?.appID, 1)
        XCTAssertEqual(q.jobs.map(\.appID), [1, 2])
    }

    func testDownloadNextGoesBehindTheRunningJob() {
        var q = DownloadQueue(jobs: [job(1), job(2), job(3, hold: .player)])
        q.moveToFront(3, running: 1)
        XCTAssertEqual(q.jobs.map(\.appID), [1, 3, 2])
        XCTAssertNil(q.job(3)?.hold, "Download next resumes a paused job")
        q.moveToFront(2)
        XCTAssertEqual(q.jobs.map(\.appID), [2, 1, 3])
        q.moveToFront(2, running: 2)
        XCTAssertEqual(q.jobs.map(\.appID), [2, 1, 3], "the running job stays")
        q.started(3)
        XCTAssertEqual(q.jobs.map(\.appID), [3, 2, 1])
    }

    func testANewProcessResumesAllButThePlayersPauses() throws {
        var q = DownloadQueue(jobs: [job(1, hold: .launch), job(2, .update, hold: .player), job(3, .repair, hold: .stopped("Steam can't be reached.")), job(4)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadQueueStore(url: dir.appendingPathComponent("Playport/downloads.json"))
        XCTAssertEqual(store.load(), DownloadQueue(), "nothing saved yet")
        q.finished(4, bytes: 240_000_000, at: Date(timeIntervalSince1970: 1_790_000_000))
        try store.save(q)
        var loaded = store.load()
        XCTAssertEqual(loaded, q)
        loaded.afterRestart()
        XCTAssertEqual(loaded.jobs.map(\.appID), [1, 2, 3])
        XCTAssertEqual(loaded.jobs.map(\.hold), [nil, .player, nil])
        XCTAssertEqual(loaded.jobs.map(\.kind), [.install, .update, .repair])
        XCTAssertEqual(loaded.next?.appID, 1)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), DownloadQueue(), "an unreadable file is an empty queue")
    }

    func testDoneTodayKeepsTodaysNewestFirst() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 14:13 UTC
        var q = DownloadQueue(jobs: [job(1), job(2, .update), job(3)])
        q.finished(1, bytes: nil, at: now.addingTimeInterval(-86_400))
        q.finished(2, bytes: 240_000_000, at: now.addingTimeInterval(-3600))
        q.finished(3, bytes: 1_200_000_000, at: now)
        XCTAssertEqual(q.doneToday(now: now, calendar: cal).map(\.line), ["Game 3 · 1.20 GB", "Game 2 update · 240 MB"])
        q.prune(now: now, calendar: cal)
        XCTAssertEqual(q.done.map(\.appID), [2, 3])
        XCTAssertTrue(q.jobs.isEmpty)
    }

    func testUpdatesQueueByThemselvesOncePerBuild() {
        let c = [
            UpdateCandidate(appID: 1, name: "Newer", installedBuild: 10, steamBuild: 12),
            UpdateCandidate(appID: 2, name: "Same", installedBuild: 10, steamBuild: 10),
            UpdateCandidate(appID: 3, name: "Stale cache", installedBuild: 10, steamBuild: 9),
            UpdateCandidate(appID: 4, name: "No record", installedBuild: nil, steamBuild: 9),
        ]
        var q = DownloadQueue()
        XCTAssertEqual(q.automaticUpdates(c, enabled: false), [], "Settings › Downloads says no")
        let found = q.automaticUpdates(c, enabled: true)
        XCTAssertEqual(found.map(\.appID), [1])
        XCTAssertEqual(found.first?.kind, .update)
        XCTAssertEqual(found.first?.automatic, true)
        q.add(found[0])
        XCTAssertEqual(q.automaticUpdates(c, enabled: true), [], "already queued")
        q.remove(1)
        XCTAssertEqual(q.automaticUpdates(c, enabled: true), [], "cancelled for build 12")
        var later = c
        later[0].steamBuild = 13
        XCTAssertEqual(q.automaticUpdates(later, enabled: true).map(\.buildID), [13], "a newer build is queued again")
        // The player's own Update over an automatic one makes it theirs: a cancel is then not a decline.
        q.add(DownloadJob(appID: 5, name: "x", kind: .update, automatic: true, buildID: 3))
        q.hold(5, .player)
        q.add(DownloadJob(appID: 5, name: "x", kind: .update))
        XCTAssertEqual(q.job(5)?.automatic, false)
    }

    func testRateAndTimeLeft() {
        var r = DownloadRate(window: 10)
        XCTAssertNil(r.bytesPerSecond)
        r.add(bytes: 0, at: 0)
        r.add(bytes: 10_000_000, at: 0.5)
        XCTAssertNil(r.bytesPerSecond, "under a second of samples")
        r.add(bytes: 20_000_000, at: 1)
        XCTAssertEqual(r.bytesPerSecond ?? 0, 20_000_000, accuracy: 1)
        r.add(bytes: 20_000_000, at: 20)
        XCTAssertNil(r.bytesPerSecond, "the old samples left the window")
        r.add(bytes: 5, at: 21)
        XCTAssertNil(r.bytesPerSecond, "a new run starts afresh")
        XCTAssertEqual(DownloadRate.seconds(remaining: 2_000_000_000, rate: 18_000_000).map { Int($0) }, 111)
        XCTAssertNil(DownloadRate.seconds(remaining: 1, rate: 0))
        XCTAssertEqual(DownloadRate.duration(30), "less than a minute")
        XCTAssertEqual(DownloadRate.duration(240), "about 4 min")
        XCTAssertEqual(DownloadRate.duration(4800), "about 1 h 20 min")
        XCTAssertEqual(DownloadRate.duration(7200), "about 2 h")
        XCTAssertEqual(DownloadRate.speed(18_000_000), "18.0 MB/s")
        XCTAssertEqual(DownloadRate.short(10), "1 min")
        XCTAssertEqual(DownloadRate.short(200), "4 min")
        XCTAssertEqual(DownloadRate.short(4800), "1 h 20 min")
    }

    func testDownloadModeDimsAfterAMinute() {
        XCTAssertFalse(DownloadMode.shouldDim(idleFor: 59, downloading: true, enabled: true))
        XCTAssertTrue(DownloadMode.shouldDim(idleFor: 60, downloading: true, enabled: true))
        XCTAssertFalse(DownloadMode.shouldDim(idleFor: 600, downloading: false, enabled: true))
        XCTAssertFalse(DownloadMode.shouldDim(idleFor: 600, downloading: true, enabled: false))
        XCTAssertEqual(DownloadMode.dimmed(from: 0.8), 0.05)
        XCTAssertEqual(DownloadMode.dimmed(from: 0.01), 0.01)
    }
}

final class PlayTimeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("playtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    private func catalog() -> Catalog {
        Catalog(titles: [InstalledTitle(id: "app-367520", appID: 367520, name: "Hollow Knight", developer: nil,
                                        installDir: "Hollow Knight", executable: "hollow_knight.exe", buildID: nil, depots: [],
                                        sizeBytes: nil, source: .cohort, checksums: nil, note: nil, addedAt: at(0),
                                        lastPlayed: nil, lastVerification: nil)])
    }

    func testBeatsCountPlayButNotASuspendedGap() {
        var s = PlaySession(titleID: "app-367520", now: at(0))
        for t in stride(from: 5.0, through: 60, by: 5) { s.beat(now: at(t)) }
        XCTAssertEqual(s.seconds, 60)
        // Suspended in the background for ten minutes: one beat's cap counts.
        s.beat(now: at(660))
        XCTAssertEqual(s.seconds, 60 + PlaySession.maxGap)
        s.beat(now: at(600))
        XCTAssertEqual(s.seconds, 75, "a clock that went back counts nothing")
        XCTAssertEqual(s.lastBeat, at(660))
    }

    func testSessionsAddUpInTheCatalogue() {
        var c = catalog()
        var a = PlaySession(titleID: "app-367520", now: at(0))
        a.beat(now: at(10))
        XCTAssertTrue(c.addPlayTime(a))
        var b = PlaySession(titleID: "app-367520", now: at(100))
        b.beat(now: at(105))
        XCTAssertTrue(c.addPlayTime(b))
        XCTAssertEqual(c.title(id: "app-367520")?.playSeconds, 15)
        XCTAssertFalse(c.addPlayTime(PlaySession(titleID: "app-1", now: at(0))), "a title no longer catalogued")
    }

    /// Decision 0029: the process ends after the game (or with it), and the next one adds the session from disk.
    func testASessionLeftOnDiskIsCountedByTheNextProcess() throws {
        let store = PlaySessionStore(url: root.appendingPathComponent("state/session.json"))
        XCTAssertNil(store.load())
        var s = PlaySession(titleID: "app-367520", now: at(0))
        for t in stride(from: 5.0, through: 25, by: 5) {
            s.beat(now: at(t))
            try store.save(s)
        }
        // The process ends here, before the session's end was counted. The next one:
        var c = catalog()
        let left = try XCTUnwrap(store.load())
        XCTAssertEqual(left, s)
        XCTAssertTrue(c.addPlayTime(left))
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertEqual(c.title(id: "app-367520")?.playSeconds, 25)
        // Written and read with the catalogue, and kept across a re-adoption.
        let cs = CatalogStore(url: root.appendingPathComponent("state/catalog.json"))
        try cs.save(c)
        XCTAssertEqual(cs.load().title(id: "app-367520")?.playSeconds, 25)
    }

    func testAnOlderCatalogueWithoutPlayTimeReads() throws {
        let url = root.appendingPathComponent("catalog.json")
        var c = catalog()
        c.update("app-367520") { $0.playSeconds = 1 }
        let json = String(decoding: try CatalogStore.encoder.encode(c), as: UTF8.self)
            .replacingOccurrences(of: "\"playSeconds\" : 1,", with: "")
        XCTAssertFalse(json.contains("playSeconds"))
        try Data(json.utf8).write(to: url)
        XCTAssertNil(CatalogStore(url: url).load().title(id: "app-367520")?.playSeconds)
    }

    func testFormat() {
        XCTAssertEqual(PlayTime.format(20), "less than a minute")
        XCTAssertEqual(PlayTime.format(25 * 60 + 59), "25 min")
        XCTAssertEqual(PlayTime.format(3600), "1 h")
        XCTAssertEqual(PlayTime.format(2 * 3600 + 5 * 60), "2 h 5 min")
        XCTAssertEqual(PlayTime.format(14 * 3600 + 40 * 60), "14 h")
    }
}

final class LaunchProgressTests: XCTestCase {
    func testTheBarMovesWithTheStepsAndNeverEndsBeforeTheGameDraws() {
        var last = -1.0
        for stage in [LaunchStage.preparing, .jit, .runtime, .game] {
            for t in [0.0, 1, 3, 10, 600] {
                let f = LaunchProgress.fraction(stage, elapsed: t)
                XCTAssertGreaterThanOrEqual(f, last, "\(stage) at \(t) s")
                XCTAssertLessThan(f, 1)
                last = f
            }
        }
        XCTAssertEqual(LaunchProgress.fraction(.drawing, elapsed: 0), 1)
        XCTAssertEqual(LaunchProgress.fraction(.jit, elapsed: -5), LaunchProgress.fraction(.jit, elapsed: 0))
    }

    func testStepsShowOnlyWhenOneFailedOrJITIsSlow() {
        XCTAssertFalse(LaunchProgress.showsSteps(.jit, elapsed: 3.4))
        XCTAssertTrue(LaunchProgress.showsSteps(.jit, elapsed: LaunchProgress.jitSlow))
        XCTAssertFalse(LaunchProgress.showsSteps(.game, elapsed: 60))
        XCTAssertTrue(LaunchProgress.showsSteps(.preparing, elapsed: 0, failed: .runtime))
    }

    func testAFailedResultNamesItsStep() {
        XCTAssertEqual(LaunchProgress.failedStage("launch=failed runtime=JIT pool (1536 MiB): timed out"), .jit)
        XCTAssertEqual(LaunchProgress.failedStage("launch=failed runtime=pool 1536 MiB; wine_host_init -> 5"), .runtime)
        XCTAssertEqual(LaunchProgress.failedStage("launch=failed selfcheck=pool-alias"), .runtime)
        XCTAssertEqual(LaunchProgress.failedStage("launch=failed run_exe=-2"), .game)
        XCTAssertEqual(LaunchProgress.failedStage("launch=failed wait=-1"), .game)
        XCTAssertNil(LaunchProgress.failedStage("launch=refused resolve=2 reason=missing"))
        XCTAssertNil(LaunchProgress.failedStage("exit=0x00000000 after_s=97"))
        XCTAssertNil(LaunchProgress.failedStage("still-running after_s=40"))
    }
}

final class CloudChoiceTests: XCTestCase {
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + s) }

    func testEachSideIsSummedOverTheConflictingFiles() {
        let sides = CloudSides([
            .init(name: "user1.dat", phoneSize: 100, phoneTime: at(50), steamSize: 90, steamTime: at(10)),
            .init(name: "user2.dat", phoneSize: 20, phoneTime: at(70), steamSize: 30, steamTime: at(5)),
        ])
        XCTAssertEqual(sides.phone, .init(files: 2, bytes: 120, newest: at(70)))
        XCTAssertEqual(sides.steam, .init(files: 2, bytes: 120, newest: at(10)))
        XCTAssertFalse(sides.steamHasNone)
        XCTAssertEqual(sides.newer, .phone)
    }

    func testAFirstSyncsPhoneOnlySavesHaveNothingOnSteam() {
        let sides = CloudSides([.init(name: "user1.dat", phoneSize: 100, phoneTime: at(0))])
        XCTAssertTrue(sides.steamHasNone)
        XCTAssertNil(sides.newer)
        XCTAssertEqual(SteamService.resolveAll([.init(name: "a"), .init(name: "b")], .phone), ["a": .phone, "b": .phone])
    }
}

final class SetupChecklistTests: XCTestCase {
    func testTheStepsAndWhereTheRingStarts() {
        var f = SetupFacts(controller: "Xbox Wireless Controller", pairing: false, pairsOnPhone: false, tunnelUp: false)
        let items = SetupChecklist.items(f)
        XCTAssertEqual(items.map(\.step), [.pairing, .vpn, .steam])
        XCTAssertEqual(items.map(\.done), [false, false, false])
        XCTAssertEqual(items[0].title, "Pairing file")
        XCTAssertEqual(items[0].action, "Choose file")
        XCTAssertEqual(SetupChecklist.firstTodo(f), .pairing)
        f.pairsOnPhone = true
        XCTAssertEqual(SetupChecklist.item(.pairing, f).action, "Pair this iPhone")
        f.pairing = true
        f.tunnelUp = true
        XCTAssertEqual(SetupChecklist.item(.pairing, f).action, "Pair again")
        XCTAssertNil(SetupChecklist.item(.vpn, f).action)
        XCTAssertEqual(SetupChecklist.firstTodo(f), .steam)
        XCTAssertEqual(SetupChecklist.doneCount(f), 2)
        f.steamSignedIn = true
        XCTAssertEqual(SetupChecklist.firstTodo(f), .pairing)
        XCTAssertEqual(SetupChecklist.doneCount(f), 3)
        XCTAssertEqual(SetupChecklist.item(.vpn, SetupFacts(tunnelUp: nil)).detail, "Checking…")
    }

    func testTheChecklistOpensByItselfOnlyOnAFirstRun() {
        XCTAssertTrue(SetupChecklist.showsAtStart(left: false, pairing: false))
        XCTAssertFalse(SetupChecklist.showsAtStart(left: true, pairing: false))
        XCTAssertFalse(SetupChecklist.showsAtStart(left: false, pairing: true))
        // Completing pairing is not an escape if the app closes mid-setup.
        XCTAssertTrue(SetupChecklist.showsAtStart(left: false, pairing: true, started: true))
        XCTAssertFalse(SetupChecklist.showsAtStart(left: true, pairing: true, started: true))
    }

    func testFirstRunCannotLeaveUntilEveryStepIsSettled() {
        // Both versions of pairing, with no controller required. Steam may be
        // done first: steps are freely navigable, only leaving is gated.
        for onPhone in [false, true] {
            var f = SetupFacts(pairsOnPhone: onPhone, tunnelUp: false, steamSignedIn: true)
            XCTAssertFalse(SetupChecklist.complete(f))
            XCTAssertFalse(SetupChecklist.canLeave(f, firstRun: true))
            XCTAssertTrue(SetupChecklist.canLeave(f, firstRun: false))
            f.pairing = true
            XCTAssertFalse(SetupChecklist.canLeave(f, firstRun: true))
            f.tunnelUp = nil
            XCTAssertFalse(SetupChecklist.canLeave(f, firstRun: true))
            f.tunnelUp = true
            XCTAssertTrue(SetupChecklist.complete(f))
            XCTAssertTrue(SetupChecklist.canLeave(f, firstRun: true))
            f.steamSignedIn = nil
            XCTAssertFalse(SetupChecklist.canLeave(f, firstRun: true))
        }
    }

    func testNotNowSettlesOnlyTheOptionalSteamStep() {
        var f = SetupFacts(steamSkipped: true)
        XCTAssertFalse(SetupChecklist.complete(f))
        f.pairing = true
        f.tunnelUp = true
        XCTAssertTrue(SetupChecklist.complete(f))
        XCTAssertTrue(SetupChecklist.canLeave(f, firstRun: true))
        XCTAssertEqual(SetupChecklist.doneCount(f), 3)
        XCTAssertTrue(SetupChecklist.item(.steam, f).done)
        // Not now never claims to be signed in or disables later sign-in.
        XCTAssertTrue(SetupChecklist.item(.steam, f).detail.hasPrefix("Not now."))
        XCTAssertEqual(SetupChecklist.item(.steam, f).action, "Sign in")
        XCTAssertEqual(SetupChecklist.notes(f, steamGame: true).count, 2)
        XCTAssertFalse(SetupChecklist.offersNotNow(f, firstRun: true))
        f.steamSkipped = false
        XCTAssertFalse(SetupChecklist.complete(f))
        XCTAssertTrue(SetupChecklist.offersNotNow(f, firstRun: true))
        XCTAssertFalse(SetupChecklist.offersNotNow(f, firstRun: false))
        f.steamSignedIn = true
        XCTAssertFalse(SetupChecklist.offersNotNow(f, firstRun: true))
    }

    func testTheCheckBeforeALaunch() {
        var f = SetupFacts(controller: nil, pairing: false, pairsOnPhone: true, tunnelUp: true)
        XCTAssertEqual(SetupChecklist.beforeLaunch(f), .fixesItself(.pairing))
        f.pairsOnPhone = false
        guard case .needs(.pairing, let fix) = SetupChecklist.beforeLaunch(f) else { return XCTFail() }
        XCTAssertTrue(fix.contains("Files"))
        f.pairing = true
        XCTAssertEqual(SetupChecklist.beforeLaunch(f), .go)
        f.tunnelUp = false
        XCTAssertEqual(SetupChecklist.beforeLaunch(f), .fixesItself(.vpn))
        f.tunnelUp = nil
        XCTAssertEqual(SetupChecklist.beforeLaunch(f), .fixesItself(.vpn))
        // A controller and Steam never stop a launch; the launch screen names them.
        XCTAssertEqual(SetupChecklist.notes(f, steamGame: true).count, 2)
        XCTAssertEqual(SetupChecklist.notes(f, steamGame: false).count, 1)
        f.steamSignedIn = nil   // the session still being read says nothing
        XCTAssertEqual(SetupChecklist.notes(f, steamGame: true), [SetupChecklist.noController])
        XCTAssertFalse(SetupChecklist.item(.steam, f).done)
        f.controller = "Pad"
        f.steamSignedIn = true
        XCTAssertEqual(SetupChecklist.notes(f, steamGame: true), [])
        XCTAssertEqual(SetupChecklist.summary(f), "controller=Pad pairing=file vpn=unknown steam=signed-in")
    }
}

final class QuickMenuTests: XCTestCase {
    func testTheRingMovesAlongTheRowsAndStopsAtTheEnds() {
        var m = QuickMenu()
        XCTAssertEqual(m.ring, .resume)
        m.move(down: false)
        XCTAssertEqual(m.ring, .resume)
        for _ in 0..<10 { m.move(down: true) }
        XCTAssertEqual(m.ring, .quit)
        m.move(down: false)
        XCTAssertEqual(m.ring, .controller)
        XCTAssertEqual(QuickMenu.steps(from: .resume, to: .quit), [true, true, true, true])
        XCTAssertEqual(QuickMenu.steps(from: .overlay, to: .resume), [false, false])
        XCTAssertEqual(QuickMenu.steps(from: .quit, to: .quit), [])
    }

    func testWhatTheRowsSay() {
        XCTAssertEqual(QuickMenu.playing(seconds: 20), "Playing · just started")
        XCTAssertEqual(QuickMenu.playing(seconds: 42 * 60 + 5), "Playing · 42 min")
        XCTAssertEqual(QuickMenu.controller(name: "Xbox", battery: 80), "Xbox · 80%")
        XCTAssertEqual(QuickMenu.controller(name: "DualSense", battery: nil), "DualSense")
        XCTAssertEqual(QuickMenu.controller(name: nil, battery: nil), "None")
        XCTAssertEqual(QuickMenuItem.allCases.map(\.title),
                       ["Resume", "Screenshot", "Performance overlay", "Controller", "Quit game"])
    }
}

final class LicencesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("licences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Wine"), withIntermediateDirectories: true)
        try Data("GPL text\n".utf8).write(to: root.appendingPathComponent("Playport-LICENSE.txt"))
        try Data([0x43, 0x6F, 0x70, 0x79, 0x20, 0xA9, 0x0A]).write(to: root.appendingPathComponent("Wine/COPYING.LIB"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// components.json as build/notices-app.py writes it.
    private func write(status: String = "unreviewed-app-selection", files: [String] = ["Playport-LICENSE.txt"],
                       open: [String] = ["FreeType: FTL is chosen; confirm."], schema: Int = 1) throws {
        let components: [[String: Any]] = [
            ["name": "Playport", "licence": "GPL-3.0-or-later", "covers": ["app"], "files": files],
            ["name": "Wine", "licence": "LGPL-2.1-or-later", "covers": ["P1-wine"], "files": ["Wine/COPYING.LIB"]],
        ]
        let json: [String: Any] = ["schema": schema, "status": status, "components": components,
                                   "credits": ["Based in part on the work of the Independent JPEG Group."], "open": open]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("components.json"))
    }

    func testAnUnreviewedBundleLoadsWithItsOpenQuestions() throws {
        try write()
        let l = try Licences.load(directory: root)
        XCTAssertEqual(l.components.map(\.name), ["Playport", "Wine"])
        XCTAssertEqual(l.credits.count, 1)
        XCTAssertEqual(l.open, ["FreeType: FTL is chosen; confirm."])
        XCTAssertFalse(l.reviewed)
        XCTAssertEqual(try l.text(of: "Playport-LICENSE.txt"), "GPL text\n")
    }

    func testOnlyTheReviewedStatusWithNoOpenQuestionIsReviewed() throws {
        try write(status: Licences.reviewedStatus, open: [])
        XCTAssertTrue(try Licences.load(directory: root).reviewed)
        try write(status: Licences.reviewedStatus)
        XCTAssertFalse(try Licences.load(directory: root).reviewed)
    }

    func testANonUTF8NoticeKeepsEveryByteAsLatin1() throws {
        try write()
        XCTAssertEqual(try Licences.load(directory: root).text(of: "Wine/COPYING.LIB"), "Copy \u{A9}\n")
    }

    func testAMissingOrBrokenBundleFailsRatherThanShowingAPlaceholder() throws {
        XCTAssertThrowsError(try Licences.load(directory: root))   // no components.json
        try write(files: ["Playport-LICENSE.txt", "Playport-LICENSE-EXCEPTION.md"])
        XCTAssertThrowsError(try Licences.load(directory: root)) {
            XCTAssertEqual($0 as? Licences.LoadError, .missingFile("Playport-LICENSE-EXCEPTION.md"))
        }
        try write(files: ["Wine"])   // a directory, not a file
        XCTAssertThrowsError(try Licences.load(directory: root))
        try write(schema: 2)
        XCTAssertThrowsError(try Licences.load(directory: root)) { XCTAssertEqual($0 as? Licences.LoadError, .schema(2)) }
    }

    func testUnsafeOrUnlistedNamesAreRefused() throws {
        for name in ["../Playport-LICENSE.txt", "/etc/passwd", "Wine//COPYING.LIB", "./Playport-LICENSE.txt", ""] {
            try write(files: [name])
            XCTAssertThrowsError(try Licences.load(directory: root), name) {
                XCTAssertEqual($0 as? Licences.LoadError, .unsafeName(name))
            }
        }
        try write()
        try Data("x".utf8).write(to: root.appendingPathComponent("unlisted.txt"))
        XCTAssertThrowsError(try Licences.load(directory: root).text(of: "unlisted.txt"))
    }

    func testParagraphsSplitAtBlankLines() {
        XCTAssertEqual(Licences.paragraphs("a\nb\n\n  \nc\r\n\r\nd"), ["a\nb", "c", "d"])
        XCTAssertEqual(Licences.paragraphs("\n\n"), [])
    }
}
