// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import BattleNetClientKit

/// An installed product's store region and language changed (PLA-520): a region change rewrites
/// `.build.info` and nothing else; a language change fetches only the new locale's data.
extension BattleNetInstallTests {
    /// Every file under `root` but `.build.info`, with its bytes.
    func snapshot(_ root: URL) throws -> [String: Data] {
        var out = [String: Data]()
        let e = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in e where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let path = String(url.path.dropFirst(root.path.count))
            if path != "/.build.info" { out[path] = try Data(contentsOf: url) }
        }
        return out
    }

    func testARegionChangeRewritesTheBuildInfoOnly() async throws {
        let cdn = FakeCDN()
        let p = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow")
        let before = try snapshot(root)
        let asked = cdn.requests.count

        let info = try await installer(client(cdn)).changeRegion(.wowClassicEra, root: root, to: .eu)

        // Only the version and CDN endpoints were asked; nothing came from the CDN.
        XCTAssertEqual(Set(cdn.requests.dropFirst(asked).map(\.url.path)),
                       ["/v2/products/wow_classic_era/versions", "/v2/products/wow_classic_era/cdns"])
        XCTAssertEqual(try snapshot(root), before)
        let read = try BuildInfo.read([UInt8](try Data(contentsOf: root.appendingPathComponent(".build.info"))), product: "wow_classic_era")
        XCTAssertEqual(read, info)
        XCTAssertEqual(read.region, .eu)
        XCTAssertEqual(read.buildKey, p.buildConfig)
        XCTAssertEqual(read.cdnKey, p.cdnConfig)
        XCTAssertEqual(read.cdnHosts, ["level3.blizzard.com", "eu.cdn.blizzard.com"])
        XCTAssertEqual(read.cdnServers, ["https://eu.cdn.blizzard.com/?maxhosts=4", "http://level3.blizzard.com/?maxhosts=4"])
        XCTAssertEqual(read.tags, "Windows x86_64 EU? enUS speech?:Windows x86_64 EU? enUS text?")
        XCTAssertEqual(read.locale, "enUS")
    }

    /// A region whose current build is another is an update, not a rewrite: nothing changes.
    func testARegionOnAnotherBuildIsRefused() async throws {
        let cdn = FakeCDN()
        let p = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow")
        let info = try Data(contentsOf: root.appendingPathComponent(".build.info"))
        let other = String(repeating: "ab", count: 16)
        cdn.set("/v2/products/wow_classic_era/versions", Array(("Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16\n## seqn = 2\n"
            + "us|\(p.buildConfig)|\(p.cdnConfig)||1|1.0.0.1|\(p.cdnConfig)\neu|\(other)|\(p.cdnConfig)||2|1.0.0.2|\(p.cdnConfig)\n").utf8))
        do {
            _ = try await installer(client(cdn)).changeRegion(.wowClassicEra, root: root, to: .eu)
            XCTFail("expected a refusal")
        } catch let e as BattleNetError {
            // Its own kind, so the player is told to update first (PlayportKit BattleNet.reason).
            XCTAssertEqual(e, .outdated(installed: "1.0.0.1", current: "1.0.0.2"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".build.info")), info)
    }

    /// A language change fetches the objects only the new locale has (the fake product's deDE-only
    /// ones), into a data file numbered after the install's; the store keeps the old locale's
    /// data, the journals name both, and `.build.info` and an existing `Config.wtf` say deDE.
    func testALocaleChangePlansOnlyTheNewLocalesData() async throws {
        let cdn = FakeCDN()
        let p = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        let (installed, _) = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow"), work = dir.appendingPathComponent(".wow.locale")
        let wtf = root.appendingPathComponent("_classic_era_/WTF/Config.wtf")
        try FileManager.default.createDirectory(at: wtf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("SET textLocale \"enUS\"\nSET gxApi \"D3D12\"\nSET audioLocale \"enUS\"\n".utf8).write(to: wtf)
        let before = try snapshot(root)
        let asked = cdn.requests.count

        let i = installer(client(cdn))
        let prepared = try await i.prepareLocaleChange(.wowClassicEra, root: root, to: "deDE", work: work)
        XCTAssertEqual(Set(prepared.plan.locations.map(\.key)), Set([3, 11, 19, 27, 35].map { PackedKey(p.objects[$0].keys.ekey) }))
        XCTAssertEqual(prepared.plan.files, [])
        XCTAssertEqual(prepared.plan.dataFiles, [1])
        // The CDN indexes came from the install, not the CDN.
        XCTAssertFalse(cdn.requests.dropFirst(asked).contains { $0.url.path.hasSuffix(".index") })

        _ = try await i.changeLocale(prepared, root: root, work: work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        let after = try snapshot(root)
        for (path, data) in before where !path.hasSuffix(".idx") && !path.hasSuffix("Config.wtf") {
            XCTAssertEqual(after[path], data, path)
        }
        XCTAssertNotNil(after["/Data/data/data.001"])
        XCTAssertEqual(Set(after.keys.filter { $0.hasSuffix(".idx") }),
                       Set((0..<16).map { "/Data/data/" + CASC.journalName(bucket: $0, generation: 2) }))
        let read = try BuildInfo.read([UInt8](try Data(contentsOf: root.appendingPathComponent(".build.info"))), product: "wow_classic_era")
        XCTAssertEqual(read.tags, "Windows x86_64 US? deDE speech?:Windows x86_64 US? deDE text?")
        XCTAssertEqual(read.region, .us)
        XCTAssertEqual(try String(contentsOf: wtf, encoding: .utf8), "SET textLocale \"deDE\"\nSET gxApi \"D3D12\"\nSET audioLocale \"deDE\"\n")
        // Both locales' objects are named by the journals and read back whole.
        for plan in [installed.plan, prepared.plan] {
            let v = try await BattleNetInstaller.verify(root, plan: plan)
            XCTAssertTrue(v.isIntact, "\(v.damaged) \(v.missing)")
        }

        // Back to enUS: everything is there already, so nothing is planned.
        let back = try await i.prepareLocaleChange(.wowClassicEra, root: root, to: "enUS", work: work)
        XCTAssertEqual(back.plan.objects, 0)
        XCTAssertEqual(back.plan.files, [])
    }

    /// A region change rewrites the game's `portal` too once the game has a `Config.wtf` (WoW
    /// signs in to the portal's region); every other line stays.
    func testARegionChangeRewritesTheGamesPortal() async throws {
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow")
        let wtf = root.appendingPathComponent("_classic_era_/WTF/Config.wtf")
        try FileManager.default.createDirectory(at: wtf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("SET portal \"US\"\r\nSET gxWindow \"1\"\r\n".utf8).write(to: wtf)
        try await installer(client(cdn)).changeRegion(.wowClassicEra, root: root, to: .eu)
        XCTAssertEqual(try String(contentsOf: wtf, encoding: .utf8), "SET portal \"EU\"\r\nSET gxWindow \"1\"\r\n")
    }

    /// Before Play the game's `Config.wtf` gets the install's locale and region where it names
    /// none (else WoW asks in a Win32 box first), the controller on and the software cursor
    /// where it names none (else WoW looks for no controller, and its cursor, which the pad moves
    /// at the login, is not drawn on the phone) and Direct3D 12 always (WoW saves Direct3D 11
    /// after one failed start). The file and its folder are made when missing; other lines stay.
    func testPlayWritesTheMissingLocaleRegionControllerAndCursorAndPinsDirect3D12() async throws {
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow")
        let wtf = root.appendingPathComponent("_classic_era_/WTF/Config.wtf")
        try WoWConfig.prepareForPlay(.wowClassicEra, root: root)
        XCTAssertEqual(try String(contentsOf: wtf, encoding: .utf8),
                       "SET textLocale \"enUS\"\nSET audioLocale \"enUS\"\nSET portal \"US\"\nSET GamePadEnable \"1\"\nSET HardwareCursor \"0\"\nSET GxApi \"D3D12\"\n")

        try Data("SET textLocale \"deDE\"\nSET gxApi \"D3D11\"\nSET gamePadEnable \"0\"\nSET hardwareCursor \"1\"\nSET hwDetect \"0\"\n".utf8).write(to: wtf)
        try WoWConfig.prepareForPlay(.wowClassicEra, root: root)
        XCTAssertEqual(try String(contentsOf: wtf, encoding: .utf8),
                       "SET textLocale \"deDE\"\nSET gxApi \"D3D12\"\nSET gamePadEnable \"0\"\nSET hardwareCursor \"1\"\nSET hwDetect \"0\"\nSET audioLocale \"enUS\"\nSET portal \"US\"\n")
    }

    /// Retail also gets the intro cinematic marked as seen where `Config.wtf` names none: the
    /// client saves that only on a clean exit, so on the phone the cinematic played before the
    /// login screen on every Play. A value the file has stays.
    func testRetailPlayMarksTheIntroCinematicSeenWhereTheConfigNamesNone() async throws {
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        // The fake install as retail's: its build row and its product folder name `wow`.
        let root = dir.appendingPathComponent("wow"), fm = FileManager.default
        let info = root.appendingPathComponent(".build.info")
        let text = try String(contentsOf: info, encoding: .utf8).replacingOccurrences(of: "wow_classic_era", with: "wow")
        try Data(text.utf8).write(to: info)
        try fm.moveItem(at: root.appendingPathComponent("_classic_era_"), to: root.appendingPathComponent("_retail_"))
        try Data("Product Flavor!STRING:0\nwow\n".utf8).write(to: root.appendingPathComponent("_retail_/.flavor.info"))
        let wtf = root.appendingPathComponent("_retail_/WTF/Config.wtf")

        try WoWConfig.prepareForPlay(.wow, root: root)
        XCTAssertEqual(try String(contentsOf: wtf, encoding: .utf8),
                       "SET textLocale \"enUS\"\nSET audioLocale \"enUS\"\nSET portal \"US\"\nSET GamePadEnable \"1\"\nSET HardwareCursor \"0\"\n"
                       + "SET playIntroMovie \"14\"\nSET GxApi \"D3D12\"\n")

        try Data("SET PlayIntroMovie \"11\"\nSET gxApi \"D3D12\"\n".utf8).write(to: wtf)
        try WoWConfig.prepareForPlay(.wow, root: root)
        XCTAssertEqual(try String(contentsOf: wtf, encoding: .utf8),
                       "SET PlayIntroMovie \"11\"\nSET gxApi \"D3D12\"\nSET textLocale \"enUS\"\nSET audioLocale \"enUS\"\nSET portal \"US\"\n"
                       + "SET GamePadEnable \"1\"\nSET HardwareCursor \"0\"\n")
    }

    /// A language change adds the text and voice locales to a `Config.wtf` that names neither.
    func testALocaleChangeAddsTheLocalesTheConfigLacks() {
        XCTAssertEqual(WoWConfig.locale("SET gxWindow \"1\"\n", "frFR"),
                       "SET gxWindow \"1\"\nSET textLocale \"frFR\"\nSET audioLocale \"frFR\"\n")
    }

    /// A journal of a bucket the store does not have, or a generation with no next one, is a
    /// damaged store: the language change says so and changes nothing.
    func testAStrayJournalOrTheLastGenerationIsDamagedNotATrap() async throws {
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow"), work = dir.appendingPathComponent(".wow.locale")
        let data = root.appendingPathComponent("Data/data")
        let fm = FileManager.default
        let i = installer(client(cdn))
        // Bucket 3's journal renamed as a bucket 0x1f one: still sixteen journals, one missing.
        try fm.moveItem(at: data.appendingPathComponent(CASC.journalName(bucket: 3, generation: 1)),
                        to: data.appendingPathComponent("1f0000000" + "1.idx"))
        let stray = try await i.prepareLocaleChange(.wowClassicEra, root: root, to: "deDE", work: work)
        await assertThrows(try await i.changeLocale(stray, root: root, work: work)) {
            guard case .damaged = $0 else { return XCTFail("\($0)") }
        }
        try fm.moveItem(at: data.appendingPathComponent("1f0000000" + "1.idx"),
                        to: data.appendingPathComponent(CASC.journalName(bucket: 3, generation: 1)))

        for bucket in 0..<CASC.buckets {
            try fm.moveItem(at: data.appendingPathComponent(CASC.journalName(bucket: bucket, generation: 1)),
                            to: data.appendingPathComponent(CASC.journalName(bucket: bucket, generation: .max)))
        }
        let fresh = dir.appendingPathComponent(".wow.locale2")
        let last = try await i.prepareLocaleChange(.wowClassicEra, root: root, to: "deDE", work: fresh)
        await assertThrows(try await i.changeLocale(last, root: root, work: fresh)) {
            guard case .damaged = $0 else { return XCTFail("\($0)") }
        }
    }
}
