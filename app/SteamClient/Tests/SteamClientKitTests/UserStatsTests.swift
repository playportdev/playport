// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// A stats schema as Steam's UserGameStatsSchema lays it out (made up, not a
/// real game's): two stats and an achievement block with three bits.
let schemaText = """
"367520"
{
    "gamename" "Test"
    "version" "7"
    "stats"
    {
        "1" { "type" "1" "name" "kills" "default" "0" }
        "2" { "type" "2" "name" "Best:Time" "default" "1.5" }
        "3" { "type" "3" "name" "rate" "default" "0" }
        "4"
        {
            "type" "4"
            "id" "4"
            "bits"
            {
                "0" { "name" "ACH_FIRST" "bit" "0" "display" { "name" { "english" "First" "german" "Erste" "token" "#A" } "desc" { "english" "Do it once" } "hidden" "0" } }
                "1" { "name" "ACH_SECRET" "bit" "1" "display" { "name" "Secret" "desc" "Hidden one" "hidden" "1" } }
                "2" { "name" "ACH_LAST" "bit" "2" "display" { "name" { "english" "Last" } } }
            }
        }
    }
}
"""

func testSchema() throws -> StatsSchema { try StatsSchema.parse(try KeyValue.parseText(Array(schemaText.utf8))) }

func snapshot(values: [UInt32: UInt32] = [:], times: [UInt32: [UInt32]] = [:]) throws -> UserStatsSnapshot {
    UserStatsSnapshot(appID: 367520, crc: 100, schema: try testSchema(), values: values, unlockTimes: times, fetchedAt: Date())
}

final class UserStatsTests: XCTestCase {
    func testSchemaParsing() throws {
        let s = try testSchema()
        XCTAssertEqual(s.version, 7)
        XCTAssertEqual(s.stats.map(\.name), ["kills", "Best:Time", "rate"])
        XCTAssertEqual(s.stats.map(\.kind), [.int, .float, .avgrate])
        XCTAssertEqual(s.stats[1].defaultValue, "1.5")
        XCTAssertEqual(s.achievements.map(\.name), ["ACH_FIRST", "ACH_SECRET", "ACH_LAST"])
        XCTAssertEqual(s.achievements.map(\.statID), [4, 4, 4])
        XCTAssertEqual(s.achievements.map(\.bit), [0, 1, 2])
        XCTAssertEqual(s.achievements[0].displayName, ["english": "First", "german": "Erste"], "the token is not a language")
        XCTAssertEqual(s.achievements[1].displayName, ["english": "Secret"], "a plain string is English")
        XCTAssertTrue(s.achievements[1].hidden)
        XCTAssertEqual(s.achievements[0].text(s.achievements[0].displayName, language: "german"), "Erste")
        XCTAssertEqual(s.achievements[2].text(s.achievements[2].description), "ACH_LAST", "no description: the name")
    }

    func testUnlocksAreBitsOfTheBlock() throws {
        let snap = try snapshot(values: [4: 0b101], times: [4: [1000, 0, 3000]])
        XCTAssertEqual(snap.schema.achievements.map(snap.unlocked), [true, false, true])
        XCTAssertEqual(snap.unlockTime(snap.schema.achievements[2]), 3000)
        XCTAssertEqual(snap.unlockedCount, 2)
    }

    func testTheEmulatorsSchemaFiles() throws {
        let files = EmulatorStats.schemaFiles(try testSchema())
        let ach = try XCTUnwrap(try JSONSerialization.jsonObject(with: files["achievements.json"]!) as? [[String: Any]])
        XCTAssertEqual(ach.map { $0["name"] as? String }, ["ACH_FIRST", "ACH_SECRET", "ACH_LAST"])
        XCTAssertEqual(ach[1]["hidden"] as? String, "1")
        XCTAssertEqual((ach[0]["displayName"] as? [String: String])?["german"], "Erste")
        let stats = try XCTUnwrap(try JSONSerialization.jsonObject(with: files["stats.json"]!) as? [[String: Any]])
        XCTAssertEqual(stats.map { $0["type"] as? String }, ["int", "float", "avgrate"])
        XCTAssertEqual(stats[1]["default"] as? String, "1.5", "a string: gbe_fork drops a stat whose default is a number")
    }

