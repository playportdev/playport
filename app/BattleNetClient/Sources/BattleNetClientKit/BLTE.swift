// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// Decryption keys for BLTE's encrypted blocks, by their 64-bit lookup (the key name read as a
/// little-endian integer, written as 16 hex digits in key lists). The installer itself needs
/// none (no manifest is encrypted); content that is gets decoded only with a known key.
public struct TACTKeyring: Sendable, Equatable {
    public private(set) var keys: [UInt64: [UInt8]]

    public init(keys: [UInt64: [UInt8]] = [:]) { self.keys = keys }

    /// A key list: lines of `LOOKUP KEY` (16 and 32 hex digits; more columns are ignored).
    public init(list bytes: [UInt8]) throws {
        guard let text = String(validating: bytes, as: UTF8.self) else { throw BattleNetError.damaged("key list: not UTF-8") }
        var keys = [UInt64: [UInt8]]()
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if f.isEmpty || f[0].hasPrefix("#") { continue }
            guard f.count >= 2, f[0].count == 16, let lookup = UInt64(f[0], radix: 16), let key = TACTHash(hex: f[1]) else {
                throw BattleNetError.damaged("key list: line '\(line.prefix(60))'")
            }
            keys[lookup] = key.bytes
        }
        self.keys = keys
    }

    /// A version row's key ring config: `key-<name> = <key>`, the name in the bytes' own order.
    public init(keyRingConfig bytes: [UInt8]) throws {
        let config = try TACTConfig(bytes, what: "key ring")
        var keys = [UInt64: [UInt8]]()
        for (name, value) in config.values where name.hasPrefix("key-") {
            let hex = name.dropFirst(4)
            guard hex.count == 16, let n = UInt64(hex, radix: 16), let first = value.first, let key = TACTHash(hex: first) else {
                throw BattleNetError.damaged("key ring: entry '\(name.prefix(40))'")
            }
            keys[n.byteSwapped] = key.bytes
        }
        self.keys = keys
    }

    public func merging(_ other: TACTKeyring) -> TACTKeyring {
        TACTKeyring(keys: keys.merging(other.keys) { _, new in new })
    }

    public subscript(_ lookup: UInt64) -> [UInt8]? { keys[lookup] }

    /// The lookup as key lists write it.
    public static func name(_ lookup: UInt64) -> String { String(format: "%016llX", lookup) }
}

/// BLTE, the encoding every CDN data object is in: a header with a block table (each block's
/// encoded and decoded size and the MD5 of its encoded bytes), then blocks of raw (`N`), zlib
/// (`Z`) or encrypted (`E`, Salsa20) data. The EKey is the MD5 of the header (of the whole object
/// when it has no block table), so an object is checked before anything is decoded.
public enum BLTE {
    /// The largest decoded object accepted (the largest manifest, retail's encoding table, is
    /// under 200 MB).
    public static let maxDecoded = 1 << 30

    public struct Block: Sendable, Equatable {
        public let encodedSize: Int
        public let decodedSize: Int
        public let md5: [UInt8]?
    }

    /// Checks `bytes` against its EKey (when given) and every block's MD5, without decoding.
    public static func verify(_ bytes: [UInt8], ekey: TACTHash?) throws {
        _ = try layout(bytes, ekey: ekey)
    }

    /// Decodes an object, checking its EKey (when given), every block's MD5 and size, and the
    /// decoded bytes' MD5 against `ckey` (when given).
    public static func decode(_ bytes: [UInt8], ekey: TACTHash? = nil, ckey: TACTHash? = nil,
                              keys: TACTKeyring = TACTKeyring()) throws -> [UInt8] {
        let (start, blocks) = try layout(bytes, ekey: ekey)
        var out = [UInt8]()
        out.reserveCapacity(blocks.reduce(0) { $0 + $1.decodedSize })
        var at = start
        for (i, b) in blocks.enumerated() {
            let block = bytes[at..<(at + b.encodedSize)]
            let plain = try decodeBlock(block, index: i, keys: keys, expected: b.md5 == nil ? nil : b.decodedSize)
            out.append(contentsOf: plain)
            at += b.encodedSize
        }
        if let ckey, MD5.hash(out) != ckey.bytes {
            throw BattleNetError.damaged("BLTE \(ekey?.hex ?? "object"): decoded bytes do not hash to \(ckey.hex)")
        }
        return out
    }

