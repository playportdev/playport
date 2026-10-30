// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f, api/live/utils.rs and
// licensing/splicense.rs; translated to Swift by the Playport authors, 2026-10-30.
// Modified: checked lengths and versions, portable AES-128 for CLEP state.
import Foundation
import ContentKit

internal enum XboxCrypto {
    static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
    static func decode(_ value: String) throws -> [UInt8] {
        let s = value.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: s) else { throw ClientError.protocolChanged("Microsoft returned invalid base64") }
        return Array(data)
    }
    static func random(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }
    static func hmac(_ key: [UInt8], _ value: [UInt8]) -> [UInt8] {
        let k = key.count > 64 ? SHA256Stream.hash(key) : key
        let padded = k + [UInt8](repeating: 0, count: 64 - k.count)
        return SHA256Stream.hash(padded.map { $0 ^ 0x5c } + SHA256Stream.hash(padded.map { $0 ^ 0x36 } + value))
    }
    static func derived(_ key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        // SP800-108 counter mode, L=256; no TPM second derivation (Xodus omits TPMInfo).
        hmac(key, [0, 0, 0, 1] + Array("WS-SecureConversationWS-SecureConversation".utf8) + [0] + nonce + [0, 0, 1, 0])
    }
    static func clep(_ data: [UInt8], keyBytes: Int) throws -> [UInt8] {
        guard data.count == 4096, data.readLE32(at: 0) == 4, keyBytes == 48 || keyBytes == 544 else {
            throw ClientError.protocolChanged("Microsoft returned an unsupported CLEP state")
        }
        let off = 4 + keyBytes
        return try XboxAES128(scheduleKey(data, at: off)).cbc(Array(data[4..<off]))
    }
    /// The AES-128 key hidden in a CLEP key schedule of 58 little-endian words at `off`.
    static func scheduleKey(_ data: [UInt8], at off: Int) -> [UInt8] {
        let w = (0..<58).map { data.readLE32(at: off + 4 * $0) }
        return [w[46] ^ w[56] ^ 0xE20DF371 ^ 0xCCB22FE6, w[36] ^ w[47] ^ 0xDF080E39,
                w[40] ^ w[51] ^ 0x6D09B2F5 ^ 0x2AE17AB9, w[30] ^ w[41] ^ 0x37288CEC]
            .flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    }
    static func privateKey(_ license: String) throws -> [UInt8] {
        let bytes = try decode(license)
        guard bytes.count >= 8 else { throw ClientError.protocolChanged("Microsoft returned a short device licence") }
        var off = 8
        while off < bytes.count {
            guard bytes.count - off >= 8 else { throw ClientError.protocolChanged("Microsoft returned a truncated device licence") }
            let tag = bytes.readLE32(at: off), length = Int(bytes.readLE32(at: off + 4)); off += 8
            guard length <= bytes.count - off else { throw ClientError.protocolChanged("Microsoft returned an invalid device licence block") }
            if tag == 0x12d { return try clep(Array(bytes[off..<off + length]), keyBytes: 544) }
            off += length
        }
        throw ClientError.protocolChanged("Device licence has no signing key")
    }
}

/// AES-128 inverse cipher (FIPS-197); small control-plane blobs only, no tables
/// indexed by ciphertext beyond the inverse S-box. CLEP CBC has no padding.
struct XboxAES128 {
    let keys: [UInt8]
    init(_ key: [UInt8]) throws {
        guard key.count == 16 else { throw ClientError.protocolChanged("Xbox AES key length") }
        var keys = key, rc: UInt8 = 1
        while keys.count < 176 {
            var t = Array(keys.suffix(4))
            if keys.count % 16 == 0 {
                t = [Self.sbox[Int(t[1])] ^ rc, Self.sbox[Int(t[2])], Self.sbox[Int(t[3])], Self.sbox[Int(t[0])]]
                rc = Self.mul(rc, 2)
            }
            for byte in t { keys.append(keys[keys.count - 16] ^ byte) }
        }
        self.keys = keys
    }
    func block(_ input: [UInt8]) -> [UInt8] {
        var s = input
        func add(_ round: Int) { for i in 0..<16 { s[i] ^= keys[16 * round + i] } }
        add(10)
        for r in (0..<10).reversed() {
            let old = s
            for row in 0..<4 { for col in 0..<4 { s[4 * col + row] = Self.inv[Int(old[4 * ((col - row + 4) % 4) + row])] } }
            add(r)
            if r != 0 {
                for c in 0..<4 {
                    let a = Array(s[(4 * c)..<(4 * c + 4)])
                    for i in 0..<4 {
                        s[4 * c + i] = Self.mul(a[i], 14) ^ Self.mul(a[(i + 1) % 4], 11) ^ Self.mul(a[(i + 2) % 4], 13) ^ Self.mul(a[(i + 3) % 4], 9)
                    }
                }
            }
        }
        return s
    }
    func cbc(_ input: [UInt8]) throws -> [UInt8] {
        guard !input.isEmpty, input.count % 16 == 0 else { throw ClientError.protocolChanged("Xbox AES block length") }
        var out = [UInt8](); out.reserveCapacity(input.count)
        var iv = [UInt8](repeating: 0, count: 16)
        for off in stride(from: 0, to: input.count, by: 16) {
            let cipher = Array(input[off..<off + 16])
            out += zip(block(cipher), iv).map { $0 ^ $1 }; iv = cipher
        }
        return out
    }
    static func mul(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var a = x, b = y, p: UInt8 = 0
        while b != 0 { if b & 1 != 0 { p ^= a }; a = (a << 1) ^ (a & 0x80 != 0 ? 0x1b : 0); b >>= 1 }
        return p
    }
    static let sbox: [UInt8] = (0..<256).map { i in
        let x = UInt8(i)
        var inv: UInt8 = 1
        if x == 0 { inv = 0 } else { for _ in 0..<254 { inv = mul(inv, x) } }
        func rot(_ n: Int) -> UInt8 { (inv << n) | (inv >> (8 - n)) }
        return inv ^ rot(1) ^ rot(2) ^ rot(3) ^ rot(4) ^ 0x63
    }
    static let inv: [UInt8] = { var b = [UInt8](repeating: 0, count: 256); for (i, v) in sbox.enumerated() { b[Int(v)] = UInt8(i) }; return b }()
}
