// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// A PICS record with Hollow Knight-like save rules (made up).
func cloudApp() throws -> KeyValue {
    try KeyValue.parseText(Array("""
    "367520"
    {
        "common" { "name" "Knight" }
        "ufs"
        {
            "quota" "1000000"
            "savefiles"
            {
                "0" { "root" "WinAppDataLocalLow" "path" "Team Cherry/Hollow Knight" "pattern" "user*.dat" }
                "1" { "root" "WinMyDocuments" "path" "Knight/{64BitSteamID}" "pattern" "*" "recursive" "1" }
                "2" { "root" "MacAppSupport" "path" "x" "pattern" "*" "platforms" { "1" "MacOS" } }
            }
        }
    }
    """.utf8))
}

/// A PICS record with Portal 2's save rule as it spells it: the root in lower
/// case, while Steam lists the files a Windows client uploaded as `%GameInstall%`.
func portal2CloudApp() throws -> KeyValue {
    try KeyValue.parseText(Array("""
    "620"
    {
        "common" { "name" "Portal 2" }
        "ufs"
        {
            "savefiles"
            {
                "0" { "root" "gameinstall" "path" "portal2/SAVE/{64BitSteamID}/" "pattern" "*.sav" }
            }
        }
    }
    """.utf8))
}

final class CloudTests: XCTestCase {
    var dir: URL!
    var roots: Cloud.Roots!