    /// The data start and the block table, after the magic, header, EKey and block checks.
    static func layout(_ bytes: [UInt8], ekey: TACTHash?) throws -> (Int, [Block]) {
        let what = "BLTE \(ekey?.hex ?? "object")"
        var r = ByteReader(bytes, what: what)
        guard try r.take(4).elementsEqual("BLTE".utf8) else { throw BattleNetError.damaged("\(what): no BLTE magic") }
        let headerSize = Int(try r.be(4))
        if headerSize == 0 {
            if let ekey, MD5.hash(bytes) != ekey.bytes { throw BattleNetError.damaged("\(what): does not hash to its EKey") }
            guard r.remaining > 0 else { throw BattleNetError.damaged("\(what): empty") }
            return (8, [Block(encodedSize: r.remaining, decodedSize: 0, md5: nil)])
        }
        guard headerSize >= 12, headerSize <= bytes.count else { throw BattleNetError.damaged("\(what): header size \(headerSize)") }
        if let ekey, MD5.hash(Array(bytes[0..<headerSize])) != ekey.bytes {
            throw BattleNetError.damaged("\(what): header does not hash to its EKey")
        }
        let format = try r.u8()
        guard format == 0x0F else { throw BattleNetError.unsupported("\(what): block table format \(format)") }
        let count = Int(try r.be(3))
        guard count > 0, 12 + count * 24 == headerSize else {
            throw BattleNetError.damaged("\(what): \(count) blocks in a \(headerSize)-byte header")
        }
        var blocks = [Block]()
        blocks.reserveCapacity(count)
        var encoded = 0, decoded = 0
        for _ in 0..<count {
            let e = Int(try r.be(4)), d = Int(try r.be(4))
            let md5 = Array(try r.take(16))
            guard e > 0 else { throw BattleNetError.damaged("\(what): an empty block") }
            encoded += e
            decoded += d
            guard decoded <= maxDecoded else { throw BattleNetError.damaged("\(what): decodes to more than \(maxDecoded) bytes") }
            blocks.append(Block(encodedSize: e, decodedSize: d, md5: md5))
        }
        guard encoded == bytes.count - headerSize else {
            throw BattleNetError.damaged("\(what): blocks need \(encoded) bytes, \(bytes.count - headerSize) follow the header")
        }
        var at = headerSize
        for (i, b) in blocks.enumerated() {
            guard MD5.hash(Array(bytes[at..<(at + b.encodedSize)])) == b.md5 else {
                throw BattleNetError.damaged("\(what): block \(i) does not match its MD5")
            }
            at += b.encodedSize
        }
        return (headerSize, blocks)
    }

    /// One block: its mode byte, then the data. `expected` is the table's decoded size.
    static func decodeBlock(_ block: ArraySlice<UInt8>, index: Int, keys: TACTKeyring, expected: Int?,
                            nested: Bool = false) throws -> [UInt8] {
        let what = "BLTE block \(index)"
        guard let mode = block.first else { throw BattleNetError.damaged("\(what): empty") }
        let data = block.dropFirst()
        let out: [UInt8]
        switch mode {
        case UInt8(ascii: "N"):
            out = Array(data)
        case UInt8(ascii: "Z"):
            do {
                out = try Zlib.decompress(Array(data), limit: expected ?? maxDecoded)
            } catch {
                throw BattleNetError.damaged("\(what): zlib: \(error)")
            }
        case UInt8(ascii: "E") where !nested:
            let plain = try decrypt(data, index: index, keys: keys)
            out = try decodeBlock(plain[...], index: index, keys: keys, expected: expected, nested: true)
        case UInt8(ascii: "4"), UInt8(ascii: "F"), UInt8(ascii: "E"):
            throw BattleNetError.unsupported("\(what): mode '\(Character(Unicode.Scalar(mode)))'")
        default:
            throw BattleNetError.damaged("\(what): unknown mode 0x\(String(mode, radix: 16))")
        }
        if let expected, out.count != expected {
            throw BattleNetError.damaged("\(what): decodes to \(out.count) bytes, the table says \(expected)")
        }
        return out
    }

