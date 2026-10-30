// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A bounds-checked big-endian reader: every read past the end is a damaged-content error.
struct ByteReader {
    let bytes: [UInt8]
    var pos: Int
    let what: String

    init(_ bytes: [UInt8], at pos: Int = 0, what: String) {
        self.bytes = bytes
        self.pos = pos
        self.what = what
    }

    var remaining: Int { bytes.count - pos }

    func need(_ n: Int) throws {
        guard n >= 0, n <= bytes.count - pos else { throw BattleNetError.damaged("\(what): truncated at byte \(pos) (needs \(n) more)") }
    }

    mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return bytes[pos] }
    mutating func be(_ n: Int) throws -> UInt64 {
        try need(n)
        defer { pos += n }
        return Self.be(bytes, at: pos, n)
    }
    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> { try need(n); defer { pos += n }; return bytes[pos..<(pos + n)] }
    mutating func skip(_ n: Int) throws { try need(n); pos += n }
    /// A NUL-terminated string.
    mutating func cString() throws -> String {
        guard let end = bytes[pos...].firstIndex(of: 0) else { throw BattleNetError.damaged("\(what): unterminated string at byte \(pos)") }
        guard let s = String(validating: bytes[pos..<end], as: UTF8.self) else { throw BattleNetError.damaged("\(what): string at byte \(pos) is not UTF-8") }
        pos = end + 1
        return s
    }

    /// The `n` bytes (at most 8) at `at` as a big-endian number, for formats already checked to
    /// hold them (an index's blocks, a manifest's entries).
    static func be(_ bytes: [UInt8], at: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n { v = v << 8 | UInt64(bytes[at + i]) }
        return v
    }
}
