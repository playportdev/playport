// SPDX-License-Identifier: GPL-3.0-or-later

/// Bob Jenkins' lookup3 hashes (`hashlittle`, `hashlittle2`), which the local store's headers
/// and `.idx` journals are checked with. Bytes are read little-endian, as on the platforms the
/// store is written on.
enum Lookup3 {
    /// `hashlittle(key, initval)`.
    static func hashlittle(_ key: ArraySlice<UInt8>, _ initval: UInt32) -> UInt32 {
        hashlittle2(key, pc: initval, pb: 0).c
    }

    /// `hashlittle2(key, &pc, &pb)`: two 32-bit hashes, `c` the better one.
    static func hashlittle2(_ key: ArraySlice<UInt8>, pc: UInt32, pb: UInt32) -> (c: UInt32, b: UInt32) {
        var a = 0xDEAD_BEEF &+ UInt32(truncatingIfNeeded: key.count) &+ pc
        var b = a
        var c = a &+ pb
        var at = key.startIndex
        var length = key.count
        @inline(__always) func word(_ i: Int) -> UInt32 {
            UInt32(key[i]) | UInt32(key[i + 1]) << 8 | UInt32(key[i + 2]) << 16 | UInt32(key[i + 3]) << 24
        }
        while length > 12 {
            a = a &+ word(at)
            b = b &+ word(at + 4)
            c = c &+ word(at + 8)
            mix(&a, &b, &c)
            length -= 12
            at += 12
        }
        if length == 0 { return (c, b) }
        for j in 0..<length {
            let v = UInt32(key[at + j]) << (8 * UInt32(j & 3))
            switch j >> 2 {
            case 0: a = a &+ v
            case 1: b = b &+ v
            default: c = c &+ v
            }
        }
        final(&a, &b, &c)
        return (c, b)
    }

    @inline(__always) static func rot(_ x: UInt32, _ k: UInt32) -> UInt32 { x << k | x >> (32 - k) }

    @inline(__always) static func mix(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32) {
        a = a &- c; a ^= rot(c, 4); c = c &+ b
        b = b &- a; b ^= rot(a, 6); a = a &+ c
        c = c &- b; c ^= rot(b, 8); b = b &+ a
        a = a &- c; a ^= rot(c, 16); c = c &+ b
        b = b &- a; b ^= rot(a, 19); a = a &+ c
        c = c &- b; c ^= rot(b, 4); b = b &+ a
    }

    @inline(__always) static func final(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32) {
        c ^= b; c = c &- rot(b, 14)
        a ^= c; a = a &- rot(c, 11)
        b ^= a; b = b &- rot(a, 25)
        c ^= b; c = c &- rot(b, 16)
        a ^= c; a = a &- rot(c, 4)
        b ^= a; b = b &- rot(a, 14)
        c ^= b; c = c &- rot(b, 24)
    }
}
