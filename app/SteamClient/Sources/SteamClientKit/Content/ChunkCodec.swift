// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decompresses a decrypted depot chunk by its container marker
/// (DepotChunk.kt): "VZa" (LZMA), "PK\x03\x04" (zip) or "VSZa" (zstd).
public enum ChunkCodec {
    public static func decompress(_ buf: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard buf.count >= 16 else { throw SteamError.protocolChanged("decrypted chunk of \(buf.count) bytes is too short") }
        if buf[0] == 0x56, buf[1] == 0x53, buf[2] == 0x5A, buf[3] == 0x61 {
            return try vzstd(buf, expectedSize: expectedSize)
        }
        if buf[0] == 0x56, buf[1] == 0x5A, buf[2] == 0x61 {
            return try vzip(buf, expectedSize: expectedSize)
        }
        if buf[0] == 0x50, buf[1] == 0x4B, buf[2] == 0x03, buf[3] == 0x04 {
            return try ZipSingleEntry.extract(buf, maxSize: expectedSize)
        }
        throw SteamError.protocolChanged("unknown chunk container \(Array(buf.prefix(4)).hex)")
    }

    /// VZstd: "VSZa", u32 crc, zstd frame, footer u32 crc, u32 size, 4 bytes,
    /// "zsv" (VZstdUtil.kt).
    static func vzstd(_ buf: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard buf.count >= 8 + 15, buf[buf.count - 3] == 0x7A, buf[buf.count - 2] == 0x73, buf[buf.count - 1] == 0x76 else {
            throw SteamError.protocolChanged("vzstd: missing footer")
        }
        let crc = buf.readLE32(at: buf.count - 15)
        let size = Int(buf.readLE32(at: buf.count - 11))
        guard size == expectedSize else {
            throw SteamError.verificationFailed("vzstd declares \(size) bytes, manifest says \(expectedSize)")
        }
        let out = try Zstd.decompress(buf[8..<(buf.count - 15)], limit: size)
        guard out.count == size else { throw SteamError.verificationFailed("vzstd produced \(out.count) of \(size) bytes") }
        guard CRC32.checksum(out) == crc else { throw SteamError.verificationFailed("vzstd CRC mismatch") }
        return out
    }

    /// VZip: "VZ" 'a' u32 crc/timestamp, 5 LZMA property bytes, stream,
    /// footer u32 crc, u32 size, "zv" (VZipUtil.kt).
    static func vzip(_ buf: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard buf.count >= 7 + 5 + 10 else { throw SteamError.protocolChanged("vzip: too short") }
        let footer = buf.count - 10
        guard buf[buf.count - 2] == 0x7A, buf[buf.count - 1] == 0x76 else {
            throw SteamError.protocolChanged("vzip: missing footer")
        }
        let crc = buf.readLE32(at: footer)
        let size = Int(buf.readLE32(at: footer + 4))
        guard size == expectedSize else {
            throw SteamError.verificationFailed("vzip declares \(size) bytes, manifest says \(expectedSize)")
        }
        let props = buf[7]
        let dict = buf.readLE32(at: 8)
        let out = try LZMA.decompress(buf[12..<footer], properties: props, dictionarySize: dict, outSize: size)
        guard out.count == size else { throw SteamError.verificationFailed("vzip produced \(out.count) of \(size) bytes") }
        guard CRC32.checksum(out) == crc else { throw SteamError.verificationFailed("vzip CRC mismatch") }
        return out
    }
}
