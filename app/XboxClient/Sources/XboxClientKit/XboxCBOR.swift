// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// A CBOR (RFC 8949) data item: what MSIXVC2's metadata is written in.
indirect enum XboxCBOR: Equatable {
    case unsigned(UInt64)
    /// A negative integer: -1 - n.
    case negative(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([XboxCBOR])
    /// Key/value pairs in the order written.
    case map([(XboxCBOR, XboxCBOR)])
    case tag(UInt64, XboxCBOR)
    case bool(Bool)
    case null
    case undefined
    case float(Double)

    static func == (a: XboxCBOR, b: XboxCBOR) -> Bool {
        switch (a, b) {
        case let (.unsigned(x), .unsigned(y)), let (.negative(x), .negative(y)): x == y
        case let (.bytes(x), .bytes(y)): x == y
        case let (.text(x), .text(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.map(x), .map(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.tag(t, x), .tag(u, y)): t == u && x == y
        case let (.bool(x), .bool(y)): x == y
        case (.null, .null), (.undefined, .undefined): true
        case let (.float(x), .float(y)): x == y
        default: false
        }
    }

    /// Decodes exactly one item filling `bytes`. Definite lengths only (MSIXVC2's
    /// writer uses no others); nesting, item counts and string lengths are bounded
    /// by the input, so damaged metadata throws and never traps or balloons.
    static func decode(_ bytes: [UInt8], what: String) throws -> XboxCBOR {
        var r = Reader(b: bytes, what: what)
        let v = try r.item(depth: 0)
        guard r.at == bytes.count else { throw r.bad("has \(bytes.count - r.at) bytes after its end") }
        return v
    }

    struct Reader {
        let b: [UInt8]
        let what: String
        var at = 0
        static let maxDepth = 48

        func bad(_ why: String) -> ClientError { XboxXVD.damaged("its \(what) \(why)") }

        mutating func byte() throws -> UInt8 {
            guard at < b.count else { throw bad("is cut short") }
            defer { at += 1 }
            return b[at]
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24...27:
                let n = 1 << Int(info - 24)
                guard b.count - at >= n else { throw bad("is cut short") }
                var v: UInt64 = 0
                for i in 0..<n { v = v << 8 | UInt64(b[at + i]) }
                at += n
                return v
            default: throw bad("uses an indefinite or reserved length")
            }
        }

        /// A length that fits in what is left of the input (each element takes at least one byte).
        mutating func count(_ info: UInt8, per: Int) throws -> Int {
            let n = try argument(info)
            guard n <= UInt64(b.count - at) / UInt64(per) else { throw bad("declares \(n) items past its end") }
            return Int(n)
        }

        mutating func item(depth: Int) throws -> XboxCBOR {
            guard depth < Self.maxDepth else { throw bad("nests too deeply") }
            let initial = try byte()
            let major = initial >> 5, info = initial & 0x1F
            switch major {
            case 0: return .unsigned(try argument(info))
            case 1: return .negative(try argument(info))
            case 2:
                let n = try count(info, per: 1)
                defer { at += n }
                return .bytes(Array(b[at..<(at + n)]))
            case 3:
                let n = try count(info, per: 1)
                guard let s = String(validating: b[at..<(at + n)], as: UTF8.self) else { throw bad("has a string that is not UTF-8") }
                at += n
                return .text(s)
            case 4:
                let n = try count(info, per: 1)
                var out: [XboxCBOR] = []
                out.reserveCapacity(n)
                for _ in 0..<n { out.append(try item(depth: depth + 1)) }
                return .array(out)
            case 5:
                let n = try count(info, per: 2)
                var out: [(XboxCBOR, XboxCBOR)] = []
                out.reserveCapacity(n)
                for _ in 0..<n { out.append((try item(depth: depth + 1), try item(depth: depth + 1))) }
                return .map(out)
            case 6:
                let t = try argument(info)
                return .tag(t, try item(depth: depth + 1))
            default:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                case 23: return .undefined
                case 25:
                    // RFC 8949 appendix D, without Float16 (unavailable on Intel macOS).
                    let h = Int(try argument(25)), exp = (h >> 10) & 0x1F, mant = Double(h & 0x3FF)
                    let v = exp == 0 ? mant * pow(2, -24) : exp != 31 ? (mant + 1024) * pow(2, Double(exp - 25)) : mant == 0 ? .infinity : .nan
                    return .float(h & 0x8000 != 0 ? -v : v)
                case 26: return .float(Double(Float(bitPattern: UInt32(try argument(26)))))
                case 27: return .float(Double(bitPattern: try argument(27)))
                default: throw bad("has a simple value \(info) it shouldn't")
                }
            }
        }
    }
}

/// Typed reads of MSIXVC2's maps: integer labels, values of one expected kind.
extension XboxCBOR {
    /// Self-describe (55799), then the item's own tag.
    func tagged(_ tag: UInt64, what: String) throws -> XboxCBOR {
        guard case let .tag(55799, inner) = self, case let .tag(t, body) = inner, t == tag else {
            throw XboxXVD.damaged("its \(what) is not tagged as one")
        }
        return body
    }

    func fields(_ what: String) throws -> XboxFields {
        guard case let .map(pairs) = self else { throw XboxXVD.damaged("its \(what) is not a map") }
        var out: [UInt64: XboxCBOR] = [:]
        for (k, v) in pairs {
            guard case let .unsigned(label) = k else { throw XboxXVD.damaged("its \(what) has a key that is not a label") }
            guard out.updateValue(v, forKey: label) == nil else { throw XboxXVD.damaged("its \(what) has label \(label) twice") }
        }
        return XboxFields(values: out, what: what)
    }

    func list(_ what: String) throws -> [XboxCBOR] {
        guard case let .array(items) = self else { throw XboxXVD.damaged("its \(what) is not a list") }
        return items
    }
}

struct XboxFields {
    let values: [UInt64: XboxCBOR]
    let what: String

    func bad(_ label: UInt64, _ why: String) -> ClientError { XboxXVD.damaged("its \(what) field \(label) \(why)") }
    subscript(_ label: UInt64) -> XboxCBOR? { values[label] }
    func required(_ label: UInt64) throws -> XboxCBOR {
        guard let v = values[label] else { throw bad(label, "is missing") }
        return v
    }

    func uint(_ label: UInt64, max: UInt64 = .max) throws -> UInt64? {
        guard let v = values[label] else { return nil }
        guard case let .unsigned(n) = v, n <= max else { throw bad(label, "is not a number up to \(max)") }
        return n
    }
    func int(_ label: UInt64, max: Int = Int(Int32.max)) throws -> Int? { try uint(label, max: UInt64(max)).map(Int.init) }
    func bool(_ label: UInt64) throws -> Bool? {
        guard let v = values[label] else { return nil }
        guard case let .bool(b) = v else { throw bad(label, "is not a boolean") }
        return b
    }
    func bytes(_ label: UInt64) throws -> [UInt8]? {
        guard let v = values[label] else { return nil }
        guard case let .bytes(b) = v else { throw bad(label, "is not bytes") }
        return b
    }
    func text(_ label: UInt64) throws -> String? {
        guard let v = values[label] else { return nil }
        guard case let .text(s) = v else { throw bad(label, "is not text") }
        return s
    }
    /// A GUID written as text (`Guid.ToString()`).
    func guid(_ label: UInt64) throws -> UUID? {
        guard let s = try text(label) else { return nil }
        guard let id = UUID(uuidString: s) else { throw bad(label, "is not a GUID") }
        return id
    }
}
