// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import BattleNetClientKit

/// A CDN in memory, by URL path: ranged reads answer 206 with `Content-Range`, a path in
/// `throttle` answers 429 that many times first, and every request is recorded with its headers.
final class FakeCDN: BattleNetTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files = [String: [UInt8]]()
    private var throttle = [String: (left: Int, retryAfter: String?)]()
    private var log = [(url: URL, headers: [String: String], status: Int)]()
    private var inFlight = 0
    private(set) var peak = 0
    var delay: UInt64 = 0

    func set(_ path: String, _ body: [UInt8]) { lock.withLock { files[path] = body } }
    func remove(_ path: String) { lock.withLock { _ = files.removeValue(forKey: path) } }
    func throttle(_ path: String, times: Int, retryAfter: String?) { lock.withLock { throttle[path] = (times, retryAfter) } }
    var requests: [(url: URL, headers: [String: String], status: Int)] { lock.withLock { log } }
    func ranged(_ path: String) -> [String] { requests.filter { $0.url.path == path && $0.status == 206 }.compactMap { $0.headers["Range"] } }

    private func answer(_ url: URL, _ headers: [String: String]) -> BattleNetResponse {
        lock.withLock {
            let path = url.path
            let response: BattleNetResponse
            if let t = throttle[path], t.left > 0 {
                throttle[path] = (t.left - 1, t.retryAfter)
                response = BattleNetResponse(status: 429, headers: t.retryAfter.map { ["retry-after": $0] } ?? [:], body: [])
            } else if let body = files[path] {
                if let range = headers["Range"], range.hasPrefix("bytes=") {
                    let ends = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                    if ends.count == 2, ends[0] <= ends[1], ends[1] < body.count {
                        response = BattleNetResponse(status: 206, headers: ["content-range": "bytes \(ends[0])-\(ends[1])/\(body.count)"],
                                                     body: Array(body[ends[0]...ends[1]]))
                    } else {
                        response = BattleNetResponse(status: 416, body: [])
                    }
                } else {
                    response = BattleNetResponse(status: 200, body: body)
                }
            } else {
                response = BattleNetResponse(status: 404, body: Array("Not Found".utf8))
            }
            log.append((url, headers, response.status))
            return response
        }
    }

    func get(_ url: URL, headers: [String: String]) async throws -> BattleNetResponse {
        lock.withLock {
            inFlight += 1
            peak = max(peak, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return answer(url, headers)
    }
}

/// Pauses the client asked for, instead of waiting them.
final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = [Double]()
    var all: [Double] { lock.withLock { seen } }
    func record(_ s: Double) { lock.withLock { seen.append(s) } }
}

/// A small product on a fake CDN, built from the formats: a few dozen stored objects in two
/// archives and loose, the product folder's files, and the manifests and configs naming them.
struct FakeProduct {
    static let tags: [(String, UInt16)] = [("Windows", 1), ("arm64", 2), ("x86_64", 2), ("deDE", 3), ("enUS", 3),
                                           ("EU", 4), ("KR", 4), ("TW", 4), ("US", 4), ("speech", 5), ("text", 5),
                                           ("Alternate", 0x4000)]
    static let everywhere = ["Windows", "arm64", "x86_64", "deDE", "enUS", "EU", "KR", "TW", "US", "speech", "text"]
    static let cdnPath = "/tpr/wow"

    struct Object {
        let blte: [UInt8]
        let keys: KeyPair
        let tags: [String]
    }

    var objects = [Object]()
    /// name → (content, tags)
    var files = [(name: String, content: [UInt8], tags: [String])]()
    var archives = [TACTHash]()
    var buildConfig = TACTHash(bytes: [UInt8](repeating: 0, count: 16))
    var cdnConfig = TACTHash(bytes: [UInt8](repeating: 0, count: 16))
    var archiveGroup = TACTHash(bytes: [UInt8](repeating: 0, count: 16))
    /// Which objects sit in which archive (index into `objects`), the rest are loose.
    var archived = [[Int]]()

    static func bytes(_ seed: Int, _ count: Int) -> [UInt8] {
        var x = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        return (0..<count).map { _ in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return UInt8(truncatingIfNeeded: x)
        }
    }

    static func data(_ key: TACTHash) -> String { "\(cdnPath)/data/\(key.cdnPath)" }

