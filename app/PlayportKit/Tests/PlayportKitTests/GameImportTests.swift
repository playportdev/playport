// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit
import SteamClientKit

final class GameImportTests: XCTestCase {
    var root: URL!
    var src: URL { root.appendingPathComponent("Files/Celeste") }
    var layout: InstallLayout { InstallLayout.root(root.appendingPathComponent("container")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ rel: String, _ text: String = "x", in base: URL? = nil) throws {
        let url = (base ?? src).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func importer(free: UInt64 = 1 << 40) -> GameImporter {
        var i = GameImporter(layout: layout)
        i.freeSpace = { _ in free }
        i.reserveBytes = 0
        return i
    }

    func testAFolderIsCopiedWithItsTreeAndAReceipt() async throws {
        try file("Celeste.exe", "MZ game")
        try file("Content/Dialog/English.txt", "hello")
        try file("Content/.hidden", "kept")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Saves"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link.exe").path, withDestinationPath: "Celeste.exe")
        let plan = try GameImporter.plan(.folder(src))
        XCTAssertEqual(plan.name, "Celeste")
        XCTAssertEqual(plan.files.map(\.path), ["Celeste.exe", "Content/.hidden", "Content/Dialog/English.txt"])
        XCTAssertEqual(plan.directories, ["Content", "Content/Dialog", "Saves"])
        XCTAssertEqual(plan.skippedSymlinks, 1)
        XCTAssertEqual(plan.totalBytes, 7 + 4 + 5)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let receipt = try await importer().run(plan, folder: "Celeste", now: at)
        let game = layout.gamesRoot.appendingPathComponent("Celeste")
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("Content/Dialog/English.txt"), encoding: .utf8), "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.appendingPathComponent("Saves").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("link.exe").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: importer().stage(folder: "Celeste").path))
        XCTAssertEqual(receipt.key, StoreGameKey(store: .local, id: "celeste"))
        XCTAssertEqual(receipt.importedFrom, "Celeste")
        XCTAssertEqual(receipt.files, 3)
        XCTAssertEqual(layout.storeReceipts(), [receipt])
        // Adoption: an imported title, as dir-<folder>.
        let c = Adoption.scan(games: layout.gamesRoot, cohort: Cohort(titles: []), receipts: [],
                              storeReceipts: layout.storeReceipts(), previous: Catalog())
        XCTAssertEqual(c.titles.map(\.id), ["dir-celeste"])
        XCTAssertEqual(c.titles.first?.source, .imported)
        XCTAssertEqual(c.titles.first?.executable, "Celeste.exe")
        let text = String(decoding: try Data(contentsOf: layout.receiptFile(receipt.key)), as: UTF8.self)
        XCTAssertFalse(text.contains(root.path), "the receipt names no path")
    }

    func testAStoppedImportResumesWithoutCopyingWhatIsInPlace() async throws {
        try file("a.bin", String(repeating: "a", count: 100))
        try file("b.bin", String(repeating: "b", count: 100))
        let plan = try GameImporter.plan(.folder(src))
        let stage = importer().stage(folder: "Celeste")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 100).utf8).write(to: stage.appendingPathComponent("a.bin"))
        try Data("torn".utf8).write(to: stage.appendingPathComponent(".b.bin.part"))
        let seen = Seen()
        _ = try await importer().run(plan, folder: "Celeste") { seen.add($0) }
        XCTAssertEqual(seen.first?.bytesDone, 100, "a.bin was in place")
        XCTAssertEqual(try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Celeste/b.bin")).count, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent("Celeste/.b.bin.part").path))
    }

    func testNotEnoughSpaceStopsBeforeCopying() async throws {
        try file("big.bin", String(repeating: "z", count: 1000))
        let plan = try GameImporter.plan(.folder(src))
        do {
            _ = try await importer(free: 1000).run(plan, folder: "Celeste")
            XCTFail("expected a refusal")
        } catch let ImportError.insufficientSpace(needed, available) {
            XCTAssertEqual(needed, 1050)
            XCTAssertEqual(available, 1000)
        }
    }

    func testNamesWindowsCannotHoldAreRefused() throws {
        try file("game.exe")
        try file("Data/aux.dat")
        XCTAssertThrowsError(try GameImporter.plan(.folder(src))) { XCTAssertTrue("\($0)".contains("reserved"), "\($0)") }
        try FileManager.default.removeItem(at: src.appendingPathComponent("Data/aux.dat"))
        try file("Data/A.bin")
        try file("data/a.bin")
        XCTAssertThrowsError(try GameImporter.plan(.folder(src))) { XCTAssertTrue("\($0)".contains("case"), "\($0)") }
    }

    func testICloudPlaceholdersAskForADownload() throws {
        try file("game.exe")
        try file(".data.pak.icloud")
        XCTAssertThrowsError(try GameImporter.plan(.folder(src))) { XCTAssertEqual($0 as? ImportError, .notDownloaded(1)) }
    }

    func testAZipWithOneTopFolderImportsThatFolder() async throws {
        let zip = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/game", withExtension: "zip"))
        let plan = try GameImporter.plan(.zip(zip))
        XCTAssertEqual(plan.name, "Game")
        XCTAssertEqual(plan.files.map(\.path), ["data/big.bin", "game.exe", "readme.txt"])
        XCTAssertEqual(plan.skippedSymlinks, 1)
        let receipt = try await importer().run(plan, folder: "Game")
        XCTAssertEqual(receipt.importedFrom, "game.zip")
        let big = try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Game/data/big.bin"))
        XCTAssertEqual(SHA1.hash([UInt8](big)).hex, "1da63ba332c31bd5c9b132c4cf0eb7b16eb7c68e")
    }

    func testUniqueFolderNames() {
        XCTAssertEqual(GameImporter.uniqueFolder("Celeste", existing: ["Hollow Knight"]), "Celeste")
        XCTAssertEqual(GameImporter.uniqueFolder("Celeste", existing: ["celeste"]), "Celeste 2")
        XCTAssertEqual(GameImporter.uniqueFolder("Celeste", existing: ["celeste"], taken: ["Celeste 2"]), "Celeste 3")
        XCTAssertEqual(GameImporter.uniqueFolder("con", existing: []), "Game")
        XCTAssertEqual(GameImporter.uniqueFolder(".hidden", existing: []), "Game")
    }

    func testAGOGFolderIsAGOGCopy() async throws {
        try file("bin/launcher.exe")
        try file("bin/game.exe")
        try file("steam_appid.txt", "367520\n")
        try file("goggame-1207664663.info", """
        {"gameId":"1207664663","rootGameId":"1207664663","name":"A GOG Game","buildId":"57107",
         "playTasks":[{"category":"launcher","type":"FileTask","path":"bin\\\\launcher.exe"},
                      {"isPrimary":true,"category":"game","type":"FileTask","path":"BIN\\\\GAME.EXE","arguments":"-windowed \\"-name x\\""}]}
        """)
        try file("goggame-1207664664.info", #"{"gameId":"1207664664","rootGameId":"1207664663","name":"A DLC"}"#)
        let receipt = try await importer().run(try GameImporter.plan(.folder(src)), folder: "Celeste")
        XCTAssertEqual(receipt.key, StoreGameKey(store: .gog, id: "1207664663"))
        XCTAssertEqual(receipt.name, "A GOG Game")
        XCTAssertEqual(receipt.version, "57107")
        XCTAssertEqual(receipt.executable, #"bin\game.exe"#)
        XCTAssertEqual(receipt.arguments, ["-windowed", "-name x"])
        XCTAssertEqual(receipt.hintSteamAppID, 367520)
        XCTAssertEqual(layout.receiptFile(receipt.key).lastPathComponent, "gog-1207664663.json")
        let c = Adoption.scan(games: layout.gamesRoot, cohort: Cohort(titles: []), receipts: [],
                              storeReceipts: layout.storeReceipts(), previous: Catalog())
        XCTAssertEqual(c.titles.map(\.id), ["gog-1207664663"])
        XCTAssertEqual(c.titles.first?.source, .imported)
        XCTAssertNil(c.titles.first?.appID, "steam_appid.txt is a hint only")
    }

    func testAnEpicFolderCopiedInSomeOtherWayIsFoundAsEpics() throws {
        let games = layout.gamesRoot
        try file("Sugar/Sugar.exe", in: games)
        try file("Sugar/.egstore/ABC.mancpn", #"{"FormatVersion":0,"AppName":"Sugar","CatalogNamespace":"ns","CatalogItemId":"x"}"#, in: games)
        try file("Plain/plain.exe", in: games)
        let c = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], previous: Catalog())
        XCTAssertEqual(c.titles.map(\.id).sorted(), ["dir-plain", "epic-Sugar"])
        XCTAssertEqual(c.titles.first { $0.id == "epic-Sugar" }?.store, .epic)
    }

    func testTheExecutablePickerRanksAndThePlayersPickSticks() throws {
        let games = layout.gamesRoot
        try file("Kingdom/Bin/Win64/KingdomCome.exe", in: games)
        try file("Kingdom/Bin/Win32/KingdomCome.exe", in: games)
        try file("Kingdom/_CommonRedist/vc_redist.x64.exe", in: games)
        try file("Kingdom/Tools/Editor.exe", in: games)
        let dir = games.appendingPathComponent("Kingdom")
        XCTAssertEqual(Adoption.candidates(in: dir, folder: "Kingdom"),
                       [#"Bin\Win64\KingdomCome.exe"#, #"Bin\Win32\KingdomCome.exe"#, #"_CommonRedist\vc_redist.x64.exe"#, #"Tools\Editor.exe"#])
        var c = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], previous: Catalog())
        XCTAssertEqual(c.titles.first?.executable, #"Bin\Win64\KingdomCome.exe"#)
        c.update("dir-kingdom") {
            $0.chosenExecutable = #"bin\win32\kingdomcome.exe"#
            $0.displayName = "Kingdom Come"
        }
        let again = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], previous: c)
        XCTAssertEqual(again.titles.first?.executable, #"Bin\Win32\KingdomCome.exe"#)
        XCTAssertEqual(again.titles.first?.name, "Kingdom Come")
        XCTAssertEqual(again.titles.first?.id, "dir-kingdom", "a name is display only")
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [GameImporter.Progress] = []
    func add(_ p: GameImporter.Progress) { lock.withLock { all.append(p) } }
    var first: GameImporter.Progress? { lock.withLock { all.first } }
}

final class PEIconTests: XCTestCase {
    func testTheLargestIconComesOutAsAOneImageIco() throws {
        let exe = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/icon", withExtension: "exe"))
        let ico = [UInt8](try XCTUnwrap(PEIcon.ico(of: exe)))
        XCTAssertEqual(Array(ico[0..<6]), [0, 0, 1, 0, 1, 0])
        XCTAssertEqual(ico[6], 48, "the 48-pixel image over the 16-pixel one")
        XCTAssertEqual(ico.readLE32(at: 18), 22)
        XCTAssertEqual(Array(ico[22..<26]), [0x89, 0x50, 0x4E, 0x47], "its PNG")
        XCTAssertEqual(Int(ico.readLE32(at: 14)), ico.count - 22)
    }

    func testAnExecutableWithoutIconsOrNoPEGivesNone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.exe")
        try Data("MZ but nothing more".utf8).write(to: junk)
        XCTAssertNil(PEIcon.ico(of: junk))
        XCTAssertNil(PEIcon.ico(of: dir.appendingPathComponent("missing.exe")))
    }
}
