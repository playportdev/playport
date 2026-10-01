// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Minimal protobuf wire codec. The client does not generate code from .proto
/// files; each message in Schemas.swift names its field numbers explicitly and
/// reads them through `ProtoFields`, whose accessors reject a wrong wire type
/// with `SteamError.protocolChanged` instead of guessing.
public struct ProtoWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func tag(_ field: Int, _ wireType: UInt64) { varint(UInt64(field) << 3 | wireType) }

    public mutating func uint64(_ field: Int, _ v: UInt64?) { guard let v else { return }; tag(field, 0); varint(v) }
    public mutating func uint32(_ field: Int, _ v: UInt32?) { uint64(field, v.map(UInt64.init)) }
    /// int32 negatives are sign-extended to ten bytes, as protobuf requires.
    public mutating func int32(_ field: Int, _ v: Int32?) { uint64(field, v.map { UInt64(bitPattern: Int64($0)) }) }
    public mutating func bool(_ field: Int, _ v: Bool?) { uint64(field, v.map { $0 ? 1 : 0 }) }
    public mutating func fixed64(_ field: Int, _ v: UInt64?) {
        guard let v else { return }
        tag(field, 1)
        withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
    }
    public mutating func fixed32(_ field: Int, _ v: UInt32?) {
        guard let v else { return }
        tag(field, 5)
        withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
    }
    public mutating func bytes(_ field: Int, _ v: [UInt8]?) {
        guard let v else { return }
        tag(field, 2); varint(UInt64(v.count)); bytes.append(contentsOf: v)
    }
    public mutating func string(_ field: Int, _ v: String?) { bytes(field, v.map { Array($0.utf8) }) }
}

public enum ProtoValue: Sendable, Equatable {
    case varint(UInt64)
    case fixed64(UInt64)
    case bytes([UInt8])
    case fixed32(UInt32)

    var wireType: Int {
        switch self {
        case .varint: return 0
        case .fixed64: return 1
        case .bytes: return 2
        case .fixed32: return 5
        }
    }
}

/// A decoded message: its fields in wire order. Unknown fields are kept and
/// ignored, as protobuf intends; known fields are type-checked on access.
public struct ProtoFields: Sendable {
    public let message: String
    public private(set) var entries: [(field: Int, value: ProtoValue)] = []

    public static let maxMessageBytes = 64 << 20

