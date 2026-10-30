// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// SHA-512 and SHA-384 (FIPS 180-4), streaming, portable Swift: MSIXVC2 names its
/// hashes by algorithm and may use either (ContentKit has SHA-1 and SHA-256 only).
struct SHA512Stream: Sendable {
    private var h: [UInt64]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0
    private let outputBytes: Int

    static func sha512() -> SHA512Stream {
        SHA512Stream(h: [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                       0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179], outputBytes: 64)
    }
    static func sha384() -> SHA512Stream {
        SHA512Stream(h: [0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
                       0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4], outputBytes: 48)
    }
    private init(h: [UInt64], outputBytes: Int) { self.h = h; self.outputBytes = outputBytes; pending.reserveCapacity(128) }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        length &+= UInt64(data.count)
        var i = 0
        if !pending.isEmpty {
            let take = min(128 - pending.count, data.count)
            pending += data[0..<take]
            i = take
            if pending.count == 128 { pending.withUnsafeBytes { block($0.baseAddress!) }; pending.removeAll(keepingCapacity: true) }
        }
        while data.count - i >= 128 { block(data.baseAddress! + i); i += 128 }
        if i < data.count { pending += data[i..<data.count] }
    }
    mutating func update(_ data: [UInt8]) { data.withUnsafeBytes { update($0) } }

    func finalize() -> [UInt8] {
        var copy = self
        // 0x80, zeros to 112 mod 128, then the length in bits as 128-bit big-endian.
        var tail = [UInt8(0x80)] + [UInt8](repeating: 0, count: (pending.count < 112 ? 111 : 239) - pending.count)
        let high = length >> 61, bits = length << 3
        for v in [high, bits] { tail += (0..<8).map { UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * $0)) } }
        let p = copy.pending + tail
        p.withUnsafeBytes { b in
            var o = 0
            while o < b.count { copy.block(b.baseAddress! + o); o += 128 }
        }
        return Array(copy.h.flatMap { v in (0..<8).map { UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * $0)) } }.prefix(outputBytes))
    }

    static func hash512(_ data: [UInt8]) -> [UInt8] { var s = sha512(); s.update(data); return s.finalize() }
    static func hash384(_ data: [UInt8]) -> [UInt8] { var s = sha384(); s.update(data); return s.finalize() }

    private mutating func block(_ p: UnsafeRawPointer) {
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 80) { w in
            Self.k.withUnsafeBufferPointer { k in
                for t in 0..<16 { w[t] = UInt64(bigEndian: p.loadUnaligned(fromByteOffset: 8 * t, as: UInt64.self)) }
                for t in 16..<80 {
                    let s0 = w[t - 15].rotr(1) ^ w[t - 15].rotr(8) ^ (w[t - 15] >> 7)
                    let s1 = w[t - 2].rotr(19) ^ w[t - 2].rotr(61) ^ (w[t - 2] >> 6)
                    w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                }
                for t in 0..<80 {
                    let t1 = hh &+ (e.rotr(14) ^ e.rotr(18) ^ e.rotr(41)) &+ ((e & f) ^ (~e & g)) &+ k[t] &+ w[t]
                    let t2 = (a.rotr(28) ^ a.rotr(34) ^ a.rotr(39)) &+ ((a & b) ^ (a & c) ^ (b & c))
                    hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
                }
            }
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    private static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019,
        0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3,
        0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65, 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b, 0xa2bfe8a14cf10364, 0xa81a664bbc423001,
        0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb,
        0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c, 0xd186b8c721c0c207,
        0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a,
        0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]
}

extension UInt64 {
    fileprivate func rotr(_ n: UInt64) -> UInt64 { (self >> n) | (self << (64 - n)) }
}
