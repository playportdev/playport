// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// The memory-kill note (PLA-847): a game's page says its last Play was ended for memory only when
/// the session its process left on disk read the footprint near the limit, and with that Play's peak
/// and limit.
final class MemoryKillTests: XCTestCase {
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + s) }

    /// A Play's readings, one per sampler tick, as the session on disk holds them.
    private func session(_ readings: [(footprintMB: Int, limitMB: Int)]) -> PlaySession {
        var s = PlaySession(titleID: "app-367520", now: at(0))
        for r in readings { s.read(footprintMB: r.footprintMB, limitMB: r.limitMB) }
        return s
    }

    func testAProcessThatEndedNearTheLimitWasKilledForMemory() {
        let left = session([(700, 8_192), (5_900, 8_192), (7_400, 8_192), (8_050, 8_192)])
        XCTAssertEqual(MemoryKill(leftBy: left), MemoryKill(peakMB: 8_050, limitMB: 8_192))
    }

    /// A crash, the app switcher, or `pp ui` ending the app with the game far from the limit.
    func testAProcessThatEndedFarFromTheLimitWasNot() {
        let left = session([(700, 8_192), (3_100, 8_192), (2_950, 8_192)])
        XCTAssertNil(MemoryKill(leftBy: left))
    }

    /// The peak is the Play's highest reading; nearness is the last one's: a game that climbed near
    /// the limit while loading, came back down and then ended is not a memory kill.
    func testOnlyTheLastReadingDecides() {
        XCTAssertNil(MemoryKill(leftBy: session([(7_900, 8_192), (4_000, 8_192)])))
        XCTAssertEqual(MemoryKill(leftBy: session([(7_900, 8_192), (4_000, 8_192), (7_500, 8_192)])),
                       MemoryKill(peakMB: 7_900, limitMB: 8_192))
    }

    /// Game Mode raises the limit a few seconds into the app (6 GB to 8 GB on the reference phone):
    /// the last reading's limit is the one the kill came at.
    func testTheLimitIsTheLastReadings() {
        let left = session([(5_500, 6_144), (7_600, 8_192)])
        XCTAssertEqual(MemoryKill(leftBy: left), MemoryKill(peakMB: 7_600, limitMB: 8_192))
    }

    /// A reading without a limit (none reported) keeps the last limit; a session with none at all,
    /// or from before the readings, says nothing.
    func testNoLimitNoNote() {
        var s = session([(7_000, 8_192)])
        s.read(footprintMB: 7_800, limitMB: nil)
        XCTAssertEqual(MemoryKill(leftBy: s), MemoryKill(peakMB: 7_800, limitMB: 8_192))
        var none = PlaySession(titleID: "app-367520", now: at(0))
        none.read(footprintMB: 7_800, limitMB: nil)
        XCTAssertNil(MemoryKill(leftBy: none))
        XCTAssertNil(MemoryKill(leftBy: PlaySession(titleID: "app-367520", now: at(0))))
    }

    /// The session on disk at a kill, from readings (seconds, footprint) under one limit: the app reads
    /// every 250 ms, writes the session at every 5 s beat, and between beats when the reading needs it.
    private func onDiskAtKill(_ readings: [(Double, Int)], limitMB: Int) -> (session: PlaySession?, writes: Int) {
        var s = PlaySession(titleID: "app-1174180", now: at(0))
        var written: PlaySession?
        var lastWrite = -Double.infinity, writes = 0
        for (t, mb) in readings {
            s.read(footprintMB: mb, limitMB: limitMB)
            if t - lastWrite >= 5 || s.memory!.needsWrite(after: written?.memory) {
                written = s
                lastWrite = t
                writes += 1
            }
        }
        return (written, writes)
    }

    /// Run l9's last 41 s before iOS ended it at its 8,192 MB limit: the last beat's 6,9xx MB is
    /// over 1 GB under the limit, but the climb near it is on disk up to the kill.
    func testAKillFindsItsLastClimbOnDisk() throws {
        let (left, _) = onDiskAtKill(FootprintJumpTriggerTests.l9, limitMB: 8_192)
        XCTAssertEqual(MemoryKill(leftBy: try XCTUnwrap(left)), MemoryKill(peakMB: 8_106, limitMB: 8_192))
    }

    /// A game that left the zone near the limit before its process ended is on disk as far from it.
    func testLeavingTheLimitIsOnDisk() throws {
        let (left, _) = onDiskAtKill([(0, 7_500), (1, 7_600), (2, 4_000)], limitMB: 8_192)
        XCTAssertNil(MemoryKill(leftBy: try XCTUnwrap(left)))
    }

    /// Far from the limit only the beats write, as before the readings.
    func testFarFromTheLimitOnlyTheBeatsWrite() {
        let readings = stride(from: 0.0, to: 20, by: 0.25).map { ($0, 2_000 + Int($0 * 100)) }
        XCTAssertEqual(onDiskAtKill(readings, limitMB: 8_192).writes, 4)
    }

    private func title(_ id: String, app: UInt32, dir: String) -> InstalledTitle {
        InstalledTitle(id: id, appID: app, name: dir, developer: nil, installDir: dir, executable: "game.exe",
                       buildID: nil, depots: [], sizeBytes: nil, source: .installed, checksums: nil, note: nil,
                       addedAt: at(0), lastPlayed: nil, lastVerification: nil)
    }

    /// The next process notes a kill on the game it ended; the game's next Play that ends any other
    /// way (in its process, or left on disk far from the limit) clears it; other games keep theirs.
    func testTheNoteLastsUntilTheGamesNextOtherEnd() throws {
        var c = Catalog(titles: [title("app-367520", app: 367520, dir: "Hollow Knight"),
                                 title("app-1562700", app: 1562700, dir: "SANABI")])
        let kill = try XCTUnwrap(MemoryKill(leftBy: session([(5_800, 6_144)])))
        c.playEnded("app-1562700", kill: kill)
        c.playEnded("app-367520", kill: MemoryKill(leftBy: session([(2_900, 8_192)])))
        XCTAssertEqual(c.title(id: "app-1562700")?.memoryKill, MemoryKill(peakMB: 5_800, limitMB: 6_144))
        XCTAssertNil(c.title(id: "app-367520")?.memoryKill)
        // A second kill replaces the figures.
        c.playEnded("app-1562700", kill: MemoryKill(peakMB: 8_100, limitMB: 8_192))
        XCTAssertEqual(c.title(id: "app-1562700")?.memoryKill, MemoryKill(peakMB: 8_100, limitMB: 8_192))
        c.playEnded("app-367520", kill: nil)
        XCTAssertEqual(c.title(id: "app-1562700")?.memoryKill, MemoryKill(peakMB: 8_100, limitMB: 8_192))
        c.playEnded("app-1562700", kill: nil)
        XCTAssertNil(c.title(id: "app-1562700")?.memoryKill)
    }

    /// The note is the catalogue's: on disk with it, across a re-adoption of the folder and over a
    /// scan that ran while the Play ended.
    func testTheNoteIsKeptWithTheCatalogue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memorykill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let games = root.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: games.appendingPathComponent("SANABI"), withIntermediateDirectories: true)
        try Data().write(to: games.appendingPathComponent("SANABI/SANABI.exe"))
        let empty = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], previous: Catalog(), now: at(0))
        let id = try XCTUnwrap(empty.titles.first?.id)
        var c = empty
        c.playEnded(id, kill: MemoryKill(peakMB: 8_100, limitMB: 8_192))
        let store = CatalogStore(url: root.appendingPathComponent("catalog.json"))
        try store.save(c)
        XCTAssertEqual(store.load().title(id: id)?.memoryKill, MemoryKill(peakMB: 8_100, limitMB: 8_192))
        let again = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], previous: c, now: at(10))
        XCTAssertEqual(again.title(id: id)?.memoryKill, MemoryKill(peakMB: 8_100, limitMB: 8_192))
        XCTAssertEqual(empty.keepingEdits(of: c).title(id: id)?.memoryKill, MemoryKill(peakMB: 8_100, limitMB: 8_192))
    }

    /// The note never stands between the player and Play: the game stays ready, with the same
    /// launch, and the checks before a launch pass with any memory signature.
    func testNothingRefusesPlay() throws {
        var c = Catalog(titles: [title("app-1562700", app: 1562700, dir: "SANABI")])
        let before = try XCTUnwrap(c.title(id: "app-1562700")).launchPlan(cohort: Cohort(titles: []))
        c.playEnded("app-1562700", kill: MemoryKill(peakMB: 6_200, limitMB: 6_144))
        let noted = try XCTUnwrap(c.title(id: "app-1562700"))
        XCTAssertTrue(noted.canPlay)
        XCTAssertEqual(noted.badge, .ready)
        XCTAssertEqual(try noted.launchPlan(cohort: Cohort(titles: [])), before)
        for entitled in [true, false, nil] as [Bool?] {
            XCTAssertEqual(SetupChecklist.beforeLaunch(SetupFacts(pairing: true, tunnelUp: true, steamSignedIn: true,
                                                                  memoryEntitled: entitled)), .go)
        }
    }
}
