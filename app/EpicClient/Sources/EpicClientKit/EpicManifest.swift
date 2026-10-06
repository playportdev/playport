// SPDX-License-Identifier: GPL-3.0-or-later
// Epic's binary manifest, as the spike measured it (plan 3.1; every manifest seen
// was this form, feature level 17):
//
//   header   magic 0x44BEC00C, header size, body sizes, SHA-1 of the body, stored-as
//            (bit 0: zlib), version
//   body     meta (app name, build version, launch executable and command, prerequisites),
//            chunk data list (GUID, rolling hash, SHA-1, group, window size, file size,
//            each a column), file manifest list (names, symlink targets, SHA-1s, flags,
//            install tags, chunk parts, from version 1 md5s and MIME types, from 2 SHA-256s),
//            custom fields
//
// Every count, size and string is capped, and every read is bounds-checked: a
// truncated or hostile manifest throws, it never crashes.

import Foundation
import ContentKit

public struct EpicManifest: Sendable {
    public struct Chunk: Sendable, Equatable {
        /// The four GUID words, as the manifest stores them (little-endian each).
        public var guid: [UInt8]
        public var hash: UInt64
        public var sha1: [UInt8]
        public var group: UInt8
        /// The chunk's plain size.
        public var window: UInt32
        /// The chunk file's size on the CDN.
        public var fileSize: UInt64

        /// `8CBFF7EB496875E5FDB9E08EF33F5C0D`: the words in hex, as the CDN names it.
        public var guidHex: String {
            stride(from: 0, to: 16, by: 4).map { i in
                String(format: "%08X", UInt32(guid[i]) | UInt32(guid[i + 1]) << 8 | UInt32(guid[i + 2]) << 16 | UInt32(guid[i + 3]) << 24)
            }.joined()
        }
    }

    public struct Part: Sendable, Equatable, Codable {
        /// Index into `chunks`.
        public var chunk: Int
        public var offset: UInt32
        public var size: UInt32
    }

    public struct File: Sendable, Equatable {
        /// `/`-separated, checked by `SafePath`.
        public var path: String
        public var symlinkTarget: String
        public var sha1: [UInt8]
        public var flags: UInt8
        public var installTags: [String]
        public var parts: [Part]
        public var size: UInt64 { parts.reduce(0) { $0 + UInt64($1.size) } }
        public var isExecutable: Bool { flags & 4 != 0 }
    }

    public var featureLevel: UInt32
    public var appName: String
    public var buildVersion: String
    public var launchExe: String
    public var launchCommand: String
    public var prerequisites: [String]
    public var chunks: [Chunk]
    public var files: [File]
    public var custom: [String: String]

    public var installBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
    public var downloadBytes: UInt64 { chunks.reduce(0) { $0 + $1.fileSize } }

    /// The CDN folder of the chunk files for this feature level.
    public var chunkDirectory: String {
        featureLevel >= 15 ? "ChunksV4" : featureLevel >= 6 ? "ChunksV3" : featureLevel >= 3 ? "ChunksV2" : "Chunks"
    }

    /// A chunk file's path under a CDN base: `ChunksV4/GG/HASH_GUID.chunk`.
    public func chunkPath(_ c: Chunk) -> String {
        "\(chunkDirectory)/" + String(format: "%02d/%016llX_", Int(c.group), c.hash) + c.guidHex + ".chunk"
    }

    /// Why Playport does not install it, from its files (plan 3.5): anti-cheat.
    public var refusal: String? {
        let names = ["easyanticheat", "battleye", "beclient", "eac_launcher"]
        if files.contains(where: { f in let p = f.path.lowercased(); return names.contains { p.contains($0) } }) {
            return "This game uses anti-cheat, which does not run in Playport."
        }
        return nil
    }

    // MARK: parsing

    static let magic: UInt32 = 0x44BEC00C
    static let maxBody = 256 << 20
    static let maxCount = 4 << 20
    static let maxString = 1 << 16

