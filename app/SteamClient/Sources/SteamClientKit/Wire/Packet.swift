// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One CM message. Over the WebSocket transport each binary frame is one
/// packet: u32 EMsg (high bit = protobuf), then for protobuf messages a u32
/// header length, the CMsgProtoBufHeader and the body.
public struct CMPacket: Sendable {
    public static let protoMask: UInt32 = 0x8000_0000
    public var emsg: UInt32
    public var header: ProtoHeader
    public var body: [UInt8]

    public init(emsg: EMsg, header: ProtoHeader = ProtoHeader(), body: [UInt8]) {
        self.emsg = emsg.rawValue
        self.header = header
        self.body = body
    }

    public var knownEMsg: EMsg? { EMsg(rawValue: emsg) }

    public func serialize() -> [UInt8] {
        let h = header.encode()
        var out = [UInt8]()
        out.reserveCapacity(8 + h.count + body.count)
        out.appendLE(emsg | Self.protoMask)
        out.appendLE(UInt32(h.count))
        out.append(contentsOf: h)
        out.append(contentsOf: body)
        return out
    }

    /// Parses one frame. A non-protobuf (legacy struct header) message is
    /// reported as a typed failure: every message this client handles is
    /// protobuf-framed in the pinned schema.
    public static func parse(_ frame: [UInt8]) throws -> CMPacket {
        guard frame.count >= 8 else { throw SteamError.protocolChanged("CM frame shorter than 8 bytes") }
        let raw = frame.readLE32(at: 0)
        guard raw & protoMask != 0 else {
            throw SteamError.protocolChanged("non-protobuf CM message \(raw)")
        }
        let headerLength = Int(frame.readLE32(at: 4))
        guard headerLength <= frame.count - 8 else { throw SteamError.protocolChanged("CM header length overflow") }
        let header = try ProtoHeader.decode(Array(frame[8..<(8 + headerLength)]))
        var p = CMPacket(emsg: .multi, header: header, body: Array(frame[(8 + headerLength)...]))
        p.emsg = raw & ~protoMask
        return p
    }

    /// Expands a Multi message into its packets. Gzipped bodies are inflated
    /// with the declared size as a hard ceiling (and at most `maxMultiBytes`).
    public static let maxMultiBytes = 32 << 20

    /// Legacy (non-protobuf) packets inside a Multi are skipped and reported
    /// through `skipped`, never fatal to the rest: after an account logon Steam
    /// bundles ClientLogOnResponse with legacy messages such as
    /// ClientUpdateGuestPassesList (798), and dropping the whole Multi lost the
    /// logon response (device pairing run, 2026-09-24).
    public static func expandMulti(_ body: [UInt8], skipped: (UInt32) -> Void = { _ in }) throws -> [CMPacket] {
        let multi = try CMsgMulti.decode(body)
        var payload = multi.messageBody
        if multi.sizeUnzipped > 0 {
            guard Int(multi.sizeUnzipped) <= maxMultiBytes else {
                throw SteamError.unsafeContent("Multi declares \(multi.sizeUnzipped) bytes")
            }
            payload = try Gzip.decompress(payload, limit: Int(multi.sizeUnzipped))
            guard payload.count == Int(multi.sizeUnzipped) else {
                throw SteamError.protocolChanged("Multi inflated to \(payload.count), declared \(multi.sizeUnzipped)")
            }
        }
        var out: [CMPacket] = []
        var i = 0
        while i < payload.count {
            guard payload.count - i >= 4 else { throw SteamError.protocolChanged("Multi: truncated length") }
            let n = Int(payload.readLE32(at: i)); i += 4
            guard n <= payload.count - i else { throw SteamError.protocolChanged("Multi: truncated packet") }
            let inner = Array(payload[i..<(i + n)])
            i += n
            if inner.count >= 4, inner.readLE32(at: 0) & protoMask == 0 {
                skipped(inner.readLE32(at: 0))
                continue
            }
            let packet = try parse(inner)
            if packet.knownEMsg == .multi {
                out.append(contentsOf: try expandMulti(packet.body, skipped: skipped))
            } else {
                out.append(packet)
            }
        }
        return out
    }
}

/// SteamID helpers (SteamID.kt): universe 1 (Public).
public enum SteamIDs {
    /// Individual account with account id 0, desktop instance: what
    /// SteamUser.logOn puts in the header before Steam assigns the real one.
    public static let individualPlaceholder: UInt64 = (1 << 56) | (1 << 52) | (1 << 32)
    /// Anonymous user (EAccountType.AnonUser = 10), instance 0.
    public static let anonymousUser: UInt64 = (1 << 56) | (10 << 52)
}
