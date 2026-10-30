// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// The synthetic MSIXVC2 package `Fixtures/msixvc2-synthetic.msixvc2`, written by
/// `Tests/msixvc2-fixture.py` (Python's zipfile, zlib and `cryptography`, independent
/// of the reader): the real layout, a test key. Expected values are that script's.
enum XboxMSIXVC2Fixture {
    static let keyID = UUID(uuidString: "5e0a4c51-8f1d-4b7a-9c1e-0d5a3b2c1f00")!
    static let key = Array(0x40...0x5F).map(UInt8.init)
    static let contentID = "2c6a9d8e-31f4-4b0a-8e57-1f2a3b4c5d6e"
    static let fulfillmentID = "7d1e2f3a-4b5c-4d6e-8f70-8192a3b4c5d6"
    /// Path, size, SHA-256 of every file as the script printed them.
    static let files: [(String, UInt64, String)] = [
        ("Data/Sub/readme.txt", 33, "865bac19c9b171b56a23c569a2cb2361163d9602e35cb63ef26346bfe59569da"),
        ("Data/Sub/shared.bin", 5000, "bb963871b9ed1a04f3ca3f8915d3f94ce7e57ab822a861dd8fe1043a52ab1a2e"),
        ("Data/empty.txt", 0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("Data/level1.bin", 28000, "b2397e74b5c0143ed7d28bd958d5ae82ae651c185a30cd51103a773ef61b9dd7"),
        ("Game.exe", 9004, "77c1d98acf98fc0ae4f9475d09b0536ce577b01e48c70c173ac3edd522e1fa27"),
        ("MicrosoftGame.config", 411, "5f070775308ea60927ec176582e1426168e9ffa960dbf604402e11a18712859d"),
    ]
    static func bytes() throws -> [UInt8] { try xboxFixture("msixvc2-synthetic.msixvc2") }
    static var licence: [UUID: [UInt8]] { [keyID: key] }

    /// Where a stored or deflated ZIP entry's bytes start and how many there are (local headers, in order).
    static func entry(_ name: String, in b: [UInt8]) -> Range<Int> {
        var o = 0
        while b.readLE32(at: o) == 0x0403_4B50 {
            let n = Int(b.readLE16(at: o + 26)), x = Int(b.readLE16(at: o + 28)), size = Int(b.readLE32(at: o + 18))
            let at = o + 30 + n + x
            if String(decoding: b[(o + 30)..<(o + 30 + n)], as: UTF8.self) == name { return at..<(at + size) }
            o = at + size
        }
        fatalError("no \(name)")
    }
}

/// Package bytes from memory, counting what is read.
final class XboxMemoryPackage: XboxPackageBytes, @unchecked Sendable {
    let lock = NSLock()
    let body: [UInt8]
    private(set) var reads: [Range<UInt64>] = []
    init(_ body: [UInt8]) { self.body = body }
    var size: UInt64 { UInt64(body.count) }
    func read(_ offset: UInt64, _ count: Int) async throws -> [UInt8] {
        guard offset + UInt64(count) <= size else { throw ClientError.transport("past the end") }
        lock.withLock { reads.append(offset..<(offset + UInt64(count))) }
        return Array(body[Int(offset)..<(Int(offset) + count)])
    }
}

final class XboxMSIXVC2Tests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-msixvc2-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func fetch(_ bytes: [UInt8], licence: [UUID: [UInt8]] = XboxMSIXVC2Fixture.licence, log: Logger = .silent) async throws -> XboxMSIXVC2Package {
        try await XboxMSIXVC2Package.fetch(XboxMemoryPackage(bytes), into: root.appendingPathComponent("meta.package"), licence: licence, log: log)
    }

