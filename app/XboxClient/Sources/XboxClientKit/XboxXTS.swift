// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/msixvc/src/crypt.rs (the
// per-page tweak and XTS-AES); translated to Swift by the Playport authors,
// 2026-10-30. Modified: table-driven AES-128 in portable Swift (FIPS-197 5.3.5
// equivalent inverse cipher, as ContentKit's AES-256), whole-page transforms only.
import Foundation
import ContentKit

/// An MSIXVC region's XTS-AES-128 (IEEE 1619-2007) over 4 KiB pages. The content
/// key's first 16 bytes encrypt the tweak, the last 16 the data (Xodus's split).
/// A page's tweak is its data unit (from the package's hash entry), the region ID
/// and the first eight bytes of the package's VDUID as Windows lays a GUID out.
struct XboxXTS: Sendable {
    static let page = 4096
    private let tweakCipher: XboxAESTables.Encryptor
    private let dataEncryptor: XboxAESTables.Encryptor
    private let dataDecryptor: XboxAESTables.Decryptor
    private let region: UInt32
    private let vduid: [UInt8]

    init(key: [UInt8], region: UInt32, vduid: UUID) throws {
        guard key.count == 32 else { throw ClientError.verificationFailed("Xbox content key is \(key.count) bytes, expected 32") }
        tweakCipher = XboxAESTables.Encryptor(Array(key[0..<16]))
        dataEncryptor = XboxAESTables.Encryptor(Array(key[16..<32]))
        dataDecryptor = XboxAESTables.Decryptor(Array(key[16..<32]))
        self.region = region
        self.vduid = Array(XboxXTS.guidBytes(vduid)[0..<8])
    }

    /// A GUID as Windows stores it: three little-endian fields, then eight bytes as they are.
    static func guidBytes(_ id: UUID) -> [UInt8] {
        let u = id.uuid
        return [u.3, u.2, u.1, u.0, u.5, u.4, u.7, u.6, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    func tweak(unit: UInt32) -> [UInt8] {
        var t = [UInt8]()
        t.reserveCapacity(16)
        t.appendLE(unit)
        t.appendLE(region)
        t += vduid
        return t
    }

    /// Decrypts (or encrypts) whole pages in place: `bytes.count` is a multiple of
    /// 4096 and `units` holds one data unit per page.
    func decrypt(_ bytes: inout [UInt8], units: ArraySlice<UInt32>) { transform(&bytes, units: units, decrypt: true) }
    func encrypt(_ bytes: inout [UInt8], units: ArraySlice<UInt32>) { transform(&bytes, units: units, decrypt: false) }

    private func transform(_ bytes: inout [UInt8], units: ArraySlice<UInt32>, decrypt: Bool) {
        precondition(bytes.count % Self.page == 0 && bytes.count / Self.page == units.count)
        var t = tweak(unit: 0)
        bytes.withUnsafeMutableBytes { buf in
            for (n, unit) in units.enumerated() {
                t[0] = UInt8(truncatingIfNeeded: unit); t[1] = UInt8(truncatingIfNeeded: unit >> 8)
                t[2] = UInt8(truncatingIfNeeded: unit >> 16); t[3] = UInt8(truncatingIfNeeded: unit >> 24)
                var e = t
                e.withUnsafeMutableBytes { tweakCipher.block($0.baseAddress!) }
                var lo = e.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
                var hi = e.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
                let page = buf.baseAddress! + n * Self.page
                for b in stride(from: 0, to: Self.page, by: 16) {
                    let p = page + b
                    let x0 = UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) ^ lo
                    let x1 = UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) ^ hi
                    p.storeBytes(of: x0.littleEndian, toByteOffset: 0, as: UInt64.self)
                    p.storeBytes(of: x1.littleEndian, toByteOffset: 8, as: UInt64.self)
                    if decrypt { dataDecryptor.block(p) } else { dataEncryptor.block(p) }
                    let y0 = UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) ^ lo
                    let y1 = UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) ^ hi
                    p.storeBytes(of: y0.littleEndian, toByteOffset: 0, as: UInt64.self)
                    p.storeBytes(of: y1.littleEndian, toByteOffset: 8, as: UInt64.self)
                    // Multiply the tweak by x in GF(2^128), x^128 + x^7 + x^2 + x + 1.
                    let carry = hi >> 63
                    hi = (hi << 1) | (lo >> 63)
                    lo = (lo << 1) ^ (0x87 & (0 &- carry))
                }
            }
        }
    }
}