    func testTheEmulatorsSaveRoundTrips() throws {
        let dir = try scratchDir("gse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = try testSchema()
        XCTAssertEqual(EmulatorStats.read(dir, schema: schema), .init(), "nothing saved yet")
        let p = EmulatorStats.Progress(unlocked: ["ACH_FIRST": 1234], stats: ["kills": 7, "best:time": Float(2.5).bitPattern])
        try EmulatorStats.write(p, to: dir)
        XCTAssertEqual(EmulatorStats.read(dir, schema: schema), p)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("stats/kills")), Data([7, 0, 0, 0]), "int32, little-endian")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stats/best.COLON.time").path))
        // The emulator's own entries stay; a locked one is not an unlock.
        let url = dir.appendingPathComponent("achievements.json")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["ACH_LAST"] = ["earned": false, "earned_time": 0]
        json["NOT_IN_SCHEMA"] = ["earned": true, "earned_time": 9]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        try EmulatorStats.write(.init(unlocked: ["ACH_SECRET": 5]), to: dir)
        XCTAssertEqual(EmulatorStats.read(dir, schema: schema).unlocked, ["ACH_FIRST": 1234, "ACH_SECRET": 5])
    }

    func testThePlan() throws {
        let steam = try snapshot(values: [4: 0b001, 1: 3, 2: Float(9).bitPattern], times: [4: [500]])
        // The emulator unlocked ACH_LAST, and killed more since the last sync;
        // its time is the one the last sync wrote (Steam's is newer).
        let local = EmulatorStats.Progress(unlocked: ["ACH_LAST": 600], stats: ["kills": 10, "best:time": Float(4).bitPattern])
        let plan = EmulatorStats.plan(steam: steam, local: local, baseline: ["kills": 3, "best:time": Float(4).bitPattern])
        XCTAssertEqual(plan.newUnlocks, ["ACH_LAST"])
        XCTAssertEqual(plan.store, [4: 0b101, 1: 10], "the block keeps Steam's bit and gets the new one")
        XCTAssertEqual(plan.local.unlocked, ["ACH_FIRST": 500], "Steam's unlock comes to the save")
        XCTAssertEqual(plan.local.stats, ["best:time": Float(9).bitPattern], "an unchanged local stat takes Steam's")
    }

    func testAFirstSyncTakesSteamsStatsAndSendsOnlyUnlocks() throws {
        let steam = try snapshot(values: [1: 3])
        let untouched = EmulatorStats.plan(steam: steam, local: .init(), baseline: nil)
        XCTAssertEqual(untouched.store, [:])
        XCTAssertEqual(untouched.local.stats, ["kills": 3, "best:time": Float(1.5).bitPattern])
        let played = EmulatorStats.plan(steam: steam, local: .init(unlocked: ["ACH_FIRST": 9], stats: ["kills": 1]), baseline: nil)
        XCTAssertEqual(played.store, [4: 1], "the unlock goes; the stat, maybe stale, does not")
        XCTAssertEqual(played.local.stats["kills"], 3)
        let changed = EmulatorStats.plan(steam: steam, local: .init(stats: ["kills": 5]), baseline: ["kills": 3])
        XCTAssertEqual(changed.store, [1: 5], "after a sync, a change is the game's")
        let same = EmulatorStats.plan(steam: steam, local: .init(stats: ["kills": 3]), baseline: ["kills": 0])
        XCTAssertEqual(same.store, [:], "nothing to store when both agree")
    }
}

