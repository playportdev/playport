// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import BattleNetClientKit

/// One canned answer for every URL, and what was asked with which headers.
private final class OneAnswer: BattleNetTransport, @unchecked Sendable {
    private let lock = NSLock()
    let answer: BattleNetResponse
    private(set) var asked = [(url: URL, headers: [String: String])]()

    init(_ answer: BattleNetResponse) { self.answer = answer }

    func get(_ url: URL, headers: [String: String]) async throws -> BattleNetResponse {
        lock.withLock {
            asked.append((url, headers))
            return answer
        }
    }
}

final class BattleNetArtTests: XCTestCase {
    /// The start of a JPEG (SOI, then a JFIF APP0 marker), as Blizzard's image host sends one.
    let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9]

    func testEachProductHasItsOwnArtOnBlizzardsPublicImageHost() {
        // Retail's tile: the World of Warcraft site's page image (curl, 2026-10-31: 200, 800×450 JPEG).
        XCTAssertEqual(BattleNetArt.url(.wow, .tile).absoluteString,
                       "https://blz-contentstack-images.akamaized.net/v3/assets/blt9c12f249ac15c7ec/bltb5a24e5ab1e2cfb0/"
                           + "6a88e3589b942efdb6f74110/wow-thumbnail-homepage.jpg?width=800&format=jpg&quality=85")
        // Classic Era's page backdrop: the Classic site's Era panel, cropped to 16:9 at 1600 wide.
        XCTAssertEqual(BattleNetArt.url(.wowClassicEra, .hero).absoluteString,
                       "https://blz-contentstack-images.akamaized.net/v3/assets/blt9c12f249ac15c7ec/bltd7f3db63b41b3f73/"
                           + "6a86c0659b942ed84ef740cf/classic-bg.png?crop=2000,1125,x0,y300&width=1600&format=jpg&quality=85")
        for size in BattleNetArt.Size.allCases {
            let urls = BattleNetProduct.allCases.map { BattleNetArt.url($0, size) }
            XCTAssertEqual(Set(urls).count, BattleNetProduct.allCases.count, "each product its own \(size) art")
            for url in urls {
                XCTAssertEqual(url.scheme, "https")
                XCTAssertEqual(url.host, "blz-contentstack-images.akamaized.net")
            }
        }
        // Tile and backdrop are one picture at two widths.
        for p in BattleNetProduct.allCases {
            XCTAssertEqual(BattleNetArt.url(p, .tile).path, BattleNetArt.url(p, .hero).path)
            XCTAssertNotEqual(BattleNetArt.url(p, .tile), BattleNetArt.url(p, .hero))
        }
    }

    func testOnlyRetailsArtCarriesTheGamesName() {
        // Retail's picture has the World of Warcraft logo; the Classic panels have no words, so
        // the tile draws the product's name over them.
        XCTAssertEqual(BattleNetProduct.allCases.filter(BattleNetArt.carriesName), [.wow])
    }

    func testArtIsAskedWithPlayportsUserAgentAndMustBeAJPEG() async throws {
        let good = OneAnswer(BattleNetResponse(status: 200, headers: ["content-type": "image/jpeg"], body: jpeg))
        let bytes = try await BattleNetClient(transport: good).art(.wowAnniversary, .tile)
        XCTAssertEqual(bytes, jpeg)
        XCTAssertEqual(good.asked.map(\.url), [BattleNetArt.url(.wowAnniversary, .tile)])
        XCTAssertEqual(good.asked.first?.headers["User-Agent"], "Playport")

        let gone = OneAnswer(BattleNetResponse(status: 404, body: Array("Not Found".utf8)))
        do {
            _ = try await BattleNetClient(transport: gone).art(.wow, .hero)
            XCTFail("a 404 is no art")
        } catch let e as BattleNetError {
            XCTAssertEqual(e, .refused(status: 404, "wow art from blz-contentstack-images.akamaized.net"))
        }

        let page = OneAnswer(BattleNetResponse(status: 200, headers: ["content-type": "text/html"], body: Array("<html>".utf8)))
        do {
            _ = try await BattleNetClient(transport: page).art(.wow, .hero)
            XCTFail("a page is no art")
        } catch let e as BattleNetError {
            XCTAssertEqual(e, .damaged("wow art: not a JPEG"))
        }
    }
}
