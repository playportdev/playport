// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Valve KeyValues tree, as PICS returns it: apps as text VDF, packages as
/// binary KeyValues (KeyValue.kt / KVTextReader.kt). Keys compare
/// case-insensitively, as Steam's do. Depth and size are bounded.
public struct KeyValue: Sendable, Equatable {
    public var name: String
    public var value: String?
    public var children: [KeyValue]

    public init(name: String, value: String? = nil, children: [KeyValue] = []) {
        self.name = name; self.value = value; self.children = children
    }

    public subscript(key: String) -> KeyValue? {
        children.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    public func path(_ keys: String...) -> KeyValue? {
        var node: KeyValue? = self
        for k in keys { node = node?[k] }
        return node
    }

    public var uint64: UInt64? { value.flatMap { UInt64($0) } }
    public var uint32: UInt32? { value.flatMap { UInt32($0) } }

    static let maxDepth = 64

    // MARK: text

    public static func parseText(_ bytes: [UInt8]) throws -> KeyValue {
        var p = TextParser(bytes: bytes.prefix { $0 != 0 })
        guard let name = try p.token() else { throw SteamError.protocolChanged("VDF: empty document") }
        guard try p.token() == "{" else { throw SteamError.protocolChanged("VDF: expected '{' after root key") }
        return KeyValue(name: name, children: try p.block(depth: 1))
    }

    struct TextParser {
        let bytes: ArraySlice<UInt8>
        var i: Int
        init(bytes: ArraySlice<UInt8>) { self.bytes = bytes; i = bytes.startIndex }

        /// Next token; "{" and "}" are returned as themselves. Quoted strings
        /// honour \\ \" \n \t escapes. Conditionals ([$WIN32]) are skipped.
        mutating func token() throws -> String? {
            while i < bytes.endIndex {
                let c = bytes[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
                if c == 0x2F, i + 1 < bytes.endIndex, bytes[i + 1] == 0x2F {
                    while i < bytes.endIndex, bytes[i] != 0x0A { i += 1 }
                    continue
                }
                if c == 0x5B { // [condition]
                    while i < bytes.endIndex, bytes[i] != 0x5D { i += 1 }
                    i += 1
                    continue
                }
                if c == 0x7B || c == 0x7D { i += 1; return c == 0x7B ? "{" : "}" }
                var out = [UInt8]()
                if c == 0x22 {
                    i += 1
                    while true {
                        guard i < bytes.endIndex else { throw SteamError.protocolChanged("VDF: unterminated string") }
                        let d = bytes[i]; i += 1
                        if d == 0x22 { break }
                        if d == 0x5C, i < bytes.endIndex {
                            let e = bytes[i]; i += 1
                            switch e {
                            case 0x6E: out.append(0x0A)
                            case 0x74: out.append(0x09)
                            default: out.append(e)
                            }
                            continue
                        }
                        out.append(d)
                    }
                } else {
                    while i < bytes.endIndex {
                        let d = bytes[i]
                        if d == 0x20 || d == 0x09 || d == 0x0A || d == 0x0D || d == 0x7B || d == 0x7D || d == 0x22 { break }
                        out.append(d); i += 1
                    }
                }
                return String(decoding: out, as: UTF8.self)
            }
            return nil
        }

        mutating func block(depth: Int) throws -> [KeyValue] {
            guard depth < KeyValue.maxDepth else { throw SteamError.unsafeContent("VDF nesting deeper than \(KeyValue.maxDepth)") }
            var out: [KeyValue] = []
            while true {
                guard let key = try token() else { throw SteamError.protocolChanged("VDF: unexpected end") }
                if key == "}" { return out }
                guard let next = try token() else { throw SteamError.protocolChanged("VDF: key without value") }
                if next == "{" {
                    out.append(KeyValue(name: key, children: try block(depth: depth + 1)))
                } else {
                    out.append(KeyValue(name: key, value: next))
                }
            }
        }
    }

    // MARK: binary

    public static func parseBinary(_ bytes: ArraySlice<UInt8>) throws -> KeyValue {
        var r = BinaryReader(bytes: bytes)
        let children = try r.block(depth: 0)
        guard children.count == 1 else {
            return KeyValue(name: "", children: children)
        }
        return children[0]
    }

    struct BinaryReader {
        let bytes: ArraySlice<UInt8>
        var i: Int
        init(bytes: ArraySlice<UInt8>) { self.bytes = bytes; i = bytes.startIndex }

        mutating func need(_ n: Int) throws {
            guard bytes.endIndex - i >= n else { throw SteamError.protocolChanged("binary KV: truncated") }
        }
        mutating func cstring() throws -> String {
            let start = i
            while i < bytes.endIndex, bytes[i] != 0 { i += 1 }
            guard i < bytes.endIndex else { throw SteamError.protocolChanged("binary KV: unterminated string") }
            defer { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
        mutating func u32() throws -> UInt32 { try need(4); defer { i += 4 }; return bytes.readLE32(at: i) }
        mutating func u64() throws -> UInt64 { let lo = try u32(); let hi = try u32(); return UInt64(hi) << 32 | UInt64(lo) }

        mutating func block(depth: Int) throws -> [KeyValue] {
            guard depth < KeyValue.maxDepth else { throw SteamError.unsafeContent("binary KV nesting deeper than \(KeyValue.maxDepth)") }
            var out: [KeyValue] = []
            while true {
                try need(1)
                let type = bytes[i]; i += 1
                if type == 8 || type == 11 { return out }
                let name = try cstring()
                switch type {
                case 0: out.append(KeyValue(name: name, children: try block(depth: depth + 1)))
                case 1: out.append(KeyValue(name: name, value: try cstring()))
                case 2: out.append(KeyValue(name: name, value: String(Int32(bitPattern: try u32()))))
                case 3: out.append(KeyValue(name: name, value: String(Float(bitPattern: try u32()))))
                case 4, 6: out.append(KeyValue(name: name, value: String(try u32())))
                case 7: out.append(KeyValue(name: name, value: String(try u64())))
                case 10: out.append(KeyValue(name: name, value: String(Int64(bitPattern: try u64()))))
                default: throw SteamError.protocolChanged("binary KV: unknown type \(type)")
                }
            }
        }
    }
}