    func damaged(_ bytes: [UInt8], _ why: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await XboxMSIXVC2Package.fetch(XboxMemoryPackage(bytes), into: root.appendingPathComponent("\(UUID().uuidString).package"),
                                                   licence: XboxMSIXVC2Fixture.licence)
            XCTFail("a damaged package loaded", file: file, line: line)
        } catch let ClientError.verificationFailed(message) {
            XCTAssertEqual(message, "Xbox package is damaged: " + why, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    /// The package's metadata through its ZIP directory: identity, version, every
    /// file's name (from the chunk secrets, decrypted with the licence's key) and size.
    func testThePackageListsItsFilesFromItsEncryptedChunkSecrets() async throws {
        let package = try await fetch(try XboxMSIXVC2Fixture.bytes())
        XCTAssertEqual(package.contentID.uuidString.lowercased(), XboxMSIXVC2Fixture.contentID)
        XCTAssertEqual(package.fulfillmentContentID?.uuidString.lowercased(), XboxMSIXVC2Fixture.fulfillmentID)
        XCTAssertEqual(package.version, "1.2.3.0")
        XCTAssertEqual(package.files.map(\.path).sorted(), XboxMSIXVC2Fixture.files.map(\.0))
        for (path, size, _) in XboxMSIXVC2Fixture.files { XCTAssertEqual(package.files.first { $0.path == path }?.size, size, path) }
        XCTAssertEqual(package.gameConfigPath, "MicrosoftGame.config")
        // One chunk per distinct segment: shared.bin's bytes are level1.bin's middle segment.
        let plan = package.plan()
        XCTAssertEqual(plan.totalBytes, XboxMSIXVC2Fixture.files.reduce(0) { $0 + $1.1 })
        XCTAssertEqual(plan.chunks.count, 8, "Game.exe 3, the config 1, level1.bin 3, readme.txt 1")
    }

    /// The metadata reads are kept beside the stage: loading again reads nothing remote.
    func testTheMetadataIsNotFetchedTwice() async throws {
        let remote = XboxMemoryPackage(try XboxMSIXVC2Fixture.bytes())
        let url = root.appendingPathComponent("meta.package")
        let first = try await XboxMSIXVC2Package.fetch(remote, into: url, licence: XboxMSIXVC2Fixture.licence)
        let reads = remote.reads.count
        XCTAssertGreaterThan(reads, 0)
        XCTAssertLessThan(first.metadataBytes, remote.size, "segments of files are not metadata")
        let again = try await XboxMSIXVC2Package.fetch(remote, into: url, licence: XboxMSIXVC2Fixture.licence)
        XCTAssertEqual(remote.reads.count, reads)
        XCTAssertEqual(again.files, first.files)
        // A record cut short by a stop is dropped and fetched again.
        let kept = try Data(contentsOf: url)
        try kept.prefix(kept.count - 5).write(to: url)
        _ = try await XboxMSIXVC2Package.fetch(remote, into: url, licence: XboxMSIXVC2Fixture.licence)
        XCTAssertEqual(remote.reads.count, reads + 1)
    }

    /// Damage anywhere in the metadata throws "damaged" (and never traps): the ZIP's
    /// directory or end record, a metadata entry (its CRC), a box's header, trailer or
    /// manifest (its seal), a chunk secret's box bytes (its box hash).
    func testDamagedMetadataIsRefused() async throws {
        let good = try XboxMSIXVC2Fixture.bytes()
        func flipped(_ at: Int) -> [UInt8] { var b = good; b[at] ^= 0x20; return b }
        let package = XboxMSIXVC2Fixture.entry("XboxPackage.cbor", in: good)
        let chunk1 = XboxMSIXVC2Fixture.entry("Chunks/1.cbor", in: good)
        let box0 = XboxMSIXVC2Fixture.entry("Boxes/box0", in: good)
        let manifestAt = box0.lowerBound + Int(good.readLE64(at: box0.upperBound - 12))
        let directoryAt = Int(good.readLE32(at: good.count - 22 + 16))
        await damaged(flipped(package.lowerBound + 10), "its XboxPackage.cbor doesn't inflate")
        await damaged(flipped(chunk1.lowerBound + 40), "its Chunks/1.cbor doesn't match its CRC")
        await damaged(flipped(manifestAt + 30), "box box0's manifest doesn't match its seal")
        await damaged(flipped(box0.upperBound - 12), "its box box0 seal has a simple value 17 it shouldn't")
        await damaged(flipped(box0.lowerBound + 2), "its box box0 has no box header")
        // The chunk secrets are box0's last segments: chunk 1's ends where the manifest starts.
        await damaged(flipped(manifestAt - 5), "chunk 1's secret doesn't match its box hash")
        await damaged(flipped(directoryAt + 3), "its ZIP directory is damaged")
        await damaged(Array(good[0..<(good.count - 30)]), "it has no ZIP directory")
        await damaged(Array(good[0..<(good.count / 2)]), "it has no ZIP directory")
    }

    /// A licence whose key is not the package's: the chunk secrets' box bytes check, their
    /// plaintext doesn't, which is the licence's fault, not the package's.
    func testAWrongLicenceKeyIsItsOwnError() async throws {
        let good = try XboxMSIXVC2Fixture.bytes()
        let lines = XboxLines()
        do {
            _ = try await fetch(good, licence: [UUID(): [UInt8](repeating: 7, count: 32)], log: lines.logger)
            XCTFail("decrypted with the wrong key")
        } catch let ClientError.verificationFailed(why) {
            XCTAssertEqual(why, "Xbox licence key doesn't decrypt this package")
        }
        XCTAssertTrue(lines.text.contains("using the licence's only key"))
        do {
            _ = try await fetch(good, licence: [UUID(): XboxMSIXVC2Fixture.key, UUID(): XboxMSIXVC2Fixture.key])
            XCTFail("no key")
        } catch let ClientError.verificationFailed(why) {
            XCTAssertEqual(why, "Xbox licence has no key for this package")
        }
    }

    // Known answers from independent sources.

    func testSHA384AndSHA512MatchFIPS180() {
        XCTAssertEqual(XboxSHA512.hash512(Array("abc".utf8)).hex,
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(XboxSHA512.hash384(Array("abc".utf8)).hex,
                       "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
        // Across block boundaries, fed in uneven pieces (Python hashlib).
        let a = [UInt8](repeating: 0x61, count: 1000)
        var s = XboxSHA512.sha384()
        for piece in [a[0..<1], a[1..<130], a[130..<1000]] { s.update(Array(piece)) }
        XCTAssertEqual(s.finalize().hex, "f54480689c6b0b11d0303285d9a81b21a93bca6ba5a1b4472765dca4da45ee328082d469c650cd3b61b16d3266ab8ced")
        XCTAssertEqual(XboxSHA512.hash512(a).hex,
                       "67ba5535a46e3f86dbfbed8cbbaf0125c76ed549ff8b0b9e03e0c88cf90fa634fa7b12b47d77b694de488ace8d9a65967dc96df599727d3292a8d9d447709c97")
    }

    /// NIST SP800-38A F.2.6 (CBC-AES256.Decrypt), no padding.
    func testCBCWithoutPaddingMatchesSP80038A() throws {
        var c = Array(hexBytes: "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b")!
        try AES256Decryptor(key: Array(hexBytes: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")!)
            .decryptCBCInPlace(&c, iv: Array(hexBytes: "000102030405060708090a0b0c0d0e0f")!)
        XCTAssertEqual(c.hex, "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
    }

    /// RFC 3394 4.6 (256-bit KEK, 256-bit key); RFC 5649 by Python `cryptography`.
    func testKeyUnwrapMatchesRFC3394AndRFC5649() throws {
        let rfc = try XboxMSIXVC2Keys.unwrap(Array(hexBytes: "28c9f404c4b810f4cbccb35cfb87f8263f5786e2d80ed326cbc7f0e71a99f43bfb988b9b7a02dd21")!,
                                             with: Array(0...31).map(UInt8.init), iv: nil)
        XCTAssertEqual(rfc.hex, "00112233445566778899aabbccddeeff000102030405060708090a0b0c0d0e0f")
        let kek = Array(0x20...0x3F).map(UInt8.init)
        let padded = try XboxMSIXVC2Keys.unwrap(Array(hexBytes: "9465dd648aa0ddae887f20dc7cb52f5c89f32ca08acb7f499f766285bb7926f0f00e67c8bce0f4f8")!, with: kek, iv: nil)
        XCTAssertEqual(padded, Array(0x80...0x9F).map(UInt8.init))
        let short = try XboxMSIXVC2Keys.keyUnwrap(Array(hexBytes: "29c8d8e90d93203abef8565e0143628bcecf77759dd659621a68540b620f9bee")!, AES256Decryptor(key: kek))
        XCTAssertEqual(short, Array(0xA0...0xB3).map(UInt8.init))
        var bad = Array(hexBytes: "9465dd648aa0ddae887f20dc7cb52f5c89f32ca08acb7f499f766285bb7926f0f00e67c8bce0f4f8")!
        bad[3] ^= 1
        XCTAssertThrowsError(try XboxMSIXVC2Keys.unwrap(bad, with: kek, iv: nil))
    }

    /// SP800-108 HMAC-SHA256 with MSIXVC2's label (Python hmac).
    func testKeyDerivationMatchesSP800108() {
        XCTAssertEqual(XboxMSIXVC2Keys.derive(Array(0...31).map(UInt8.init), context: Array("context-0123".utf8)).hex,
                       "eed2d14a0069e8763b2a81505c1d120ff869a81755969ead5883595cabcc0d98")
    }

    /// Nothing signs an MSIXVC2's metadata (none is known): a segment counts only when its
    /// key is wrapped under the licence's, so a key written in the package or a plain
    /// segment is refused. An empty segment carries no bytes and needs no key.
    func testASegmentMustBeEncryptedUnderTheLicencesKey() throws {
        typealias L = XboxMSIXVC2.Label
        func segment(_ extra: [(UInt64, XboxCBOR)], length: UInt64 = 16) -> XboxCBOR {
            .map([(.unsigned(L.hash), .tag(XboxMSIXVC2.Tag.sha256, .bytes([UInt8](repeating: 1, count: 32)))),
                  (.unsigned(L.length), .unsigned(length))] + extra.map { (.unsigned($0.0), $0.1) })
        }
        var iv: XboxMSIXVC2.IV? = nil
        let key = XboxCBOR.bytes([UInt8](repeating: 7, count: 40))
        XCTAssertNoThrow(try XboxMSIXVC2.Segment.parse(segment([(L.wrappedKey, key)]), iv: &iv, what: "wrapped"))
        XCTAssertNoThrow(try XboxMSIXVC2.Segment.parse(segment([], length: 0), iv: &iv, what: "empty"))
        for (what, s) in [("plain", segment([])), ("inline key", segment([(L.encryptionKey, .bytes([UInt8](repeating: 7, count: 32)))])),
                          ("both", segment([(L.wrappedKey, key), (L.encryptionKey, .bytes([UInt8](repeating: 7, count: 32)))]))] {
            XCTAssertThrowsError(try XboxMSIXVC2.Segment.parse(s, iv: &iv, what: what), what) {
                XCTAssertTrue("\($0)".contains("not encrypted under its licence"), "\($0)")
            }
        }
    }

    /// Damaged CBOR throws, never traps or allocates what it declares.
    func testDamagedCBORIsRefused() {
        for bad: [UInt8] in [[0x9F, 0x01, 0xFF], [0x5B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], [0xBA, 0xFF, 0xFF, 0xFF, 0xFF],
                             [UInt8](repeating: 0x81, count: 200) + [0x01], [0x63, 0xC3, 0x28, 0x41], [0x01, 0x02], [0x18], []] {
            XCTAssertThrowsError(try XboxCBOR.decode(bad, what: "test"), bad.hex)
        }
        XCTAssertEqual(try XboxCBOR.decode([0xD9, 0xD9, 0xF7, 0xA1, 0x19, 0x01, 0x04, 0x82, 0xF5, 0x20], what: "test"),
                       .tag(55799, .map([(.unsigned(260), .array([.bool(true), .negative(0)]))])))
    }
}