    override func setUpWithError() throws {
        dir = try scratchDir("cloud")
        roots = Cloud.Roots(user: dir.appendingPathComponent("users/playport"), gameInstall: dir.appendingPathComponent("Games/Knight"),
                            remote: dir.appendingPathComponent("GSE Saves/367520/remote"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testRootsMapIntoThePrefixAndMatchCaseAsWindowsDoes() throws {
        XCTAssertEqual(roots.file("%WinAppDataLocalLow%Team Cherry/Hollow Knight/user1.dat")?.path,
                       dir.appendingPathComponent("users/playport/AppData/LocalLow/Team Cherry/Hollow Knight/user1.dat").path)
        XCTAssertEqual(roots.file("save.bin")?.path, dir.appendingPathComponent("GSE Saves/367520/remote/save.bin").path,
                       "no token: the emulator's remote storage")
        XCTAssertEqual(roots.file("%GameInstall%saves/a.sav")?.path, dir.appendingPathComponent("Games/Knight/saves/a.sav").path)
        XCTAssertNil(roots.file("%LinuxHome%x"), "a root Playport does not map")
        XCTAssertNil(roots.file("%WinMyDocuments%../escape"))
        try write(dir.appendingPathComponent("users/playport/AppData/LocalLow/TEAM CHERRY/x.dat"), "a")
        XCTAssertEqual(roots.file("%WinAppDataLocalLow%Team Cherry/x.dat")?.path,
                       dir.appendingPathComponent("users/playport/AppData/LocalLow/TEAM CHERRY/x.dat").path)
    }

    func testARulesRootTakesSteamsSpellingAndLocalNamesTakeSteamsCase() throws {
        let rules = Cloud.rules(try portal2CloudApp())
        XCTAssertEqual(rules.map(\.root), ["gameinstall"])
        let save = dir.appendingPathComponent("Games/Knight/portal2/SAVE/42")
        try write(save.appendingPathComponent("autosave.sav"), "auto")
        try write(save.appendingPathComponent("1791103990.sav"), "quick")
        let files = Cloud.localFiles(rules: rules, roots: roots, steamID: 42)
        XCTAssertEqual(files.keys.sorted(), ["%GameInstall%portal2/SAVE/42/1791103990.sav", "%GameInstall%portal2/SAVE/42/autosave.sav"],
                       "the token as Steam lists it, not as the rule spells it")
        XCTAssertEqual(Cloud.canonicalRoot("WINAPPDATALOCALLOW"), "WinAppDataLocalLow")
        XCTAssertEqual(Cloud.canonicalRoot("LinuxHome"), "LinuxHome", "a root Playport does not map stays as given")

        // A file an earlier sync uploaded under the rule's spelling keeps the name Steam has for it.
        let named = Cloud.named(files, like: ["%gameinstall%portal2/SAVE/42/1791103990.sav", "%GameInstall%portal2/save/42/other.sav"])
        XCTAssertEqual(named.keys.sorted(), ["%GameInstall%portal2/SAVE/42/autosave.sav", "%gameinstall%portal2/SAVE/42/1791103990.sav"])
        XCTAssertEqual(named["%gameinstall%portal2/SAVE/42/1791103990.sav"], files["%GameInstall%portal2/SAVE/42/1791103990.sav"])
        let first = Cloud.named(["a/X.sav": save, "a/x.sav": dir], like: ["A/x.sav", "a/x.SAV"])
        XCTAssertEqual(first, ["A/x.sav": save], "the first of the names wins, and two local names for one file become one")
    }

    func testRulesAndTheLocalFilesTheyCover() throws {
        let rules = Cloud.rules(try cloudApp())
        XCTAssertEqual(rules.map(\.root), ["WinAppDataLocalLow", "WinMyDocuments"], "the macOS rule is skipped")
        let hk = dir.appendingPathComponent("users/playport/AppData/LocalLow/Team Cherry/Hollow Knight")
        try write(hk.appendingPathComponent("user1.dat"), "one")
        try write(hk.appendingPathComponent("shared.dat"), "not a user file")
        try write(hk.appendingPathComponent("sub/user2.dat"), "not recursive")
        try write(dir.appendingPathComponent("users/playport/Documents/Knight/42/slot/a.sav"), "recursive")
        try write(dir.appendingPathComponent("GSE Saves/367520/remote/api.bin"), "through the API")
        let files = Cloud.localFiles(rules: rules, roots: roots, steamID: 42)
        XCTAssertEqual(files.keys.sorted(), ["%WinAppDataLocalLow%Team Cherry/Hollow Knight/user1.dat",
                                             "%WinMyDocuments%Knight/42/slot/a.sav", "api.bin"])
        XCTAssertTrue(Cloud.glob("user*.dat", "USER3.DAT"))
        XCTAssertFalse(Cloud.glob("user?.dat", "user10.dat"))
    }

    func testThePlan() {
        func r(_ sha: String) -> Cloud.Remote { .init(name: "", sha: sha, size: 1, time: 0) }
        let base = Cloud.Baseline(changeNumber: 1, files: ["same": "a", "phone": "a", "steam": "a", "both": "a", "gone": "a"])
        let plan = Cloud.plan(remote: ["same": r("a"), "phone": r("a"), "steam": r("b"), "both": r("b"), "gone": r("a"), "newsteam": r("c")],
                              local: ["same": "a", "phone": "b", "steam": "a", "both": "c", "newphone": "d"], baseline: base)
        XCTAssertEqual(plan, ["phone": .upload, "steam": .download, "both": .conflict, "newsteam": .download, "newphone": .upload],
                       "a file the phone deleted is not fetched again")
        let first = Cloud.plan(remote: ["x": r("a"), "y": r("b")], local: ["x": "a", "y": "c", "z": "d"], baseline: nil)
        XCTAssertEqual(first, ["y": .conflict], "no baseline: a difference is the player's to settle, a phone-only file waits")
    }

    func testABodyIsTakenAsIsOrUnzippedButAlwaysChecked() throws {
        let content = Array("the save".utf8)
        let sha = SHA1.hash(content).hex
        XCTAssertEqual(try Cloud.content(content, rawSize: 8, sha: sha), content)
        XCTAssertThrowsError(try Cloud.content(Array("tampered".utf8), rawSize: 8, sha: sha))
        XCTAssertThrowsError(try Cloud.content(Array("PK\u{3}\u{4}junk".utf8), rawSize: 8, sha: sha))
    }

    func testTheChangelistNamesFilesByPrefix() throws {
        var w = ProtoWriter()
        w.uint64(1, 9)
        for (name, prefix, state) in [("user1.dat", 0, 0), ("old.dat", 0, 2), ("api.bin", -1, 0)] as [(String, Int, UInt32)] {
            var m = ProtoWriter()
            m.string(1, name); m.bytes(2, SHA1.hash(Array(name.utf8))); m.uint64(3, 5); m.uint32(4, 3); m.uint32(5, state)
            if prefix >= 0 { m.uint32(7, UInt32(prefix)) }
            w.bytes(2, m.bytes)
        }
        w.string(4, "%WinAppDataLocalLow%Team Cherry/Hollow Knight/")
        let r = try CCloudGetAppFileChangelistResponse.decode(w.bytes)
        XCTAssertEqual(r.currentChangeNumber, 9)
        XCTAssertEqual(r.remote.keys.sorted(), ["%WinAppDataLocalLow%Team Cherry/Hollow Knight/user1.dat", "api.bin"],
                       "a deleted file is not listed")
    }
}

final class CloudServiceTests: XCTestCase {
    var dir: URL!
    var roots: Cloud.Roots!
    let saveName = "%WinAppDataLocalLow%Team Cherry/Hollow Knight/user1.dat"

    override func setUpWithError() throws {
        dir = try scratchDir("cloud-svc")
        roots = Cloud.Roots(user: dir.appendingPathComponent("users/playport"), gameInstall: dir.appendingPathComponent("Games/Knight"),
                            remote: dir.appendingPathComponent("GSE Saves/367520/remote"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    var save: URL { roots.file(saveName)! }
    var backups: URL { dir.appendingPathComponent("backups") }

    func service(_ b: FakeBackend) async throws -> SteamService {
        await b.set(library: [367520], [367520: try cloudApp()])
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: dir.appendingPathComponent("state"))
        _ = await s.restoreIfPossible()
        return s
    }

    func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    func testAFreshPhoneGetsSteamsSaveAndThenSendsItsPlays() async throws {
        let b = FakeBackend()
        await b.set(cloud: [saveName: Array("from the PC".utf8)])
        let s = try await service(b)
        let first = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(first.downloaded, [saveName])
        XCTAssertEqual(text(save), "from the PC")

        // A play changes the save: it goes up, once.
        try Data("played on the phone".utf8).write(to: save)
        let second = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(second.uploaded, [saveName])
        let onSteam = await b.cloudFile(saveName)
        XCTAssertEqual(onSteam, Array("played on the phone".utf8))
        let third = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(third.uploaded + third.downloaded, [])

        // The PC plays next: it comes down, and the phone's copy is backed up.
        await b.set(cloud: [saveName: Array("the PC again".utf8)])
        let fourth = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(fourth.downloaded, [saveName])
        XCTAssertEqual(text(save), "the PC again")
        let kept = TitleInstaller.regularFiles(under: backups)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(text(backups.appendingPathComponent(kept[0])), "played on the phone")
    }

    /// Portal 2: its rule spells the root `gameinstall`, Steam lists `%GameInstall%`. Each save
    /// had two names, and every sync sent Steam copies it refused (DuplicateRequest).
    func testPortal2sSavesSyncUnderTheNamesSteamHas() async throws {
        let auto = "%GameInstall%portal2/SAVE/7/autosave.sav"
        let earlier = "%gameinstall%portal2/SAVE/7/1791103990.sav"   // uploaded under the rule's spelling
        let config = "cfg/config.cfg"                                   // through ISteamRemoteStorage
        let b = FakeBackend()
        await b.set(cloud: [auto: Array("pc auto".utf8), earlier: Array("phone quick".utf8), config: Array("cfg".utf8)])
        await b.set(library: [620], [620: try portal2CloudApp()])
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: dir.appendingPathComponent("state"))
        _ = await s.restoreIfPossible()
        let p2 = Cloud.Roots(user: dir.appendingPathComponent("users/playport"), gameInstall: dir.appendingPathComponent("Games/Portal 2"),
                             remote: dir.appendingPathComponent("GSE Saves/620/remote"))

        let first = try await s.syncCloud(appID: 620, roots: p2, backups: backups)
        XCTAssertEqual(first.downloaded.sorted(), [auto, earlier, config].sorted())
        let saves = dir.appendingPathComponent("Games/Portal 2/portal2/SAVE/7")
        XCTAssertEqual(text(saves.appendingPathComponent("autosave.sav")), "pc auto")
        XCTAssertEqual(text(dir.appendingPathComponent("GSE Saves/620/remote/cfg/config.cfg")), "cfg")

        let unchanged = try await s.syncCloud(appID: 620, roots: p2, backups: backups)
        XCTAssertEqual(unchanged.uploaded + unchanged.downloaded, [], "no second name for a file Steam has")
        XCTAssertEqual(unchanged.failed, [:])
        XCTAssertEqual(unchanged.conflicts, [])

        // A play saves anew and rewrites the autosave: both go up, under Steam's spelling.
        try Data("phone auto".utf8).write(to: saves.appendingPathComponent("autosave.sav"))
        try Data("new save".utf8).write(to: saves.appendingPathComponent("1791200000.sav"))
        let played = try await s.syncCloud(appID: 620, roots: p2, backups: backups)
        XCTAssertEqual(played.uploaded, ["%GameInstall%portal2/SAVE/7/1791200000.sav", auto])
        XCTAssertEqual(played.failed, [:])
        let onSteam = await b.cloudFile(auto)
        XCTAssertEqual(onSteam, Array("phone auto".utf8))

        // The PC plays next: Steam's newer autosave comes down before the phone's next play.
        await b.set(cloud: [auto: Array("pc again".utf8), earlier: Array("phone quick".utf8), config: Array("cfg".utf8),
                            "%GameInstall%portal2/SAVE/7/1791200000.sav": Array("new save".utf8)])
        let next = try await s.syncCloud(appID: 620, roots: p2, backups: backups)
        XCTAssertEqual(next.downloaded, [auto])
        XCTAssertEqual(next.uploaded, [])
        XCTAssertEqual(text(saves.appendingPathComponent("autosave.sav")), "pc again")
    }

    func testBothChangedIsAConflictThePlayerSettles() async throws {
        let b = FakeBackend()
        await b.set(cloud: [saveName: Array("v1".utf8)])
        let s = try await service(b)
        _ = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        try Data("phone v2".utf8).write(to: save)
        await b.set(cloud: [saveName: Array("pc v2".utf8)])
        let r = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(r.conflicts.map(\.name), [saveName])
        XCTAssertEqual(r.conflicts[0].phoneSize, 8)
        XCTAssertEqual(r.conflicts[0].steamSize, 5)
        XCTAssertEqual(text(save), "phone v2", "nothing moves until the player chooses")
        let kept = await s.keptCloud(appID: 367520)
        XCTAssertEqual(kept?.conflicts.map(\.name), [saveName])

        // Keep the phone's: it goes up, Steam's is backed up first.
        let settled = try await s.syncCloud(appID: 367520, roots: roots, backups: backups, resolve: [saveName: .phone])
        XCTAssertEqual(settled.uploaded, [saveName])
        XCTAssertEqual(settled.conflicts, [])
        let onSteam = await b.cloudFile(saveName)
        XCTAssertEqual(onSteam, Array("phone v2".utf8))
        XCTAssertEqual(TitleInstaller.regularFiles(under: backups).map { text(backups.appendingPathComponent($0)) }, ["pc v2"])
    }

    func testKeepingSteamsCopyInAConflict() async throws {
        let b = FakeBackend()
        await b.set(cloud: [saveName: Array("steam".utf8)])
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("phone".utf8).write(to: save)
        let s = try await service(b)
        let first = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(first.conflicts.map(\.name), [saveName], "a first sync never overwrites either side")
        let r = try await s.syncCloud(appID: 367520, roots: roots, backups: backups, resolve: [saveName: .steam])
        XCTAssertEqual(r.downloaded, [saveName])
        XCTAssertEqual(text(save), "steam")
        XCTAssertEqual(TitleInstaller.regularFiles(under: backups).map { text(backups.appendingPathComponent($0)) }, ["phone"])
    }

    func testAFirstSyncAsksBeforeUploadingAPhoneOnlySave() async throws {
        let b = FakeBackend()
        let s = try await service(b)
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("phone only".utf8).write(to: save)
        let first = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(first.uploaded, [])
        XCTAssertEqual(first.conflicts.map(\.name), [saveName])
        XCTAssertNil(first.conflicts[0].steamSize)
        // Unanswered, it stays a question: a later sync does not upload it.
        let unanswered = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(unanswered.uploaded, [])
        XCTAssertEqual(unanswered.conflicts.map(\.name), [saveName])
        // Kept off Steam by choice: it stays off, until the game changes it.
        let off = try await s.syncCloud(appID: 367520, roots: roots, backups: backups, resolve: [saveName: .steam])
        XCTAssertEqual(off.uploaded + off.downloaded, [])
        XCTAssertEqual(off.conflicts, [])
        XCTAssertEqual(text(save), "phone only")
        try Data("played".utf8).write(to: save)
        let later = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(later.uploaded, [saveName])
    }

    func testOneChoiceSettlesEveryConflictInOneSyncAndKeepsTheOtherSide() async throws {
        let other = "%WinAppDataLocalLow%Team Cherry/Hollow Knight/user2.dat"
        let b = FakeBackend()
        await b.set(cloud: [saveName: Array("pc 1".utf8), other: Array("pc 2".utf8)])
        let s = try await service(b)
        _ = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        try Data("phone 1".utf8).write(to: save)
        try Data("phone 2".utf8).write(to: roots.file(other)!)
        await b.set(cloud: [saveName: Array("pc 1b".utf8), other: Array("pc 2b".utf8)])
        let r = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(r.conflicts.map(\.name), [saveName, other])

        // Forgotten, the next sync is a first one: the same files are still the question.
        await s.forgetCloud(appID: 367520)
        let again = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertEqual(again.conflicts.map(\.name), [saveName, other])

        let resolve = SteamService.resolveAll(r.conflicts, .steam)
        XCTAssertEqual(resolve, [saveName: .steam, other: .steam])
        let settled = try await s.syncCloud(appID: 367520, roots: roots, backups: backups, resolve: resolve)
        XCTAssertEqual(settled.conflicts, [])
        XCTAssertEqual(settled.downloaded.sorted(), [saveName, other])
        XCTAssertEqual(text(save), "pc 1b")
        // The phone's copies, the side not picked, are in one sync's backup folder.
        let kept = TitleInstaller.regularFiles(under: backups).sorted()
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(Set(kept.map { $0.split(separator: "/").dropLast().joined(separator: "/") }).count, 1)
        XCTAssertEqual(Set(kept.compactMap { text(backups.appendingPathComponent($0)) }), ["phone 1", "phone 2"])
    }

    func testBackupsLastThirtyDays() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 24 * 3600
        let name = Cloud.Backups.folderName(for: now)
        XCTAssertFalse(name.contains(":"))
        XCTAssertEqual(Cloud.Backups.date(ofFolder: name), now)
        XCTAssertNil(Cloud.Backups.date(ofFolder: "notes"))

        let fm = FileManager.default
        func make(_ app: String, _ folder: String) throws -> URL {
            let url = backups.appendingPathComponent("\(app)/\(folder)", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("user1.dat"))
            return url
        }
        let old = try make("367520", Cloud.Backups.folderName(for: now - 31 * day))
        let recent = try make("367520", Cloud.Backups.folderName(for: now - 29 * day))
        let lone = try make("292030", Cloud.Backups.folderName(for: now - 40 * day))
        XCTAssertEqual(Cloud.Backups.expired(in: backups, now: now).map(\.lastPathComponent).sorted(),
                       [old.lastPathComponent, lone.lastPathComponent].sorted())
        let removed = Cloud.Backups.prune(backups, now: now)
        XCTAssertEqual(removed.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertFalse(fm.fileExists(atPath: lone.deletingLastPathComponent().path), "a game's folder left empty goes too")
        XCTAssertEqual(Cloud.Backups.prune(backups, now: now), [])
        XCTAssertEqual(Cloud.Backups.prune(backups.appendingPathComponent("none"), now: now), [])
    }

    func testSignOutForgetsTheBaseline() async throws {
        let b = FakeBackend()
        let s = try await service(b)
        _ = try await s.syncCloud(appID: 367520, roots: roots, backups: backups)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state/steam-cloud").path))
        _ = try await s.signOut()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state/steam-cloud").path))
    }
}