    /// Lays the product out on `cdn`. Build 2 (an update, PLA-521) changes objects 9, 19, 29 and 39
    /// and `Utils\a.dll`, adds objects 40..<44 (loose), and is the version endpoint's build.
    /// `filesInStore` also lists the product folder files' objects in the download manifest, as
    /// Blizzard's manifests do, so the store holds them too.
    static func make(on cdn: FakeCDN, productConfig: [UInt8], build: Int = 1, filesInStore: Bool = false) -> FakeProduct {
        typealias S = Synthetic
        var p = FakeProduct()
        // Stored objects: most for every locale and region, some for one locale, one region,
        // the Alternate data, the x64 client only or the ARM64 client only.
        for i in 0..<(build == 1 ? 40 : 44) {
            var tags = everywhere
            switch i % 8 {
            case 3: tags.removeAll { $0 == "enUS" }                                  // deDE only
            case 4: tags.removeAll { $0 == "arm64" }                                  // x64 only
            case 5: tags.removeAll { ["US", "KR", "TW"].contains($0) }                // EU only
            case 6: tags.append("Alternate")
            case 7: tags.removeAll { $0 == "x86_64" }                                 // ARM64 only
            default: break
            }
            let seed = build > 1 && i % 10 == 9 ? 1000 * build + i : i
            let (blte, keys) = S.blte(bytes(seed, 300 + 97 * i), blocks: 1 + i % 3)
            p.objects.append(Object(blte: blte, keys: keys, tags: tags))
        }
        // Product folder files (two directories spelled two ways, as Blizzard's manifests do).
        p.files = [("WoWClassic.exe", bytes(101, 4000), ["Windows", "x86_64"] + everywhere.suffix(8)),
                   ("WowClassic-arm64.exe", bytes(100, 5000), ["Windows", "arm64"] + everywhere.suffix(8)),
                   ("Utils\\a.dll", bytes(build == 1 ? 102 : 202, 1500), ["Windows", "x86_64"] + everywhere.suffix(8)),
                   ("UTILS\\b.dll", bytes(103, 700), ["Windows", "x86_64"] + everywhere.suffix(8))]
        let fileObjects = p.files.map { S.blte($0.content, blocks: 2) }

        // Archive 0: objects 0..<20 and file 0, with gaps between some; archive 1: 20..<34 and
        // files 1, 2; objects 34..<40 and file 3 are loose.
        var archiveIndexes = [[ArchiveIndex.Entry]]()
        var groupEntries = [ArchiveIndex.Entry]()
        var looseKeys = [ArchiveIndex.Entry]()
        let layout: [([Int], [Int])] = [(Array(0..<20), [0]), (Array(20..<34), [1, 2])]
        for (a, (objs, fls)) in layout.enumerated() {
            var archive = [UInt8](), entries = [ArchiveIndex.Entry]()
            let blobs = objs.map { (p.objects[$0].blte, p.objects[$0].keys.ekey) } + fls.map { (fileObjects[$0].0, fileObjects[$0].1.ekey) }
            for (n, (blob, ekey)) in blobs.enumerated() {
                if n % 5 == 4 { archive += bytes(1000 + n, n % 10 == 9 ? 40_000 : 64) }  // unselected neighbours
                entries.append(ArchiveIndex.Entry(key: PackedKey(ekey), size: UInt32(blob.count), archive: a, offset: UInt32(archive.count)))
                archive += blob
            }
            entries.sort { $0.key < $1.key }
            let index = ArchiveIndex.build(entries, offsetBytes: 4)
            let name = TACTHash(bytes: MD5.hash(Array(index.suffix(28))))
            p.archives.append(name)
            p.archived.append(objs)
            cdn.set(data(name), archive)
            cdn.set(data(name) + ".index", index)
            archiveIndexes.append(entries)
            groupEntries += entries
        }
        for i in 34..<p.objects.count {
            cdn.set(data(p.objects[i].keys.ekey), p.objects[i].blte)
            looseKeys.append(ArchiveIndex.Entry(key: PackedKey(p.objects[i].keys.ekey), size: UInt32(p.objects[i].blte.count), archive: nil, offset: 0))
        }
        cdn.set(data(fileObjects[3].1.ekey), fileObjects[3].0)
        looseKeys.sort { $0.key < $1.key }
        let fileIndex = ArchiveIndex.build(looseKeys, offsetBytes: 0)
        let fileIndexName = TACTHash(bytes: MD5.hash(Array(fileIndex.suffix(28))))
        cdn.set(data(fileIndexName) + ".index", fileIndex)
        groupEntries.sort { $0.key < $1.key }
        let group = ArchiveIndex.build(groupEntries, offsetBytes: 6)
        p.archiveGroup = TACTHash(bytes: MD5.hash(Array(group.suffix(28))))

        // Manifests: install, download and encoding, loose on the CDN.
        var install = Array("IN".utf8) + [1, 16] + S.be(UInt64(tags.count), 2) + S.be(UInt64(p.files.count), 4)
        install += S.tagBlock(tags, entries: p.files.map(\.tags))
        for f in p.files { install += Array(f.name.utf8) + [0] + MD5.hash(f.content) + S.be(UInt64(f.content.count), 4) }
        let downloaded = p.objects.map { (blte: $0.blte, ekey: $0.keys.ekey, tags: $0.tags) }
            + (filesInStore ? zip(p.files, fileObjects).map { (blte: $1.0, ekey: $1.1.ekey, tags: $0.tags) } : [])
        var download = Array("DL".utf8) + [1, 16, 0] + S.be(UInt64(downloaded.count), 4) + S.be(UInt64(tags.count), 2)
        for o in downloaded { download += o.ekey.bytes + S.be(UInt64(o.blte.count), 5) + [0] }
        download += S.tagBlock(tags, entries: downloaded.map(\.tags))
        let root = p.objects[0].keys
        let contents = [(ckey: root.ckey.bytes, size: UInt64(300), ekeys: [root.ekey.bytes])]
            + zip(p.files, fileObjects).map { (ckey: MD5.hash($0.content), size: UInt64($0.content.count), ekeys: [$1.1.ekey.bytes]) }
        let encoding = S.encoding(contents: contents, specs: ["b:{*=n}"],
                                  encodedSizes: [UInt64(p.objects[0].blte.count)] + fileObjects.map { UInt64($0.0.count) })
        var config = "# Build Configuration\n\nroot = \(root.ckey)\n"
        for (name, plain) in [("install", install), ("download", download), ("encoding", encoding)] {
            let (blte, keys) = S.blte(plain, blocks: 3)
            cdn.set(data(keys.ekey), blte)
            config += "\(name) = \(keys.ckey) \(keys.ekey)\n\(name)-size = \(plain.count) \(blte.count)\n"
        }
        config += "build-name = WOW-\(build)patch1.0_Test\nbuild-uid = wow_classic_era\n"
        p.buildConfig = TACTHash(bytes: MD5.hash(Array(config.utf8)))
        cdn.set("\(cdnPath)/config/\(p.buildConfig.cdnPath)", Array(config.utf8))
        let cdnText = "# CDN Configuration\n\narchives = \(p.archives.map(\.hex).joined(separator: " "))\n"
            + "archives-index-size = 1 2\narchive-group = \(p.archiveGroup)\nfile-index = \(fileIndexName)\n"
        p.cdnConfig = TACTHash(bytes: MD5.hash(Array(cdnText.utf8)))
        cdn.set("\(cdnPath)/config/\(p.cdnConfig.cdnPath)", Array(cdnText.utf8))
        let pc = TACTHash(bytes: MD5.hash(productConfig))
        cdn.set("/tpr/configs/data/\(pc.cdnPath)", productConfig)
        cdn.set("/v2/products/wow_classic_era/versions", Array(("Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16\n## seqn = \(build)\n"
            + "us|\(p.buildConfig)|\(p.cdnConfig)||\(build)|1.0.0.\(build)|\(pc)\neu|\(p.buildConfig)|\(p.cdnConfig)||\(build)|1.0.0.\(build)|\(pc)\n").utf8))
        cdn.set("/v2/products/wow_classic_era/cdns", Array(("Name!STRING:0|Path!STRING:0|Hosts!STRING:0|Servers!STRING:0|ConfigPath!STRING:0\n## seqn = 1\n"
            + "us|tpr/wow|level3.blizzard.com us.cdn.blizzard.com|https://us.cdn.blizzard.com/?maxhosts=4 http://level3.blizzard.com/?maxhosts=4|tpr/configs/data\n"
            + "eu|tpr/wow|level3.blizzard.com eu.cdn.blizzard.com|https://eu.cdn.blizzard.com/?maxhosts=4 http://level3.blizzard.com/?maxhosts=4|tpr/configs/data\n").utf8))
        return p
    }
}