/// AES-128 with 32-bit tables (as OpenSSL's aes_core.c): one block in place.
enum XboxAESTables {
    struct Encryptor: Sendable {
        private let rk: [UInt32]
        init(_ key: [UInt8]) { rk = XboxAESTables.expand(key) }

        func block(_ p: UnsafeMutableRawPointer) {
            rk.withUnsafeBufferPointer { k in
                XboxAESTables.te.withUnsafeBufferPointer { te in
                    let k = k.baseAddress!, te = te.baseAddress!
                    @inline(__always) func t(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
                        te[Int(a >> 24)] ^ te[256 + Int((b >> 16) & 0xFF)] ^ te[512 + Int((c >> 8) & 0xFF)] ^ te[768 + Int(d & 0xFF)]
                    }
                    @inline(__always) func last(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
                        te[1024 + Int(a >> 24)] << 24 | te[1024 + Int((b >> 16) & 0xFF)] << 16
                            | te[1024 + Int((c >> 8) & 0xFF)] << 8 | te[1024 + Int(d & 0xFF)]
                    }
                    var s0 = XboxAESTables.load(p, 0) ^ k[0], s1 = XboxAESTables.load(p, 1) ^ k[1]
                    var s2 = XboxAESTables.load(p, 2) ^ k[2], s3 = XboxAESTables.load(p, 3) ^ k[3]
                    for round in 1..<10 {
                        let r = k + 4 * round
                        let t0 = t(s0, s1, s2, s3) ^ r[0], t1 = t(s1, s2, s3, s0) ^ r[1]
                        let t2 = t(s2, s3, s0, s1) ^ r[2], t3 = t(s3, s0, s1, s2) ^ r[3]
                        s0 = t0; s1 = t1; s2 = t2; s3 = t3
                    }
                    XboxAESTables.store(p, 0, last(s0, s1, s2, s3) ^ k[40]); XboxAESTables.store(p, 1, last(s1, s2, s3, s0) ^ k[41])
                    XboxAESTables.store(p, 2, last(s2, s3, s0, s1) ^ k[42]); XboxAESTables.store(p, 3, last(s3, s0, s1, s2) ^ k[43])
                }
            }
        }
    }

    struct Decryptor: Sendable {
        /// The equivalent inverse cipher's schedule: round keys in decryption order,
        /// the middle nine passed through InvMixColumns.
        private let rk: [UInt32]
        init(_ key: [UInt8]) {
            let w = XboxAESTables.expand(key)
            var d = [UInt32](repeating: 0, count: 44)
            for round in 0...10 {
                for c in 0..<4 {
                    let k = w[(10 - round) * 4 + c]
                    d[round * 4 + c] = round == 0 || round == 10 ? k : XboxAESTables.invMixColumn(k)
                }
            }
            rk = d
        }

        func block(_ p: UnsafeMutableRawPointer) {
            rk.withUnsafeBufferPointer { k in
                XboxAESTables.td.withUnsafeBufferPointer { td in
                    let k = k.baseAddress!, td = td.baseAddress!
                    @inline(__always) func t(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
                        td[Int(a >> 24)] ^ td[256 + Int((b >> 16) & 0xFF)] ^ td[512 + Int((c >> 8) & 0xFF)] ^ td[768 + Int(d & 0xFF)]
                    }
                    @inline(__always) func last(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
                        td[1024 + Int(a >> 24)] << 24 | td[1024 + Int((b >> 16) & 0xFF)] << 16
                            | td[1024 + Int((c >> 8) & 0xFF)] << 8 | td[1024 + Int(d & 0xFF)]
                    }
                    var s0 = XboxAESTables.load(p, 0) ^ k[0], s1 = XboxAESTables.load(p, 1) ^ k[1]
                    var s2 = XboxAESTables.load(p, 2) ^ k[2], s3 = XboxAESTables.load(p, 3) ^ k[3]
                    for round in 1..<10 {
                        let r = k + 4 * round
                        let t0 = t(s0, s3, s2, s1) ^ r[0], t1 = t(s1, s0, s3, s2) ^ r[1]
                        let t2 = t(s2, s1, s0, s3) ^ r[2], t3 = t(s3, s2, s1, s0) ^ r[3]
                        s0 = t0; s1 = t1; s2 = t2; s3 = t3
                    }
                    XboxAESTables.store(p, 0, last(s0, s3, s2, s1) ^ k[40]); XboxAESTables.store(p, 1, last(s1, s0, s3, s2) ^ k[41])
                    XboxAESTables.store(p, 2, last(s2, s1, s0, s3) ^ k[42]); XboxAESTables.store(p, 3, last(s3, s2, s1, s0) ^ k[43])
                }
            }
        }
    }

