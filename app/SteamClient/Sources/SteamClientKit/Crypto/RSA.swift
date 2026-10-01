// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// RSA public-key encryption with PKCS#1 v1.5 padding (RFC 8017 7.2.1), the
/// one asymmetric primitive Steam's credential sign-in needs: the password
/// goes to `BeginAuthSessionViaCredentials` encrypted with the per-account
/// key `GetPasswordRSAPublicKey` returns, then base64 encoded. Portable Swift
/// (Montgomery exponentiation over 32-bit limbs) so the same code runs on the
/// Linux host and iOS; checked against OpenSSL-made ciphertexts in RSATests.
public struct RSAPublicKey: Sendable, Equatable {
    /// Little-endian 32-bit limbs of the modulus.
    let modulus: [UInt32]
    /// The exponent, big-endian bytes without leading zeros.
    let exponent: [UInt8]
    /// The modulus length in bytes (the ciphertext's length).
    public let byteCount: Int

    /// From the hex strings Steam sends (`publickey_mod`, `publickey_exp`).
    public init(modulusHex: String, exponentHex: String) throws {
        guard let n = Self.bytes(hex: modulusHex), let e = Self.bytes(hex: exponentHex) else {
            throw SteamError.protocolChanged("RSA key is not hex")
        }
        try self.init(modulus: n, exponent: e)
    }

    /// From big-endian modulus and exponent bytes.
    public init(modulus n: [UInt8], exponent e: [UInt8]) throws {
        let n = Array(n.drop { $0 == 0 })
        let e = Array(e.drop { $0 == 0 })
        // 512 bits at least (Steam's keys are 2048), odd, and an exponent above 1.
        guard n.count >= 64, n.count <= 1024, n.last! & 1 == 1 else { throw SteamError.protocolChanged("RSA modulus of \(n.count) bytes") }
        guard !e.isEmpty, e.count <= 8, e != [1] else { throw SteamError.protocolChanged("RSA exponent") }
        byteCount = n.count
        modulus = Self.limbs(n, count: (n.count + 3) / 4)
        exponent = e
    }

    /// PKCS#1 v1.5 type 2: `00 02 PS 00 M` with at least eight random nonzero
    /// bytes of PS, raised to the exponent. The message is at most
    /// `byteCount - 11` bytes.
    public func encryptPKCS1(_ message: [UInt8]) throws -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return try encryptPKCS1(message, using: &rng)
    }

    public func encryptPKCS1<R: RandomNumberGenerator>(_ message: [UInt8], using rng: inout R) throws -> [UInt8] {
        guard message.count <= byteCount - 11 else { throw SteamError.unsupported("message too long for the RSA key") }
        var em = [UInt8](repeating: 0, count: byteCount)
        em[1] = 2
        for i in 2..<(byteCount - message.count - 1) {
            var b: UInt8 = 0
            while b == 0 { b = UInt8.random(in: 1...255, using: &rng) }
            em[i] = b
        }
        em.replaceSubrange((byteCount - message.count)..., with: message)
        return raw(em, power: exponent)
    }

    /// `m^power mod n`, big-endian in and out, `byteCount` bytes out. `m`
    /// must be below the modulus (a padded block always is).
    func raw(_ m: [UInt8], power: [UInt8]) -> [UInt8] {
        let k = modulus.count
        let mont = Montgomery(modulus)
        let x = mont.toMont(Self.limbs(m, count: k))
        var acc = mont.one
        for byte in power {
            for bit in (0..<8).reversed() {
                acc = mont.mul(acc, acc)
                if byte >> bit & 1 == 1 { acc = mont.mul(acc, x) }
            }
        }
        var one = [UInt32](repeating: 0, count: k)
        one[0] = 1
        return Self.bytes(limbs: mont.mul(acc, one), count: byteCount)
    }

    // MARK: conversions

    static func bytes(hex: String) -> [UInt8]? {
        var s = Array(hex.utf8)
        if s.count % 2 == 1 { s.insert(UInt8(ascii: "0"), at: 0) }
        guard !s.isEmpty else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        for i in stride(from: 0, to: s.count, by: 2) {
            guard let hi = nibble(s[i]), let lo = nibble(s[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }

    /// Big-endian bytes to `count` little-endian limbs (higher bytes dropped).
    static func limbs(_ be: [UInt8], count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count)
        for (i, b) in be.reversed().enumerated() where i / 4 < count {
            out[i / 4] |= UInt32(b) << (8 * UInt32(i % 4))
        }
        return out
    }

    static func bytes(limbs: [UInt32], count: Int) -> [UInt8] {
        (0..<count).reversed().map { i in i / 4 < limbs.count ? UInt8(truncatingIfNeeded: limbs[i / 4] >> (8 * UInt32(i % 4))) : 0 }
    }
}

/// Montgomery arithmetic modulo an odd `n` with R = 2^(32k) (CIOS, Koç et al. 1996).
struct Montgomery {
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
