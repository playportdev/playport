// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/xodus-service/src/connection/
// {mod,xml}.rs and proto/xodus/common.proto, and Xodus Nexus
// e0668a12f1da931aed13537ef04295599011317b's src/main/xodus-service.ts (the keyed TCP
// bridge) and xgameruntime-tcp-bridge/store-updates patches; translated to Swift by
// the Playport authors, 2026-10-30. Modified: one reader for the key and the frames,
// a 64 KiB frame cap, a malformed frame ends the connection.
import Foundation

/// One message on the bridge (decision 0167), as xgameruntime writes it: magic
/// 0x58445358, the type and the body's length, all little-endian, then an XML body.
/// A reply's type is its request's plus one.
public struct XboxBridgeFrame: Sendable, Equatable {
    static let magic: UInt32 = 0x5844_5358
    static let headerSize = 8
    /// 64 KiB a frame, header included.
    static let maxSize = 64 * 1024
    static let maxBody = maxSize - headerSize

    public let type: UInt16
    public let body: [UInt8]
    public init(type: UInt16, body: [UInt8]) { self.type = type; self.body = body }

    /// The header and body. The service never builds a body over `maxBody`.
    public var encoded: [UInt8] {
        precondition(body.count <= Self.maxBody, "an Xbox bridge frame over the cap")
        var out = [UInt8](); out.reserveCapacity(Self.headerSize + body.count)
        withUnsafeBytes(of: Self.magic.littleEndian) { out += $0 }
        withUnsafeBytes(of: type.littleEndian) { out += $0 }
        withUnsafeBytes(of: UInt16(body.count).littleEndian) { out += $0 }
        return out + body
    }
}

/// The message types Xodus's runtime and backend use, and Playport's own save conflict
/// question (patches/xgameruntime/0002), numbered clear of Xodus's.
enum XboxBridgeMessage: UInt16 {
    case ping = 1, pong = 2
    case msaTokenRequest = 3, msaTokenResponse = 4
    case storeLicenseTokenRequest = 5, storeLicenseTokenResponse = 6
    case storePackageUpdatesRequest = 9, storePackageUpdatesResponse = 10
    case saveConflictRequest = 0x5001, saveConflictResponse = 0x5002

    static func name(_ type: UInt16) -> String {
        switch Self(rawValue: type) {
        case .ping: "PING"
        case .pong: "PONG"
        case .msaTokenRequest: "MSA_TOKEN_REQUEST"
        case .msaTokenResponse: "MSA_TOKEN_RESPONSE"
        case .storeLicenseTokenRequest: "STORE_LICENSE_TOKEN_REQUEST"
        case .storeLicenseTokenResponse: "STORE_LICENSE_TOKEN_RESPONSE"
        case .storePackageUpdatesRequest: "STORE_PACKAGE_UPDATES_REQUEST"
        case .storePackageUpdatesResponse: "STORE_PACKAGE_UPDATES_RESPONSE"
        case .saveConflictRequest: "SAVE_CONFLICT_REQUEST"
        case .saveConflictResponse: "SAVE_CONFLICT_RESPONSE"
        case nil: "type \(type)"
        }
    }
}

public enum XboxBridgeWireError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The connection's first 64 bytes are not the play's key.
    case wrongKey
    case badMagic
    /// A frame over 64 KiB.
    case oversized
    public var description: String {
        switch self {
        case .wrongKey: "no key or the wrong key"
        case .badMagic: "not an Xodus frame"
        case .oversized: "a frame over 64 KiB"
        }
    }
}

/// One connection's bytes in arrival order: the play's key, then whole frames.
/// Nothing is read as a frame before the key is matched, and a wrong key,
/// another magic or an oversized frame throws: the connection ends.
struct XboxBridgeReader {
    private let key: [UInt8]
    private var buffer: [UInt8] = []
    private(set) var authenticated = false

    init(key: [UInt8]) { self.key = key }

    mutating func receive<C: Collection>(_ bytes: C) throws -> [XboxBridgeFrame] where C.Element == UInt8 {
        buffer += bytes
        if !authenticated {
            guard buffer.count >= key.count else { return [] }
            // Constant time, as Nexus's timingSafeEqual.
            var difference: UInt8 = 0
            for (a, b) in zip(buffer.prefix(key.count), key) { difference |= a ^ b }
            guard difference == 0 else { throw XboxBridgeWireError.wrongKey }
            buffer.removeFirst(key.count)
            authenticated = true
        }
        var frames: [XboxBridgeFrame] = []
        var at = 0
        while buffer.count - at >= XboxBridgeFrame.headerSize {
            func le16(_ i: Int) -> UInt16 { UInt16(buffer[at + i]) | UInt16(buffer[at + i + 1]) << 8 }
            let magic = UInt32(le16(0)) | UInt32(le16(2)) << 16
            guard magic == XboxBridgeFrame.magic else { throw XboxBridgeWireError.badMagic }
            let length = Int(le16(6))
            guard length <= XboxBridgeFrame.maxBody else { throw XboxBridgeWireError.oversized }
            let end = at + XboxBridgeFrame.headerSize + length
            guard buffer.count >= end else { break }
            frames.append(XboxBridgeFrame(type: le16(4), body: Array(buffer[(at + XboxBridgeFrame.headerSize)..<end])))
            at = end
        }
        buffer.removeFirst(at)
        return frames
    }
}
