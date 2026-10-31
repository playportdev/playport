// SPDX-License-Identifier: GPL-3.0-or-later
@testable import PlayportKit
import BattleNetClientKit
import Foundation
import XCTest

/// Counts the fetches it is asked for and answers each with the next of its answers.
private final class Fetches: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<[UInt8], Error>]
    private(set) var count = 0

    init(_ answers: [Result<[UInt8], Error>]) { self.answers = answers }

    func next() throws -> [UInt8] {
        try lock.withLock {
            count += 1
            return try answers.removeFirst().get()
        }
    }
}

final class BattleNetArtCacheTests: XCTestCase {
    func testAProductsArtIsFetchedOnceThenReadFromCaches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bnet-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let picture: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9]
        let fetches = Fetches([.success(picture)])

        XCTAssertNil(BattleNetArtCache(directory: dir).cached(.wowClassicEra, .hero), "nothing before the first fetch")
        let first = await BattleNetArtCache(directory: dir).load(.wowClassicEra, .hero) { try fetches.next() }
        XCTAssertEqual(first.map { [UInt8]($0) }, picture)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("battlenet-wow_classic_era_hero.jpg")), Data(picture))

        // Another launch: the file, with no fetch; the launch screen reads it with no network.
        let again = await BattleNetArtCache(directory: dir).load(.wowClassicEra, .hero) { try fetches.next() }
        XCTAssertEqual(again.map { [UInt8]($0) }, picture)
        XCTAssertEqual(BattleNetArtCache(directory: dir).cached(.wowClassicEra, .hero), Data(picture))
        XCTAssertEqual(fetches.count, 1)
        // The tile is its own file.
        XCTAssertNil(BattleNetArtCache(directory: dir).cached(.wowClassicEra, .tile))
    }

    func testAFailedFetchKeepsNothingAndIsAskedAgainNextTime() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bnet-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let picture: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDB, 9, 0xFF, 0xD9]
        let fetches = Fetches([.failure(BattleNetError.refused(status: 404, "wow art")), .success(picture)])
        let cache = BattleNetArtCache(directory: dir)

        let failed = await cache.load(.wow, .tile) { try fetches.next() }
        XCTAssertNil(failed)
        XCTAssertNil(cache.cached(.wow, .tile))
        let later = await cache.load(.wow, .tile) { try fetches.next() }
        XCTAssertEqual(later.map { [UInt8]($0) }, picture)
        XCTAssertEqual(fetches.count, 2)
    }
}
