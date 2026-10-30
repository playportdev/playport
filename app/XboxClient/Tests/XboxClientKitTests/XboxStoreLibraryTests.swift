// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
import XboxClientKit

/// Fixtures: `entitlements.json` is rows of the ground-truth PCGAFD response (PLA-487
/// capture 40, renewal IDs redacted); `catalog-products.json` is the display
/// catalogue's records for those products and their bundles' products (the pilot's
/// from capture 21, the rest from the public endpoint), trimmed to the fields read.
struct XboxStaticTickets: XboxStoreTickets {
    func storeAuthorization() async throws -> Secret<String> { Secret("t=" + String(repeating: "s", count: 24) + "&p=") }
}

actor XboxLibraryHTTP: XboxHTTP {
    var pages: [XboxHTTPResponse]
    var catalogue: [String: Any] = [:]
    var calls: [XboxHTTPRequest] = []
    init(entitlements: [[UInt8]], continuation: [String?] = []) throws {
        pages = entitlements.enumerated().map { i, body in
            XboxHTTPResponse(status: 200, body: body, headers: (i < continuation.count ? continuation[i] : nil).map { ["x-ms-ct": $0] } ?? [:])
        }
        let root = try JSONSerialization.jsonObject(with: Data(xboxFixture("catalog-products.json"))) as! [String: Any]
        for case let product as [String: Any] in root["Products"] as! [Any] { catalogue[product["ProductId"] as! String] = product }
    }
    func forget(_ id: String) { catalogue[id] = nil }
    func send(_ request: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        calls.append(request)
        switch request.url.host {
        case "beige.xboxservices.com": return pages.isEmpty ? XboxHTTPResponse(status: 500, body: []) : pages.removeFirst()
        case "displaycatalog.mp.microsoft.com":
            let ids = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "bigIds" }!.value!
            let found = ids.split(separator: ",").compactMap { catalogue[String($0)] }
            return XboxHTTPResponse(status: 200, body: Array(try JSONSerialization.data(withJSONObject: ["Products": found])))
        default: return XboxHTTPResponse(status: 404, body: [])
        }
    }
    /// Product IDs asked of the display catalogue, in order.
    func looked() -> [String] {
        calls.filter { $0.url.host == "displaycatalog.mp.microsoft.com" }.flatMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "bigIds" }!.value!.split(separator: ",").map(String.init)
        }
    }
    func entitlementRequests() -> [XboxHTTPRequest] { calls.filter { $0.url.host == "beige.xboxservices.com" } }
}

final class XboxStoreLibraryTests: XCTestCase, @unchecked Sendable {
    /// 2026-10-30 12:00 UTC, the capture's day: before the Game Pass licences' end.
    let now = Date(timeIntervalSince1970: 1_793_361_600)
    let pilot = "9MW9469V91LM"

    func library(_ http: XboxLibraryHTTP, log: Logger = .silent) -> XboxStoreLibrary {
        XboxStoreLibrary(tickets: XboxStaticTickets(), http: http, log: log, now: { [now] in now })
    }
    func rows(_ rows: [String: [String: Any]]) throws -> [UInt8] {
        Array(try JSONSerialization.data(withJSONObject: ["entitlements": rows]))
    }
    func row(_ parent: String? = "CFQ7TTC0KGQ8", status: String = "Active", trial: Bool = false, sharing: String = "None",
             end: String = "9999-12-31T23:59:59.997Z") -> [String: Any] {
        var row: [String: Any] = ["status": status, "isTrial": trial, "sharingSource": sharing, "endDate": end, "autoRenew": false]
        if let parent { row["satisfiedByProductId"] = parent }
        return row
    }