    public static func parse(_ data: [UInt8]) throws -> EpicManifest {
        var h = Reader(data)
        guard data.count >= 4 else { throw ClientError.protocolChanged("Epic manifest: empty") }
        guard try h.u32() == magic else {
            if data.first == 0x7B { throw ClientError.unsupported("Epic's older JSON manifest") }
            throw ClientError.protocolChanged("Epic manifest: not a manifest")
        }
        let headerSize = Int(try h.u32()), plainSize = Int(try h.u32()), storedSize = Int(try h.u32())
        let sha = try h.bytes(20)
        let storedAs = try h.u8()
        _ = try h.u32()     // version
        guard headerSize >= 37, plainSize <= maxBody, storedSize <= maxBody, headerSize <= data.count,
              data.count - headerSize >= storedSize else {
            throw ClientError.protocolChanged("Epic manifest: sizes out of range")
        }
        let stored = Array(data[headerSize..<(headerSize + storedSize)])
        let body = storedAs & 1 != 0 ? try Zlib.decompress(stored, limit: plainSize) : stored
        guard storedAs & 2 == 0 else { throw ClientError.unsupported("an encrypted Epic manifest") }
        guard body.count == plainSize, SHA1.hash(body) == sha else {
            throw ClientError.verificationFailed("Epic manifest body does not match its SHA-1")
        }
        return try parseBody(body)
    }

    static func parseBody(_ body: [UInt8]) throws -> EpicManifest {
        var r = Reader(body)
        // Meta.
        var start = r.at
        var size = Int(try r.u32())
        let dataVersion = try r.u8()
        let featureLevel = try r.u32()
        _ = try r.u8()      // is file data
        _ = try r.u32()     // app ID
        let appName = try r.string(), buildVersion = try r.string(), launchExe = try r.string(), launchCommand = try r.string()
        let prereqs = try (0..<r.count()).map { _ in try r.string() }
        _ = try r.string(); _ = try r.string(); _ = try r.string()      // prerequisite name, path, arguments
        if dataVersion >= 1 { _ = try r.string() }                      // build ID
        if dataVersion >= 2 { _ = try r.string(); _ = try r.string() }  // uninstall action
        try r.seek(start, size)

        // Chunk data list.
        start = r.at
        size = Int(try r.u32())
        _ = try r.u8()
        let nc = try r.count()
        let guids = try (0..<nc).map { _ in try r.bytes(16) }
        let hashes = try (0..<nc).map { _ in try r.u64() }
        let shas = try (0..<nc).map { _ in try r.bytes(20) }
        let groups = try (0..<nc).map { _ in try r.u8() }
        let windows = try (0..<nc).map { _ in try r.u32() }
        let fileSizes = try (0..<nc).map { _ in try r.u64() }
        try r.seek(start, size)
        var chunks: [Chunk] = []
        chunks.reserveCapacity(nc)
        var byGUID: [[UInt8]: Int] = [:]
        for i in 0..<nc {
            guard windows[i] > 0, windows[i] <= 64 << 20, fileSizes[i] <= 128 << 20, groups[i] < 100 else {
                throw ClientError.unsafeContent("Epic chunk \(i): sizes out of range")
            }
            guard byGUID.updateValue(i, forKey: guids[i]) == nil else { throw ClientError.unsafeContent("Epic chunk GUID listed twice") }
            chunks.append(Chunk(guid: guids[i], hash: hashes[i], sha1: shas[i], group: groups[i], window: windows[i], fileSize: fileSizes[i]))
        }

        // File manifest list.
        start = r.at
        size = Int(try r.u32())
        let fileVersion = try r.u8()
        let nf = try r.count()
        let names = try (0..<nf).map { _ in try r.string() }
        let links = try (0..<nf).map { _ in try r.string() }
        let fshas = try (0..<nf).map { _ in try r.bytes(20) }
        let flags = try (0..<nf).map { _ in try r.u8() }
        let tags = try (0..<nf).map { _ in try (0..<r.count()).map { _ in try r.string() } }
        var parts: [[Part]] = []
        parts.reserveCapacity(nf)
        for _ in 0..<nf {
            let np = try r.count()
            var list: [Part] = []
            list.reserveCapacity(np)
            for _ in 0..<np {
                let ps = r.at
                let psize = Int(try r.u32())
                let guid = try r.bytes(16), offset = try r.u32(), length = try r.u32()
                try r.seek(ps, psize)
                guard let k = byGUID[guid] else { throw ClientError.unsafeContent("Epic file part names a chunk the manifest lacks") }
                guard UInt64(offset) + UInt64(length) <= UInt64(chunks[k].window), length > 0 else {
                    throw ClientError.unsafeContent("Epic file part outside its chunk")
                }
                list.append(Part(chunk: k, offset: offset, size: length))
            }
            parts.append(list)
        }
        if fileVersion >= 1 {
            for _ in 0..<nf { if try r.u32() != 0 { _ = try r.bytes(16) } }
            for _ in 0..<nf { _ = try r.string() }
        }
        if fileVersion >= 2 { for _ in 0..<nf { _ = try r.bytes(32) } }
        try r.seek(start, size)
        var files: [File] = []
        files.reserveCapacity(nf)
        for i in 0..<nf {
            files.append(File(path: try SafePath.normalize(names[i]), symlinkTarget: links[i], sha1: fshas[i], flags: flags[i],
                              installTags: tags[i], parts: parts[i]))
        }

        // Custom fields (optional).
        var custom: [String: String] = [:]
        if r.at < body.count {
            _ = try r.u32()
            _ = try r.u8()
            let n = try r.count()
            let keys = try (0..<n).map { _ in try r.string() }
            let values = try (0..<n).map { _ in try r.string() }
            for (k, v) in zip(keys, values) { custom[k] = v }
        }
        return EpicManifest(featureLevel: featureLevel, appName: appName, buildVersion: buildVersion, launchExe: launchExe,
                            launchCommand: launchCommand, prerequisites: prereqs, chunks: chunks, files: files, custom: custom)
    }