final class BattleNetInstallTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))))
    }

    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bnet-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func client(_ cdn: FakeCDN, pauses: Pauses = Pauses(), limit: Int = 4) -> BattleNetClient {
        var m = BattleNetManners()
        m.maxConcurrent = limit
        m.sleep = { pauses.record($0) }
        return BattleNetClient(transport: cdn, manners: m)
    }

    func installer(_ client: BattleNetClient) -> BattleNetInstaller {
        var i = BattleNetInstaller(client: client)
        i.freeSpace = { _ in 1 << 40 }
        i.engine.flushEveryChunks = 1
        return i
    }

    /// Prepares and installs the fake product (us, enUS) into `dir/wow`.
    func install(_ cdn: FakeCDN, in dir: URL, options: BattleNetInstallOptions = BattleNetInstallOptions(locale: "enUS"),
                 client c: BattleNetClient? = nil,
                 configure: (inout BattleNetInstaller) -> Void = { _ in }) async throws -> (BattleNetInstaller.Prepared, BattleNetInstaller.Result) {
        var i = installer(c ?? client(cdn))
        configure(&i)
        let root = dir.appendingPathComponent("wow"), work = dir.appendingPathComponent(".wow.install")
        let prepared = try await i.prepare(.wowClassicEra, .us, options: options, work: work)
        return (prepared, try await i.install(prepared, into: root, work: work))
    }

    // MARK: the local store's formats

    /// The reference implementation's published answers (lookup3's self-test driver).
    func testLookup3MatchesItsPublishedAnswers() {
        let empty = ArraySlice<UInt8>(), four = ArraySlice(Array("Four score and seven years ago".utf8))
        XCTAssertEqual(Lookup3.hashlittle(empty, 0), 0xDEAD_BEEF)
        XCTAssertEqual(Lookup3.hashlittle(empty, 0xDEAD_BEEF), 0xBD5B_7DDE)
        XCTAssertEqual(Lookup3.hashlittle(four, 0), 0x1777_0551)
        XCTAssertEqual(Lookup3.hashlittle(four, 1), 0xCD62_8161)
        XCTAssert(Lookup3.hashlittle2(empty, pc: 0, pb: 0) == (0xDEAD_BEEF, 0xDEAD_BEEF))
        XCTAssert(Lookup3.hashlittle2(empty, pc: 0, pb: 0xDEAD_BEEF) == (0xBD5B_7DDE, 0xDEAD_BEEF))
        XCTAssert(Lookup3.hashlittle2(empty, pc: 0xDEAD_BEEF, pb: 0xDEAD_BEEF) == (0x9C09_3CCD, 0xBD5B_7DDE))
        XCTAssert(Lookup3.hashlittle2(four, pc: 0, pb: 0) == (0x1777_0551, 0xCE72_26E6))
        XCTAssert(Lookup3.hashlittle2(four, pc: 0, pb: 1) == (0xE360_7CAE, 0xBD37_1DE4))
        XCTAssert(Lookup3.hashlittle2(four, pc: 1, pb: 0) == (0xCD62_8161, 0x6CBE_A4B3))
    }

    /// A real archive index (recorded from the CDN) is checked by its name and hashes, locates
    /// the recorded archive object, and is rebuilt byte for byte from its entries, the same
    /// writer that builds the archive group.
    func testARealArchiveIndexLocatesItsObjectsAndIsRebuiltByteForByte() throws {
        let name = TACTHash(hex: "093e5cde8ece3cb1db9dc70343c9cd5d")!
        let bytes = try fixture("093e5cde8ece3cb1db9dc70343c9cd5d.index")
        let index = try ArchiveIndex(bytes, name: name)
        XCTAssertEqual(index.count, 812)
        XCTAssertEqual(index.offsetBytes, 4)
        var entries = [ArchiveIndex.Entry]()
        index.forEach(archive: 7) { entries.append($0) }
        let sample = try XCTUnwrap(entries.first { $0.key == PackedKey(TACTHash(hex: "ff830631095b4ab604a8575a9b8c843e")!) })
        XCTAssertEqual(sample, ArchiveIndex.Entry(key: sample.key, size: 64, archive: 7, offset: 0x0FFF_FFC0))
        let object = try fixture("archive-range-sample-ff830631095b4ab604a8575a9b8c843e.blte")
        XCTAssertNoThrow(try BLTE.verify(object, ekey: sample.key.hash))
        XCTAssertEqual(ArchiveIndex.build(entries, offsetBytes: 4), bytes)

        for at in [5, 4096 + 100, bytes.count - 40, bytes.count - 3] {
            var damaged = bytes
            damaged[at] ^= 0x10
            XCTAssertThrowsError(try ArchiveIndex(damaged, name: name), "byte \(at)")
        }
        XCTAssertThrowsError(try ArchiveIndex(Array(bytes.dropLast(10)), name: nil))
        XCTAssertThrowsError(try ArchiveIndex(bytes, name: TACTHash(bytes: [UInt8](repeating: 1, count: 16))))
    }

    /// A local header carries the reversed EKey, the size with the header, and two checksums
    /// that depend on its place; a flipped bit or the wrong place fails them.
    func testALocalHeaderIsCheckedByItsChecksumsAndPlace() {
        let key = PackedKey(MD5.hash(Array("object".utf8)))
        let h = CASC.header(key, size: 1000, dataFile: 5, offset: 4096)
        XCTAssertEqual(h.count, 30)
        XCTAssertEqual(Array(h[0..<16]), key.bytes.reversed())
        XCTAssertEqual(h.readLE32(at: 16), 1030)
        XCTAssertEqual(CASC.readHeader(h[...], dataFile: 5, offset: 4096)?.key, key)
        XCTAssertEqual(CASC.readHeader(h[...], dataFile: 5, offset: 4096)?.size, 1000)
        XCTAssertNil(CASC.readHeader(h[...], dataFile: 5, offset: 4097))
        XCTAssertNil(CASC.readHeader(h[...], dataFile: 6, offset: 4096))
        for i in 0..<30 {
            var d = h
            d[i] ^= 0x04
            XCTAssertNil(CASC.readHeader(d[...], dataFile: 5, offset: 4096), "byte \(i)")
        }
    }

    /// Each data file starts with sixteen header-only entries, one per journal by the headers'
    /// seed, each naming the data file; the journals list them with every object, sorted, and a
    /// flipped byte in a journal fails its hashes.
    func testDataFileHeadsAndJournalsNameEveryObject() throws {
        let keys = CASC.segmentKeys(dataFile: 3)
        XCTAssertEqual(keys.enumerated().map { CASC.bucket($0.element, seed: 1) == $0.offset }, [Bool](repeating: true, count: 16))
        XCTAssertEqual(Set(keys.map { $0.bytes[1] }), [3])
        let head = CASC.segmentHeader(dataFile: 3)
        XCTAssertEqual(head.count, CASC.segmentHeaderSize)
        for slot in 0..<16 {
            let h = try XCTUnwrap(CASC.readHeader(head[(slot * 30)...], dataFile: 3, offset: UInt32(slot * 30)))
            XCTAssertEqual(h.size, 0)
            XCTAssertEqual(h.key, keys[slot])
        }
        let objects = (0..<200).map { (i: Int) -> CASC.Location in
            let file = i % 2 == 0 ? 3 : 1023
            return CASC.Location(key: PackedKey(MD5.hash([UInt8(i), 9])), dataFile: file, offset: UInt32(480 + i * 100), size: 130)
        }
        let journals = CASC.journals(objects: objects, dataFiles: [3])
        XCTAssertEqual(journals.count, 16)
        var found = [CASC.Location]()
        for (b, j) in journals.enumerated() {
            XCTAssertEqual(j.count % 0x1000, 0)
            let (bucket, locations) = try CASC.readJournal(j)
            XCTAssertEqual(bucket, b)
            XCTAssertEqual(locations.map(\.key), locations.map(\.key).sorted())
            found += locations
        }
        XCTAssertEqual(found.count, 216)
        for o in objects {
            let l = try XCTUnwrap(found.first { $0.key.key9 == o.key.key9 })
            XCTAssertEqual([l.dataFile, Int(l.offset), Int(l.size)], [o.dataFile, Int(o.offset), 130])
        }
        var damaged = journals[0]
        damaged[0x28 + 3] ^= 1
        XCTAssertThrowsError(try CASC.readJournal(damaged))
        damaged = journals[0]
        damaged[10] ^= 1
        XCTAssertThrowsError(try CASC.readJournal(damaged))
    }

    // MARK: the plan

    /// The plan for WoW Classic Era's real install manifest (x64, enUS; decision 0177): the
    /// product folder gets the x64 client and its files under `_classic_era_`, each directory
    /// spelled once, and nothing of the ARM64 client; the store gets the download manifest's
    /// selection for every region, without other locales, the ARM64 client's data or the
    /// Alternate data, and the build's manifests.
    func testThePlanForARealInstallManifestSelectsTheX64ClientInItsProductFolder() async throws {
        let cdn = Recorded()
        cdn.set("/v2/products/wow_classic_era/versions", try fixture("wow_classic_era-versions.psv"))
        cdn.set("/v2/products/wow_classic_era/cdns", try fixture("wow_classic_era-cdns.psv"))
        let config = try fixture("wow_classic_era-buildconfig.txt")
        let row = String(decoding: try fixture("wow_classic_era-versions.psv"), as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("us|") }!.split(separator: "|", omittingEmptySubsequences: false)
        cdn.set("/tpr/wow/config/\(TACTHash(hex: String(row[1]))!.cdnPath)", config)
        cdn.set("/tpr/configs/data/\(TACTHash(hex: String(row[6]))!.cdnPath)", try fixture("wow_classic_era-productconfig.json"))
        let build = try await BattleNetClient(transport: cdn).build(.wowClassicEra, .us)
        let install = try InstallManifest(try BLTE.decode(try fixture("wow_classic_era-install.blte")))

        // Synthetic download manifest and encoding table over the real install manifest.
        typealias S = Synthetic
        let tags = FakeProduct.tags
        let entryTags: [[String]] = [FakeProduct.everywhere, FakeProduct.everywhere.filter { $0 != "enUS" },
                                     FakeProduct.everywhere.filter { !["US", "KR", "TW"].contains($0) },
                                     FakeProduct.everywhere + ["Alternate"], FakeProduct.everywhere.filter { $0 != "arm64" },
                                     FakeProduct.everywhere.filter { $0 != "x86_64" }]
        let ekeys = (0..<entryTags.count).map { MD5.hash([UInt8($0), 0xEE]) }
        var download = Array("DL".utf8) + [1, 16, 0] + S.be(UInt64(entryTags.count), 4) + S.be(UInt64(tags.count), 2)
        for (i, k) in ekeys.enumerated() { download += k + S.be(UInt64(1000 + i), 5) + [UInt8(i % 3)] }
        download += S.tagBlock(tags, entries: entryTags)
        let rootCKey = TACTHash(hex: build.config.config["root"]![0])!
        let contents = [(ckey: rootCKey.bytes, size: UInt64(10), ekeys: [MD5.hash(Array("root".utf8))])]
            + install.files.map { (ckey: $0.ckey.bytes, size: $0.size, ekeys: [MD5.hash($0.ckey.bytes)]) }
        let encoding = try EncodingTable(S.encoding(contents: contents, specs: ["z"]))

        func plan(_ options: BattleNetInstallOptions) throws -> BattleNetInstallPlan {
            let selection = try BattleNetSelection(build: build, download: try DownloadManifest(download), install: install,
                                                   encoding: encoding, options: options)
            return try BattleNetInstallPlan(build: build, archives: [], selection: selection, locations: ArchiveLocations(), options: options)
        }
        let p = try plan(BattleNetInstallOptions(locale: "enUS"))
        let paths = p.files.map(\.path)
        // 35 x64 files (without the three China-region helpers).
        XCTAssertEqual(p.files.count, 35)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("_classic_era_/") })
        let client = try XCTUnwrap(p.client)
        XCTAssertEqual(client.path, "_classic_era_/WowClassic.exe", "the manifest's spelling, not the product config's WoWClassic.exe")
        XCTAssertEqual(p.selection.client(build.productConfig), client)
        XCTAssertFalse(paths.contains("_classic_era_/WowClassic-arm64.exe"))
        XCTAssertFalse(paths.contains { $0.lowercased().contains("arm64") })
        // The x64 build of the helpers the clients share names with under Utils.
        let cef = try XCTUnwrap(p.files.first { $0.path.lowercased() == "_classic_era_/utils/libcef.dll" })
        let x64Cef = try XCTUnwrap(install.files.indices.first {
            install.files[$0].name.lowercased() == #"utils\libcef.dll"# && install.file($0, has: ["Windows", "x86_64"])
        })
        XCTAssertEqual(cef.ckey, install.files[x64Cef].ckey)
        XCTAssertEqual(Set(paths.map { $0.lowercased() }).count, 35)
        let dirs = Set(paths.map { $0.split(separator: "/").dropLast().joined(separator: "/") })
        XCTAssertEqual(dirs.count, Set(dirs.map { $0.lowercased() }).count)
        XCTAssertEqual(Set(p.content.files.map(\.path)).isSuperset(of: paths), true)

        // Stored: the all-locale entry, the EU-only one and the x64-only one; then root and the
        // build's manifests.
        let stored = Set(p.selection.objects.map(\.key))
        XCTAssertEqual(stored.intersection(ekeys.map { PackedKey($0) }), [PackedKey(ekeys[0]), PackedKey(ekeys[2]), PackedKey(ekeys[4])])
        let cfg = build.config.config
        for name in ["encoding", "install", "download", "size", "patch-index", "vfs-root", "vfs-1", "vfs-239"] {
            XCTAssertTrue(stored.contains(PackedKey(TACTHash(hex: cfg[name]![1])!)), name)
        }
        XCTAssertTrue(stored.contains(PackedKey(MD5.hash(Array("root".utf8)))))
        // Every object is loose here (no archive lists it): one request each, laid out after
        // the data file's head.
        XCTAssertEqual(p.dataFiles, [0])
        XCTAssertEqual(p.content.files[0].path, "Data/data/data.000")
        XCTAssertEqual(p.content.files[0].parts[1].fileOffset, 480)
        XCTAssertEqual(p.locations.count, p.selection.objects.count)

        // A product config naming another x64 executable: the selection has no client.
        let renamed = try ProductConfig(Array(String(decoding: try fixture("wow_classic_era-productconfig.json"), as: UTF8.self)
            .replacingOccurrences(of: #""relative_path":"WoWClassic.exe""#, with: #""relative_path":"Elsewhere.exe""#).utf8))
        XCTAssertNil(p.selection.client(renamed))
        var us = BattleNetInstallOptions(locale: "enUS")
        us.regions = [.us]
        XCTAssertFalse(Set(try plan(us).selection.objects.map(\.key)).contains(PackedKey(ekeys[2])))
        XCTAssertThrowsError(try plan(BattleNetInstallOptions(locale: "xxXX")))
    }

    /// Neighbouring objects of an archive are one ranged read, across gaps up to a size; data
    /// files are cut at their size and each starts with its head.
    func testNeighboursAreOneReadAndDataFilesAreCutAtTheirSize() async throws {
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        func plan(_ configure: (inout BattleNetInstallOptions) -> Void) async throws -> BattleNetInstallPlan {
            var options = BattleNetInstallOptions(locale: "enUS")
            configure(&options)
            return try await installer(client(cdn)).prepare(.wowClassicEra, .us, options: options, work: try temp()).plan
        }
        // 40 objects, of which 3 per 8 are deDE-only, Alternate or ARM64-only; root is object 0;
        // and the three manifests.
        let wide = try await plan { $0.maxGapBytes = 1 << 20 }
        XCTAssertEqual(wide.objects, 25 + 3)
        // One read per archive, one per loose object (3 selected, 3 manifests), one per file
        // (the ARM64 client is not selected).
        XCTAssertEqual(wide.requests, 2 + 6 + 3)
        XCTAssertEqual(wide.dataFiles, [0])
        let narrow = try await plan { $0.maxGapBytes = 0 }
        XCTAssertGreaterThan(narrow.requests, wide.requests)
        XCTAssertEqual(narrow.storedBytes, wide.storedBytes)
        XCTAssertLessThan(narrow.fetchBytes, wide.fetchBytes)

        let cut = try await plan { $0.maxDataFileSize = 8000 }
        XCTAssertGreaterThan(cut.dataFiles.count, 3)
        XCTAssertEqual(cut.dataFiles, Array(0..<cut.dataFiles.count))
        XCTAssertEqual(cut.storedBytes, wide.storedBytes)
        for f in cut.content.files where f.path.hasPrefix("Data/data/") {
            XCTAssertLessThanOrEqual(f.size, 8000)
            XCTAssertEqual(f.parts[0].fileOffset, 0)
            XCTAssertEqual(f.parts[0].length, 480)
        }
    }

    // MARK: install

    /// The whole install on a temporary folder: the layout the game reads, the product folder's
    /// files byte for byte, and a verify that reads every object back.
    func testAnInstallWritesTheLayoutTheGameReads() async throws {
        let cdn = FakeCDN()
        let p = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        let (prepared, result) = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow")
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(".wow.install").path))
        XCTAssertTrue(result.archiveGroup)

        let info = try String(contentsOf: root.appendingPathComponent(".build.info"), encoding: .utf8)
        let lines = info.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0]), BuildInfo.header.joined(separator: "|"))
        let read = try BuildInfo.read(Array(info.utf8), product: "wow_classic_era")
        XCTAssertEqual(read.region, .us)
        XCTAssertEqual(read.buildKey, p.buildConfig)
        XCTAssertEqual(read.cdnKey, p.cdnConfig)
        XCTAssertEqual(read.installKey, prepared.plan.build.config.install.ekey)
        XCTAssertEqual(read.cdnHosts, ["level3.blizzard.com", "us.cdn.blizzard.com"])
        XCTAssertEqual(read.cdnServers, ["https://us.cdn.blizzard.com/?maxhosts=4", "http://level3.blizzard.com/?maxhosts=4"])
        XCTAssertEqual(read.tags, "Windows x86_64 US? enUS speech?:Windows x86_64 US? enUS text?")
        XCTAssertEqual(read.version, "1.0.0.1")

        for h in [p.buildConfig, p.cdnConfig] {
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Data/config/\(h.cdnPath)").path))
        }
        let indices = Set(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Data/indices").path))
        XCTAssertTrue(indices.isSuperset(of: (p.archives + [p.archiveGroup]).map { $0.hex + ".index" }))
        let data = Set(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Data/data").path))
        XCTAssertEqual(data.filter { $0.hasSuffix(".idx") }, Set((0..<16).map { CASC.journalName(bucket: $0, generation: 1) }))
        XCTAssertTrue(data.contains("data.000"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("_classic_era_/.flavor.info"), encoding: .utf8),
                       "Product Flavor!STRING:0\nwow_classic_era\n")

        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("_classic_era_/WoWClassic.exe"))), p.files[0].content)
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("_classic_era_/Utils/a.dll"))), p.files[2].content)
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("_classic_era_/Utils/b.dll"))), p.files[3].content)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("_classic_era_/WowClassic-arm64.exe").path))
        XCTAssertEqual(prepared.clientPath, "_classic_era_/WoWClassic.exe")

        // Each stored object is in data.000 exactly as the CDN serves it, after its header.
        let store = [UInt8](try Data(contentsOf: root.appendingPathComponent("Data/data/data.000")))
        for o in p.objects.enumerated().filter({ [0, 1, 2, 4].contains($0.offset % 8) }).map(\.element) {
            let at = try XCTUnwrap(store.firstRange(of: o.blte)?.lowerBound, "\(o.keys.ekey)")
            XCTAssertEqual(CASC.readHeader(store[(at - 30)...], dataFile: 0, offset: UInt32(at - 30))?.key, PackedKey(o.keys.ekey))
        }
        let v = try await BattleNetInstaller.verify(root, plan: prepared.plan)
        XCTAssertTrue(v.isIntact, "\(v.damaged) \(v.missing)")
        XCTAssertEqual(v.objects, prepared.plan.objects)
        XCTAssertEqual(v.files, 3)
    }

    /// A flipped byte anywhere in the store or a product folder file is found by verify.
    func testVerifyFindsAFlippedByte() async throws {
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        let (prepared, _) = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow")
        func flip(_ path: String, at: Int) throws {
            let url = root.appendingPathComponent(path)
            var b = [UInt8](try Data(contentsOf: url))
            b[at] ^= 0x20
            try Data(b).write(to: url)
        }
        let store = "Data/data/data.000"
        let size = Int(InstallFS.fileSize(root.appendingPathComponent(store))!)
        for at in [5, 480 + 3, 480 + 30 + 9, size / 2, size - 1] {
            try flip(store, at: at)
            let v = try await BattleNetInstaller.verify(root, plan: prepared.plan)
            XCTAssertFalse(v.isIntact, "byte \(at)")
            try flip(store, at: at)
        }
        try flip("_classic_era_/Utils/a.dll", at: 100)
        let v = try await BattleNetInstaller.verify(root, plan: prepared.plan)
        XCTAssertEqual(v.damaged.count, 1)
        XCTAssertTrue(v.damaged[0].hasPrefix("_classic_era_/Utils/a.dll"))
    }

    /// An install interrupted after a few reads resumes without reading them again; a chunk
    /// damaged on disk while it was stopped is read again rather than trusted.
    func testAnInterruptedInstallResumesAndRefetchesWhatWasDamaged() async throws {
        let cdn = FakeCDN()
        let p = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let dir = try temp()
        do {
            _ = try await install(cdn, in: dir) { $0.engine.cancelAfterChunks = 3; $0.engine.concurrency = 1 }
            XCTFail("expected a pause")
        } catch ClientError.cancelled {}
        let before = cdn.requests.filter { $0.status == 206 }.count
        XCTAssertGreaterThan(before, 0)
        // Damage the first run's last byte in the stage.
        let staged = dir.appendingPathComponent(".wow.install/tree/Data/data/data.000")
        var b = [UInt8](try Data(contentsOf: staged))
        let firstRun = try XCTUnwrap(b.firstRange(of: p.objects[0].blte))
        b[firstRun.upperBound - 1] ^= 0x01
        try Data(b).write(to: staged)

        let (prepared, result) = try await install(cdn, in: dir)
        XCTAssertEqual(result.engine.chunksRejected, 1)
        XCTAssertGreaterThan(result.engine.chunksResumed, 0)
        // Indexes and manifests came from the work area, not the CDN, the second time.
        XCTAssertEqual(cdn.requests.filter { $0.url.path.hasSuffix(".index") }.count, 3)
        let v = try await BattleNetInstaller.verify(dir.appendingPathComponent("wow"), plan: prepared.plan)
        XCTAssertTrue(v.isIntact, "\(v.damaged) \(v.missing)")
    }

    // MARK: manners

    /// Every request goes to a host the version or CDN endpoint names, carries Playport's
    /// User-Agent, and no more than the limit are in flight at once.
    func testOnlyNamedHostsWithPlaysportsUserAgentAndBoundedConcurrency() async throws {
        let cdn = FakeCDN()
        cdn.delay = 2_000_000
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        var options = BattleNetInstallOptions(locale: "enUS")
        options.maxGapBytes = 0
        _ = try await install(cdn, in: try temp(), options: options, client: client(cdn, limit: 3)) { $0.engine.concurrency = 16 }
        let named: Set<String> = ["us.version.battle.net", "us.cdn.blizzard.com", "level3.blizzard.com"]
        XCTAssertGreaterThan(cdn.requests.count, 20)
        for r in cdn.requests {
            XCTAssertTrue(named.contains(r.url.host ?? ""), "\(r.url)")
            XCTAssertEqual(r.headers["User-Agent"], "Playport")
        }
        XCTAssertLessThanOrEqual(cdn.peak, 3)
        XCTAssertEqual(cdn.peak, 3)
    }

    /// A 429 pauses the host for its Retry-After, or a doubling back-off without one, and the
    /// request is asked again; it gives up only after the retries.
    func testA429BacksOffAndAsksAgain() async throws {
        let cdn = FakeCDN()
        let p = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        let pauses = Pauses()
        cdn.throttle(FakeProduct.data(p.archives[0]), times: 2, retryAfter: "7")
        cdn.throttle(FakeProduct.data(p.archives[1]), times: 3, retryAfter: nil)
        let dir = try temp()
        let (prepared, _) = try await install(cdn, in: dir, client: client(cdn, pauses: pauses, limit: 1))
        // The host waits other requests make while it is paused are fractions of a second short
        // of a whole pause; the client's own pauses are whole seconds.
        XCTAssertEqual(pauses.all.filter { $0 == $0.rounded() }, [7, 7, 2, 4, 8])
        XCTAssertEqual(cdn.requests.filter { $0.status == 429 }.count, 5)
        let v = try await BattleNetInstaller.verify(dir.appendingPathComponent("wow"), plan: prepared.plan)
        XCTAssertTrue(v.isIntact)

        let always = FakeCDN()
        _ = FakeProduct.make(on: always, productConfig: try fixture("wow_classic_era-productconfig.json"))
        always.throttle("/v2/products/wow_classic_era/versions", times: 100, retryAfter: "1")
        do {
            _ = try await client(always).build(.wowClassicEra, .us)
            XCTFail("expected a refusal")
        } catch let e as BattleNetError {
            XCTAssertEqual(e, .refused(status: 429, "wow_classic_era versions from us.version.battle.net"))
        }
        XCTAssertEqual(always.requests.filter { $0.url.path.hasSuffix("/versions") }.count, 6)
    }

    /// A Retry-After that is negative, infinite, not a number or huge never traps: the pause is
    /// the back-off for an unreadable one and at most `maxBackoff` for a huge one.
    func testADamagedRetryAfterWaitsABoundedTime() async throws {
        for (value, pause) in [("-1", 2.0), ("inf", 2), ("nan", 2), ("1e20", 120), ("abc", 2), ("30", 30)] {
            let cdn = FakeCDN()
            _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
            cdn.throttle("/v2/products/wow_classic_era/versions", times: 1, retryAfter: value)
            let pauses = Pauses()
            _ = try await client(cdn, pauses: pauses, limit: 1).version(.wowClassicEra, .us)
            XCTAssertEqual(pauses.all, [pause], value)
        }
    }

    /// A client given a build's key ring keeps the store client's manners: the same request
    /// limit and the same hosts paused by a 429.
    func testAClientWithAKeyRingSharesTheRequestLimitAndPauses() async throws {
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: try fixture("wow_classic_era-productconfig.json"))
        cdn.throttle("/v2/products/wow_classic_era/versions", times: 1, retryAfter: "30")
        let pauses = Pauses()
        let store = client(cdn, pauses: pauses, limit: 1)
        _ = try await store.version(.wowClassicEra, .us)
        let keyed = store.adding(keys: TACTKeyring(keys: [1: [UInt8](repeating: 7, count: 16)]))
        XCTAssertEqual(keyed.keys.keys[1], [UInt8](repeating: 7, count: 16))
        _ = try await keyed.cdn(.wowClassicEra, .us)
        // The store client's own pause, then the keyed client waits out what is left of it.
        XCTAssertEqual(pauses.all.count, 2, "\(pauses.all)")
        XCTAssertGreaterThan(pauses.all.last ?? 0, 25)
    }

    /// A build whose plan lacks the x64 client the product config names is refused while it is
    /// planned, before anything is downloaded; the plan names the client otherwise.
    func testAPlanWithoutItsX64ClientIsRefusedBeforeTheDownload() async throws {
        let config = try fixture("wow_classic_era-productconfig.json")
        let cdn = FakeCDN()
        _ = FakeProduct.make(on: cdn, productConfig: config)
        let dir = try temp()
        let prepared = try await installer(client(cdn)).prepare(.wowClassicEra, .us, options: BattleNetInstallOptions(locale: "enUS"),
                                                                 work: dir.appendingPathComponent(".ok"))
        XCTAssertEqual(prepared.plan.client?.path, "_classic_era_/WoWClassic.exe")
        XCTAssertEqual(prepared.clientPath, "_classic_era_/WoWClassic.exe")

        let other = FakeCDN()
        let renamed = String(decoding: config, as: UTF8.self).replacingOccurrences(of: #""relative_path":"WoWClassic.exe""#,
                                                                                    with: #""relative_path":"Elsewhere.exe""#)
        _ = FakeProduct.make(on: other, productConfig: Array(renamed.utf8))
        await assertThrows(try await installer(client(other)).prepare(.wowClassicEra, .us, options: BattleNetInstallOptions(locale: "enUS"),
                                                                      work: dir.appendingPathComponent(".no"))) {
            guard case let .unsupported(why) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("x64 client"), why)
        }
        XCTAssertFalse(other.requests.contains { $0.status == 206 })
    }

    // MARK: live (workstation)

    /// Installs a product from Blizzard's CDN on the workstation and writes what it took to a
    /// Markdown report. `BATTLENET_LIVE_INSTALL=<product>:<install root>` (region us, locale
    /// enUS), `BATTLENET_LIVE_REPORT=<file>`.
    /// Skipped unless both are set. A network failure resumes the install, up to 20 times; run
    /// again after an interruption, it resumes too.
    func testLiveInstall() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["BATTLENET_LIVE_INSTALL"], let out = env["BATTLENET_LIVE_REPORT"], !out.isEmpty,
              let colon = spec.firstIndex(of: ":"), let product = BattleNetProduct(rawValue: String(spec[..<colon])) else {
            throw XCTSkip("BATTLENET_LIVE_INSTALL and BATTLENET_LIVE_REPORT are not set")
        }
        let root = URL(fileURLWithPath: String(spec[spec.index(after: colon)...]))
        let work = BattleNetInstaller.workArea(for: root)
        let options = BattleNetInstallOptions(locale: "enUS")
        let transport = Counting(BattleNetClientKitTests.live)
        let installer = BattleNetInstaller(client: BattleNetClient(transport: transport), log: .stderr())
        @Sendable func say(_ s: String) { FileHandle.standardError.write(Data("[live] \(s)\n".utf8)) }
        @Sendable func gb(_ b: UInt64) -> String { String(format: "%.2f GB (%llu B)", Double(b) / 1e9, b) }
        func time(_ s: Double) -> String { String(format: "%.0f s (%.1f min)", s, s / 60) }

        var started = Date()
        let prepared = try await installer.prepare(product, .us, options: options, work: work)
        let prepareSeconds = Date().timeIntervalSince(started)
        let plan = prepared.plan
        say("plan: \(plan.objects) objects, \(gb(plan.storedBytes)) stored, \(plan.requests) requests, \(gb(plan.fetchBytes)) to fetch, "
            + "\(plan.files.count) files, \(plan.dataFiles.count) data files")

        started = Date()
        var attempts = 0
        var result: BattleNetInstaller.Result?
        while result == nil {
            attempts += 1
            do {
                result = try await installer.install(prepared, into: root, work: work) { p in
                    say(String(format: "%.1f%% %@ of %@ written, %d/%d reads, %.0f s", Double(p.bytesDone) / Double(max(1, p.bytesTotal)) * 100,
                               gb(p.bytesDone), gb(p.bytesTotal), p.chunksDownloaded, p.chunksToDownload, p.seconds))
                }
            } catch let e as BattleNetError where e.isNetwork && attempts < 20 {
                say("attempt \(attempts): \(e); resuming in 30 s")
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        let installSeconds = Date().timeIntervalSince(started)
        started = Date()
        let v = try await BattleNetInstaller.verify(root, plan: plan)
        let verifySeconds = Date().timeIntervalSince(started)
        say("verify: \(v.objects) objects, \(v.files) files, damaged \(v.damaged.prefix(5)), missing \(v.missing.prefix(5))")

        let b = plan.build
        let engine = result!.engine
        var lines = ["| | |", "|---|---|",
                     "| product | `\(product.code)` \(b.version.versionsName) (build \(b.version.buildID)), region us, enUS, regions kept: \(options.regions.map(\.rawValue).joined(separator: " ")) |",
                     "| machines | \(b.productConfig.x64Tags.joined(separator: " ")) (`\(prepared.clientPath)`) |",
                     "| stored objects | \(plan.objects), \(gb(plan.storedBytes)) in \(plan.dataFiles.count) data files |",
                     "| product folder files | \(plan.files.count), \(gb(plan.files.reduce(0) { $0 + $1.size })) |",
                     "| CDN reads | \(plan.requests) planned (\(gb(plan.fetchBytes))); this run \(engine.chunksDownloaded) chunks, \(gb(engine.downloadedBytes)) written from the CDN; \(engine.chunksResumed) resumed, \(engine.chunksRejected) rejected on resume |",
                     "| HTTP answers | \(transport.summary) |",
                     "| install attempts | \(attempts) |",
                     "| prepare (configs, manifests, \(prepared.indexes.count) indexes) | \(time(prepareSeconds)) |",
                     "| install | \(time(installSeconds)) |",
                     "| verify (every object and file read back) | \(time(verifySeconds)): \(v.objects) objects, \(gb(v.bytes)), \(v.files) files; \(v.isIntact ? "intact" : "damaged \(v.damaged.count), missing \(v.missing.count)") |",
                     "| archive group built here matches its CDN name | \(result!.archiveGroup ? "yes" : "no") |",
                     "", "`.build.info`:", "", "```", BattleNetInstaller.buildInfo(prepared).text.trimmingCharacters(in: .newlines), "```", "",
                     "Layout:", "", "```"]
        let fm = FileManager.default
        for top in try fm.contentsOfDirectory(atPath: root.path).sorted() {
            let url = root.appendingPathComponent(top)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            guard isDir.boolValue else {
                lines.append("\(top)  \(InstallFS.fileSize(url) ?? 0) B")
                continue
            }
            var count = 0, bytes: UInt64 = 0
            var kinds = [String: Int]()
            for case let f as String in fm.enumerator(atPath: url.path) ?? NSEnumerator() {
                guard let s = InstallFS.fileSize(url.appendingPathComponent(f)),
                      (try? fm.attributesOfItem(atPath: url.appendingPathComponent(f).path)[.type] as? FileAttributeType) == .typeRegular else { continue }
                count += 1
                bytes += s
                let parts = f.split(separator: "/")
                kinds[parts.count > 1 ? parts.dropLast().joined(separator: "/") : ".", default: 0] += 1
            }
            lines.append("\(top)/  \(count) files, \(gb(bytes))")
            for (dir, n) in kinds.sorted(by: { $0.key < $1.key }) { lines.append("  \(dir)/  \(n) files") }
        }
        lines.append("```")
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        XCTAssertTrue(v.isIntact)
    }
}

/// Counts the answers by HTTP status (for the live report).
final class Counting: BattleNetTransport, @unchecked Sendable {
    let inner: any BattleNetTransport
    private let lock = NSLock()
    private var statuses = [Int: Int]()

    init(_ inner: any BattleNetTransport) { self.inner = inner }

    var summary: String { lock.withLock { statuses.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }.joined(separator: ", ") } }

    func get(_ url: URL, headers: [String: String]) async throws -> BattleNetResponse {
        let r = try await inner.get(url, headers: headers)
        lock.withLock { statuses[r.status, default: 0] += 1 }
        if r.status == 429 { FileHandle.standardError.write(Data("[live] 429 from \(url.host ?? "?") retry-after \(r.headers["retry-after"] ?? "-")\n".utf8)) }
        return r
    }
}
