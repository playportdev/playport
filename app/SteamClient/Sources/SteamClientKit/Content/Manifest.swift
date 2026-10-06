// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// EDepotFileFlag bits this client acts on (enums.steamd).
public enum DepotFileFlag {
    public static let directory: UInt32 = 64
    public static let symlink: UInt32 = 512
}

/// A parsed, validated depot manifest. Construction fails if any entry would
/// escape the install root, so nothing downstream sees an unsafe path.
public struct DepotManifest: Sendable {
    public struct File: Sendable {
        public var path: String            // validated, "/"-separated, relative
        public var size: UInt64
        public var flags: UInt32
        public var shaContent: [UInt8]?
        public var chunks: [ContentManifestPayload.Chunk]
        public var linkTarget: String?
        public var isDirectory: Bool { flags & DepotFileFlag.directory != 0 }
        public var isSymlink: Bool { flags & DepotFileFlag.symlink != 0 || linkTarget != nil }
    }

    public var depotID: UInt32
    public var gid: UInt64
    public var creationTime: UInt32?
    public var totalSize: UInt64
    public var files: [File]

    static let payloadMagic: UInt32 = 0x71F6_17D0
    static let metadataMagic: UInt32 = 0x1F48_12BE
    static let signatureMagic: UInt32 = 0x1B81_B817
    static let endMagic: UInt32 = 0x32C4_15AB
    static let maxSectionBytes = 128 << 20
    public static let maxFiles = 500_000
    public static let maxChunkBytes: UInt32 = 16 << 20

    /// Parses the unzipped manifest (DepotManifest.internalDeserialize) and
    /// decrypts filenames with the depot key when they are encrypted.
    public init(_ data: [UInt8], depotKey: Secret<[UInt8]>?, expectDepot: UInt32, expectGID: UInt64) throws {
        var i = 0
        var payload: [UInt8]?, metadata: [UInt8]?, signature: [UInt8]?
        while true {
            guard data.count - i >= 4 else { throw SteamError.protocolChanged("manifest: missing end marker") }
            let magic = data.readLE32(at: i); i += 4
            if magic == Self.endMagic { break }
            guard data.count - i >= 4 else { throw SteamError.protocolChanged("manifest: truncated section length") }
            let len = Int(data.readLE32(at: i)); i += 4
            guard len <= Self.maxSectionBytes, len <= data.count - i else { throw SteamError.unsafeContent("manifest section of \(len) bytes") }
            let section = Array(data[i..<(i + len)]); i += len
            switch magic {
            case Self.payloadMagic: payload = section
            case Self.metadataMagic: metadata = section
            case Self.signatureMagic: signature = section
            default: throw SteamError.protocolChanged(String(format: "manifest: unknown section magic 0x%08x", magic))
            }
        }
        guard let payload, let metadata, signature != nil else {
            throw SteamError.protocolChanged("manifest: payload, metadata or signature section missing")
        }
        let meta = try ContentManifestMetadata.decode(metadata)
        guard meta.depotID == expectDepot, meta.gidManifest == expectGID else {
            throw SteamError.verificationFailed("manifest is depot \(meta.depotID) gid \(meta.gidManifest), requested \(expectDepot) gid \(expectGID)")
        }
        // The CRC covers the payload as served, prefixed with its u32 length
        // (DepotManifest.serialize): crc_encrypted when filenames are encrypted.
        if let crc = meta.filenamesEncrypted ? meta.crcEncrypted : meta.crcClear, crc != 0 {
            var prefixed = [UInt8](); prefixed.appendLE(UInt32(payload.count)); prefixed += payload
            guard CRC32.checksum(prefixed) == crc else { throw SteamError.verificationFailed("manifest payload CRC mismatch") }
        }
        let body = try ContentManifestPayload.decode(payload)
        guard body.mappings.count <= Self.maxFiles else { throw SteamError.unsafeContent("manifest lists \(body.mappings.count) files") }

        let decryptor: AES256Decryptor?
        if meta.filenamesEncrypted {
            guard let depotKey else { throw SteamError.unsupported("manifest filenames are encrypted and no depot key is held") }
            decryptor = try AES256Decryptor(key: depotKey.value)
        } else {
            decryptor = nil
        }

        var files: [File] = []
        var seen = Set<String>()
        for m in body.mappings {
            var name = m.filename
            var link = m.linkTarget
            if let decryptor {
                name = try Self.decryptName(name, decryptor)
                if let l = link { link = try Self.decryptName(l, decryptor) }
            }
            let path = try SafePath.normalize(name)
            guard seen.insert(path.lowercased()).inserted else { throw SteamError.unsafeContent("duplicate manifest path \(path)") }
            if let link {
                try SafePath.checkLink(from: path, target: link)
            }
            for c in m.chunks {
                guard c.cbOriginal <= Self.maxChunkBytes, c.cbCompressed <= Self.maxChunkBytes, c.sha.count == 20 else {
                    throw SteamError.unsafeContent("chunk in \(path) declares \(c.cbOriginal)/\(c.cbCompressed) bytes")
                }
                guard c.offset + UInt64(c.cbOriginal) <= m.size else {
                    throw SteamError.unsafeContent("chunk in \(path) runs past the file end")
                }
            }
            files.append(File(path: path, size: m.size, flags: m.flags, shaContent: m.shaContent,
                              chunks: m.chunks.sorted { $0.offset < $1.offset }, linkTarget: link))
        }
        depotID = meta.depotID
        gid = meta.gidManifest
        creationTime = meta.creationTime
        totalSize = files.reduce(0) { $0 + $1.size }
        self.files = files.sorted { $0.path < $1.path }
    }

