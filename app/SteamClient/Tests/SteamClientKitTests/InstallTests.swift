// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ContentKit
@testable import SteamClientKit

/// Serves chunk plaintext from memory and counts what it served.
final class FakeChunkSource: ChunkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [[UInt8]: [UInt8]] = [:]
    private var served: [[UInt8]] = []
    var failWith: SteamError?

    func add(_ bytes: [UInt8]) { lock.withLock { store[SHA1.hash(bytes)] = bytes } }
    var fetches: Int { lock.withLock { served.count } }
    func reset() { lock.withLock { served.removeAll() } }

    func chunk(depotID: UInt32, _ c: ContentManifestPayload.Chunk) async throws -> [UInt8] {
        if let e = lock.withLock({ failWith }) { throw e }
        return try lock.withLock {
            guard let b = store[c.sha] else { throw SteamError.notFound("chunk") }
            served.append(c.sha)
            return b
        }
    }
}

/// Builds manifest files from content, cut into fixed-size chunks.
struct Fixture {
    let source = FakeChunkSource()

    func file(_ path: String, _ content: [UInt8], chunk: Int = 4) -> DepotManifest.File {
        var chunks: [ContentManifestPayload.Chunk] = []
        var off = 0
        while off < content.count {
            let piece = Array(content[off..<min(off + chunk, content.count)])
            source.add(piece)
            chunks.append(.init(sha: SHA1.hash(piece), crc: SteamAdler32.checksum(piece), offset: UInt64(off),
                                cbOriginal: UInt32(piece.count), cbCompressed: 0))
            off += chunk
        }
        return DepotManifest.File(path: path, size: UInt64(content.count), flags: 0,
                                  shaContent: content.isEmpty ? nil : SHA1.hash(content), chunks: chunks, linkTarget: nil)
    }

    func directory(_ path: String) -> DepotManifest.File {
        DepotManifest.File(path: path, size: 0, flags: DepotFileFlag.directory, shaContent: nil, chunks: [], linkTarget: nil)
    }
}

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

func scratchDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("steamclient-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class HashStreamTests: XCTestCase {
    func testSHA1StreamMatchesOneShotAcrossSplits() {
        XCTAssertEqual(SHA1.hash(bytes("abc")).hex, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hash([]).hex, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        let data = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let want = SHA1.hash(data)
        for split in [1, 7, 63, 64, 65, 500] {
            var s = SHA1Stream()
            var i = 0
            while i < data.count { s.update(Array(data[i..<min(i + split, data.count)])); i += split }
            XCTAssertEqual(s.finalize(), want, "split \(split)")
        }
    }

    func testSHA256KnownAnswers() {
        XCTAssertEqual(SHA256Stream.hash(bytes("abc")).hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Stream.hash([]).hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var s = SHA256Stream()
        for _ in 0..<10 { s.update(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) }
        var one = [UInt8]()
        for _ in 0..<10 { one += bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") }
        XCTAssertEqual(s.finalize(), SHA256Stream.hash(one))
    }
}

final class DepotSelectionTests: XCTestCase {
    func depot(_ id: UInt32, os: [String] = ["windows"], arch: String? = nil, gid: UInt64? = 1, from: UInt32? = nil,
               dlc: UInt32? = nil, language: String? = nil, lowViolence: Bool = false) -> DepotInfo {
        DepotInfo(depotID: id, name: nil, osList: os, osArch: arch, publicManifestGID: gid, publicManifestSize: nil,
                  publicManifestDownload: nil, depotFromApp: from, sharedInstall: from != nil, dlcAppID: dlc,
                  encryptedManifestsOnly: false, language: language, lowViolence: lowViolence)
    }

    var app: AppDepots {
        AppDepots(appID: 10, name: "T", publicBuildID: 5, changeNumber: nil, depots: [
            depot(11, os: []),                  // OS-neutral content
            depot(12),                          // Windows
            depot(13, os: ["linux"]),
            depot(14, arch: "32"),
            depot(15, arch: "64"),
            depot(16, from: 228980),            // redistributable
            depot(17, dlc: 99),
            depot(18, dlc: 98),
            depot(19, language: "german"),
            depot(20, lowViolence: true),
            depot(21, gid: nil),
            depot(22, os: ["macos"]),
        ], installDir: "Title")
    }

    func testAutomaticSelectionFilters() throws {
        // A depot no owned package lists is left out (Steam denies its key); nil tries every one.
        let owned = try DepotSelection.select(app, .init(ownedDLC: [99], ownedDepots: [11, 15, 17]))
        XCTAssertEqual(owned.depots.map(\.depotID), [11, 15, 17])
        XCTAssertEqual(owned.skipped.first { $0.depotID == 12 }?.reason, "not in an owned package")
        XCTAssertEqual(owned.skipped.first { $0.depotID == 18 }?.reason, "DLC app 98 not owned")
        let s = try DepotSelection.select(app, .init(language: "english", ownedDLC: [99]))
        XCTAssertEqual(s.depots.map(\.depotID), [11, 12, 15, 17])
        let reasons = Dictionary(uniqueKeysWithValues: s.skipped.map { ($0.depotID, $0.reason) })
        XCTAssertEqual(reasons[13], "os linux")
        XCTAssertEqual(reasons[14], "osarch 32")
        XCTAssertTrue(reasons[16]!.contains("redistributable"))
        XCTAssertEqual(reasons[18], "DLC app 98 not owned")
        XCTAssertEqual(reasons[19], "language german")
        XCTAssertEqual(reasons[20], "low-violence variant")
        XCTAssertEqual(reasons[21], "no public manifest")
        XCTAssertEqual(s.skipped.count, 8)
        // The chosen language adds its split depot; anonymous sessions own no DLC.
        XCTAssertEqual(try DepotSelection.select(app, .init(language: "German")).depots.map(\.depotID), [11, 12, 15, 19])
    }

    func testExplicitSelection() throws {
        XCTAssertEqual(try DepotSelection.select(app, .init(explicit: [13, 12])).depots.map(\.depotID), [12, 13])
        XCTAssertThrowsError(try DepotSelection.select(app, .init(explicit: [16])))   // redistributable
        XCTAssertThrowsError(try DepotSelection.select(app, .init(explicit: [21])))   // no manifest
        XCTAssertThrowsError(try DepotSelection.select(app, .init(explicit: [999])))  // unknown
        let none = AppDepots(appID: 1, name: "x", publicBuildID: nil, changeNumber: nil, depots: [depot(2, os: ["linux"])])
        XCTAssertThrowsError(try DepotSelection.select(none))
    }

    func testPICSParsingOfSelectionFields() throws {
        let vdf = """
        "4020"
        {
            "common" { "name" "Server" }
            "config" { "installdir" "GarrysModDS" }
            "depots"
            {
                "1004" { "depotfromapp" "1007" "sharedinstall" "1" }
                "4021" { "manifests" { "public" { "gid" "81" "size" "665" } } }
                "4022" { "config" { "oslist" "windows" "osarch" "64" "language" "German" "lowviolence" "1" } "manifests" { "public" { "gid" "87" } } }
                "branches" { "public" { "buildid" "25375525" } }
            }
        }
        """
        let d = try Library.parseDepots(appID: 4020, try KeyValue.parseText(Array(vdf.utf8)))
        XCTAssertEqual(d.installDir, "GarrysModDS")
        XCTAssertEqual(d.publicBuildID, 25375525)
        let byID = Dictionary(uniqueKeysWithValues: d.depots.map { ($0.depotID, $0) })
        XCTAssertEqual(byID[1004]?.depotFromApp, 1007)
        XCTAssertEqual(byID[4022]?.language, "german")
        XCTAssertEqual(byID[4022]?.lowViolence, true)
        XCTAssertNil(byID[4021]?.language)
        XCTAssertEqual(try DepotSelection.select(d).depots.map(\.depotID), [4021])
    }

    /// Counter-Strike (10) installs into Half-Life (70)'s folder, and its engine
    /// (hl.exe, depot 2) and base content (depot 1) are app 70's depots: they are
    /// content to install with app 70's manifests and keys. The Steamworks Common
    /// Redistributables depot (228980, `Steamworks Shared`) stays out.
    func testCounterStrikeInstallsHalfLifesSharedDepots() throws {
        let cs = """
        "10"
        {
            "common" { "name" "Counter-Strike" "type" "Game" }
            "config" { "installdir" "Half-Life" }
            "depots"
            {
                "1" { "config" { "language" "" } "depotfromapp" "70" "sharedinstall" "2" }
                "11" { "manifests" { "public" { "gid" "3018" "size" "292340389" } "steam_legacy" { "gid" "4720" } } }
                "12" { "config" { "language" "french" } "manifests" { "public" { "gid" "7476" } } }
                "141" { "config" { "language" "russian" } "depotfromapp" "70" "sharedinstall" "2" }
                "2" { "config" { "language" "" "oslist" "windows" } "depotfromapp" "70" "sharedinstall" "2" }
                "228988" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
                "branches" { "public" { "buildid" "12934623" } "steam_legacy" { "buildid" "100" } }
            }
        }
        """
        let hl = """
        "70"
        {
            "common" { "name" "Half-Life" "type" "Game" }
            "config" { "installdir" "Half-Life" }
            "depots"
            {
                "1" { "manifests" { "public" { "gid" "2667" "size" "513399519" } "steam_legacy" { "gid" "2668" } } }
                "141" { "config" { "language" "russian" } "manifests" { "public" { "gid" "1410" } } }
                "2" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "7242" "size" "49814373" } } }
                "branches" { "public" { "buildid" "12934623" } }
            }
        }
        """
        let redist = """
        "228980"
        {
            "common" { "name" "Steamworks Common Redistributables" "type" "Tool" }
            "config" { "installdir" "Steamworks Shared" }
            "depots" { "228988" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "9" } } } }
        }
        """
        let parse = { (id: UInt32, vdf: String) in try Library.parseDepots(appID: id, try KeyValue.parseText(Array(vdf.utf8))) }
        let app = try parse(10, cs)
        // Without its source apps' records every borrowed depot stays a redistributable, as before.
        XCTAssertEqual(try DepotSelection.select(app).depots.map(\.depotID), [11])

        let resolved = app.resolvingSharedInstalls([70: try parse(70, hl), 228980: try parse(228980, redist)])
        let s = try DepotSelection.select(resolved)
        XCTAssertEqual(s.depots.map(\.depotID), [1, 11, 2])
        XCTAssertEqual(s.depots.map(\.publicManifestGID), [2667, 3018, 7242])
        let reasons = Dictionary(uniqueKeysWithValues: s.skipped.map { ($0.depotID, $0.reason) })
        XCTAssertEqual(reasons[228988], "shared install from app 228980 (redistributable, not installed)")
        XCTAssertEqual(reasons[141], "language russian")
        // Keys and manifest request codes are asked for the source app.
        XCTAssertEqual(resolved.keyAppID(depot: 1), 70)
        XCTAssertEqual(resolved.keyAppID(depot: 2), 70)
        XCTAssertEqual(resolved.keyAppID(depot: 11), 10)
        XCTAssertEqual(resolved.keyAppID(depot: 228988), 10)
        // An owned-depot list without app 70's depots leaves them out rather than failing at the key.
        XCTAssertEqual(try DepotSelection.select(resolved, .init(ownedDepots: [11])).skipped.first { $0.depotID == 1 }?.reason,
                       "not in an owned package")
        // A branch takes the source app's manifest for that branch; one it lacks leaves the depot out.
        let legacy = try DepotSelection.select(try resolved.onBranch("steam_legacy"))
        XCTAssertEqual(legacy.depots.map(\.depotID), [1, 11])
        XCTAssertEqual(legacy.depots.map(\.publicManifestGID), [2668, 4720])
        XCTAssertEqual(try DepotSelection.select(resolved, .init(explicit: [2])).depots.map(\.depotID), [2])
        XCTAssertThrowsError(try DepotSelection.select(resolved, .init(explicit: [228988])))
    }

    /// Red Dead Redemption 2 (1174180) lists depot 1899671, Rockstar's installers, from the config app
    /// 1899670 (`RGLSC`) with no `sharedinstall`, and its manifest in the game's own record: Steam
    /// installs it into the game's folder (PLA-365), as it does the game's own depots. The two
    /// Steamworks Common Redistributables depots stay shared installs. PICS as read on 2026-10-15.
    func testRedDeadRedemption2InstallsRockstarsInstallerDepotInItsFolder() throws {
        let rdr2 = """
        "1174180"
        {
            "common" { "name" "Red Dead Redemption 2" "type" "Game" }
            "config" { "installdir" "Red Dead Redemption 2" }
            "depots"
            {
                "228987" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
                "228990" { "config" { "oslist" "windows" } "depotfromapp" "228980" "sharedinstall" "1" }
                "1174181" { "manifests" { "public" { "gid" "4757128409362785099" "size" "746" "download" "528" } } }
                "1174182" { "manifests" { "public" { "gid" "2258488483491377476" } } }
                "1174183" { "manifests" { "public" { "gid" "4785346550216140531" } } }
                "1174184" { "manifests" { "public" { "gid" "2698939236196220127" } } }
                "1174185" { "manifests" { "public" { "gid" "8173342615013177810" } } }
                "1174186" { "manifests" { "public" { "gid" "357926288062992323" } } }
                "1899671" { "manifests" { "public" { "gid" "3914969219305676290" "size" "239826989" "download" "209058416" } } "depotfromapp" "1899670" }
                "branches" { "public" { "buildid" "13773296" } }
            }
        }
        """
        let app = try Library.parseDepots(appID: 1174180, try KeyValue.parseText(Array(rdr2.utf8)))
        let s = try DepotSelection.select(app)
        XCTAssertEqual(s.depots.map(\.depotID), [1174181, 1174182, 1174183, 1174184, 1174185, 1174186, 1899671])
        XCTAssertEqual(s.depots.last?.publicManifestGID, 3914969219305676290)
        XCTAssertEqual(s.skipped.map(\.depotID), [228987, 228990])
        XCTAssertEqual(s.skipped.map(\.reason), [DepotSelection.sharedInstallReason(228980), DepotSelection.sharedInstallReason(228980)])
        // Its key and manifest request code are asked for the source app, as for Half-Life's depots.
        XCTAssertEqual(app.keyAppID(depot: 1899671), 1899670)
        XCTAssertEqual(app.keyAppID(depot: 1174181), 1174180)
        XCTAssertEqual(try DepotSelection.select(app, .init(explicit: [1899671])).depots.map(\.depotID), [1899671])
        // A `sharedinstall` depot of an app other than 228980 is left out, with a reason no older record gave.
        var other = app
        other.depots[8].sharedInstall = true
        let reason = try DepotSelection.select(other).skipped.first { $0.depotID == 1899671 }?.reason
        XCTAssertEqual(reason, "shared install in app 1899670's own folder (not installed)")
        XCTAssertNil(DepotSelection.sharedInstall(skipped: "1899671: \(reason!)"))
    }

    /// A record written before that rule (the phone's RDR2 install of 2026-10-15) left depot 1899671
    /// out as a redistributable: a repair checks it with Steam again; 228980's are not rechecked.
    func testAnOlderRecordsOtherAppDepotsAreRecheckedAtRepair() {
        let r = InstallReceipt(appID: 1174180, name: "Red Dead Redemption 2", installDir: "Red Dead Redemption 2", buildID: 13773296,
                               depots: [DepotRef(depotID: 1174181, gid: 4757128409362785099)], files: 120, bytes: 1,
                               skippedDepots: ["228987: shared install from app 228980 (redistributable, not installed)",
                                               "228990: shared install from app 228980 (redistributable, not installed)",
                                               "1899671: shared install from app 1899670 (redistributable, not installed)"],
                               skippedSymlinks: 0, installedAt: "-")
        XCTAssertEqual(r.depotsToRecheck, [1899671])
        XCTAssertEqual(r.commonRedistributableDepots, [228987, 228990])
        var now = r
        now.skippedDepots[2] = "1899671: shared install in app 1899670's own folder (not installed)"
        XCTAssertEqual(now.depotsToRecheck, [])
    }

    /// The launch entry an install records: Counter-Strike's `hl.exe -steam -game cstrike`,
    /// Windows only (macOS and Linux start `hl.sh`); Half-Life's own carries just `-steam`.
    func testTheWindowsLaunchEntryCarriesItsArguments() throws {
        let launch = { (id: UInt32, args: String) in """
        "\(id)"
        {
            "common" { "name" "GoldSrc" "type" "Game" }
            "config"
            {
                "installdir" "Half-Life"
                "launch"
                {
                    "0" { "executable" "hl.exe" "arguments" "\(args)" "config" { "oslist" "windows" } }
                    "1" { "executable" "hl.sh" "arguments" "\(args)" "config" { "oslist" "macos" } }
                    "2" { "executable" "hl.sh" "arguments" "\(args)" "config" { "oslist" "linux" } }
                }
            }
        }
        """ }
        let cs = try SteamAppInfo.parse(appID: 10, try KeyValue.parseText(Array(launch(10, "-steam -game cstrike").utf8)))
        XCTAssertEqual(cs.windowsLaunch?.executable, "hl.exe")
        XCTAssertEqual(cs.windowsLaunch?.arguments, "-steam -game cstrike")
        let hl = try SteamAppInfo.parse(appID: 70, try KeyValue.parseText(Array(launch(70, "-steam").utf8)))
        XCTAssertEqual(hl.windowsLaunch?.arguments, "-steam")
    }

    /// The size a page and Downloads show counts only what an install takes:
    /// RC Cars lists a Russian and a Polish depot beside its content, which
    /// made it read 1.15 GB for a 0.99 GB install.
    func testInstallSizeLeavesOutOtherLanguages() throws {
        let vdf = """
        "289460"
        {
            "common" { "name" "RC Cars" "type" "Game" }
            "depots"
            {
                "228990" { "depotfromapp" "228980" "sharedinstall" "1" "config" { "oslist" "windows" } }
                "289461" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "1" "size" "985786348" } } }
                "289462" { "config" { "oslist" "windows" "language" "russian" } "manifests" { "public" { "gid" "2" "size" "157255481" } } }
                "289463" { "config" { "oslist" "windows" "language" "polish" } "manifests" { "public" { "gid" "3" "size" "7369974" } } }
                "289464" { "config" { "oslist" "windows" "lowviolence" "1" } "manifests" { "public" { "gid" "4" "size" "5" } } }
                "branches" { "public" { "buildid" "20319773" } }
            }
        }
        """
        let info = try SteamAppInfo.parse(appID: 289460, try KeyValue.parseText(Array(vdf.utf8)))
        XCTAssertEqual(info.windowsContentDepots.map(\.depotID), [289461])
        XCTAssertEqual(info.installSize, 985786348)
        XCTAssertEqual(try DepotSelection.select(info.depots).depots.map(\.depotID), [289461])
    }

    /// A beta in the clear (The Witcher 3's `classic`) and a password one.
    func testBranches() throws {
        let vdf = """
        "292030"
        {
            "common" { "name" "W3" }
            "depots"
            {
                "292031" { "manifests" { "public" { "gid" "10" "size" "100" } "classic" { "gid" "20" "size" "200" } } }
                "292032" { "manifests" { "public" { "gid" "11" "size" "110" } } }
                "292033" { "manifests" { "classic" "21" } }
                "292034" { "manifests" { "public" { "gid" "12" } } "encryptedmanifests" { "qa" { "gid" "x" } } }
                "branches"
                {
                    "public" { "buildid" "900" "timeupdated" "1700000000" }
                    "classic" { "buildid" "3280809" "description" "1.32 (DX11)" "timeupdated" "1600000000" }
                    "qa" { "buildid" "901" "pwdrequired" "1" }
                    "empty" { "buildid" "902" }
                }
            }
        }
        """
        let d = try Library.parseDepots(appID: 292030, try KeyValue.parseText(Array(vdf.utf8)))
        XCTAssertEqual(d.branches?.count, 4)
        XCTAssertEqual(d.installableBranches.map(\.name), ["public", "classic"])
        XCTAssertEqual(d.buildID(branch: "classic"), 3280809)
        XCTAssertEqual(d.buildID(branch: "public"), 900)

        let classic = try d.onBranch("classic")
        XCTAssertEqual(classic.publicBuildID, 3280809)
        XCTAssertEqual(try DepotSelection.select(classic).depots.map { $0.publicManifestGID }, [20, 21])
        XCTAssertEqual(try DepotSelection.select(d).depots.map { $0.publicManifestGID }, [10, 11, 12])
        XCTAssertEqual(try d.onBranch("public"), d)
        XCTAssertThrowsError(try d.onBranch("qa"))       // password
        XCTAssertThrowsError(try d.onBranch("missing"))

        let info = try SteamAppInfo.parse(appID: 292030, try KeyValue.parseText(Array(vdf.utf8)))
        XCTAssertEqual(info.installSize(branch: "classic"), 200)
        XCTAssertEqual(info.installSize, 210)
    }
}

final class InstallPlanTests: XCTestCase {
    func testLaterDepotOverridesByPathWithoutCase() throws {
        let fx = Fixture()
        let a = try DepotManifest(depotID: 1, gid: 100, files: [
            fx.file("a.txt", bytes("version one")), fx.file("Bin/x.dll", bytes("xdll")), fx.directory("data"),
            fx.file("empty.cfg", []),
        ])
        let b = try DepotManifest(depotID: 2, gid: 200, files: [
            fx.file("A.TXT", bytes("version two!")), fx.file("new.txt", bytes("n")),
            DepotManifest.File(path: "link", size: 0, flags: DepotFileFlag.symlink, shaContent: nil, chunks: [], linkTarget: "new.txt"),
        ])
        let plan = try InstallPlan.make(appID: 9, buildID: 3, manifests: [a, b])
        XCTAssertEqual(plan.files.map(\.path), ["A.TXT", "Bin/x.dll", "empty.cfg", "new.txt"])
        let over = plan.files[0]
        XCTAssertEqual(over.depotID, 2)
        XCTAssertEqual(over.size, UInt64("version two!".utf8.count))
        XCTAssertEqual(plan.directories, ["data"])
        XCTAssertEqual(plan.skippedSymlinks, ["link"])
        XCTAssertEqual(plan.totalBytes, UInt64("version two!".utf8.count + 4 + 0 + 1))
        XCTAssertEqual(plan.files.map(\.firstChunk), [0, 3, 4, 4])
        XCTAssertEqual(plan.chunkCount, 5)
        XCTAssertEqual(plan.depots, [DepotRef(depotID: 1, gid: 100), DepotRef(depotID: 2, gid: 200)])
        // The order of depots decides the winner, so it is part of the identity.
        let reversed = try InstallPlan.make(appID: 9, buildID: 3, manifests: [b, a])
        XCTAssertEqual(reversed.files.first { $0.path.lowercased() == "a.txt" }?.depotID, 1)
        XCTAssertNotEqual(reversed.identity, plan.identity)
        XCTAssertEqual(plan.fileIndex(forChunk: 3), 1)
        XCTAssertEqual(plan.fileIndex(forChunk: 4), 3)
        XCTAssertNil(plan.fileIndex(forChunk: 5))
    }

    func testFileInOneDepotAndDirectoryInAnotherIsRefused() throws {
        let fx = Fixture()
        let a = try DepotManifest(depotID: 1, gid: 1, files: [fx.file("maps", bytes("file"))])
        let b = try DepotManifest(depotID: 2, gid: 2, files: [fx.file("maps/one.bsp", bytes("map"))])
        XCTAssertThrowsError(try InstallPlan.make(appID: 1, buildID: nil, manifests: [a, b])) { e in
            guard case SteamError.unsafeContent = e else { return XCTFail("\(e)") }
        }
    }

    func testRetainedManifestRoundTripAndRevalidation() throws {
        let fx = Fixture()
        let m = try DepotManifest(depotID: 7, gid: 77, creationTime: 5, files: [fx.file("a/b.bin", Array(repeating: 3, count: 10)), fx.directory("a")])
        let dir = try scratchDir("retained")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("7_77.json")
        try RetainedManifest.save(m, to: url)
        let back = try XCTUnwrap(try RetainedManifest.load(url))
        XCTAssertEqual(back.files.map(\.path), m.files.map(\.path))
        XCTAssertEqual(back.files[1].chunks, m.files[1].chunks)
        XCTAssertEqual(back.files[1].shaContent, m.files[1].shaContent)
        // A tampered path on disk is refused like a download would be.
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "a\\/b.bin", with: "..\\/b.bin")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RetainedManifest.load(url))
    }
}

final class InstallEngineTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws { dir = try scratchDir("engine") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    var tree: URL { dir.appendingPathComponent("staging/9_3", isDirectory: true) }
    var journal: URL { dir.appendingPathComponent("staging/9_3.journal") }

    func engine(_ source: ChunkSource, _ configure: (inout InstallEngine.Options) -> Void = { _ in }) -> InstallEngine {
        var o = InstallEngine.Options()
        o.concurrency = 1
        o.flushEveryChunks = 1
        configure(&o)
        var e = InstallEngine(tree: tree, journal: journal, source: source, log: .silent, options: o)
        e.freeSpace = { _ in 1 << 40 }
        return e
    }

    /// Two 16-byte files of four chunks each, a dedup pair, an empty file.
    func plan(_ fx: Fixture) throws -> InstallPlan {
        let m = try DepotManifest(depotID: 1, gid: 1, files: [
            fx.file("one.bin", bytes("AAAABBBBCCCCDDDD")),
            fx.file("sub/two.bin", bytes("EEEEFFFFGGGGHHHH")),
            fx.file("sub/copy.bin", bytes("AAAAZZZZ")),
            fx.file("zero.txt", []),
            fx.directory("saves"),
        ])
        return try InstallPlan.make(appID: 9, buildID: 3, manifests: [m])
    }

    func content(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: tree.appendingPathComponent(path)), as: UTF8.self)
    }

    func assertStaged() throws {
        XCTAssertEqual(try content("one.bin"), "AAAABBBBCCCCDDDD")
        XCTAssertEqual(try content("sub/two.bin"), "EEEEFFFFGGGGHHHH")
        XCTAssertEqual(try content("sub/copy.bin"), "AAAAZZZZ")
        XCTAssertEqual(try content("zero.txt"), "")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("saves").path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testFullStageDeduplicatesAndVerifies() async throws {
        let fx = Fixture()
        let p = try plan(fx)
        let r = try await engine(fx.source) { $0.concurrency = 4 }.run(p)
        try assertStaged()
        XCTAssertEqual(p.chunkCount, 10)
        XCTAssertEqual(fx.source.fetches, 9)          // "AAAA" once for two files
        XCTAssertEqual(r.chunksDownloaded, 9)
        XCTAssertEqual(r.chunksDeduped, 1)
        XCTAssertEqual(r.filesVerified, 4)
        XCTAssertEqual(r.bytes, 40)
    }

    func testJournalReplayAfterInterruptedRun() async throws {
        let fx = Fixture()
        let p = try plan(fx)
        do {
            _ = try await engine(fx.source) { $0.cancelAfterChunks = 6 }.run(p)
            XCTFail("expected a pause")
        } catch SteamError.cancelled {}
        XCTAssertEqual(fx.source.fetches, 6)
        // A torn record at the tail (the kill landed mid-append) is dropped.
        let h = try FileHandle(forWritingTo: journal)
        h.seekToEndOfFile()
        h.write(Data([1, 0, 0, 0, 9, 9]))
        try h.close()

        let (j, replay) = try InstallJournal.open(journal, plan: p.content)
        j.close()
        XCTAssertFalse(replay.fresh)
        XCTAssertEqual(replay.discardedBytes, 6)
        // Files sort as one.bin, sub/copy.bin, sub/two.bin, zero.txt. Six fetches
        // (AAAA..DDDD, ZZZZ, EEEE) finish one.bin and copy.bin (AAAA dedups
        // onto both); the empty file needs none. two.bin holds one chunk.
        XCTAssertEqual(replay.files, [0, 1, 3])
        XCTAssertEqual(replay.chunks.count, 7)

        fx.source.reset()
        let r = try await engine(fx.source).run(p)
        try assertStaged()
        XCTAssertEqual(r.filesResumed, 3)
        XCTAssertEqual(r.chunksResumed, 1)           // two.bin's journalled chunk, re-hashed on disk
        XCTAssertEqual(r.chunksRejected, 0)
        XCTAssertEqual(fx.source.fetches, 9 - 6)
        XCTAssertEqual(r.filesVerified, 1)
    }

    func testJournalForAnotherPlanStartsFresh() async throws {
        let fx = Fixture()
        let p = try plan(fx)
        _ = try? await engine(fx.source) { $0.cancelAfterChunks = 3 }.run(p)
        let other = p.restricted(to: ["one.bin"])
        let (j, replay) = try InstallJournal.open(journal, plan: other.content)
        j.close()
        XCTAssertTrue(replay.fresh)
        XCTAssertEqual(replay.chunks.count, 0)
    }

    func testCorruptRecordEndsReplay() throws {
        let fx = Fixture()
        let p = try plan(fx)
        let (j, _) = try InstallJournal.open(journal, plan: p.content)
        let c = p.files[0].chunks
        try j.append([.init(kind: .chunk, index: 0, sha: c[0].sha), .init(kind: .chunk, index: 1, sha: c[1].sha),
                      .init(kind: .chunk, index: 2, sha: c[0].sha) /* wrong hash for chunk 2 */, .init(kind: .chunk, index: 3, sha: c[3].sha)])
        j.close()
        var raw = [UInt8](try Data(contentsOf: journal))
        XCTAssertEqual(raw.count, InstallJournal.headerSize + 4 * InstallJournal.recordSize)
        let (j2, replay) = try InstallJournal.open(journal, plan: p.content)
        j2.close()
        XCTAssertEqual(replay.chunks, [0, 1])
        XCTAssertEqual(replay.discardedBytes, 2 * InstallJournal.recordSize)
        // A flipped bit fails the record's CRC.
        raw = [UInt8](try Data(contentsOf: journal))
        raw[InstallJournal.headerSize + 5] ^= 1
        try Data(raw).write(to: journal)
        let (j3, replay3) = try InstallJournal.open(journal, plan: p.content)
        j3.close()
        XCTAssertEqual(replay3.chunks, [])
    }

    func testTruncatedAndCorruptedStagedFilesAreFetchedAgain() async throws {
        let fx = Fixture()
        let p = try plan(fx)
        _ = try? await engine(fx.source) { $0.cancelAfterChunks = 6 }.run(p)
        // one.bin was verified, then truncated behind the journal's back.
        let one = tree.appendingPathComponent("one.bin")
        let h1 = try FileHandle(forWritingTo: one)
        try h1.truncate(atOffset: 5)
        try h1.close()
        // two.bin's journalled first chunk was overwritten on disk.
        let two = tree.appendingPathComponent("sub/two.bin")
        let h2 = try FileHandle(forWritingTo: two)
        try h2.seek(toOffset: 1)
        h2.write(Data(bytes("X")))
        try h2.close()

        fx.source.reset()
        let r = try await engine(fx.source).run(p)
        try assertStaged()
        // one.bin lost its verified mark; of its journalled chunks only the
        // first survives the truncation (bytes 0-4 kept). copy.bin and the empty
        // file stay verified.
        XCTAssertEqual(r.filesResumed, 2)
        XCTAssertEqual(r.chunksResumed, 1)
        XCTAssertEqual(r.chunksRejected, 4)          // one.bin x3, two.bin's overwritten chunk
        XCTAssertEqual(fx.source.fetches, 7)         // BBBB..DDDD, EEEE..HHHH
    }

    func testPreflightPausesWhenSpaceIsShortAndKeepsTheStage() async throws {
        let fx = Fixture()
        let p = try plan(fx)
        var e = engine(fx.source)
        e.options.reserveBytes = 100
        e.freeSpace = { _ in 120 }                   // 40 to write + 5% margin (2) + 100 reserve > 120
        do {
            _ = try await e.run(p)
            XCTFail("expected insufficient space")
        } catch let SteamError.insufficientSpace(needed, available) {
            XCTAssertEqual(needed, 142)
            XCTAssertEqual(available, 120)
            XCTAssertTrue(SteamError.insufficientSpace(needed: needed, available: available).description.contains("paused"))
        }
        XCTAssertEqual(fx.source.fetches, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        e.freeSpace = { _ in 1 << 30 }
        _ = try await e.run(p)
        try assertStaged()
    }

    func testCDNAuthRefusalIsUnsupported() async throws {
        let fx = Fixture()
        let p = try plan(fx)
        fx.source.failWith = .unsupported("CDN auth tokens (GetCDNAuthToken) are not supported")
        do {
            _ = try await engine(fx.source).run(p)
            XCTFail("expected unsupported")
        } catch SteamError.unsupported {}
    }
}

final class VerifyRepairTests: XCTestCase {
    func testVerifyFindsCorruptionAndRepairReplacesOnlyThatFile() async throws {
        let dir = try scratchDir("verify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fx = Fixture()
        let m = try DepotManifest(depotID: 1, gid: 1, files: [
            fx.file("one.bin", bytes("AAAABBBBCCCCDDDD")), fx.file("sub/two.bin", bytes("EEEEFFFF")),
        ])
        let layout = InstallLayout.root(dir)
        let session = SteamSession(store: try FileSecretStore(directory: dir.appendingPathComponent("store")), log: .silent)
        let installer = TitleInstaller(layout: layout, session: session, log: .silent)
        let plan = try InstallPlan.make(appID: 9, buildID: 3, manifests: [m])

        // Install through the engine and the same commit the installer uses.
        let tree = layout.stagingTree(appID: 9, buildID: 3)
        var e = InstallEngine(tree: tree, journal: layout.journal(appID: 9, buildID: 3), source: fx.source, log: .silent)
        e.freeSpace = { _ in 1 << 40 }
        _ = try await e.run(plan)
        let (final, replacing, sharing) = try installer.destination("Title", appID: 9)
        XCTAssertFalse(replacing)
        XCTAssertEqual(sharing, [])
        try installer.commit(tree, to: final, replacing: false,
                             receipt: InstallReceipt(appID: 9, name: "T", installDir: "Title", buildID: 3, depots: [DepotRef(depotID: 1, gid: 1)],
                                                     files: 2, bytes: 24, skippedDepots: [], skippedSymlinks: 0, installedAt: "-"))
        try RetainedManifest.save(m, to: layout.manifestFile(DepotRef(depotID: 1, gid: 1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))

        var report = try await installer.verify(appID: 9)
        XCTAssertEqual(report.bad, [])
        XCTAssertEqual(report.files, 2)

        // Same size, one byte changed; plus a save the manifest does not list.
        let two = final.appendingPathComponent("sub/two.bin")
        try Data(bytes("EEEEFFFX")).write(to: two)
        try Data(bytes("save")).write(to: final.appendingPathComponent("user.sav"))
        let oneBefore = try FileManager.default.attributesOfItem(atPath: final.appendingPathComponent("one.bin").path)[.modificationDate] as? Date
        report = try await installer.verify(appID: 9)
        XCTAssertEqual(report.bad, ["sub/two.bin"])
        XCTAssertEqual(report.unlisted, ["user.sav"])

        let v = try await installer.verifyPlan(appID: 9, concurrency: 2)
        fx.source.reset()
        let fixed = try await installer.replace(v.report, plan: v.plan.restricted(to: Set(v.report.bad)), receipt: v.receipt,
                                                root: v.root, source: fx.source, options: .init(), say: { _ in })
        XCTAssertEqual(fixed.repaired, 1)
        XCTAssertEqual(fx.source.fetches, 2)
        XCTAssertEqual(String(decoding: try Data(contentsOf: two), as: UTF8.self), "EEEEFFFF")
        let again = try await installer.verify(appID: 9)
        XCTAssertEqual(again.bad, [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: final.appendingPathComponent("one.bin").path)[.modificationDate] as? Date, oneBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.appendingPathComponent("user.sav").path))
    }

    func testReinstallRecordsTheNewBuildBeforeDeletingTheOldTree() throws {
        let dir = try scratchDir("commit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = InstallLayout.root(dir)
        let installer = TitleInstaller(layout: layout, session: SteamSession(store: try FileSecretStore(directory: dir.appendingPathComponent("s")), log: .silent), log: .silent)
        func receipt(_ build: UInt32) -> InstallReceipt {
            InstallReceipt(appID: 9, name: "T", installDir: "Title", buildID: build, depots: [DepotRef(depotID: 1, gid: UInt64(build))],
                           files: 1, bytes: 1, skippedDepots: [], skippedSymlinks: 0, installedAt: "-")
        }
        func stage(_ build: UInt32) throws -> URL {
            let tree = layout.stagingTree(appID: 9, buildID: build)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try Data(bytes("build \(build)")).write(to: tree.appendingPathComponent("game.bin"))
            return tree
        }
        func asides() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []).filter { $0.hasPrefix("replaced-") }
        }
        let final = layout.gamesRoot.appendingPathComponent("Title")
        try installer.commit(try stage(1), to: final, replacing: false, receipt: receipt(1))
        XCTAssertEqual(installer.loadReceipt(9), receipt(1))

        try installer.commit(try stage(2), to: final, replacing: true, receipt: receipt(2))
        XCTAssertEqual(installer.loadReceipt(9), receipt(2))
        XCTAssertEqual(asides(), [])

        // The record cannot be written: the old tree, moved aside, is kept.
        try FileManager.default.removeItem(at: layout.receiptFile(appID: 9))
        try FileManager.default.createDirectory(at: layout.receiptFile(appID: 9), withIntermediateDirectories: true)
        XCTAssertThrowsError(try installer.commit(try stage(3), to: final, replacing: true, receipt: receipt(3)))
        XCTAssertEqual(String(decoding: try Data(contentsOf: final.appendingPathComponent("game.bin")), as: UTF8.self), "build 3")
        XCTAssertEqual(asides().count, 1)
        installer.sweepStaging(appID: 9, buildID: 3)
        XCTAssertEqual(asides(), [])
    }

    func testSweepRemovesOtherBuildStagesOfTheApp() throws {
        let dir = try scratchDir("sweep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = InstallLayout.root(dir)
        let installer = TitleInstaller(layout: layout, session: SteamSession(store: try FileSecretStore(directory: dir.appendingPathComponent("s")), log: .silent), log: .silent)
        let fm = FileManager.default
        let trees = [layout.stagingTree(appID: 9, buildID: 3), layout.stagingTree(appID: 9, buildID: 4),
                     layout.stagingTree(appID: 9, buildID: 3, suffix: ".repair"), layout.stagingTree(appID: 90, buildID: 3),
                     layout.stagingRoot.appendingPathComponent("replaced-X")]
        for t in trees { try fm.createDirectory(at: t, withIntermediateDirectories: true) }
        let journals = [layout.journal(appID: 9, buildID: 3), layout.journal(appID: 9, buildID: 4),
                        layout.journal(appID: 9, buildID: 3, suffix: ".repair"), layout.journal(appID: 90, buildID: 3)]
        for j in journals { try Data().write(to: j) }

        installer.sweepStaging(appID: 9, buildID: 4)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.stagingRoot.path).sorted(),
                       ["90_3", "90_3.journal", "9_3.repair", "9_3.repair.journal", "9_4", "9_4.journal"])
    }

    func testUninstallRemovesTheTitleItsRecordAndStagesOnly() throws {
        let dir = try scratchDir("uninstall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = InstallLayout.root(dir)
        let fm = FileManager.default
        let installer = TitleInstaller(layout: layout, session: nil, log: .silent)
        let ref = DepotRef(depotID: 1, gid: 7)
        let tree = layout.stagingTree(appID: 9, buildID: 3)
        try fm.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(bytes("game")).write(to: tree.appendingPathComponent("sub/game.bin"))
        try installer.commit(tree, to: layout.gamesRoot.appendingPathComponent("Title"), replacing: false,
                             receipt: InstallReceipt(appID: 9, name: "T", installDir: "Title", buildID: 3, depots: [ref],
                                                     files: 1, bytes: 4, skippedDepots: [], skippedSymlinks: 0, installedAt: "-"))
        try fm.createDirectory(at: layout.manifestsDir, withIntermediateDirectories: true)
        try Data().write(to: layout.manifestFile(ref))
        try fm.createDirectory(at: layout.gamesRoot.appendingPathComponent("Other"), withIntermediateDirectories: true)
        // A paused update of 9 and another app's paused install.
        try fm.createDirectory(at: layout.stagingTree(appID: 9, buildID: 4), withIntermediateDirectories: true)
        try Data().write(to: layout.journal(appID: 9, buildID: 4))
        try Data().write(to: layout.journal(appID: 90, buildID: 1))
        XCTAssertTrue(installer.hasStage(appID: 9))
        XCTAssertTrue(installer.hasStage(appID: 90))

        try installer.uninstall(installDir: "Title", appID: 9)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.gamesRoot.path), ["Other"])
        XCTAssertNil(installer.loadReceipt(9))
        XCTAssertFalse(fm.fileExists(atPath: layout.manifestFile(ref).path))
        XCTAssertFalse(installer.hasStage(appID: 9))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.stagingRoot.path), ["90_1.journal"])

        // A copied-in folder with no record; a path out of games is refused.
        try installer.uninstall(installDir: "Other", appID: nil)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.gamesRoot.path), [])
        XCTAssertThrowsError(try installer.uninstall(installDir: "../state", appID: nil))
        XCTAssertTrue(fm.fileExists(atPath: layout.stateRoot.path))
    }

    func testDestinationNeverClobbersAnotherTitle() throws {
        let dir = try scratchDir("dest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = InstallLayout.root(dir)
        try FileManager.default.createDirectory(at: layout.gamesRoot.appendingPathComponent("Hollow Knight"), withIntermediateDirectories: true)
        let installer = TitleInstaller(layout: layout, session: SteamSession(store: try FileSecretStore(directory: dir.appendingPathComponent("s")), log: .silent), log: .silent)
        XCTAssertThrowsError(try installer.destination("hollow knight", appID: 4020))
        XCTAssertThrowsError(try TitleInstaller.destinationName("../Hollow Knight"))
        XCTAssertThrowsError(try TitleInstaller.destinationName("Games/x"))
        XCTAssertEqual(try installer.destination("GarrysModDS", appID: 4020).0.lastPathComponent, "GarrysModDS")
    }

    /// Counter-Strike (10) and Half-Life (70) in Steam's one Half-Life folder: depot 1 is both
    /// apps', depot 11 Counter-Strike's, depot 71 Half-Life's (SharedInstallDir).
    struct SharedFolder {
        let fx = Fixture()
        let layout: InstallLayout
        let installer: TitleInstaller
        var root: URL { layout.gamesRoot.appendingPathComponent("Half-Life") }

        init(_ dir: URL) {
            layout = InstallLayout.root(dir)
            installer = TitleInstaller(layout: layout, session: nil, log: .silent)
        }

        func manifest(_ depot: UInt32, _ gid: UInt64, _ files: [DepotManifest.File]) throws -> DepotManifest {
            let m = try DepotManifest(depotID: depot, gid: gid, files: files)
            try RetainedManifest.save(m, to: layout.manifestFile(DepotRef(depotID: depot, gid: gid)))
            return m
        }

        func receipt(_ app: UInt32, _ manifests: [DepotManifest]) -> InstallReceipt {
            InstallReceipt(appID: app, name: "app \(app)", installDir: "Half-Life", buildID: 1,
                           depots: manifests.map { DepotRef(depotID: $0.depotID, gid: $0.gid) },
                           files: 0, bytes: 0, skippedDepots: [], skippedSymlinks: 0, installedAt: "-")
        }

        /// The installer's own steps: destination, the files to stage, the engine, the commit.
        func install(_ app: UInt32, _ manifests: [DepotManifest]) async throws -> Int {
            let plan = try InstallPlan.make(appID: app, buildID: 1, manifests: manifests)
            let (final, replacing, sharing) = try installer.destination("Half-Life", appID: app)
            let tree = layout.stagingTree(appID: app, buildID: 1)
            var e = InstallEngine(tree: tree, journal: layout.journal(appID: app, buildID: 1), source: fx.source, log: .silent)
            e.freeSpace = { _ in 1 << 40 }
            if sharing.isEmpty {
                _ = try await e.run(plan)
                try installer.commit(tree, to: final, replacing: replacing, receipt: receipt(app, manifests))
                return plan.files.count
            }
            let others = SharedInstallDir.Others(try sharing.map { try installer.retainedPlan($0) })
            let staged = plan.restricted(to: try SharedInstallDir.pathsToStage(plan, others: others, folder: "Half-Life"))
            if !staged.files.isEmpty { _ = try await e.run(staged) }
            try installer.commitShared(tree, plan: plan, staged: staged, to: final, others: others, receipt: receipt(app, manifests))
            return staged.files.count
        }

        func text(_ path: String) -> String? {
            (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func testSharedInstallDirStagesOnlyOwnFilesAndRefusesAnotherAppsContent() throws {
        let fx = Fixture()
        let cs = try InstallPlan.make(appID: 10, buildID: 1, manifests: [
            try DepotManifest(depotID: 1, gid: 1, files: [fx.file("hl.exe", bytes("ENGINE")), fx.file("valve/pak0.pak", bytes("PAK"))]),
            try DepotManifest(depotID: 11, gid: 1, files: [fx.file("cstrike/cs.dll", bytes("CS")), fx.directory("cstrike/save")]),
        ])
        let others = SharedInstallDir.Others([cs])
        let hl = try InstallPlan.make(appID: 70, buildID: 1, manifests: [
            try DepotManifest(depotID: 1, gid: 1, files: [fx.file("HL.exe", bytes("ENGINE")), fx.file("valve/pak0.pak", bytes("PAK"))]),
            try DepotManifest(depotID: 71, gid: 1, files: [fx.file("valve/hl.dll", bytes("HL"))]),
        ])
        XCTAssertEqual(try SharedInstallDir.pathsToStage(hl, others: others, folder: "Half-Life"), ["valve/hl.dll"])
        XCTAssertEqual(SharedInstallDir.removable(hl.files.map(\.path), others: others), ["valve/hl.dll"])
        XCTAssertTrue(others.needs(directory: "cstrike/save"))
        XCTAssertTrue(others.needs(directory: "Valve"))
        XCTAssertFalse(others.needs(directory: "valve/maps"))
        // Depot 71 overriding a file of depot 1 would change Counter-Strike's copy.
        let clash = try InstallPlan.make(appID: 70, buildID: 1, manifests: [
            try DepotManifest(depotID: 71, gid: 1, files: [fx.file("valve/pak0.pak", bytes("HLPAK"))]),
        ])
        XCTAssertThrowsError(try SharedInstallDir.pathsToStage(clash, others: others, folder: "Half-Life")) { e in
            XCTAssertTrue("\(e)".contains("app 10's file"), "\(e)")
        }
    }

    func testSharedFolderInstallAndUninstallKeepTheOtherAppsFiles() async throws {
        let dir = try scratchDir("shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SharedFolder(dir)
        let fm = FileManager.default
        try fm.createDirectory(at: s.layout.manifestsDir, withIntermediateDirectories: true)
        let engine = try s.manifest(1, 100, [s.fx.file("hl.exe", bytes("ENGINE")), s.fx.file("valve/pak0.pak", bytes("PAKPAKPAK"))])
        let csOwn = try s.manifest(11, 110, [s.fx.file("cstrike/cs.dll", bytes("CSCS"))])
        let hlOwn = try s.manifest(71, 710, [s.fx.file("valve/dlls/hl.dll", bytes("HLHL")), s.fx.directory("valve/SAVE")])

        let csStaged = try await s.install(10, [engine, csOwn])
        XCTAssertEqual(csStaged, 3)
        // Half-Life joins: only its own file is downloaded.
        s.fx.source.reset()
        let hlStaged = try await s.install(70, [engine, hlOwn])
        XCTAssertEqual(hlStaged, 1)
        XCTAssertEqual(s.fx.source.fetches, 1)
        XCTAssertEqual(s.text("valve/dlls/hl.dll"), "HLHL")
        XCTAssertEqual(s.text("cstrike/cs.dll"), "CSCS")
        XCTAssertTrue(fm.fileExists(atPath: s.root.appendingPathComponent("valve/SAVE").path))
        let verifyCS = try await s.installer.verify(appID: 10)
        let verifyHL = try await s.installer.verify(appID: 70)
        XCTAssertEqual(verifyCS.bad, [])
        XCTAssertEqual(verifyHL.bad, [])
        // Installing it again stages only its own file again.
        let again = try await s.install(70, [engine, hlOwn])
        XCTAssertEqual(again, 1)
        XCTAssertEqual(s.text("cstrike/cs.dll"), "CSCS")

        // A save the game wrote, then Half-Life leaves: its own file and empty directories go.
        try Data(bytes("save")).write(to: s.root.appendingPathComponent("valve/config.cfg"))
        try s.installer.uninstall(installDir: "Half-Life", appID: 70)
        XCTAssertNil(s.installer.loadReceipt(70))
        XCTAssertNil(s.text("valve/dlls/hl.dll"))
        XCTAssertFalse(fm.fileExists(atPath: s.root.appendingPathComponent("valve/dlls").path))
        XCTAssertFalse(fm.fileExists(atPath: s.root.appendingPathComponent("valve/SAVE").path))
        XCTAssertEqual(s.text("valve/config.cfg"), "save")
        XCTAssertEqual(s.text("hl.exe"), "ENGINE")
        XCTAssertTrue(fm.fileExists(atPath: s.layout.manifestFile(DepotRef(depotID: 1, gid: 100)).path), "Counter-Strike's record names it")
        XCTAssertFalse(fm.fileExists(atPath: s.layout.manifestFile(DepotRef(depotID: 71, gid: 710)).path))
        let after = try await s.installer.verify(appID: 10)
        XCTAssertEqual(after.bad, [])
        XCTAssertEqual(after.unlisted, ["valve/config.cfg"])

        // The last app in the folder takes it whole.
        try s.installer.uninstall(installDir: "Half-Life", appID: 10)
        XCTAssertFalse(fm.fileExists(atPath: s.root.path))
        XCTAssertFalse(fm.fileExists(atPath: s.layout.manifestFile(DepotRef(depotID: 1, gid: 100)).path))
    }

    func testSharedFolderUpdateRemovesOnlyItsOwnDroppedFiles() async throws {
        let dir = try scratchDir("shared-update")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SharedFolder(dir)
        try FileManager.default.createDirectory(at: s.layout.manifestsDir, withIntermediateDirectories: true)
        let engine = try s.manifest(1, 100, [s.fx.file("hl.exe", bytes("ENGINE"))])
        _ = try await s.install(10, [engine, try s.manifest(11, 110, [s.fx.file("cstrike/cs.dll", bytes("CSCS"))])])
        _ = try await s.install(70, [engine, try s.manifest(71, 710, [s.fx.file("valve/old.dll", bytes("OLD1"))])])
        // Half-Life's next build drops old.dll and brings new.dll.
        let staged = try await s.install(70, [engine, try s.manifest(71, 711, [s.fx.file("valve/new.dll", bytes("NEW1"))])])
        XCTAssertEqual(staged, 1)
        XCTAssertNil(s.text("valve/old.dll"))
        XCTAssertEqual(s.text("valve/new.dll"), "NEW1")
        XCTAssertEqual(s.text("cstrike/cs.dll"), "CSCS")
        XCTAssertEqual(s.installer.loadReceipt(70)?.depots.last, DepotRef(depotID: 71, gid: 711))
        // An update whose shared file differs from Counter-Strike's is refused before anything is written.
        do {
            _ = try await s.install(70, [try s.manifest(1, 101, [s.fx.file("hl.exe", bytes("ENGINE2"))])])
            XCTFail("a changed shared file was accepted")
        } catch SteamError.unsafeContent {}
        XCTAssertEqual(s.text("hl.exe"), "ENGINE")
    }

    func testSharedFolderUninstallWithAMissingManifestKeepsEveryFile() async throws {
        let dir = try scratchDir("shared-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SharedFolder(dir)
        try FileManager.default.createDirectory(at: s.layout.manifestsDir, withIntermediateDirectories: true)
        let engine = try s.manifest(1, 100, [s.fx.file("hl.exe", bytes("ENGINE"))])
        _ = try await s.install(10, [engine, try s.manifest(11, 110, [s.fx.file("cstrike/cs.dll", bytes("CSCS"))])])
        _ = try await s.install(70, [engine, try s.manifest(71, 710, [s.fx.file("valve/hl.dll", bytes("HLHL"))])])
        try FileManager.default.removeItem(at: s.layout.manifestFile(DepotRef(depotID: 11, gid: 110)))
        try s.installer.uninstall(installDir: "Half-Life", appID: 70)
        XCTAssertNil(s.installer.loadReceipt(70))
        XCTAssertEqual(s.text("valve/hl.dll"), "HLHL", "which files are Counter-Strike's is unknown: all stay")
        XCTAssertNotNil(s.installer.loadReceipt(10))
        XCTAssertEqual(s.text("cstrike/cs.dll"), "CSCS")
    }

    func testANewInstallStillRefusesAFolderNoSteamRecordNames() throws {
        let dir = try scratchDir("shared-none")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SharedFolder(dir)
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try s.installer.destination("half-life", appID: 70))
        let r = s.receipt(10, [])
        try s.installer.saveReceipt(r)
        let (_, replacing, sharing) = try s.installer.destination("half-life", appID: 70)
        XCTAssertFalse(replacing)
        XCTAssertEqual(sharing.map(\.appID), [10])
        let (_, again, others) = try s.installer.destination("Half-Life", appID: 10)
        XCTAssertTrue(again)
        XCTAssertEqual(others, [])
    }

    func testSHA256ListVerification() async throws {
        let dir = try scratchDir("list")
        defer { try? FileManager.default.removeItem(at: dir) }
        let game = dir.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data(bytes("abc")).write(to: game.appendingPathComponent("Data/a.bin"))
        try Data(bytes("xyz")).write(to: game.appendingPathComponent("b.exe"))
        let list = dir.appendingPathComponent("sums")
        try """
        \(SHA256Stream.hash(bytes("abc")).hex)  Data/a.bin
        \(SHA256Stream.hash(bytes("xyz!")).hex)  b.exe
        \(SHA256Stream.hash(bytes("q")).hex)  missing.dll

        """.write(to: list, atomically: true, encoding: .utf8)
        let r = try await TitleInstaller.verifySHA256List(dir: game, list: list)
        XCTAssertEqual(r.files, 3)
        XCTAssertEqual(r.bad, ["b.exe", "missing.dll"])
        XCTAssertEqual(r.unlisted, [])
    }
}