    public init(_ data: [UInt8], message: String) throws {
        self.message = message
        guard data.count <= Self.maxMessageBytes else {
            throw SteamError.unsafeContent("\(message) is \(data.count) bytes")
        }
        var i = 0
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < data.count else { throw SteamError.protocolChanged("\(message): truncated varint") }
                let b = data[i]; i += 1
                if shift == 63 && b > 1 { throw SteamError.protocolChanged("\(message): varint overflow") }
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { throw SteamError.protocolChanged("\(message): varint overflow") }
            }
        }
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, n <= data.count - i else { throw SteamError.protocolChanged("\(message): truncated field") }
            defer { i += n }
            return data[i..<(i + n)]
        }
        while i < data.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            guard field > 0 else { throw SteamError.protocolChanged("\(message): field number 0") }
            switch key & 7 {
            case 0: entries.append((field, .varint(try readVarint())))
            case 1:
                let s = try take(8)
                entries.append((field, .fixed64(s.reversed().reduce(0) { $0 << 8 | UInt64($1) })))
            case 2:
                let len = try readVarint()
                guard len <= UInt64(data.count) else { throw SteamError.protocolChanged("\(message): length overflow") }
                entries.append((field, .bytes(Array(try take(Int(len))))))
            case 5:
                let s = try take(4)
                entries.append((field, .fixed32(s.reversed().reduce(0) { $0 << 8 | UInt32($1) })))
            default:
                throw SteamError.protocolChanged("\(message): unsupported wire type \(key & 7) for field \(field)")
            }
        }
    }

    private func all(_ field: Int) -> [ProtoValue] { entries.filter { $0.field == field }.map(\.value) }

    private func mismatch(_ field: Int, _ want: String, _ got: ProtoValue) -> SteamError {
        .protocolChanged("\(message).\(field): expected \(want), got wire type \(got.wireType)")
    }

    public func has(_ field: Int) -> Bool { entries.contains { $0.field == field } }

    public func uint64(_ field: Int) throws -> UInt64? {
        guard let v = all(field).last else { return nil }
        guard case let .varint(x) = v else { throw mismatch(field, "varint", v) }
        return x
    }
    public func uint32(_ field: Int) throws -> UInt32? { try uint64(field).map { UInt32(truncatingIfNeeded: $0) } }
    public func int32(_ field: Int) throws -> Int32? { try uint64(field).map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) } }
    public func bool(_ field: Int) throws -> Bool? { try uint64(field).map { $0 != 0 } }

    public func fixed64(_ field: Int) throws -> UInt64? {
        guard let v = all(field).last else { return nil }
        guard case let .fixed64(x) = v else { throw mismatch(field, "fixed64", v) }
        return x
    }
    public func fixed32(_ field: Int) throws -> UInt32? {
        guard let v = all(field).last else { return nil }
        guard case let .fixed32(x) = v else { throw mismatch(field, "fixed32", v) }
        return x
    }
    public func float(_ field: Int) throws -> Float? { try fixed32(field).map { Float(bitPattern: $0) } }

    public func bytes(_ field: Int) throws -> [UInt8]? {
        guard let v = all(field).last else { return nil }
        guard case let .bytes(x) = v else { throw mismatch(field, "length-delimited", v) }
        return x
    }
    public func string(_ field: Int) throws -> String? {
        guard let b = try bytes(field) else { return nil }
        guard let s = String(validating: b, as: UTF8.self) else {
            throw SteamError.protocolChanged("\(message).\(field): invalid UTF-8")
        }
        return s
    }
    public func repeatedBytes(_ field: Int) throws -> [[UInt8]] {
        try all(field).map { v in
            guard case let .bytes(x) = v else { throw mismatch(field, "length-delimited", v) }
            return x
        }
    }
    public func repeatedStrings(_ field: Int) throws -> [String] {
        try repeatedBytes(field).map {
            guard let s = String(validating: $0, as: UTF8.self) else {
                throw SteamError.protocolChanged("\(message).\(field): invalid UTF-8")
            }
            return s
        }
    }
    /// Repeated varint field, packed or not.
    public func repeatedUInt32(_ field: Int) throws -> [UInt32] {
        var out: [UInt32] = []
        for v in all(field) {
            switch v {
            case let .varint(x): out.append(UInt32(truncatingIfNeeded: x))
            case let .bytes(packed):
                var i = 0
                while i < packed.count {
                    var result: UInt64 = 0, shift: UInt64 = 0
                    while true {
                        guard i < packed.count, shift < 64 else {
                            throw SteamError.protocolChanged("\(message).\(field): bad packed varint")
                        }
                        let b = packed[i]; i += 1
                        result |= UInt64(b & 0x7F) << shift
                        if b & 0x80 == 0 { break }
                        shift += 7
                    }
                    out.append(UInt32(truncatingIfNeeded: result))
                }
            default: throw mismatch(field, "varint", v)
            }
        }
        return out
    }

    /// Repeated fixed32 field, packed or not.
    public func repeatedFixed32(_ field: Int) throws -> [UInt32] {
        var out: [UInt32] = []
        for v in all(field) {
            switch v {
            case let .fixed32(x): out.append(x)
            case let .bytes(packed):
                guard packed.count % 4 == 0 else { throw SteamError.protocolChanged("\(message).\(field): bad packed fixed32") }
                for i in stride(from: 0, to: packed.count, by: 4) {
                    out.append(UInt32(packed[i]) | UInt32(packed[i + 1]) << 8 | UInt32(packed[i + 2]) << 16 | UInt32(packed[i + 3]) << 24)
                }
            default: throw mismatch(field, "fixed32", v)
            }
        }
        return out
    }

    public func messages(_ field: Int, as name: String) throws -> [ProtoFields] {
        try repeatedBytes(field).map { try ProtoFields($0, message: name) }
    }
    public func message(_ field: Int, as name: String) throws -> ProtoFields? {
        try bytes(field).map { try ProtoFields($0, message: name) }
    }

    /// Reads a field the schema marks as required for this client to proceed.
    public func require<T>(_ value: T?, _ field: Int, _ what: String) throws -> T {
        guard let value else { throw SteamError.protocolChanged("\(message).\(field) (\(what)) missing") }
        return value
    }
}