    func testTheRecordedLibraryListsGDKCopiesWithTitlesAndArtAndLeavesOutOtherDeliveries() async throws {
        let http = try XboxLibraryHTTP(entitlements: [xboxFixture("entitlements.json")]), lines = XboxLines()
        let snapshot = try await library(http, log: lines.logger).refresh()
        XCTAssertEqual(snapshot.copies.map(\.id), ["9N94NCGM1Q2N", "9PP5G1F0C2B6", pilot, "9P8MK4NC0LJB", "9NB6BVL3MTG4"])
        XCTAssertEqual(snapshot.copies.map(\.title), ["Age of Empires IV: Anniversary Edition", "Halo Infinite", "Hollow Knight: Voidheart Edition",
                                                      "Minecraft Dungeons for Windows", "Minecraft Dungeons for Windows + Launcher"])
        XCTAssertEqual(snapshot.copies.map(\.access), [.gamePass, .owned, .gamePass, .gamePass, .gamePass])
        let hollow = try XCTUnwrap(snapshot.copies.first { $0.id == pilot })
        for art in [hollow.tileArt, hollow.heroArt] {
            XCTAssertEqual(art?.scheme, "https"); XCTAssertEqual(art?.host, "store-images.s-microsoft.com")
        }
        XCTAssertNotEqual(hollow.tileArt, hollow.heroArt, "titled art for the tile, the textless hero for a page")
        // Left out: other launchers, UWP/EAppx, an add-on, editions whose games are listed already.
        let delivery = snapshot.products.mapValues(\.delivery)
        XCTAssertEqual(delivery["9MTD9ZS1G3CC"], .elsewhere, "Dead Space 3: the EA app")
        XCTAssertEqual(delivery["9N0H62KZ3BXV"], .elsewhere, "Diablo IV: Battle.net")
        XCTAssertEqual(delivery["9NNLBL0T2Z43"], .otherPackage, "Sunset Overdrive: EAppx")
        XCTAssertEqual(delivery["9NBLGGH1Z6FB"], .otherPackage, "Ori: a UWP AppxBundle")
        XCTAssertEqual(delivery["9NBLGGH515BD"], .otherPackage, "Halo Wars 2's edition: its primary product is EAppx")
        XCTAssertEqual(delivery["9P4P1LPN4VZQ"], .notAGame)
        XCTAssertEqual(delivery["9NTH1K5RT43P"], .gdk, "an edition of a listed game")
        XCTAssertEqual(delivery["9NP1P1WFS0LB"], .gdk)
        XCTAssertEqual(snapshot.leftOut, 9)
        XCTAssertEqual(snapshot.checkedAt, now)
        // Bundles' products are looked up in a second round; nothing twice.
        let looked = await http.looked()
        XCTAssertEqual(Set(looked).count, looked.count)
        XCTAssertTrue(looked.contains("9PGW18NPBZV5"), "Minecraft Launcher, a product of an edition")
        // The Store ticket goes to the entitlements only; the catalogue is public.
        let calls = await http.calls
        for call in calls { XCTAssertEqual(call.headers["Authorization"] != nil, call.url.host == "beige.xboxservices.com") }
        XCTAssertFalse(lines.text.contains("sssssssss"))
        XCTAssertTrue(lines.text.contains("library: 5 copies (1 owned, 4 PC Game Pass); 9 licensed products left out"))
        // Each copy names the package it installs: the pilot's Windows.Desktop MSIXVC (the console's XVC is not it).
        let package = try XCTUnwrap(snapshot.products[pilot]?.package)
        XCTAssertEqual([package.contentID, package.format, String(package.downloadSize)], ["31f3afa5-02a7-4cd9-ac6e-4f4be4604ab8", "MSIXVC", "5281849344"])
        XCTAssertEqual(package.neededBytes, 5_545_941_811, "the download plus the install engine's 5% margin")
        for copy in snapshot.copies { XCTAssertNotNil(snapshot.products[copy.id]?.package, copy.id) }
        XCTAssertNil(snapshot.products["9NNLBL0T2Z43"]?.package, "EAppx is no package Playport installs")
    }

    /// A cache from before copies carried their package looks the GDK products up again, once.
    func testACachedCopyWithoutItsPackageIsLookedUpAgain() async throws {
        let body = try rows([pilot: row()])
        let http = try XboxLibraryHTTP(entitlements: [body, body, body])
        let library = library(http)
        var old = try await library.refresh()
        old.products[pilot]?.package = nil
        let lookedBefore = await http.looked().count
        let renewed = try await library.refresh(old)
        XCTAssertEqual(renewed.products[pilot]?.package?.contentID, "31f3afa5-02a7-4cd9-ac6e-4f4be4604ab8")
        let again = try await library.refresh(renewed)
        XCTAssertEqual(again.products[pilot], renewed.products[pilot])
        let looked = await http.looked()
        XCTAssertEqual(Array(looked[lookedBefore...]), [pilot])
    }

    func testOnlyActiveLicencesOfTheAccountGiveACopyAndABundleLicenceIsOwnership() async throws {
        // Only products with access are looked up, so the lookups show what access was given.
        let body = try rows([
            pilot: row(trial: true),                                   // a trial
            "9PP5G1F0C2B6": row(nil, end: "2026-10-01T00:00:00Z"),     // expired
            "9P8MK4NC0LJB": row(sharing: "Family"),                    // shared, not the account's
            "9N94NCGM1Q2N": row(status: "Suspended"),
            "9PGW18NPBZV5": row("9NB6BVL3MTG4"),                       // through a bought edition: owned
            "9NB6BVL3MTG4": row(nil),
            "9NBLGGH5WMKM": row("9ZZZZZZZZZZZ"),                       // an unknown parent that is no plan
            "9NBLGGH1Z6FB": ["status": "Active"],                      // malformed …
            "9NNLBL0T2Z43": row("9NBLGGH1Z6FB"),                       // … so its child is out too
            "CFQ7TTC0KGQ8": row(nil),                                  // the plan is no copy
        ])
        let http = try XboxLibraryHTTP(entitlements: [body])
        let snapshot = try await library(http).refresh()
        XCTAssertEqual(snapshot.copies.map { "\($0.id) \($0.access)" }, ["9NB6BVL3MTG4 owned", "9PGW18NPBZV5 owned"])
        let looked = await http.looked()
        XCTAssertEqual(Set(looked), ["9NB6BVL3MTG4", "9PGW18NPBZV5", "9P8MK4NC0LJB"],
                       "the two owned products, then the edition's other product (shared, so no copy)")
    }