final class StatsServiceTests: XCTestCase {
    func signedIn(_ b: FakeBackend, dir: URL?) async -> SteamService {
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: dir)
        _ = await s.restoreIfPossible()
        return s
    }

    func testSyncSendsWhatTheGameEarnedAndBringsWhatSteamHas() async throws {
        let b = FakeBackend()
        await b.set(stats: try snapshot(values: [4: 0b001, 1: 3], times: [4: [500]]))
        let dir = try scratchDir("stats-svc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saves = dir.appendingPathComponent("GSE Saves")
        let folder = EmulatorStats.folder(saves, appID: 367520)
        try EmulatorStats.write(.init(unlocked: ["ACH_SECRET": 700], stats: ["kills": 8]), to: folder)
        let s = await signedIn(b, dir: dir.appendingPathComponent("state"))

        let first = try await s.syncUserStats(appID: 367520, saves: saves)
        XCTAssertEqual(first.sentUnlocks, ["ACH_SECRET"])
        XCTAssertEqual(first.sentStats, 0, "a first sync sends no stat")
        let stored = await b.storedStats
        XCTAssertEqual(stored, [[4: 0b011]])
        XCTAssertEqual(first.steam.unlockedCount, 2)
        XCTAssertEqual(first.steam.unlockTime(first.steam.schema.achievements[1]), 700, "the game's unlock time")
        var local = EmulatorStats.read(folder, schema: first.steam.schema)
        XCTAssertEqual(local.unlocked["ACH_FIRST"], 500, "Steam's unlock is in the save")
        XCTAssertEqual(local.stats["kills"], 3, "and Steam's stats")

        // A play: the game's stat change goes; nothing else is sent again.
        try EmulatorStats.write(.init(stats: ["kills": 8]), to: folder)
        let second = try await s.syncUserStats(appID: 367520, saves: saves)
        XCTAssertEqual(second.sentStats, 1)
        let both = await b.storedStats
        XCTAssertEqual(both.last, [1: 8])
        local = EmulatorStats.read(folder, schema: first.steam.schema)
        XCTAssertEqual(local.stats["kills"], 8)

        // Nothing new: nothing sent. Then Steam moves on (another PC): the save follows.
        _ = try await s.syncUserStats(appID: 367520, saves: saves)
        let again = await b.count("storestats")
        XCTAssertEqual(again, 2)
        await b.set(stats: try snapshot(values: [4: 0b011, 1: 20], times: [4: [500, 700]]))
        _ = try await s.syncUserStats(appID: 367520, saves: saves)
        XCTAssertEqual(EmulatorStats.read(folder, schema: first.steam.schema).stats["kills"], 20)
        let stores = await b.count("storestats")
        XCTAssertEqual(stores, 2, "the save's old value was the baseline, not a change")

        // The launch tells the emulator the schema.
        let settings = await s.emulatorSettings(appID: 367520)
        XCTAssertEqual(settings.files.keys.sorted(), ["achievements.json", "stats.json"])

        // A sign-out deletes the kept stats.
        _ = try await s.signOut()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state/steam-stats").path))
    }

    func testARefusedStatGoesBackInTheSave() async throws {
        let b = FakeBackend()
        await b.set(stats: try snapshot(values: [1: 3]), refuse: [1: 3])
        let dir = try scratchDir("stats-refuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saves = dir.appendingPathComponent("GSE Saves")
        let folder = EmulatorStats.folder(saves, appID: 367520)
        let s = await signedIn(b, dir: nil)
        _ = try await s.syncUserStats(appID: 367520, saves: saves)   // the baseline
        try EmulatorStats.write(.init(stats: ["kills": 999_999]), to: folder)
        let r = try await s.syncUserStats(appID: 367520, saves: saves)
        XCTAssertEqual(r.refused, [1: 3])
        XCTAssertEqual(r.sentStats, 0)
        XCTAssertEqual(EmulatorStats.read(folder, schema: r.steam.schema).stats["kills"], 3)
    }

    func testSyncNeedsTheSessionAndNotASuspension() async throws {
        let s = SteamService(backend: FakeBackend(), log: .silent, stateDirectory: nil)
        do { _ = try await s.syncUserStats(appID: 1, saves: URL(fileURLWithPath: "/nonexistent")); XCTFail() }
        catch SteamError.notLoggedOn {}
        let b = FakeBackend()
        await b.set(stats: try snapshot())
        let s2 = await signedIn(b, dir: nil)
        await s2.suspendForLaunch()
        do { _ = try await s2.syncUserStats(appID: 1, saves: URL(fileURLWithPath: "/nonexistent")); XCTFail() }
        catch SteamError.unsupported(_) {}
    }
}

/// A CM that answers each request it is sent with `replies(request)`.
final class LoopbackCM: WebSocketTransport, @unchecked Sendable {
    let replies: @Sendable (CMPacket) -> [CMPacket]
    let frames: AsyncStream<[UInt8]>
    let input: AsyncStream<[UInt8]>.Continuation
    var iterator: AsyncStream<[UInt8]>.Iterator

    init(_ replies: @escaping @Sendable (CMPacket) -> [CMPacket]) {
        self.replies = replies
        (frames, input) = AsyncStream.makeStream()
        iterator = frames.makeAsyncIterator()
    }

    func send(_ bytes: [UInt8]) async throws {
        for r in replies(try CMPacket.parse(bytes)) { input.yield(r.serialize()) }
    }

    func receive() async throws -> [UInt8] {
        guard let f = await iterator.next() else { throw SteamError.transport("closed") }
        return f
    }

    func close() { input.finish() }
}

final class StatsReplyTests: XCTestCase {
    func reply(_ emsg: EMsg, app: UInt64, crc: UInt32) -> CMPacket {
        var w = ProtoWriter()
        w.fixed64(1, app)
        w.int32(2, 1)
        w.uint32(3, crc)
        return CMPacket(emsg: emsg, body: w.bytes)
    }

    func testAReplyForAnotherGameIsNotThisGamesStats() async throws {
        let other = reply(.clientGetUserStatsResponse, app: 1, crc: 11)
        let mine = reply(.clientGetUserStatsResponse, app: 2, crc: 22)
        let cm = CMConnection(endpoint: "loopback", log: .silent)
        let loop = LoopbackCM { _ in [other, mine] }
        await cm.attach(loop)
        defer { loop.close() }
        let p = try await cm.callEither(.clientGetUserStats, CMsgClientGetUserStats(gameID: 2, steamIDForUser: 0),
                                        reply: .clientGetUserStatsResponse, timeout: 5,
                                        accept: SteamSession.statsReply(forApp: 2))
        let r = try CMsgClientGetUserStatsResponse.decode(p.body)
        XCTAssertEqual(r.gameID, 2)
        XCTAssertEqual(r.crcStats, 22)
    }

    func testAStoreResultForAnotherGameIsNotThisGames() async throws {
        let other = reply(.clientStoreUserStatsResponse, app: 1, crc: 11)
        let cm = CMConnection(endpoint: "loopback", log: .silent)
        let loop = LoopbackCM { _ in [other] }
        await cm.attach(loop)
        defer { loop.close() }
        let msg = CMsgClientStoreUserStats2(gameID: 2, settorSteamID: 0, setteeSteamID: 0, crcStats: 0, stats: [(1, 1)])
        do {
            _ = try await cm.callEither(.clientStoreUserStats2, msg, reply: .clientStoreUserStatsResponse, timeout: 0.5,
                                        accept: SteamSession.statsReply(forApp: 2))
            XCTFail("took another game's store result")
        } catch SteamError.timeout(_) {}
    }
}
