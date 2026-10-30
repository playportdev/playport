// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f licensing/utils.rs;
// translated to Swift by the Playport authors, 2026-10-30. Modified: bounded
// BCrypt RSA2 parsing; Apple signs with Security.framework. Portable host
// exponentiation adapts Playport's SteamClientKit/Crypto/RSA.swift.
import Foundation
import ContentKit
#if canImport(Security)
import Security
#endif

struct XboxRSA {
    let n: [UInt8], e: [UInt8], p: [UInt8], q: [UInt8], d: [UInt8]
    init(_ blob: [UInt8]) throws {
        guard blob.count >= 24, blob.readLE32(at: 0) == 0x32415352 else { throw Self.invalid() }
        let sizes = [8, 12, 16, 20].map { Int(blob.readLE32(at: $0)) }
        guard sizes[0] > 0, sizes[0] <= 4, sizes[1] >= 128, sizes[1] <= 512,
              sizes[2] == sizes[1] / 2, sizes[3] == sizes[2], sizes.reduce(24, +) <= blob.count else { throw Self.invalid() }
        var off = 24
        func take(_ size: Int) -> [UInt8] { defer { off += size }; return Array(blob[off..<off + size]) }
        e = take(sizes[0]); n = take(sizes[1]); p = take(sizes[2]); q = take(sizes[3])
        let exponent = e.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard exponent >= 3, exponent <= 65537, exponent & 1 == 1, n.last! & 1 == 1,
              p.last! & 1 == 1, q.last! & 1 == 1, p.first! != 0, q.first! != 0 else { throw Self.invalid() }
        let a = Self.minusOne(Self.limbs(p)), b = Self.minusOne(Self.limbs(q))
        let phi = Self.multiply(a, b)
        let rem = Self.divide(phi, by: exponent).1
        var t: Int64 = 0, newT: Int64 = 1, r = Int64(exponent), newR = Int64(rem)
        while newR != 0 { let quot = r / newR; (t, newT) = (newT, t - quot * newT); (r, newR) = (newR, r - quot * newR) }
        guard r == 1 else { throw Self.invalid() }
        let inverse = (t % Int64(exponent) + Int64(exponent)) % Int64(exponent)
        let k = exponent - UInt64(inverse)
        var multiple = Self.multiply(phi, [UInt32(k)])
        var carry: UInt64 = 1
        for i in multiple.indices { let v = UInt64(multiple[i]) + carry; multiple[i] = UInt32(truncatingIfNeeded: v); carry = v >> 32 }
        if carry != 0 { multiple.append(UInt32(carry)) }
        let (quot, remainder) = Self.divide(multiple, by: exponent)
        guard remainder == 0 else { throw Self.invalid() }
        d = Self.bytes(quot, count: n.count)
    }
    static func invalid() -> ClientError { .protocolChanged("Microsoft returned an unsupported device RSA key") }
    func sign(_ message: [UInt8]) throws -> [UInt8] {
        #if canImport(Security)
        // No hand-written private-key operation on the phone. A BCrypt RSA2 key
        // supplies p and q; reconstruct the PKCS#1 key for Apple's hardened RSA.
        let der = privateDER()
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: n.count * 8]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error),
              let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message) as CFData, &error) else { throw Self.invalid() }
        return Array(signature as Data)
        #else
        // Test-host implementation. Phone builds always take the Security path.
        let digestInfo: [UInt8] = [0x30,0x31,0x30,0x0d,0x06,0x09,0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01,0x05,0x00,0x04,0x20]
        let encoded = digestInfo + SHA256Stream.hash(message)
        let em = [UInt8](arrayLiteral: 0, 1) + [UInt8](repeating: 0xff, count: n.count - encoded.count - 3) + [0] + encoded
        return Self.power(em, d, modulus: n)
        #endif
    }
    func privateDER() -> [UInt8] {
        let dp = Self.mod(Self.limbs(d), by: Self.minusOne(Self.limbs(p)))
        let dq = Self.mod(Self.limbs(d), by: Self.minusOne(Self.limbs(q)))
        var pMinus2 = Self.minusOne(Self.minusOne(Self.limbs(p)))
        while pMinus2.last == 0 { pMinus2.removeLast() }
        let qi = Self.power(q, Self.bytes(pMinus2, count: p.count), modulus: p)
        let fields = [[UInt8](arrayLiteral: 0), n, e, d, p, q, Self.bytes(dp, count: p.count), Self.bytes(dq, count: q.count), qi]
        return Self.der(0x30, fields.flatMap { Self.der(0x02, Self.integer($0)) })
    }
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        let b = Array(bytes.drop { $0 == 0 }); return b.isEmpty ? [0] : (b[0] & 0x80 != 0 ? [0] + b : b)
    }
    static func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let length = body.count < 128 ? [UInt8(body.count)] : (body.count < 256 ? [0x81, UInt8(body.count)] : [0x82, UInt8(body.count >> 8), UInt8(body.count & 255)])
        return [tag] + length + body
    }
    static func limbs(_ be: [UInt8], count: Int? = nil) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count ?? ((be.count + 3) / 4))
        for (i,b) in be.reversed().enumerated() where i / 4 < out.count { out[i/4] |= UInt32(b) << (8 * (i%4)) }; return out
    }
    static func bytes(_ limbs: [UInt32], count: Int) -> [UInt8] {
        (0..<count).reversed().map { i in i/4 < limbs.count ? UInt8(truncatingIfNeeded: limbs[i/4] >> (8 * (i%4))) : 0 }
    }
    static func minusOne(_ a: [UInt32]) -> [UInt32] {
        var a = a
        for i in a.indices { let old = a[i]; a[i] &-= 1; if old != 0 { break } }; return a
    }
    static func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: a.count + b.count)
        for i in a.indices {
            var c: UInt64 = 0
            for j in b.indices { let s = UInt64(a[i]) * UInt64(b[j]) + UInt64(out[i+j]) + c; out[i+j] = UInt32(truncatingIfNeeded:s); c = s >> 32 }
            out[i+b.count] = UInt32(c)
        }; return out
    }
    static func divide(_ a: [UInt32], by b: UInt64) -> ([UInt32], UInt64) {
        var out = a, rem: UInt64 = 0
        for i in a.indices.reversed() { let v = (rem << 32) | UInt64(a[i]); out[i] = UInt32(v / b); rem = v % b }; return (out, rem)
    }
    static func mod(_ a: [UInt32], by b: [UInt32]) -> [UInt32] {
        let divisor = b + [0]
        var out = [UInt32](repeating: 0, count: divisor.count)
        for limb in a.reversed() { for bit in (0..<32).reversed() {
            var c = (limb >> bit) & 1
            for i in out.indices { let next = out[i] >> 31; out[i] = (out[i] << 1) | c; c = next }
            if !XboxMontgomery.less(out, divisor) { XboxMontgomery.subtract(&out, divisor) }
        } }; return Array(out.dropLast())
    }
    static func power(_ input: [UInt8], _ exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
        let limbs = Self.limbs(modulus), k = limbs.count, mont = XboxMontgomery(limbs)
        let reduced = Self.mod(Self.limbs(input), by: limbs)
        let x = mont.toMont(reduced)
        var acc = mont.one
        for byte in exponent { for bit in (0..<8).reversed() { acc = mont.mul(acc, acc); if byte >> bit & 1 == 1 { acc = mont.mul(acc, x) } } }
        var one = [UInt32](repeating: 0, count:k); one[0] = 1
        return Self.bytes(mont.mul(acc,one), count:modulus.count)
    }
}

