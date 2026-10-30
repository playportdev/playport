// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit
import SteamClientKit

/// A copy's licence lapse (an Xbox copy's, PLA-505): only a definitive refusal starts it,
/// removal falls due 7 days after the first one, a returning licence cancels it, saves not
/// yet in the cloud hold the removal, and the player may remove the copy earlier.
final class LicenceLapseTests: XCTestCase {
    private let copy = StoreGameKey(store: .xbox, id: "9MW9469V91LM")
    private let other = StoreGameKey(store: .xbox, id: "9NBLGGH4R315")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }

    private struct Saves: UnsyncedSaves {
        var answer: [StoreGameKey: Bool] = [:]
        var unknown: Set<StoreGameKey> = []
        func unsynced(_ key: StoreGameKey) -> Bool? { unknown.contains(key) ? nil : answer[key] ?? false }
    }
    private let synced = Saves()

    func testOnlyADefinitiveRefusalStartsALapse() {
        var lapses = LicenceLapses()
        XCTAssertFalse(lapses.record(.noVerdict, for: copy, at: start))
        XCTAssertFalse(lapses.record(.granted, for: copy, at: start))
        XCTAssertEqual(lapses.state(copy, at: days(30), saves: synced), .licensed)
        XCTAssertTrue(lapses.due(at: days(30), saves: synced).isEmpty)

        XCTAssertTrue(lapses.record(.refused, for: copy, at: start))
        XCTAssertEqual(lapses.state(copy, at: start, saves: synced), .lapsed(removeAt: days(7)))
        XCTAssertEqual(lapses.state(other, at: start, saves: synced), .licensed, "a refusal lapses its own copy only")
    }

    func testNetworkAndServiceProblemsNeverCountOrCancel() {
        var lapses = LicenceLapses()
        for day in 0..<30 { XCTAssertFalse(lapses.record(.noVerdict, for: copy, at: days(Double(day)))) }
        XCTAssertNil(lapses.lapse(copy))

        lapses.record(.refused, for: copy, at: start)
        XCTAssertFalse(lapses.record(.noVerdict, for: copy, at: days(3)), "an outage neither cancels nor moves the lapse")
        XCTAssertEqual(lapses.lapse(copy)?.refusedAt, start)
    }

    func testRemovalFallsDueSevenDaysAfterTheFirstRefusal() {
        var lapses = LicenceLapses()
        lapses.record(.refused, for: copy, at: start)
        XCTAssertFalse(lapses.record(.refused, for: copy, at: days(5)), "a later refusal keeps the first one's date")
        XCTAssertEqual(lapses.lapse(copy)?.removeAt, days(7))

        XCTAssertEqual(lapses.state(copy, at: days(7).addingTimeInterval(-1), saves: synced), .lapsed(removeAt: days(7)))
        XCTAssertEqual(lapses.due(at: days(7).addingTimeInterval(-1), saves: synced), [])
        XCTAssertEqual(lapses.state(copy, at: days(7), saves: synced), .due)
        XCTAssertEqual(lapses.due(at: days(7), saves: synced), [copy])
        XCTAssertEqual(LicenceLapses.grace, 7 * 86_400)
    }

    func testAReturningLicenceCancelsTheLapse() {
        var lapses = LicenceLapses()
        lapses.record(.refused, for: copy, at: start)
        XCTAssertTrue(lapses.record(.granted, for: copy, at: days(6)))
        XCTAssertEqual(lapses.state(copy, at: days(8), saves: synced), .licensed)
        XCTAssertEqual(lapses.due(at: days(8), saves: synced), [])

        // A refusal after that starts a new grace from its own date.
        lapses.record(.refused, for: copy, at: days(10))
        XCTAssertEqual(lapses.lapse(copy)?.removeAt, days(17))
    }

    func testUnsyncedSavesHoldTheRemoval() {
        var lapses = LicenceLapses()
        lapses.record(.refused, for: copy, at: start)
        lapses.record(.refused, for: other, at: start)
        let held = Saves(answer: [copy: true])
        XCTAssertEqual(lapses.state(copy, at: days(9), saves: held), .held(removeAt: days(7)))
        XCTAssertEqual(lapses.due(at: days(9), saves: held), [other], "only the copy with unsynced saves waits")

        // Unknown counts as unsynced: no removal on a guess.
        let unknown = Saves(unknown: [copy])
        XCTAssertEqual(lapses.state(copy, at: days(9), saves: unknown), .held(removeAt: days(7)))
        XCTAssertEqual(lapses.state(copy, at: days(9), saves: UnknownSaves()), .held(removeAt: days(7)))

        // Within the grace the saves don't matter yet; once in the cloud the removal goes ahead.
        XCTAssertEqual(lapses.state(copy, at: days(2), saves: held), .lapsed(removeAt: days(7)))
        XCTAssertEqual(lapses.due(at: days(9), saves: synced), [copy, other])
    }

    /// A store's own answer (the dev app's Xbox one: XboxCloudSaves.unsynced(productID:),
    /// the runtime's save index): removal waits while the copy has unsynced saves and runs
    /// once they are synced; another store's copies stay unknown, so held.
    func testAStoresUnsyncedSavesHoldTheRemovalUntilTheyAreSynced() {
        final class Index: @unchecked Sendable { var unsynced: [String: Bool?] = [:] }
        let index = Index()
        let saves = StoreUnsyncedSaves(.xbox) { index.unsynced[$0] ?? false }
        var lapses = LicenceLapses()
        lapses.record(.refused, for: copy, at: start)
        index.unsynced[copy.id] = true
        XCTAssertEqual(lapses.due(at: days(9), saves: saves), [], "a play left saves unsynced")
        XCTAssertEqual(lapses.state(copy, at: days(9), saves: saves), .held(removeAt: days(7)))
        index.unsynced[copy.id] = .some(nil)
        XCTAssertEqual(lapses.due(at: days(9), saves: saves), [], "an index that can't be read")
        index.unsynced[copy.id] = false
        XCTAssertEqual(lapses.due(at: days(9), saves: saves), [copy], "synced at the next play: the removal runs")
        XCTAssertNil(saves.unsynced(StoreGameKey(store: .epic, id: "9MW9469V91LM")))
    }

    func testThePlayerMayRemoveTheCopyEarlier() {
        var lapses = LicenceLapses()
        lapses.record(.refused, for: copy, at: start)
        XCTAssertTrue(lapses.state(copy, at: days(1), saves: Saves(answer: [copy: true])).isLapsed)
        XCTAssertTrue(lapses.removed(copy))
        XCTAssertEqual(lapses.state(copy, at: days(1), saves: synced), .licensed)
        XCTAssertEqual(lapses.due(at: days(30), saves: synced), [])
        XCTAssertFalse(lapses.removed(copy), "nothing left to remove")
    }

    func testLapsesOfCopiesNoLongerInstalledAreDropped() {
        var lapses = LicenceLapses()
        lapses.record(.refused, for: copy, at: start)
        lapses.record(.refused, for: other, at: start)
        XCTAssertTrue(lapses.keep(only: [copy]))
        XCTAssertNotNil(lapses.lapse(copy))
        XCTAssertNil(lapses.lapse(other))
        XCTAssertFalse(lapses.keep(only: [copy]))
    }

    func testTheLedgerRoundTripsThroughItsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lapses-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state/lapses.json")
        XCTAssertEqual(LicenceLapses.load(file), LicenceLapses(), "no file: no lapse")

        var lapses = LicenceLapses()
        lapses.record(.refused, for: copy, at: start)
        try lapses.save(file)
        XCTAssertEqual(LicenceLapses.load(file), lapses)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("xbox-9MW9469V91LM"), text)

        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(LicenceLapses.load(file), LicenceLapses(), "an unreadable ledger removes nothing")
    }
}