    /// A bounds-checked little-endian reader.
    struct Reader {
        let data: [UInt8]
        var at = 0

        init(_ data: [UInt8]) { self.data = data }

        mutating func need(_ n: Int) throws {
            guard n >= 0, at <= data.count - n else { throw ClientError.protocolChanged("Epic manifest: truncated") }
        }

        mutating func u8() throws -> UInt8 {
            try need(1)
            defer { at += 1 }
            return data[at]
        }

        mutating func u32() throws -> UInt32 {
            try need(4)
            defer { at += 4 }
            return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
        }

        mutating func u64() throws -> UInt64 {
            let lo = try u32(), hi = try u32()
            return UInt64(lo) | UInt64(hi) << 32
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            try need(n)
            defer { at += n }
            return Array(data[at..<(at + n)])
        }

        /// A count, capped (and no larger than the bytes left could hold).
        mutating func count() throws -> Int {
            let n = Int(try u32())
            guard n <= EpicManifest.maxCount, n <= data.count - at else { throw ClientError.unsafeContent("Epic manifest: a count of \(n)") }
            return n
        }

        /// An FString: a signed length with its terminator; negative is UTF-16LE.
        mutating func string() throws -> String {
            let n = Int(Int32(bitPattern: try u32()))
            if n == 0 { return "" }
            if n > 0 {
                guard n <= EpicManifest.maxString else { throw ClientError.unsafeContent("Epic manifest: a string of \(n) bytes") }
                let b = try bytes(n)
                return String(decoding: b.dropLast(), as: UTF8.self)
            }
            guard -n <= EpicManifest.maxString else { throw ClientError.unsafeContent("Epic manifest: a string of \(-n) characters") }
            let b = try bytes(-n * 2)
            let units = stride(from: 0, to: b.count - 2, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        }

        /// To the end of a section that began at `start` and says it is `size` long.
        mutating func seek(_ start: Int, _ size: Int) throws {
            guard size >= 4, start + size <= data.count, start + size >= at else {
                throw ClientError.protocolChanged("Epic manifest: a section overruns")
            }
            at = start + size
        }
    }
}

/// An Epic chunk file: header (magic 0xB1FE3AA2, version, header size, stored
/// size, GUID, rolling hash, stored-as; from version 2 a SHA-1 and hash type, from
/// 3 the plain size), then the data, zlib when stored-as bit 0 is set.
public enum EpicChunkFile {
    static let magic: UInt32 = 0xB1FE3AA2

    /// The plain bytes, checked against the manifest's GUID, size and SHA-1.
    public static func decode(_ data: [UInt8], expect c: EpicManifest.Chunk) throws -> [UInt8] {
        var r = EpicManifest.Reader(data)
        guard try r.u32() == magic else { throw ClientError.verificationFailed("Epic chunk: not a chunk file") }
        _ = try r.u32()
        let headerSize = Int(try r.u32()), storedSize = Int(try r.u32())
        let guid = try r.bytes(16)
        _ = try r.u64()
        let storedAs = try r.u8()
        guard guid == c.guid else { throw ClientError.verificationFailed("Epic chunk: another chunk's GUID") }
        guard storedAs & 2 == 0 else { throw ClientError.unsupported("an encrypted Epic chunk") }
        guard headerSize >= 41, headerSize <= data.count, storedSize <= data.count - headerSize else {
            throw ClientError.verificationFailed("Epic chunk: sizes out of range")
        }
        let stored = Array(data[headerSize..<(headerSize + storedSize)])
        let plain = storedAs & 1 != 0 ? try Zlib.decompress(stored, limit: Int(c.window)) : stored
        guard plain.count == Int(c.window), SHA1.hash(plain) == c.sha1 else {
            throw ClientError.verificationFailed("Epic chunk \(c.guidHex.prefix(8)) does not match its SHA-1")
        }
        return plain
    }
}
