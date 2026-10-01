// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// Decoders checked against fixtures produced by independent encoders
/// (tools/make-fixtures.py: CPython zlib/gzip/lzma/zstd and `openssl enc`).
final class CodecTests: XCTestCase {
    struct Meta: Decodable {
        let plain_sha1: String
        let mixed_sha1: String
        let plain_len: Int
        let small_sha1: String
        let chunk_key_hex: String
        let plain_adler32_seed0: UInt32
    }

    static func fixture(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return [UInt8](try Data(contentsOf: url))
    }

    static let meta: Meta = try! JSONDecoder().decode(Meta.self, from: Data(fixture("fixtures.json")))

    func assertPlain(_ out: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(out.count, Self.meta.plain_len, file: file, line: line)
        XCTAssertEqual(SHA1.hash(out).hex, Self.meta.plain_sha1, file: file, line: line)
    }

    func testRawDeflate() throws {
        assertPlain(try Inflate.decompress(Self.fixture("plain.deflate")[...], limit: Self.meta.plain_len))
    }

    /// The bit reader buffers input ahead; a stored block must start at the
    /// byte after its header however much was buffered.
    func testDeflateStoredBlockAfterCompressedBlocks() throws {
        let out = try Inflate.decompress(Self.fixture("mixed.deflate")[...], limit: 61_000)
        XCTAssertEqual(out.count, 61_000)
        XCTAssertEqual(SHA1.hash(out).hex, Self.meta.mixed_sha1)
    }

    /// The decoders write through unsafe pointers: damaged or cut input must
    /// end in a thrown `SteamError` or bounded output, never a crash.
    func testInflateCorruptionAndTruncationAreTypedFailures() throws {
        let good = try Self.fixture("plain.deflate")
        let limit = Self.meta.plain_len
        for cut in stride(from: 0, to: good.count, by: 1_531) {
            XCTAssertThrowsError(try Inflate.decompress(good[..<cut], limit: limit)) { e in
                XCTAssert(e is SteamError, "\(e)")
            }
        }
        for at in stride(from: 0, to: good.count, by: 211) {
            var bad = good
            bad[at] ^= 0x5A
            do {
                let out = try Inflate.decompress(bad[...], limit: limit)
                XCTAssertLessThanOrEqual(out.count, limit)
            } catch { XCTAssert(error is SteamError, "\(error)") }
        }
    }

    func testLZMACorruptionAndTruncationAreTypedFailures() throws {
        let vzip = try Self.fixture("plain.vzip")
        let stream = Array(vzip[12..<(vzip.count - 10)])
        let props = vzip[7], dict = vzip.readLE32(at: 8), n = Self.meta.plain_len
        assertPlain(try LZMA.decompress(stream[...], properties: props, dictionarySize: dict, outSize: n))
        for cut in stride(from: 0, to: stream.count - 16, by: 1_499) {
            XCTAssertThrowsError(try LZMA.decompress(stream[..<cut], properties: props, dictionarySize: dict, outSize: n)) { e in
                XCTAssert(e is SteamError, "\(e)")
            }
        }
        for at in stride(from: 0, to: stream.count, by: 197) {
            var bad = stream
            bad[at] ^= 0x5A
            do {
                let out = try LZMA.decompress(bad[...], properties: props, dictionarySize: dict, outSize: n)
                XCTAssertLessThanOrEqual(out.count, n)
            } catch { XCTAssert(error is SteamError, "\(error)") }
        }
    }

    func testGzip() throws {
        assertPlain(try Gzip.decompress(Self.fixture("plain.gz"), limit: Self.meta.plain_len))
    }

    func testInflateRefusesToExceedTheDeclaredSize() throws {
        XCTAssertThrowsError(try Inflate.decompress(Self.fixture("plain.deflate")[...], limit: 1000)) { e in
            guard case SteamError.unsafeContent = e else { return XCTFail("\(e)") }
        }
    }

    func testZstdAtSeveralLevels() throws {
        for name in ["plain.l1.zst", "plain.l3.zst", "plain.l19.zst", "plain.check.zst"] {
            assertPlain(try Zstd.decompress(Self.fixture(name)[...], limit: Self.meta.plain_len))
        }
        let small = try Zstd.decompress(Self.fixture("small.zst")[...], limit: 1500)
        XCTAssertEqual(SHA1.hash(small).hex, Self.meta.small_sha1)
    }

