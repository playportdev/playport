// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// The display catalogue over a fixed set of records; records it lacks are left out, as Microsoft's.
actor XboxCatalogueHTTP: XboxHTTP {
    let records: [String: [String: Any]]
    var calls: [XboxHTTPRequest] = []
    var failing = false
    init(_ records: [String: [String: Any]]) { self.records = records }
    func fail() { failing = true }
    func send(_ request: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        calls.append(request)
        if failing { return XboxHTTPResponse(status: 503, body: []) }
        let ids = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "bigIds" }!.value!
        let found = ids.split(separator: ",").compactMap { records[String($0)] }
        return XboxHTTPResponse(status: 200, body: Array(try JSONSerialization.data(withJSONObject: ["Products": found])))
    }
}

/// Fixture: `catalog-addons.json` is the public display catalogue's records (2026-10-30,
/// US, no account) for Indiana Jones and the Great Circle (9N8FQ28Z6QX3) and two of its
/// add-ons, an add-on of DOOM: The Dark Ages, and Gears of War: Reloaded (9P8PS6993LSL)
/// with a skin that has no package, trimmed to the fields read.
final class XboxAddOnTests: XCTestCase, @unchecked Sendable {
    typealias Record = [String: Any]
    let indy = "9N8FQ28Z6QX3", whip = "9NKDMSQM0P60", suit = "9MWGFC01WNHS", doomSkin = "9N4DN43V59N8"
    let gears = "9P8PS6993LSL", anya = "9N1X737FGL21"

    func records() throws -> [String: Record] {
        let root = try JSONSerialization.jsonObject(with: Data(xboxFixture("catalog-addons.json"))) as! Record
        var out: [String: Record] = [:]
        for case let p as Record in root["Products"] as! [Any] { out[p["ProductId"] as! String] = p }
        return out
    }
    func config(name: String, store: String, related: [String] = []) -> XboxPackageConfig {
        XboxPackageConfig(name: name, publisher: "CN=Publisher", version: "1.0.0.0", storeID: store, dependency: nil,
                          allowed: [], related: related, languages: [])
    }

    /// Nexus's scope: an add-on of this game (its addOnParent, its package's main package,
    /// or the game's RelatedProducts), licensed by the account; never another game's.
    func testTheLicensedAddOnsOfAGameAreItsOwnWithTheirPackage() throws {
        let base = config(name: "BethesdaSoftworks.ProjectRelic", store: indy, related: [suit])
        let found = XboxAddOnCatalog.offers(base: indy, config: base, records: try records(),
                                            licensed: [whip: .gamePass, doomSkin: .gamePass, anya: .gamePass, indy: .gamePass])
        XCTAssertEqual(found.map(\.id), [whip, suit], "the DOOM and Gears add-ons are other games'")
        let w = found[0]
        XCTAssertEqual(w.status, .available)
        XCTAssertEqual(w.access, .gamePass)
        XCTAssertEqual(w.title, "Indiana Jones and the Great Circle™: The Last Crusade™ Pack - Lion Tamer Whip")
        XCTAssertEqual(w.package, XboxProductPackage(contentID: "47d6d3ee-6c27-46e6-a6ff-02a6d8dbef07", format: "MSIXVC", downloadSize: 10_612_736))
        XCTAssertEqual(w.packageFamily, "BethesdaSoftworks.LionTamerWhip_3275kfvn8vcwc")
        XCTAssertEqual(found[1].status, .unlicensed, "declared by the game, not licensed")
        XCTAssertNil(found[1].package)
        XCTAssertNil(found[1].access)
    }

    /// Without the game's config, the addOnParent relation and the base's own package family still decide.
    func testWithoutTheGamesConfigTheCatalogueAloneDecides() throws {
        let found = XboxAddOnCatalog.offers(base: indy, config: nil, records: try records(), licensed: [whip: .owned, suit: .owned])
        XCTAssertEqual(found.map(\.id), [whip, suit])
        XCTAssertEqual(found.map(\.status), [.available, .available])
        XCTAssertEqual(found[1].package?.contentID, "ea1cf758-1a8c-4913-b938-66dbcaea2dac")
    }