    /// A manifest from already-parsed entries (a retained manifest, or a test
    /// fixture), held to the same path, link and chunk rules as a download.
    init(depotID: UInt32, gid: UInt64, creationTime: UInt32? = nil, files raw: [File]) throws {
        guard raw.count <= Self.maxFiles else { throw SteamError.unsafeContent("manifest lists \(raw.count) files") }
        var files: [File] = []
        var seen = Set<String>()
        for var f in raw {
            f.path = try SafePath.normalize(f.path)
            guard seen.insert(f.path.lowercased()).inserted else { throw SteamError.unsafeContent("duplicate manifest path \(f.path)") }
            if let link = f.linkTarget { try SafePath.checkLink(from: f.path, target: link) }
            for c in f.chunks {
                guard c.cbOriginal <= Self.maxChunkBytes, c.cbCompressed <= Self.maxChunkBytes, c.sha.count == 20,
                      c.offset + UInt64(c.cbOriginal) <= f.size else {
                    throw SteamError.unsafeContent("chunk in \(f.path) is malformed or runs past the file end")
                }
            }
            if let sha = f.shaContent, sha.count != 20 { throw SteamError.unsafeContent("content hash of \(f.path) is \(sha.count) bytes") }
            f.chunks.sort { $0.offset < $1.offset }
            files.append(f)
        }
        self.depotID = depotID
        self.gid = gid
        self.creationTime = creationTime
        totalSize = files.reduce(0) { $0 + $1.size }
        self.files = files.sorted { $0.path < $1.path }
    }

    static func decryptName(_ b64: String, _ d: AES256Decryptor) throws -> String {
        let cleaned = b64.filter { !$0.isWhitespace }
        guard let raw = Data(base64Encoded: cleaned) else { throw SteamError.protocolChanged("manifest: filename is not base64") }
        var plain = try d.decryptSteam([UInt8](raw))
        while plain.last == 0 { plain.removeLast() }
        guard let s = String(validating: plain, as: UTF8.self) else { throw SteamError.verificationFailed("manifest: decrypted filename is not UTF-8") }
        return s
    }
}