    @inline(__always) static func load(_ p: UnsafeRawPointer, _ i: Int) -> UInt32 {
        UInt32(bigEndian: p.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
    }
    @inline(__always) static func store(_ p: UnsafeMutableRawPointer, _ i: Int, _ v: UInt32) {
        p.storeBytes(of: v.bigEndian, toByteOffset: 4 * i, as: UInt32.self)
    }

    /// FIPS-197 5.2 for Nk = 4: 44 words.
    static func expand(_ key: [UInt8]) -> [UInt32] {
        precondition(key.count == 16)
        var w = [UInt32](repeating: 0, count: 44)
        for i in 0..<4 { w[i] = UInt32(key[4 * i]) << 24 | UInt32(key[4 * i + 1]) << 16 | UInt32(key[4 * i + 2]) << 8 | UInt32(key[4 * i + 3]) }
        var rcon: UInt8 = 1
        for i in 4..<44 {
            var t = w[i - 1]
            if i % 4 == 0 {
                t = (t << 8 | t >> 24)
                t = UInt32(sBox[Int(t >> 24)]) << 24 | UInt32(sBox[Int((t >> 16) & 0xFF)]) << 16
                    | UInt32(sBox[Int((t >> 8) & 0xFF)]) << 8 | UInt32(sBox[Int(t & 0xFF)])
                t ^= UInt32(rcon) << 24
                rcon = xtime(rcon)
            }
            w[i] = w[i - 4] ^ t
        }
        return w
    }

    /// Te0..Te3 (SubBytes then MixColumns of one byte per row position), then the S-box widened.
    static let te: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 1280)
        for x in 0..<256 {
            let s = sBox[x]
            let w = UInt32(gmul(s, 2)) << 24 | UInt32(s) << 16 | UInt32(s) << 8 | UInt32(gmul(s, 3))
            for r in 0..<4 { t[256 * r + x] = r == 0 ? w : (w >> UInt32(8 * r)) | (w << UInt32(32 - 8 * r)) }
            t[1024 + x] = UInt32(s)
        }
        return t
    }()

    /// Td0..Td3 (InvSubBytes then InvMixColumns), then the inverse S-box widened.
    static let td: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 1280)
        for x in 0..<256 {
            let s = invSBox[x]
            let w = UInt32(gmul(s, 14)) << 24 | UInt32(gmul(s, 9)) << 16 | UInt32(gmul(s, 13)) << 8 | UInt32(gmul(s, 11))
            for r in 0..<4 { t[256 * r + x] = r == 0 ? w : (w >> UInt32(8 * r)) | (w << UInt32(32 - 8 * r)) }
            t[1024 + x] = UInt32(s)
        }
        return t
    }()

    static func invMixColumn(_ w: UInt32) -> UInt32 {
        let a = [UInt8(w >> 24), UInt8(truncatingIfNeeded: w >> 16), UInt8(truncatingIfNeeded: w >> 8), UInt8(truncatingIfNeeded: w)]
        func row(_ m: [UInt8]) -> UInt32 { UInt32(gmul(a[0], m[0]) ^ gmul(a[1], m[1]) ^ gmul(a[2], m[2]) ^ gmul(a[3], m[3])) }
        return row([14, 11, 13, 9]) << 24 | row([9, 14, 11, 13]) << 16 | row([13, 9, 14, 11]) << 8 | row([11, 13, 9, 14])
    }

    static let sBox: [UInt8] = {
        // The multiplicative inverse in GF(2^8) plus the affine map (as ContentKit's AES).
        var box = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            p = p ^ (p << 1) ^ (p & 0x80 != 0 ? 0x1B : 0)
            q ^= q << 1; q ^= q << 2; q ^= q << 4
            if q & 0x80 != 0 { q ^= 0x09 }
            let x = q ^ (q << 1 | q >> 7) ^ (q << 2 | q >> 6) ^ (q << 3 | q >> 5) ^ (q << 4 | q >> 4)
            box[Int(p)] = x ^ 0x63
        } while p != 1
        box[0] = 0x63
        return box
    }()
    static let invSBox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { inv[Int(sBox[i])] = UInt8(i) }
        return inv
    }()

    static func gmul(_ x: UInt8, _ m: UInt8) -> UInt8 {
        var a = x, b = m, p: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { p ^= a }
            a = xtime(a); b >>= 1
        }
        return p
    }

    static func xtime(_ b: UInt8) -> UInt8 { (b << 1) ^ (b & 0x80 != 0 ? 0x1B : 0) }
}