/// Montgomery arithmetic modulo an odd `n` with R = 2^(32k) (CIOS, Koç et al. 1996).
struct XboxMontgomery {
    let n: [UInt32]
    let k: Int
    /// -n^-1 mod 2^32.
    let n0: UInt32
    /// R^2 mod n, and R mod n (1 in Montgomery form).
    let r2: [UInt32]
    let one: [UInt32]

    init(_ n: [UInt32]) {
        self.n = n
        k = n.count
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }   // Newton: n[0]*inv = 1 mod 2^32
        n0 = 0 &- inv
        // R^2 mod n by doubling 1 2*32*k times, reducing as it goes.
        var r = [UInt32](repeating: 0, count: k)
        r[0] = 1
        for _ in 0..<(64 * k) { r = Self.doubleMod(r, n) }
        r2 = r
        var unit = [UInt32](repeating: 0, count: k)
        unit[0] = 1
        one = Self.mulMont(unit, r, n, n0)
    }

    func toMont(_ a: [UInt32]) -> [UInt32] { Self.mulMont(a, r2, n, n0) }
    func mul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] { Self.mulMont(a, b, n, n0) }

    /// 2a mod n for a < n.
    static func doubleMod(_ a: [UInt32], _ n: [UInt32]) -> [UInt32] {
        var r = a
        var carry: UInt32 = 0
        for i in r.indices {
            let v = r[i]
            r[i] = v << 1 | carry
            carry = v >> 31
        }
        if carry == 1 || !less(r, n) { subtract(&r, n) }
        return r
    }

    static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in a.indices.reversed() where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    /// a -= b modulo 2^(32k).
    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in a.indices {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = d >> 63
        }
    }

    /// a * b * R^-1 mod n, for a, b < n.
    static func mulMont(_ a: [UInt32], _ b: [UInt32], _ n: [UInt32], _ n0: UInt32) -> [UInt32] {
        let k = n.count
        var t = [UInt32](repeating: 0, count: k + 2)
        for i in 0..<k {
            var c: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<k {
                let s = UInt64(t[j]) + UInt64(a[j]) * bi + c
                t[j] = UInt32(truncatingIfNeeded: s)
                c = s >> 32
            }
            var s = UInt64(t[k]) + c
            t[k] = UInt32(truncatingIfNeeded: s)
            t[k + 1] = UInt32(truncatingIfNeeded: s >> 32)
            let m = UInt64(t[0] &* n0)
            s = UInt64(t[0]) + m * UInt64(n[0])
            c = s >> 32
            for j in 1..<k {
                s = UInt64(t[j]) + m * UInt64(n[j]) + c
                t[j - 1] = UInt32(truncatingIfNeeded: s)
                c = s >> 32
            }
            s = UInt64(t[k]) + c
            t[k - 1] = UInt32(truncatingIfNeeded: s)
            t[k] = t[k + 1] &+ UInt32(truncatingIfNeeded: s >> 32)
        }
        var r = Array(t[0..<k])
        if t[k] != 0 || !less(r, n) { subtract(&r, n) }
        return r
    }
}