    func testAnUntrustedLicenceFlagGivesNoCopy() async throws {
        var flagged = row(nil); flagged["isPositron"] = true
        var trusted = row(nil); trusted["isPositron"] = false
        let http = try XboxLibraryHTTP(entitlements: [try rows([pilot: flagged, "9PP5G1F0C2B6": trusted])])
        let snapshot = try await library(http).refresh()
        XCTAssertEqual(snapshot.copies.map(\.id), ["9PP5G1F0C2B6"])
    }

    /// The app refreshes each time the Library opens: entitlements every time, the
    /// catalogue for new products only; a title leaving Game Pass leaves the list.
    func testARefreshReadsTheEntitlementsAgainAndLooksUpOnlyNewProducts() async throws {
        let first = try rows([pilot: row(), "9PP5G1F0C2B6": row(nil)])
        let second = try rows(["9PP5G1F0C2B6": row(nil), "9P8MK4NC0LJB": row()])
        let http = try XboxLibraryHTTP(entitlements: [first, second])
        let library = library(http)
        let before = try await library.refresh()
        XCTAssertEqual(before.copies.map(\.id), ["9PP5G1F0C2B6", pilot])
        let lookedBefore = await http.looked().count
        let after = try await library.refresh(before)
        XCTAssertEqual(after.copies.map(\.id), ["9PP5G1F0C2B6", "9P8MK4NC0LJB"])
        let looked = await http.looked()
        XCTAssertEqual(Array(looked[lookedBefore...]), ["9P8MK4NC0LJB"])
        XCTAssertNil(after.products[pilot], "a product no longer licensed leaves the cache")
        let requests = await http.entitlementRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testAProductWhoseBundleCannotBeResolvedIsLookedUpAgainNextTime() async throws {
        let body = try rows(["9NB6BVL3MTG4": row()])
        let http = try XboxLibraryHTTP(entitlements: [body, body])
        await http.forget("9P8MK4NC0LJB"); await http.forget("9PGW18NPBZV5")
        let library = library(http)
        let first = try await library.refresh()
        XCTAssertEqual(first.copies, []); XCTAssertNil(first.products["9NB6BVL3MTG4"])
        let second = try await library.refresh(first)
        XCTAssertEqual(second.copies, [])
        let looked = await http.looked()
        XCTAssertEqual(looked.filter { $0 == "9NB6BVL3MTG4" }.count, 2)
    }

    func testTheMarketIsATwoLetterRegionElseUS() {
        XCTAssertEqual(XboxMarket.valid("GB"), "GB")
        for bad in [nil, "gb", "GBR", "", "419", "G1"] { XCTAssertEqual(XboxMarket.valid(bad), "US", bad ?? "nil") }
        XCTAssertEqual(XboxMarket.valid(XboxMarket.current), XboxMarket.current)
    }

    func testEntitlementPagesFollowTheContinuationAndARepeatedPageIsRefused() async throws {
        let http = try XboxLibraryHTTP(entitlements: [try rows([pilot: row()]), try rows(["9PP5G1F0C2B6": row(nil)])],
                                       continuation: ["page-two"])
        let snapshot = try await library(http).refresh()
        XCTAssertEqual(snapshot.copies.map(\.id), ["9PP5G1F0C2B6", pilot])
        let requests = await http.entitlementRequests()
        XCTAssertEqual(requests.map { $0.headers["x-ms-ct"]?.value }, [nil, "page-two"])
        XCTAssertEqual(requests.first?.url.query, "market=US&language=en-US&appVersion=0.2.3")

        let loop = try XboxLibraryHTTP(entitlements: [try rows([pilot: row()]), try rows([pilot: row()]), try rows([pilot: row()])],
                                       continuation: ["again", "again"])
        do { _ = try await library(loop).refresh(); XCTFail("a repeated page") } catch let error as ClientError {
            guard case .protocolChanged = error else { return XCTFail("\(error)") }
        }
    }

    func testARefusedTicketAsksForSignInAndAMalformedResponseIsAnError() async throws {
        let refused = try XboxLibraryHTTP(entitlements: [])
        await refused.setPages([XboxHTTPResponse(status: 401, body: [])])
        do { _ = try await library(refused).refresh(); XCTFail("refused") } catch XboxSessionError.signInRequired {}
        let malformed = try XboxLibraryHTTP(entitlements: [Array("{\"entitlements\":[]}".utf8)])
        do { _ = try await library(malformed).refresh(); XCTFail("malformed") } catch let error as ClientError {
            guard case .protocolChanged = error else { return XCTFail("\(error)") }
        }
    }
}

extension XboxLibraryHTTP {
    func setPages(_ responses: [XboxHTTPResponse]) { pages = responses }
}
