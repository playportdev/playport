// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import BattleNetClientKit

/// Recorded responses by URL path; a host in `down` throws as an unreachable server would.
final class Recorded: BattleNetTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes = [String: BattleNetResponse]()
    private var hostRoutes = [String: BattleNetResponse]()
    var down = Set<String>()
    private(set) var asked = [URL]()

    func set(_ path: String, _ body: [UInt8], status: Int = 200, host: String? = nil) {
        lock.withLock {
            if let host { hostRoutes[host + path] = BattleNetResponse(status: status, body: body) }
            else { routes[path] = BattleNetResponse(status: status, body: body) }
        }
    }

    func get(_ url: URL, headers: [String: String]) async throws -> BattleNetResponse {
        try lock.withLock {
            asked.append(url)
            if down.contains(url.host ?? "") { throw URLError(.cannotConnectToHost) }
            return hostRoutes[(url.host ?? "") + url.path] ?? routes[url.path] ?? BattleNetResponse(status: 404, body: Array("Not Found".utf8))
        }
    }
}

final class BattleNetClientKitTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))))
    }

    func hash(_ hex: String) -> TACTHash { TACTHash(hex: hex)! }

    /// Blizzard's recorded answers for every product on the fixed list, in every region.
    func recorded() throws -> Recorded {
        let t = Recorded()
        for p in BattleNetProduct.allCases {
            t.set("/v2/products/\(p.code)/versions", try fixture("\(p.code)-versions.psv"))
            t.set("/v2/products/\(p.code)/cdns", try fixture("\(p.code)-cdns.psv"))
            let versions = try fixture("\(p.code)-versions.psv")
            let row = try XCTUnwrap(String(decoding: versions, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("us|") })
                .split(separator: "|", omittingEmptySubsequences: false)
            let build = try fixture("\(p.code)-buildconfig.txt")
            t.set("/tpr/wow/config/\(hash(String(row[1])).cdnPath)", build)
            t.set("/tpr/configs/data/\(hash(String(row[6])).cdnPath)", try fixture("\(p.code)-productconfig.json"))
            let install = try TACTConfig(build, what: "test").keyPair("install", what: "test")
            t.set("/tpr/wow/data/\(install.ekey.cdnPath)", try fixture("\(p.code)-install.blte"))
        }
        return t
    }

    // MARK: discovery

    func testEachRegionGetsItsBuildAndItsCDNHostsHTTPSFirst() async throws {
        let client = BattleNetClient(transport: try recorded())
        for region in StoreRegion.allCases {
            let v = try await client.version(.wow, region)
            XCTAssertEqual(v.region, region.rawValue)
            XCTAssertEqual(v.buildID, 70575)
            XCTAssertEqual(v.versionsName, "12.1.5.70575")
            XCTAssertEqual(v.buildConfig, hash("d718abcc42604d8efbd35aecfa5bb75b"))
            XCTAssertEqual(v.keyRing, hash("3ca57fe7319a297346440e4d2a03a0cd"))
        }
        let era = try await client.version(.wowClassicEra, .kr)
        XCTAssertEqual(era.versionsName, "1.15.9.70576")
        XCTAssertNil(era.keyRing)   // the Classic products have an empty KeyRing cell

        let us = try await client.cdn(.wow, .us)
        XCTAssertEqual(us.path, "tpr/wow")
        XCTAssertEqual(us.configPath, "tpr/configs/data")
        XCTAssertEqual(us.hosts, ["level3.blizzard.com", "us.cdn.blizzard.com"])
        XCTAssertEqual(us.bases.map(\.absoluteString), ["https://level3.ssl.blizzard.com", "https://us.cdn.blizzard.com",
                                                        "http://level3.blizzard.com", "http://us.cdn.blizzard.com"])
        let eu = try await client.cdn(.wow, .eu)
        XCTAssertEqual(eu.bases.map(\.absoluteString), ["https://level3.ssl.blizzard.com", "http://level3.blizzard.com"])
        let kr = try await client.cdn(.wow, .kr)
        XCTAssertEqual(kr.bases.first?.absoluteString, "https://blizzard.gcdn.cloudn.co.kr")
        XCTAssertEqual(kr.servers.first { $0.base.absoluteString == "http://kr.cdn.blizzard.com" }?.maxHosts, 2)
        XCTAssertTrue(kr.servers.first { $0.base.absoluteString == "http://blizzard.gcdn.cloudn.co.kr" }!.fallback)
        let tw = try await client.cdn(.wow, .tw)
        XCTAssertEqual(tw.bases, us.bases)
    }

    func testABuildCarriesItsBuildAndProductConfigs() async throws {
        let client = BattleNetClient(transport: try recorded())
        let era = try await client.build(.wowClassicEra, .eu)
        XCTAssertEqual(era.config.buildName, "WOW-70576patch1.15.9_ClassicRetail")
        XCTAssertEqual(era.config.install, KeyPair(ckey: hash("a55917a500b8808e146c442083f73f5c"), ekey: hash("cd12613e3f4b2948db868e05eaa495ba")))
        XCTAssertEqual(era.config.encoding.ekey, hash("6f1851167dd66bfc2e85297b68ef2afd"))
        XCTAssertEqual(era.config.size?.ekey, hash("c517386baa8a32c87ff1ef01501a92e4"))
        XCTAssertEqual(era.productConfig.folder, "_classic_era_")
        XCTAssertEqual(era.productConfig.x64Executable, "WoWClassic.exe")
        XCTAssertEqual(era.productConfig.arm64Executable, "WowClassic-arm64.exe")
        XCTAssertEqual(era.productConfig.platformTags, ["Windows"])
        XCTAssertEqual(era.productConfig.arm64Tags, ["arm64"])
        XCTAssertFalse(era.productConfig.supportedLocales.contains("itIT"))

        let retail = try await client.build(.wow, .us)
        XCTAssertEqual(retail.productConfig.folder, "_retail_")
        XCTAssertEqual(retail.productConfig.arm64Executable, "Wow-ARM64.exe")
        XCTAssertTrue(retail.productConfig.supportedLocales.contains("itIT"))
        XCTAssertEqual(retail.productConfig.replacementLocales["enGB"], "enUS")
        let anniversary = try await client.build(.wowAnniversary, .tw)
        XCTAssertEqual(anniversary.productConfig.launchArguments, ["-initialgamemode=bccfresh"])

        // Every product's x64 client is tagged `x86_64` (`tags_64bit`): an install's `.build.info`
        // naming that tag holds the x64 client (BattleNetUpdateCheck.lacksClient).
        for product in BattleNetProduct.allCases {
            let pc = try await client.build(product, .eu).productConfig
            XCTAssertEqual(pc.x64Tags, [BattleNetProduct.x64ClientTag], product.code)
            XCTAssertEqual(pc.platformTags, ["Windows"], product.code)
            XCTAssertNotNil(pc.x64Executable, product.code)
        }
    }

    func testTheCDNConfigListsTheArchives() throws {
        let cdn = try CDNConfig(try fixture("cdnconfig.txt"))
        XCTAssertEqual(cdn.archives.count, 1402)
        XCTAssertEqual(cdn.archiveIndexBytes, 125_291_376)
        XCTAssertEqual(cdn.archiveGroup, hash("ea217b0ff9e6c2d7b6f3911fb4ce3ceb"))
        XCTAssertEqual(cdn.fileIndex, hash("fa4469b6b0d31810a6ea07bfddffe1e9"))
    }

    /// Archive index sizes that add up past 64 bits are a damaged config, not a trap.
    func testArchiveIndexSizesThatOverflowAreDamaged() {
        let text = "archives = \(String(repeating: "ab", count: 16))\narchives-index-size = 18446744073709551615 1\n"
        XCTAssertThrowsError(try CDNConfig(Array(text.utf8))) { error in
            guard case BattleNetError.damaged = error else { return XCTFail("\(error)") }
        }
    }

    /// A 5-byte archive offset past 32 bits would be cut short; the index is refused instead.
    func testAFiveByteOffsetThatDoesNotFitIsRefused() throws {
        let key = PackedKey([UInt8](repeating: 0x11, count: 16))
        var index = ArchiveIndex.build([ArchiveIndex.Entry(key: key, size: 10, archive: nil, offset: 5)], offsetBytes: 5)
        XCTAssertEqual(try ArchiveIndex(index, name: nil).count, 1)
        // The offset's high byte set, and the block, table of contents and footer hashes made to match.
        index[20] = 1
        let body = index.count - ArchiveIndex.footerSize, blocks = body / (ArchiveIndex.blockSize + 24)
        index.replaceSubrange((blocks * ArchiveIndex.blockSize + blocks * 16)..<(blocks * ArchiveIndex.blockSize + blocks * 16 + 8),
                              with: MD5.hash(Array(index[0..<ArchiveIndex.blockSize])).prefix(8))
        index.replaceSubrange(body..<(body + 8), with: MD5.hash(Array(index[(blocks * ArchiveIndex.blockSize)..<body])).prefix(8))
        XCTAssertThrowsError(try ArchiveIndex(index, name: nil)) { error in
            guard case BattleNetError.damaged = error else { return XCTFail("\(error)") }
        }
    }

    func testTheKeyRingConfigNamesKeysInTheirBytesOrder() throws {
        let ring = try TACTKeyring(keyRingConfig: try fixture("wow-keyring.txt"))
        XCTAssertEqual(ring.keys.count, 1)
        XCTAssertEqual(ring[0x533B_F295_9F86_B44E], hash("c9316739348dcc033aa8112f9a3acf5d").bytes)
    }

    // MARK: install manifest and the offer rule

    func testTheInstallManifestNamesTheX64ClientAndItsTags() async throws {
        let client = BattleNetClient(transport: try recorded())
        let retail = try await client.offer(.wow, .us)
        let query = TagQuery.client(retail.build.productConfig, locale: "enUS", regions: [.us])
        XCTAssertEqual(query, TagQuery(tags: ["Windows", "x86_64", "enUS", "US", "speech", "text"], excluded: ["Alternate"]))
        let files = try retail.install.select(query)
        // The x64 client has one entry for China and one for the other regions.
        XCTAssertEqual(retail.install.files.filter { $0.name == "Wow.exe" }.count, 2)
        XCTAssertEqual(files.filter { $0.name == "Wow.exe" }.count, 1)
        XCTAssertFalse(files.contains { $0.name == "Wow-ARM64.exe" })
        XCTAssertFalse(files.contains { $0.name.contains("ARM64") })

        let era = try await client.offer(.wowClassicEra, .us)
        let eraFiles = try era.install.select(.client(era.build.productConfig, locale: "enUS", regions: [.us]))
        XCTAssertTrue(eraFiles.contains { $0.name == "WowClassic.exe" })
        XCTAssertFalse(eraFiles.contains { $0.name == "WowClassic-arm64.exe" })
        XCTAssertThrowsError(try era.install.select(.client(era.build.productConfig, locale: "itIT", regions: [.us]))) {
            XCTAssertEqual($0 as? BattleNetError, .unsupported("install manifest has no tag 'itIT'"))
        }
    }

    func testEveryProductOnTheListIsOfferedWhileItsBuildCarriesTheX64Client() async throws {
        let client = BattleNetClient(transport: try recorded())
        let expected: [BattleNetProduct: String] = [
            .wow: "Wow.exe", .wowClassic: "WowClassic.exe", .wowClassicEra: "WowClassic.exe", .wowAnniversary: "WowClassic.exe",
        ]
        for (product, name) in expected {
            let offer = try await client.offer(product, .eu)
            XCTAssertTrue(offer.isOffered, product.code)
            XCTAssertEqual(offer.client?.name, name, product.code)
            XCTAssertGreaterThan(offer.client?.size ?? 0, 10_000_000, product.code)
        }
    }

    func testABuildWithoutItsX64ClientIsNotOffered() async throws {
        let client = BattleNetClient(transport: try recorded())
        let build = try await client.build(.wowClassicEra, .us)
        let arm64Only = try InstallManifest(Synthetic.install(tags: [("Windows", 1), ("x86_64", 2), ("arm64", 2)], files: [
            ("WowClassic-arm64.exe", 100, ["Windows", "arm64"]),
            ("BlizzardError.exe", 10, ["Windows", "x86_64", "arm64"]),
        ]))
        XCTAssertFalse(BattleNetOffer(build: build, install: arm64Only).isOffered)
        // The x64 name present but not tagged for x64 Windows is not the x64 client either.
        let mistagged = try InstallManifest(Synthetic.install(tags: [("Windows", 1), ("x86_64", 2), ("arm64", 2)], files: [
            ("WoWClassic.exe", 100, ["Windows", "arm64"]),
        ]))
        XCTAssertFalse(BattleNetOffer(build: build, install: mistagged).isOffered)
        let x64 = try InstallManifest(Synthetic.install(tags: [("Windows", 1), ("x86_64", 2), ("arm64", 2)], files: [
            ("WOWCLASSIC.EXE", 100, ["Windows", "x86_64"]),
            ("WowClassic-arm64.exe", 90, ["Windows", "arm64"]),
        ]))
        XCTAssertEqual(BattleNetOffer(build: build, install: x64).client?.size, 100)
    }

    // MARK: sizes

    func testSizesSumTheSelectedDownloadAndTheProductFolderFiles() async throws {
        // A build whose size manifest is synthetic, with the recorded era product config.
        let t = try recorded()
        let tags: [(String, UInt16)] = [("Windows", 1), ("OSX", 1), ("arm64", 2), ("x86_64", 2), ("enUS", 3), ("deDE", 3),
                                        ("EU", 4), ("US", 4), ("speech", 5), ("text", 5), ("Alternate", 0x4000)]
        let size = Synthetic.size(tags: tags, entries: [
            (1000, ["Windows", "arm64", "x86_64", "enUS", "deDE", "EU", "US", "speech", "text"]),   // shared
            (200, ["Windows", "arm64", "enUS", "EU", "US", "speech", "text"]),                       // ARM64 only
            (300, ["Windows", "x86_64", "enUS", "EU", "US", "speech", "text"]),                      // x64 only
            (40, ["Windows", "x86_64", "deDE", "EU", "US", "speech", "text"]),                       // German
            (5, ["Windows", "x86_64", "enUS", "EU", "speech", "text"]),                              // EU only
            (7, ["Windows", "x86_64", "enUS", "EU", "US", "speech", "text", "Alternate"]),           // censored
            (11, ["OSX", "x86_64", "enUS", "EU", "US", "speech", "text"]),                           // Mac
        ])
        let install = Synthetic.install(tags: tags, files: [
            ("WowClassic-arm64.exe", 60, ["Windows", "arm64", "enUS", "deDE", "EU", "US", "speech", "text"]),
            ("WoWClassic.exe", 70, ["Windows", "x86_64", "enUS", "deDE", "EU", "US", "speech", "text"]),
        ])
        let (sizeBlob, sizeKeys) = Synthetic.blte(size)
        let (installBlob, installKeys) = Synthetic.blte(install)
        let buildConfig = Array("""
            # Build Configuration

            root = 00000000000000000000000000000000
            install = \(installKeys.ckey) \(installKeys.ekey)
            encoding = 11111111111111111111111111111111 22222222222222222222222222222222
            size = \(sizeKeys.ckey) \(sizeKeys.ekey)
            build-name = WOW-1patch1_Test

            """.utf8)
        let buildKey = TACTHash(bytes: MD5.hash(buildConfig))
        let era = try fixture("wow_classic_era-versions.psv")
        t.set("/v2/products/wow_classic_era/versions", Array(String(decoding: era, as: UTF8.self)
            .replacingOccurrences(of: "5604ce35a8644bdcf0e26c1daf979c15", with: buildKey.hex).utf8))
        t.set("/tpr/wow/config/\(buildKey.cdnPath)", buildConfig)
        t.set("/tpr/wow/data/\(sizeKeys.ekey.cdnPath)", sizeBlob)
        t.set("/tpr/wow/data/\(installKeys.ekey.cdnPath)", installBlob)

        let client = BattleNetClient(transport: t)
        let us = try await client.offer(.wowClassicEra, .us)
        XCTAssertTrue(us.isOffered)
        let usSizes = try await client.sizes(us, locale: "enUS")
        XCTAssertEqual(usSizes, try BattleNetSizes(size: SizeManifest(size), install: InstallManifest(install),
                                                   query: TagQuery(tags: ["Windows", "x86_64", "enUS", "US", "speech", "text"], excluded: ["Alternate"])))
        XCTAssertEqual(usSizes.download, 1300)
        XCTAssertEqual(usSizes.objects, 2)
        XCTAssertEqual(usSizes.installFiles, 70)
        XCTAssertEqual(usSizes.install, 1370)
        let euSizes = try await client.sizes(try await client.offer(.wowClassicEra, .eu), locale: "deDE")
        XCTAssertEqual(euSizes.download, 1040)
        XCTAssertEqual(euSizes.install, 1110)
    }

    // MARK: BLTE

    func testPlainZlibAndEncryptedBLTEDecodeToTheirContentKeys() async throws {
        let sample = try fixture("archive-range-sample-ff830631095b4ab604a8575a9b8c843e.blte")
        XCTAssertEqual(try BLTE.decode(sample, ekey: hash("ff830631095b4ab604a8575a9b8c843e")).count, 19)

        let t = Recorded()
        let encrypted: [(ekey: String, ckey: String, size: Int)] = [
            ("48a3c3b446bdfe81c891c6b974f2c022", "42e93d9cf0a5537304b41cece9ff5110", 2640),
            ("ca0ed1122ad00e7a91de2fa91bc82ec2", "c3ff4fd2c47e3bb90b6363e35f17f7f0", 11988),
            ("c0a49e3d26175d3ec3343282804376ff", "be468c3c7723e4e5e637d4b06956c200", 14330),
        ]
        for e in encrypted { t.set("/tpr/wow/data/\(hash(e.ekey).cdnPath)", try fixture("blte-encrypted-\(e.ekey).blte")) }
        let cdn = try XCTUnwrap(CDNEndpoint.parse(try fixture("wow-cdns.psv"), what: "test").first { $0.region == "us" })
        let keys = try TACTKeyring(list: try fixture("known-keys.txt"))
        let client = BattleNetClient(transport: t, keys: keys)
        let skin = try await client.data(KeyPair(ckey: hash(encrypted[0].ckey), ekey: hash(encrypted[0].ekey)), from: cdn)
        XCTAssertEqual(skin.count, 2640)
        XCTAssertEqual(Array(skin.prefix(4)), Array("SKIN".utf8))
        let md21 = try await client.data(KeyPair(ckey: hash(encrypted[1].ckey), ekey: hash(encrypted[1].ekey)), from: cdn)
        XCTAssertEqual(Array(md21.prefix(4)), Array("MD21".utf8))

        // A key nobody published: a typed error naming the key, after the first host (the same on all).
        let asked = t.asked.count
        do {
            _ = try await client.data(KeyPair(ckey: hash(encrypted[2].ckey), ekey: hash(encrypted[2].ekey)), from: cdn)
            XCTFail("decoded without its key")
        } catch let e as BattleNetError {
            XCTAssertEqual(e, .missingKey("1B84AE8C716E4629"))
            XCTAssertFalse(e.isNetwork)
        }
        XCTAssertEqual(t.asked.count, asked + 1)
        // Without the key list, the decryptable ones are missing their key too.
        XCTAssertThrowsError(try BLTE.decode(try fixture("blte-encrypted-\(encrypted[0].ekey).blte"))) {
            XCTAssertEqual($0 as? BattleNetError, .missingKey("C3E89049C5CAEBDF"))
        }
        // Every block is checked before any is decrypted.
        XCTAssertNoThrow(try BLTE.verify(try fixture("blte-encrypted-\(encrypted[2].ekey).blte"), ekey: hash(encrypted[2].ekey)))
    }

    func testBLTEChecksTheEKeyBlockHashesAndTheContentKey() throws {
        let (blob, keys) = Synthetic.blte(Array("hello, world".utf8), blocks: 3)
        XCTAssertEqual(try BLTE.decode(blob, ekey: keys.ekey, ckey: keys.ckey), Array("hello, world".utf8))
        XCTAssertThrowsError(try BLTE.decode(blob, ekey: keys.ckey))
        XCTAssertThrowsError(try BLTE.decode(blob, ekey: keys.ekey, ckey: keys.ekey))
        var lz4 = Synthetic.blte(Array("x".utf8), mode: UInt8(ascii: "4")).0
        XCTAssertThrowsError(try BLTE.decode(lz4)) { XCTAssertEqual($0 as? BattleNetError, .unsupported("BLTE block 0: mode '4'")) }
        lz4[8] = 0x10
        XCTAssertThrowsError(try BLTE.decode(lz4))
    }

    // MARK: encoding table

    func testTheEncodingTableFindsContentAndEncodedKeysAcrossPages() throws {
        var contents = [(ckey: [UInt8], size: UInt64, ekeys: [[UInt8]])]()
        for i in 0..<300 {   // three content pages at 1 KiB
            contents.append((MD5.hash([UInt8(i & 0xFF), UInt8(i >> 8), 1]), UInt64(1000 + i), [MD5.hash([UInt8(i & 0xFF), UInt8(i >> 8), 2])]))
        }
        let table = try EncodingTable(Synthetic.encoding(contents: contents, specs: ["b:{*=z}", "b:{256K*=e:{0011223344556677,8899AABBCCDDEEFF,z}}"]))
        XCTAssertEqual(table.specs.count, 2)
        for i in [0, 41, 150, 299] {
            let c = try XCTUnwrap(table.content(TACTHash(bytes: contents[i].ckey)))
            XCTAssertEqual(c.decodedSize, UInt64(1000 + i))
            XCTAssertEqual(c.ekeys, [TACTHash(bytes: contents[i].ekeys[0])])
            let e = try XCTUnwrap(table.encoded(c.ekeys[0]))
            XCTAssertEqual(e.encodedSize, UInt64(500 + i))
            XCTAssertEqual(e.spec, i % 2 == 0 ? "b:{*=z}" : "b:{256K*=e:{0011223344556677,8899AABBCCDDEEFF,z}}")
        }
        XCTAssertNil(table.content(TACTHash(bytes: MD5.hash([9, 9, 9]))))
        XCTAssertNil(table.encoded(TACTHash(bytes: [UInt8](repeating: 0, count: 16))))
    }

    // MARK: failures

    func testAnUnreachableOrRefusingNetworkIsToldApartFromADamagedAnswer() async throws {
        let offline = Recorded()
        offline.down = ["us.version.battle.net"]
        do {
            _ = try await BattleNetClient(transport: offline).offer(.wow, .us)
            XCTFail("offline")
        } catch let e as BattleNetError {
            guard case .unreachable = e else { return XCTFail("\(e)") }
            XCTAssertTrue(e.isNetwork)
        }

        let unknown = Recorded()
        unknown.set("/v2/products/wow/versions", try fixture("v2-nonexistent-product-404.txt"), status: 404)
        await assertThrows(try await BattleNetClient(transport: unknown).version(.wow, .us)) {
            XCTAssertEqual($0, .refused(status: 404, "wow versions from us.version.battle.net"))
        }

        let garbled = try recorded()
        garbled.set("/v2/products/wow/versions", Array("<html>maintenance</html>".utf8))
        await assertThrows(try await BattleNetClient(transport: garbled).version(.wow, .us)) {
            XCTAssertEqual($0, .damaged("wow versions: header cell '<html>maintenance</html>' is not Name!TYPE:size"))
            XCTAssertFalse($0.isNetwork)
        }

        // Every CDN host down: the network's failure. One host damaged, the next whole: the content.
        let cdnDown = try recorded()
        cdnDown.down = ["level3.ssl.blizzard.com", "us.cdn.blizzard.com", "level3.blizzard.com"]
        await assertThrows(try await BattleNetClient(transport: cdnDown).build(.wow, .us)) { XCTAssertTrue($0.isNetwork, "\($0)") }

        let flaky = try recorded()
        var build = try fixture("wow-buildconfig.txt")
        build[100] ^= 1
        flaky.set("/tpr/wow/config/\(hash("d718abcc42604d8efbd35aecfa5bb75b").cdnPath)", build, host: "level3.ssl.blizzard.com")
        let b = try await BattleNetClient(transport: flaky).build(.wow, .us)
        XCTAssertEqual(b.config.buildName, "WOW-70575patch12.1.5_Retail")
        flaky.set("/tpr/wow/config/\(hash("d718abcc42604d8efbd35aecfa5bb75b").cdnPath)", build)
        await assertThrows(try await BattleNetClient(transport: flaky).build(.wow, .us)) {
            XCTAssertEqual($0, .damaged("config d718abcc42604d8efbd35aecfa5bb75b: does not hash to its name"))
        }
        // A damaged install manifest on every host, and a refused one.
        let badInstall = try recorded()
        var blob = try fixture("wow-install.blte")
        blob[blob.count - 1] ^= 0xFF
        badInstall.set("/tpr/wow/data/\(hash("77d2e5d7fb7ea30d9361fb258ceb56c0").cdnPath)", blob)
        await assertThrows(try await BattleNetClient(transport: badInstall).offer(.wow, .us)) {
            guard case .damaged = $0 else { return XCTFail("\($0)") }
        }
        badInstall.set("/tpr/wow/data/\(hash("77d2e5d7fb7ea30d9361fb258ceb56c0").cdnPath)", [], status: 503)
        await assertThrows(try await BattleNetClient(transport: badInstall).offer(.wow, .us)) {
            XCTAssertEqual($0, .refused(status: 503, "data 77d2e5d7fb7ea30d9361fb258ceb56c0 from level3.ssl.blizzard.com"))
        }
    }

    func testTruncatedOrDamagedInputsThrowAndNeverCrash() throws {
        // The real install manifest: every truncation of the BLTE and of the decoded manifest,
        // and a flipped byte at a stride through the BLTE.
        let blob = try fixture("wow_classic_era-install.blte")
        let ekey = hash("cd12613e3f4b2948db868e05eaa495ba"), ckey = hash("a55917a500b8808e146c442083f73f5c")
        let manifest = try BLTE.decode(blob, ekey: ekey, ckey: ckey)
        for n in stride(from: 0, to: blob.count, by: 7) {
            XCTAssertThrowsError(try BLTE.decode(Array(blob[..<n]), ekey: ekey, ckey: ckey))
        }
        for i in stride(from: 0, to: blob.count, by: 13) {
            var b = blob
            b[i] ^= 0x41
            XCTAssertThrowsError(try BLTE.decode(b, ekey: ekey, ckey: ckey))
        }
        for n in 0..<manifest.count { XCTAssertThrowsError(try InstallManifest(Array(manifest[..<n]))) }
        for i in 0..<min(manifest.count, 4096) {   // flips that keep a valid shape may parse; none may trap
            var m = manifest
            m[i] ^= 0xFF
            _ = try? InstallManifest(m)
        }

        // Encrypted BLTE without its tail, or with a flipped ciphertext byte.
        let keys = try TACTKeyring(list: try fixture("known-keys.txt"))
        let enc = try fixture("blte-encrypted-48a3c3b446bdfe81c891c6b974f2c022.blte")
        for n in 0..<enc.count { XCTAssertThrowsError(try BLTE.decode(Array(enc[..<n]), keys: keys)) }
        for i in 0..<enc.count {
            var b = enc
            b[i] ^= 0x01
            XCTAssertThrowsError(try BLTE.decode(b, ekey: hash("48a3c3b446bdfe81c891c6b974f2c022"),
                                                 ckey: hash("42e93d9cf0a5537304b41cece9ff5110"), keys: keys))
        }

        // Synthetic size manifest and encoding table, every truncation; flips never trap.
        let tags: [(String, UInt16)] = [("Windows", 1), ("arm64", 2)]
        let size = Synthetic.size(tags: tags, entries: (0..<20).map { (UInt32($0), $0 % 2 == 0 ? ["Windows", "arm64"] : ["Windows"]) })
        for n in 0..<size.count { XCTAssertThrowsError(try SizeManifest(Array(size[..<n]))) }
        let enc2 = Synthetic.encoding(contents: (0..<50).map { (MD5.hash([UInt8($0)]), UInt64($0), [MD5.hash([UInt8($0), 1])]) }, specs: ["n"])
        for n in 0..<enc2.count { XCTAssertThrowsError(try EncodingTable(Array(enc2[..<n]))) }
        for i in 0..<enc2.count {
            var e = enc2
            e[i] ^= 0x80
            if let t = try? EncodingTable(e) {
                for k in 0..<50 { _ = t.content(TACTHash(bytes: MD5.hash([UInt8(k)]))).map { $0.ekeys.map { t.encoded($0) } } }
            }
        }

        // Texts: every truncation of the version table and the configs is either a shorter valid
        // text or an error, never a trap; mid-row cuts are errors.
        let versions = try fixture("wow-versions.psv")
        for n in 0..<versions.count { _ = try? VersionRow.parse(Array(versions[..<n]), what: "test") }
        XCTAssertThrowsError(try VersionRow.parse(Array(versions[..<(versions.count - 5)]), what: "test"))
        for name in ["wow-cdns.psv"] {
            let b = try fixture(name)
            for n in 0..<b.count { _ = try? CDNEndpoint.parse(Array(b[..<n]), what: "test") }
        }
        let product = try fixture("wow_classic_era-productconfig.json")
        for n in stride(from: 0, to: product.count, by: 3) { XCTAssertThrowsError(try ProductConfig(Array(product[..<n]))) }
        XCTAssertThrowsError(try BuildConfig(Array("install = 00\n".utf8)))
        XCTAssertThrowsError(try TACTKeyring(list: Array("C3E89049C5CAEBDF 7C1B8F88\n".utf8)))
    }

    // MARK: live (workstation)

    /// One session for the process: on Linux, freeing a URLSession that has run requests aborts
    /// the process (its curl handle outlives it).
    static let live = URLSessionTransport()

    /// Asks Blizzard's live endpoints for every product and region and writes a Markdown table to
    /// the file BATTLENET_LIVE_REPORT names. Skipped unless it is set.
    func testLiveOffersAndSizes() async throws {
        guard let out = ProcessInfo.processInfo.environment["BATTLENET_LIVE_REPORT"], !out.isEmpty else {
            throw XCTSkip("BATTLENET_LIVE_REPORT is not set")
        }
        let client = BattleNetClient(transport: Self.live)
        var rows = ["| product | region | version | build | offered | x64 client | download | install | of which product folder | objects |",
                    "|---|---|---|---|---|---|---|---|---|---|"]
        var sizeCache = [TACTHash: SizeManifest]()
        func gb(_ b: UInt64) -> String { String(format: "%.2f GB (%llu B)", Double(b) / 1e9, b) }
        for product in BattleNetProduct.allCases {
            for region in StoreRegion.allCases {
                let offer = try await client.offer(product, region)
                let v = offer.build.version
                var cells = [product.code, region.rawValue, v.versionsName, "\(v.buildID)", offer.isOffered ? "yes" : "no",
                             offer.client.map { "`\($0.name)` \($0.size) B" } ?? "—"]
                if let key = offer.build.config.size {
                    if sizeCache[key.ekey] == nil { sizeCache[key.ekey] = try await client.sizeManifest(offer.build) }
                    let s = try BattleNetSizes(size: sizeCache[key.ekey]!, install: offer.install,
                                               query: .client(offer.build.productConfig, locale: "enUS", regions: [region]))
                    cells += [gb(s.download), gb(s.install), gb(s.installFiles), "\(s.objects)"]
                } else {
                    cells += ["no size manifest", "—", "—", "—"]
                }
                rows.append("| " + cells.joined(separator: " | ") + " |")
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}

extension XCTestCase {
    func assertThrows<T>(_ body: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
                         _ check: (BattleNetError) -> Void) async {
        do {
            _ = try await body()
            XCTFail("did not throw", file: file, line: line)
        } catch let e as BattleNetError {
            check(e)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}

/// Builders for the binary formats, written from the format descriptions (tests only).
enum Synthetic {
    static func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    static func tagBlock(_ tags: [(String, UInt16)], entries: [[String]]) -> [UInt8] {
        var out = [UInt8]()
        for (name, type) in tags {
            out += Array(name.utf8) + [0] + be(UInt64(type), 2)
            var mask = [UInt8](repeating: 0, count: (entries.count + 7) / 8)
            for (i, e) in entries.enumerated() where e.contains(name) { mask[i >> 3] |= 0x80 >> UInt8(i & 7) }
            out += mask
        }
        return out
    }

    static func install(tags: [(String, UInt16)], files: [(String, UInt32, [String])]) -> [UInt8] {
        var out = Array("IN".utf8) + [1, 16] + be(UInt64(tags.count), 2) + be(UInt64(files.count), 4)
        out += tagBlock(tags, entries: files.map(\.2))
        for (name, size, _) in files { out += Array(name.utf8) + [0] + MD5.hash(Array(name.utf8)) + be(UInt64(size), 4) }
        return out
    }

    static func size(tags: [(String, UInt16)], entries: [(UInt32, [String])]) -> [UInt8] {
        var out = Array("DS".utf8) + [1, 9] + be(UInt64(entries.count), 4) + be(UInt64(tags.count), 2)
        out += be(entries.reduce(0) { $0 + UInt64($1.0) }, 5)
        out += tagBlock(tags, entries: entries.map(\.1))
        for (i, e) in entries.enumerated() { out += Array(MD5.hash([UInt8(i & 0xFF), UInt8(i >> 8)]).prefix(9)) + be(UInt64(e.0), 4) }
        return out
    }

    /// EN with 1 KiB pages; content i's EKey has encoded size `encodedSizes[i]` (else 500 + i)
    /// and spec i % specs.count.
    static func encoding(contents: [(ckey: [UInt8], size: UInt64, ekeys: [[UInt8]])], specs: [String],
                         encodedSizes: [UInt64]? = nil) -> [UInt8] {
        let page = 1024
        func pages(_ entries: [([UInt8], [UInt8])], terminator: Int) -> ([UInt8], [UInt8], Int) {
            var index = [UInt8](), data = [UInt8](), current = [UInt8](), first: [UInt8]?
            var count = 0
            func flush() {
                guard let f = first else { return }
                current += [UInt8](repeating: 0, count: page - current.count)
                index += f + MD5.hash(current)
                data += current
                current = []
                first = nil
                count += 1
            }
            for (key, bytes) in entries {
                if current.count + bytes.count + terminator > page { flush() }
                if first == nil { first = key }
                current += bytes
            }
            flush()
            return (index, data, count)
        }
        let byCKey = contents.sorted { $0.ckey.lexicographicallyPrecedes($1.ckey) }
        let ce = pages(byCKey.map { c in
            (c.ckey, [UInt8(c.ekeys.count)] + be(c.size, 5) + c.ckey + c.ekeys.flatMap { $0 })
        }, terminator: 1)
        let encoded = contents.enumerated().flatMap { i, c in c.ekeys.map { ($0, i) } }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        let es = pages(encoded.map { e, i in (e, e + be(UInt64(i % specs.count), 4) + be(encodedSizes?[i] ?? UInt64(500 + i), 5)) },
                       terminator: 16)
        let specBlock: [UInt8] = specs.flatMap { Array($0.utf8) + [UInt8(0)] }
        var out = Array("EN".utf8) + [1, 16, 16] + be(1, 2) + be(1, 2) + be(UInt64(ce.2), 4) + be(UInt64(es.2), 4) + [0]
        out += be(UInt64(specBlock.count), 4) + specBlock
        out += ce.0 + ce.1 + es.0 + es.1
        return out
    }

    /// A chunked BLTE of `blocks` raw blocks; the keys are (MD5 of the content, MD5 of the header).
    static func blte(_ content: [UInt8], blocks: Int = 1, mode: UInt8 = UInt8(ascii: "N")) -> ([UInt8], KeyPair) {
        let per = max(1, (content.count + blocks - 1) / blocks)
        let parts = stride(from: 0, to: max(content.count, 1), by: per).map { [mode] + Array(content[$0..<min(content.count, $0 + per)]) }
        var header = Array("BLTE".utf8) + be(UInt64(12 + 24 * parts.count), 4) + [0x0F] + be(UInt64(parts.count), 3)
        for (i, p) in parts.enumerated() {
            header += be(UInt64(p.count), 4) + be(UInt64(min(content.count, (i + 1) * per) - i * per), 4) + MD5.hash(p)
        }
        return (header + parts.flatMap { $0 }, KeyPair(ckey: TACTHash(bytes: MD5.hash(content)), ekey: TACTHash(bytes: MD5.hash(header))))
    }
}