    func testADurableWithoutAPackageIsLicenceOnly() throws {
        let found = XboxAddOnCatalog.offers(base: gears, config: nil, records: try records(), licensed: [anya: .gamePass])
        XCTAssertEqual(found.map(\.id), [anya])
        XCTAssertEqual(found[0].status, .licenceOnly)
        XCTAssertNil(found[0].package)
    }

    /// Synthetic records for the edges: a pack, two packages, another game's package,
    /// pre-order and trial SKUs only, an MSIXVC2 package, a game.
    func testAPackOrAnAmbiguousPackageIsNotInstallableAndAGameIsNoAddOn() throws {
        let base = "9BASEGAME001", family = "Pub.Base_abc"
        func package(_ content: String, format: String = "MSIXVC", family pf: String = "Pub.Dlc_abc", main: String? = family,
                     platform: String = "Windows.Desktop") -> Record {
            ["ContentId": content, "PackageFormat": format, "Architectures": ["x64"], "PlatformDependencies": [["PlatformName": platform]],
             "PackageFamilyName": pf, "MainPackageFamilyNameForDlc": main ?? NSNull(), "MaxDownloadSizeInBytes": 4096]
        }
        func product(_ id: String, _ type: String = "Durable", parent: String? = base, skus: [Record]) -> Record {
            ["ProductId": id, "ProductType": type, "LocalizedProperties": [["ProductTitle": "Product \(id)"]],
             "MarketProperties": [["RelatedProducts": parent.map { [["RelatedProductId": $0, "RelationshipType": "addOnParent"]] } ?? []]],
             "DisplaySkuAvailabilities": skus.map { ["Sku": ["Properties": $0]] }]
        }
        func sku(_ packages: Any?, trial: Bool = false, preorder: Bool = false, bundled: [String] = []) -> Record {
            ["IsTrial": trial, "IsPreOrder": preorder, "BundledSkus": bundled.map { ["BigId": $0] }, "Packages": packages ?? NSNull()]
        }
        let a = "9ADDONAAAAA1", b = "9ADDONBBBBB2", c = "9ADDONCCCCC3", d = "9ADDONDDDDD4", e = "9ADDONEEEEE5", g = "9OTHERGAME06", h = "9ADDONHHHHH7"
        let records: [String: Record] = [
            base: product(base, "Game", parent: nil, skus: [sku([package("00000000-0000-4000-8000-0000000000b0", family: family, main: nil)])]),
            a: product(a, skus: [sku([], bundled: [b])]),
            b: product(b, skus: [sku([package("00000000-0000-4000-8000-0000000000b1"), package("00000000-0000-4000-8000-0000000000b2")])]),
            c: product(c, skus: [sku([package("00000000-0000-4000-8000-0000000000c1", main: "Other.Game_abc")])]),
            d: product(d, skus: [sku([package("00000000-0000-4000-8000-0000000000d1")], preorder: true),
                                 sku([package("00000000-0000-4000-8000-0000000000d1")], trial: true)]),
            e: product(e, skus: [sku([package("00000000-0000-4000-8000-0000000000E1", format: "MSIXVC2"),
                                      package("00000000-0000-4000-8000-0000000000e9", platform: "Windows.Xbox")])]),
            g: product(g, "Game", skus: [sku([package("00000000-0000-4000-8000-0000000000f1", family: "Pub.Other_abc", main: nil)])]),
            // No addOnParent: in scope through its package's main package family alone.
            h: product(h, parent: nil, skus: [sku([package("00000000-0000-4000-8000-0000000000a1")])]),
        ]
        let licensed = Dictionary(uniqueKeysWithValues: [a, b, c, d, e, g, h].map { ($0, XboxAccess.owned) })
        let found = XboxAddOnCatalog.offers(base: base, config: config(name: "Pub.Base", store: base), records: records, licensed: licensed)
        let status = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.status) })
        XCTAssertEqual(status, [a: .bundle, b: .unsupported, c: .unsupported, d: .unsupported, e: .available, h: .available])
        XCTAssertEqual(found.first { $0.id == e }?.package, XboxProductPackage(contentID: "00000000-0000-4000-8000-0000000000e1", format: "MSIXVC2", downloadSize: 4096))
        XCTAssertNil(status[g], "a game is no add-on")
    }

    /// The finder asks the public catalogue (no credentials) for the game, what its
    /// config declares and the licensed candidates, 20 at a time.
    func testTheFinderAsksTheCatalogueForTheGameItsDeclaredAndLicensedProductsOnly() async throws {
        let http = XboxCatalogueHTTP(try records())
        let finder = XboxAddOnFinder(http: http)
        let licensed = Dictionary(uniqueKeysWithValues: ([whip, doomSkin] + (0..<25).map { String(format: "9FILLER%05d", $0) }).map { ($0, XboxAccess.gamePass) })
        let found = try await finder.addOns(of: indy, config: config(name: "BethesdaSoftworks.ProjectRelic", store: indy, related: [suit]), licensed: licensed)
        XCTAssertEqual(found.map(\.id), [whip, suit])
        let calls = await http.calls
        let looked = calls.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "bigIds" }!.value!.split(separator: ",").map(String.init) }
        XCTAssertEqual(Set(looked), Set([indy, suit] + licensed.keys))
        XCTAssertEqual(looked.count, Set(looked).count, "each product once")
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.method == "GET" && $0.headers["Authorization"] == nil && $0.url.host == "displaycatalog.mp.microsoft.com" })

        await http.fail()
        do { _ = try await finder.addOns(of: indy, config: nil, licensed: licensed); XCTFail("a failed page is no empty list") } catch {}
    }

    func testTheGamesConfigGivesItsIdentityRelatedProductsAndLanguages() throws {
        let xml = "\u{FEFF}<?xml version=\"1.0\"?><Game configVersion=\"1\"><Identity Name=\"Pub.Dlc\" Publisher=\"CN=Pub\" Version=\"1.2.0.0\"/>"
            + "<StoreId>9ADDONAAAAA1</StoreId><DesktopRegistration><MainPackageDependency Name=\"Pub.Base\"/></DesktopRegistration>"
            + "<AllowedProducts><AllowedProduct>9BASEGAME001</AllowedProduct><AllowedProduct>bad</AllowedProduct></AllowedProducts>"
            + "<RelatedProducts><RelatedProduct>9RELATED0001</RelatedProduct></RelatedProducts>"
            + "<Resources><Resource Language=\"en-US\"/><Resource Language=\"pl-PL\"/><Resource Language=\"ms-resource:x\"/></Resources></Game>"
        let c = try XboxPackageConfig.parse(Array(xml.utf8))
        XCTAssertEqual(c, XboxPackageConfig(name: "Pub.Dlc", publisher: "CN=Pub", version: "1.2.0.0", storeID: "9ADDONAAAAA1", dependency: "Pub.Base",
                                            allowed: ["9BASEGAME001"], related: ["9RELATED0001"], languages: ["en-US", "pl-PL"]))
        XCTAssertThrowsError(try XboxPackageConfig.parse(Array("<Package><Identity Name=\"x\"/></Package>".utf8)))
        XCTAssertThrowsError(try XboxPackageConfig.parse(Array("<Game><StoreId>9ADDONAAAAA1</StoreId></Game>".utf8)), "no identity")
    }

    // MARK: the play's environment

    /// The runtime's variables: the add-ons as discovery hints (never rights), the content
    /// roots as Windows paths, the package locale; anything the runtime would refuse is left out.
    func testThePlaysEnvironmentNamesTheAddOnsTheirRootsAndTheLocale() {
        let env = XboxAddOnEnvironment.values(base: indy, related: [whip, suit, whip, indy, "bad", "9nkdmsqm0p61"],
                                              contentRoots: ["C:\\Games\\Indiana Jones\\DLC", "relative\\DLC", "C:\\Games\\a;b\\DLC"],
                                              locale: "pl-PL")
        XCTAssertEqual(env["NEXUS_RELATED_PRODUCT_IDS"]?.value, "\(whip),\(suit)")
        XCTAssertEqual(env["XODUS_CONTENT_ROOTS"]?.value, "C:\\Games\\Indiana Jones\\DLC")
        XCTAssertEqual(env["XODUS_PACKAGE_LOCALE"]?.value, "pl-PL")
        XCTAssertEqual(XboxAddOnEnvironment.values(base: indy, related: [], contentRoots: [], locale: "not a locale!"), [:])
        let many = (0..<300).map { String(format: "9MANY%07d", $0) }
        XCTAssertEqual(XboxAddOnEnvironment.values(base: indy, related: many, contentRoots: [], locale: nil)["NEXUS_RELATED_PRODUCT_IDS"]?.value
                        .split(separator: ",").count, 256, "the runtime takes 256 at most and ignores a longer list whole")
    }

    /// The phone's language when the package declares it (case as declared), else one with
    /// the same language, else the phone's own (Nexus's choice).
    func testThePackageLocaleIsThePhonesLanguageAsThePackageDeclaresIt() {
        let declared = ["en-US", "fr-FR", "pl-PL"]
        XCTAssertEqual(XboxAddOnEnvironment.locale(preferred: ["PL-pl", "en-US"], declared: declared), "pl-PL")
        XCTAssertEqual(XboxAddOnEnvironment.locale(preferred: ["en-GB"], declared: declared), "en-US")
        XCTAssertEqual(XboxAddOnEnvironment.locale(preferred: ["de-DE", "fr-CA"], declared: declared), "fr-FR")
        XCTAssertEqual(XboxAddOnEnvironment.locale(preferred: ["ja-JP"], declared: declared), "ja-JP")
        XCTAssertEqual(XboxAddOnEnvironment.locale(preferred: ["zh-Hans-CN"], declared: []), "zh-Hans-CN")
        XCTAssertNil(XboxAddOnEnvironment.locale(preferred: ["", "x;y"], declared: declared))
    }

    // MARK: the bridge

    /// The licence token the runtime asks for an add-on, once the play names it; another product stays refused.
    func testTheBridgeGrantsTheLicenceTokenForThePlaysAddOns() async throws {
        let account = XboxBridgeFakeAccount()
        let copy = XboxBridgeCopy(productID: indy, relatedProductIDs: [suit], msaAppID: nil).adding(related: [whip, "bad", indy, suit])
        XCTAssertEqual(copy.relatedProductIDs, [suit, whip])
        let s = XboxBridgeService(copy: copy, account: account, updates: nil, log: .silent)
        let body = "<StoreLicenseTokenRequest><ParentProductId>\(indy)</ParentProductId><ProductId>\(whip)/0010</ProductId>"
            + "<ProductId>\(suit)</ProductId><CustomDeveloperString>n</CustomDeveloperString></StoreLicenseTokenRequest>"
        let granted = await s.handle(XboxBridgeFrame(type: 5, body: Array(body.utf8)))
        XCTAssertEqual(try XboxXML.parse(granted!.body).value("Hresult"), "0")
        let other = body.replacingOccurrences(of: suit, with: doomSkin)
        let refused = await s.handle(XboxBridgeFrame(type: 5, body: Array(other.utf8)))
        XCTAssertEqual(try XboxXML.parse(refused!.body).value("Hresult"), XboxBridgeTests.denied)
    }
}