    /// An `E` block: key name, IV and cipher, then the ciphertext of an inner block.
    static func decrypt(_ data: ArraySlice<UInt8>, index: Int, keys: TACTKeyring) throws -> [UInt8] {
        var r = ByteReader(Array(data), what: "BLTE block \(index) (encrypted)")
        let nameLength = Int(try r.u8())
        guard nameLength == 8 else { throw BattleNetError.damaged("\(r.what): key name of \(nameLength) bytes") }
        let lookup = try r.take(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        let ivLength = Int(try r.u8())
        guard ivLength == 4 || ivLength == 8 else { throw BattleNetError.damaged("\(r.what): IV of \(ivLength) bytes") }
        var iv = Array(try r.take(ivLength)) + [UInt8](repeating: 0, count: 8 - ivLength)
        let cipher = try r.u8()
        guard cipher == UInt8(ascii: "S") else {
            throw BattleNetError.unsupported("\(r.what): cipher '\(Character(Unicode.Scalar(cipher)))'")
        }
        guard let key = keys[lookup] else { throw BattleNetError.missingKey(TACTKeyring.name(lookup)) }
        for i in 0..<4 { iv[i] ^= UInt8(truncatingIfNeeded: index >> (8 * i)) }
        return Salsa20.xor(Array(r.bytes[r.pos...]), key: key, nonce: iv)
    }
}

/// Salsa20/20 with a 16-byte key (the "expand 16-byte k" constants), the counter from 0.
enum Salsa20 {
    static func xor(_ input: [UInt8], key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        precondition(key.count == 16 && nonce.count == 8)
        func word(_ b: [UInt8], _ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        let k = (0..<4).map { word(key, $0 * 4) }
        let n = (word(nonce, 0), word(nonce, 4))
        let tau: [UInt32] = [0x6170_7865, 0x3120_646E, 0x7962_2D36, 0x6B20_6574]
        var out = input
        var counter: UInt64 = 0
        var at = 0
        var state = [UInt32](repeating: 0, count: 16)
        var x = state
        while at < out.count {
            state = [tau[0], k[0], k[1], k[2], k[3], tau[1], n.0, n.1,
                     UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32), tau[2],
                     k[0], k[1], k[2], k[3], tau[3]]
            x = state
            @inline(__always) func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
                x[b] ^= (x[a] &+ x[d]).rotl(7)
                x[c] ^= (x[b] &+ x[a]).rotl(9)
                x[d] ^= (x[c] &+ x[b]).rotl(13)
                x[a] ^= (x[d] &+ x[c]).rotl(18)
            }
            for _ in 0..<10 {
                qr(0, 4, 8, 12); qr(5, 9, 13, 1); qr(10, 14, 2, 6); qr(15, 3, 7, 11)
                qr(0, 1, 2, 3); qr(5, 6, 7, 4); qr(10, 11, 8, 9); qr(15, 12, 13, 14)
            }
            for i in 0..<16 {
                let w = x[i] &+ state[i]
                for j in 0..<4 where at + i * 4 + j < out.count {
                    out[at + i * 4 + j] ^= UInt8(truncatingIfNeeded: w >> (8 * UInt32(j)))
                }
            }
            at += 64
            counter += 1
        }
        return out
    }
}

private extension UInt32 {
    @inline(__always) func rotl(_ n: UInt32) -> UInt32 { self << n | self >> (32 - n) }
}
