// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// PLA-840 (decisions 0169, 0183): the Social Club layout engages for a Play whose game folder holds a
/// Rockstar bootstrap Playport verified by hash, or for the launcher's Open when the Launcher.exe it
/// starts is verified; a title or launcher key plays no part.
final class SocialClubBootstrapTests: XCTestCase {
    // FIPS 180-2's SHA-256 test vectors, not computed here.
    static let abc = Data("abc".utf8)
    static let abcSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let long = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
    static let longSHA = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

    /// Entries shaped like the shipped ones, with the test vectors' bytes.
    static let table = [
        SocialClubBootstrap(name: "Test game", place: .game, files: [
            .init(path: "PlayRDR2.exe", size: 3, sha256: abcSHA),
            .init(path: "Redistributables/Rockstar-Games-Launcher.exe", size: 56, sha256: longSHA),
        ]),
        SocialClubBootstrap(name: "Test launcher", place: .launcher, files: [
            .init(path: "Launcher.exe", size: 56, sha256: longSHA),
        ]),
    ]

    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("scb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Redistributables"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func put(_ data: Data, _ path: String) throws {
        try data.write(to: folder.appendingPathComponent(path))
    }

    func check(_ cache: inout SocialClubBootstrap.HashCache, _ place: SocialClubBootstrap.Place = .game,
               dev: Bool = true) -> SocialClubBootstrap.Verdict {
        SocialClubBootstrap.check(folder: folder, place: place, table: Self.table, cache: &cache, hashMismatches: dev)
    }

    func testAVerifiedBootstrapEngagesTheLayout() throws {
        try put(Self.abc, "PlayRDR2.exe")
        try put(Self.long, "Redistributables/Rockstar-Games-Launcher.exe")
        var cache = SocialClubBootstrap.HashCache()
        let v = check(&cache)
        XCTAssertTrue(v.engaged)
        XCTAssertEqual(v.bootstrap?.name, "Test game")
        XCTAssertEqual(v.logLines(hashes: true), ["the Social Club layout is on: verified Rockstar bootstrap Test game "
                                                  + "(PlayRDR2.exe, Redistributables/Rockstar-Games-Launcher.exe)"])
    }

    func testAFolderWithoutTheBootstrapHoldsNoLayout() {
        var cache = SocialClubBootstrap.HashCache()
        let v = check(&cache)
        XCTAssertFalse(v.engaged)
        XCTAssertEqual(v.observed, [])
        XCTAssertEqual(v.logLines(hashes: true), ["the Social Club layout is off: no Rockstar bootstrap in the game's folder"])
    }

    func testOneFileOfTheBootstrapAloneIsNotEnough() throws {
        try put(Self.abc, "PlayRDR2.exe")
        var cache = SocialClubBootstrap.HashCache()
        XCTAssertFalse(check(&cache).engaged)
    }

    /// Same sizes, other bytes (a Steam update of PlayRDR2.exe): no layout, and a dev build logs the hash to add.
    func testAnUnverifiedBootstrapHoldsNoLayoutAndADevBuildLogsItsHash() throws {
        try put(Data("abd".utf8), "PlayRDR2.exe")
        try put(Self.long, "Redistributables/Rockstar-Games-Launcher.exe")
        var cache = SocialClubBootstrap.HashCache()
        let v = check(&cache)
        XCTAssertFalse(v.engaged)
        XCTAssertEqual(v.logLines(hashes: true), [
            "the Social Club layout is off: the Rockstar bootstrap in the game's folder is not one Playport verified",
            // sha256("abd"), from sha256sum
            "bootstrap PlayRDR2.exe: 3 B, sha256 a52d159f262b2c6ddb724a61840befc36eb30c88877a4030b65cbe86298449c9, not in the table",
            "bootstrap Redistributables/Rockstar-Games-Launcher.exe: 56 B, verified",
        ])
        XCTAssertFalse(v.logLines(hashes: false).joined().contains("a52d159f"))
    }

    /// A size no entry has is hashed only for a dev build's log; a release build reads no such file.
    func testAFileOfAnotherSizeIsHashedOnlyForADevBuild() throws {
        try put(Data("abcd".utf8), "PlayRDR2.exe")
        var release = SocialClubBootstrap.HashCache()
        let r = check(&release, dev: false)
        XCTAssertEqual(r.observed.map(\.sha256), [nil])
        XCTAssertEqual(release, .init())
        XCTAssertEqual(r.logLines(hashes: false).last, "bootstrap PlayRDR2.exe: 4 B, not in the table")
        var dev = SocialClubBootstrap.HashCache()
        // sha256("abcd"), from sha256sum
        XCTAssertEqual(check(&dev).observed.map(\.sha256),
                       ["88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589"])
    }

    /// The 111 MB installer is not read at every Play: a file whose size and modification time are as
    /// last hashed keeps its hash; a new modification time reads it again.
    func testAFileUnchangedInSizeAndTimeIsNotReadAgain() throws {
        let fm = FileManager.default
        let exe = folder.appendingPathComponent("PlayRDR2.exe").path
        let then = Date(timeIntervalSince1970: 1_760_000_000)
        try put(Self.abc, "PlayRDR2.exe")
        try fm.setAttributes([.modificationDate: then], ofItemAtPath: exe)
        try put(Self.long, "Redistributables/Rockstar-Games-Launcher.exe")
        var cache = SocialClubBootstrap.HashCache()
        XCTAssertTrue(check(&cache).engaged)
        try put(Data("abd".utf8), "PlayRDR2.exe")
        try fm.setAttributes([.modificationDate: then], ofItemAtPath: exe)
        XCTAssertTrue(check(&cache).engaged)
        try fm.setAttributes([.modificationDate: then.addingTimeInterval(60)], ofItemAtPath: exe)
        XCTAssertFalse(check(&cache).engaged)
    }

    func testTheCacheSurvivesAsJSON() throws {
        try put(Self.abc, "PlayRDR2.exe")
        var cache = SocialClubBootstrap.HashCache()
        _ = check(&cache)
        let back = try JSONDecoder().decode(SocialClubBootstrap.HashCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(back, cache)
        XCTAssertEqual(cache.entries.count, 1)
    }

    /// The launcher's Open: the Launcher.exe it starts, in the launcher's install folder.
    func testAVerifiedLauncherEngagesTheOpensLayoutAndAnUnverifiedOneDoesNot() throws {
        try put(Self.long, "Launcher.exe")
        var cache = SocialClubBootstrap.HashCache()
        let v = check(&cache, .launcher)
        XCTAssertTrue(v.engaged)
        XCTAssertEqual(v.logLines(hashes: true), ["the Social Club layout is on: verified Rockstar bootstrap Test launcher (Launcher.exe)"])
        try put(Data(Self.long.reversed()), "Launcher.exe")   // a self-update Playport has not verified
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_760_000_000)],
                                              ofItemAtPath: folder.appendingPathComponent("Launcher.exe").path)
        let u = check(&cache, .launcher)
        XCTAssertFalse(u.engaged)
        XCTAssertEqual(u.logLines(hashes: false).first,
                       "the Social Club layout is off: the Rockstar bootstrap in the launcher's folder is not one Playport verified")
    }

    /// Each entry counts only in its own folder: a game folder's Launcher.exe (The Witcher 2 ships one)
    /// is not read, and a launcher folder holding the game's files is no game.
    func testAnEntryCountsOnlyInItsOwnFolder() throws {
        try put(Self.long, "Launcher.exe")
        var cache = SocialClubBootstrap.HashCache()
        let game = check(&cache, .game)
        XCTAssertFalse(game.engaged)
        XCTAssertEqual(game.observed, [])
        XCTAssertEqual(cache, .init())
        try put(Self.abc, "PlayRDR2.exe")
        try put(Self.long, "Redistributables/Rockstar-Games-Launcher.exe")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Launcher.exe"))
        XCTAssertFalse(check(&cache, .launcher).engaged)
    }

    /// The launcher plays no part: Rockstar's launcher carries no layout key, so neither RDR2's Play
    /// nor the Open gets one from it in either build.
    func testRockstarsLauncherCarriesNoLayoutKey() {
        let key = "env." + GameSocialClubEndPolicy.layoutVariable
        XCTAssertNil(PublisherLauncher.rockstar.runtime[key])
        XCTAssertNil(PublisherLauncher.rockstar.openSettings(saved: nil).config[key])
        let plain = LaunchSettings.resolve(game: nil, global: LaunchSettings())
        XCTAssertNil(PublisherLauncher.rockstar.startingGame(plain).settings.runtime[key])
        XCTAssertNil(LaunchSettings.everyGameKeys[key])
    }

    /// The shipped table: RDR2's Steam copy (PlayRDR2.exe and depot 1899671's installer, recorded in
    /// docs/evidence/2026-10-15-rockstar-launcher-recon.md and 2026-10-18-rockstar-desktop-comparison.md)
    /// and Rockstar's launcher 1.0.109.3031.
    func testTheShippedTableNamesRDR2sSteamBootstrapAndTheLauncher() {
        let rdr2 = SocialClubBootstrap.verified.first { $0.place == .game }
        XCTAssertEqual(rdr2?.files.map(\.path), ["PlayRDR2.exe", "Redistributables/Rockstar-Games-Launcher.exe"])
        XCTAssertEqual(rdr2?.files.first?.sha256.prefix(8), "028db16c")
        XCTAssertEqual(rdr2?.files.last?.sha256, "321886457b7e4ab727a27671c17a815684a3943579eedf7e2248a3b9f0973746")
        let launcher = SocialClubBootstrap.verified.first { $0.place == .launcher }
        XCTAssertEqual(launcher?.files.map(\.path), [PublisherLauncher.rockstar.executable])
        for b in SocialClubBootstrap.verified {
            for f in b.files {
                XCTAssertTrue(f.size > 0, f.path)
                XCTAssertTrue(f.sha256.count == 64 && f.sha256.allSatisfy { "0123456789abcdef".contains($0) }, f.path)
            }
        }
    }
}