    func testZstdBombStopsAtTheLimit() throws {
        XCTAssertThrowsError(try Zstd.decompress(Self.fixture("plain.l3.zst")[...], limit: 4096)) { e in
            guard case SteamError.unsafeContent = e else { return XCTFail("\(e)") }
        }
    }

    func testZstdCorruptionIsATypedFailure() throws {
        var z = try Self.fixture("plain.l3.zst")
        for i in stride(from: 40, to: z.count, by: 997) { z[i] ^= 0x5A }
        XCTAssertThrowsError(try Zstd.decompress(z[...], limit: Self.meta.plain_len))
    }

    func testVZipLZMAContainer() throws {
        assertPlain(try ChunkCodec.decompress(Self.fixture("plain.vzip"), expectedSize: Self.meta.plain_len))
    }

    func testVZstdContainer() throws {
        assertPlain(try ChunkCodec.decompress(Self.fixture("plain.vzstd"), expectedSize: Self.meta.plain_len))
    }

    func testDeclaredSizeMustMatchTheManifest() throws {
        XCTAssertThrowsError(try ChunkCodec.decompress(Self.fixture("plain.vzstd"), expectedSize: 10)) { e in
            guard case SteamError.verificationFailed = e else { return XCTFail("\(e)") }
        }
    }

    func testUnknownChunkContainerIsTyped() {
        XCTAssertThrowsError(try ChunkCodec.decompress([UInt8](repeating: 0x41, count: 64), expectedSize: 64)) { e in
            guard case SteamError.protocolChanged = e else { return XCTFail("\(e)") }
        }
    }

    /// The whole depot-chunk path: Steam's AES scheme, VZstd, Adler-32 and SHA-1.
    func testEncryptedChunkEndToEnd() throws {
        let enc = try Self.fixture("plain.vzstd.enc")
        let key = try AES256Decryptor(key: Array(hexString: Self.meta.chunk_key_hex))
        let plainSHA = Array(hexString: Self.meta.plain_sha1)
        let chunk = ContentManifestPayload.Chunk(sha: plainSHA, crc: Self.meta.plain_adler32_seed0, offset: 0,
                                                 cbOriginal: UInt32(Self.meta.plain_len), cbCompressed: UInt32(enc.count))
        assertPlain(try ContentClient.processChunk(enc, chunk, key: key))

        var wrongKeyBytes = Array(hexString: Self.meta.chunk_key_hex); wrongKeyBytes[0] ^= 1
        XCTAssertThrowsError(try ContentClient.processChunk(enc, chunk, key: AES256Decryptor(key: wrongKeyBytes)))

        var badCRC = chunk; badCRC.crc ^= 1
        XCTAssertThrowsError(try ContentClient.processChunk(enc, badCRC, key: key)) { e in
            guard case SteamError.verificationFailed = e else { return XCTFail("\(e)") }
        }
    }
}

final class CryptoTests: XCTestCase {
    func testSHA1KnownAnswers() {
        XCTAssertEqual(SHA1.hash([]).hex, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA1.hash(Array("abc".utf8)).hex, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).hex,
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    func testCRC32AndSteamAdler() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        // Steam seeds Adler-32 with 0: for "abc" s1 = 294, s2 = 97 + 195 + 294 = 586.
        XCTAssertEqual(SteamAdler32.checksum(Array("abc".utf8)), 586 << 16 | 294)
        XCTAssertEqual(SteamAdler32.checksum(Array("abc".utf8), seed: 1), 0x024D_0127) // standard Adler-32
    }

    /// FIPS-197 appendix C.3 (AES-256).
    func testAES256FIPS197() throws {
        let aes = try AES256Decryptor(key: Array(hexString: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        var block = Array(hexString: "8ea2b7ca516745bfeafc49904b496089")
        aes.decryptBlock(&block)
        XCTAssertEqual(block.hex, "00112233445566778899aabbccddeeff")
    }

    func testBadPaddingIsRejected() throws {
        let aes = try AES256Decryptor(key: [UInt8](repeating: 7, count: 32))
        XCTAssertThrowsError(try aes.decryptCBC([UInt8](repeating: 0, count: 32)[...], iv: [UInt8](repeating: 0, count: 16)))
        XCTAssertThrowsError(try AES256Decryptor(key: [1, 2, 3]))
    }
}

extension Array where Element == UInt8 {
    init(hexString: String) {
        var out: [UInt8] = []
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            out.append(UInt8(hexString[i..<j], radix: 16)!)
            i = j
        }
        self = out
    }
}
