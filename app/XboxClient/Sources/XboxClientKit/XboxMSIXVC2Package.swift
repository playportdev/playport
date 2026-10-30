// SPDX-License-Identifier: GPL-3.0-only
// Xodus pull request #219 (cyberps96/xodus feat/msixvc2-support) at
// e8194a89ea372c809015952bcab255e65b2b3089, crates/msixvc2/src/package.rs
// (Msixvc2Archive: XboxPackage.cbor, Chunks/<id>.cbor, file names from the chunk
// secrets, each file's segments from its boxes, the file's hash) and
// crates/xodus-cli/src/commands/extract.rs (a "PK\x03\x04" package is MSIXVC2);
// translated to Swift by the Playport authors, 2026-10-30. Modified: the ZIP is
// read with HTTP ranges (its directory, the metadata entries, each box's manifest),
// never downloaded whole; the metadata reads are kept beside the stage so a resumed
// install doesn't fetch them again; ContentKit's install engine fetches each
// segment straight into the stage, checked against its box hash before it is
// decrypted and its own hash after; every file's hash is checked before the stage
// is committed.
import Foundation
import ContentKit

/// A file an MSIXVC2 package installs: installed decrypted and uncompressed.
public struct XboxMSIXVC2File: Sendable, Equatable {
    /// `/`-separated, relative to the game's folder.
    public let path: String
    public let size: UInt64
    let hash: XboxMSIXVC2.Hash
    /// Its segments in order, and the content key index of the chunk it is in.
    let segments: [XboxMSIXVC2.Segment]
    let keyIndex: Int
}

/// An MSIXVC2 package's metadata, read with HTTP ranges and checked: the package and
/// chunk metadata, every box's sealed manifest, the file names, every file's segments.
public struct XboxMSIXVC2Package: Sendable {
    public let contentID: UUID
    /// The content ID the Store fulfils, when the package names one.
    public let fulfillmentContentID: UUID?
    public let version: String
    public let files: [XboxMSIXVC2File]
    /// Bytes the metadata took (kept beside the stage until the install commits).
    public let metadataBytes: UInt64
    /// SHA-256 of XboxPackage.cbor.
    let packageHash: [UInt8]
    /// Each box's first data byte in the package.
    let boxData: [UInt64]
    let keys: XboxMSIXVC2Keys

    static let maxMetadataEntry: UInt64 = 256 << 20

    /// Reads the metadata (resuming from `url`, where every read is kept) and the file
    /// names, which need the licence's keys (`licence`: key bytes by key ID).
    public static func fetch(_ bytes: any XboxPackageBytes, into url: URL, licence: [UUID: [UInt8]], log: Logger = .silent,
                             progress: @escaping @Sendable (UInt64) -> Void = { _ in }) async throws -> XboxMSIXVC2Package {
        let cache = try XboxRangeCache(url, remote: bytes, progress: progress)
        defer { cache.close() }
        let package = try await load(cache, licence: licence, log: log)
        try cache.synchronize()
        log.info("xbox", "package metadata: \(cache.bytes) bytes, \(package.files.count) files")
        return package
    }

    static func load(_ r: XboxRangeCache, licence: [UUID: [UInt8]], log: Logger) async throws -> XboxMSIXVC2Package {
        let directory = try await XboxZip.directory(size: r.size) { try await r.read($0, $1) }
        func entry(_ names: String...) throws -> XboxZip.Entry {
            for n in names { if let e = directory[n.lowercased()] { return e } }
            throw XboxXVD.damaged("it has no \(names[0])")
        }
        func whole(_ e: XboxZip.Entry) async throws -> [UInt8] {
            guard e.size <= maxMetadataEntry, e.compressedSize <= maxMetadataEntry else { throw XboxXVD.damaged("its \(e.name) is \(e.size) bytes") }
            let at = try await XboxZip.dataOffset(e, size: r.size) { try await r.read($0, $1) }
            let raw = try await r.read(at, Int(e.compressedSize))
            let data: [UInt8]
            switch e.method {
            case 0: data = raw
            case 8:
                guard let inflated = try? Inflate.decompress(raw[...], limit: Int(e.size)) else { throw XboxXVD.damaged("its \(e.name) doesn't inflate") }
                data = inflated
            default: throw ClientError.unsupported("Xbox package entry \(e.name) uses ZIP method \(e.method)")
            }
            guard UInt64(data.count) == e.size, CRC32.checksum(data) == e.crc else { throw XboxXVD.damaged("its \(e.name) doesn't match its CRC") }
            return data
        }

        let packageBytes = try await whole(try entry("XboxPackage.cbor"))
        let meta = try XboxMSIXVC2.Package.parse(packageBytes)
        let keys = try XboxMSIXVC2Keys(package: meta, licence: licence, log: log)

        // Boxes: stored entries, so a segment is a byte range of the package. Each ends in
        // its manifest, sealed by a hash, then the manifest's offset and length.
        var boxData: [UInt64] = [], boxEnd: [UInt64] = [], listed: [Set<XboxMSIXVC2.Hash.Listed>] = []
        for name in meta.boxes {
            let e = try entry("Boxes/" + name, name)
            guard e.method == 0, e.compressedSize == e.size else { throw ClientError.unsupported("Xbox package box \(name) is compressed in its ZIP") }
            guard e.size >= 20 else { throw XboxXVD.damaged("its box \(name) is cut short") }
            let at = try await XboxZip.dataOffset(e, size: r.size) { try await r.read($0, $1) }
            guard try await r.read(at, 8) == XboxMSIXVC2.boxMagic else { throw XboxXVD.damaged("its box \(name) has no box header") }
            let trailer = try await r.read(at + e.size - 12, 12)
            let manifestAt = trailer.readLE64(at: 0), manifestLength = UInt64(trailer.readLE32(at: 8))
            guard manifestAt >= 8, manifestAt <= e.size - 12, manifestLength <= e.size - 12 - manifestAt,
                  e.size - 12 - manifestAt <= maxMetadataEntry else {
                throw XboxXVD.damaged("its box \(name)'s manifest is out of range")
            }
            let tail = try await r.read(at + manifestAt, Int(e.size - 12 - manifestAt))
            listed.append(try XboxMSIXVC2.boxManifest(Array(tail[0..<Int(manifestLength)]), seal: Array(tail[Int(manifestLength)...]), name: name))
            boxData.append(at); boxEnd.append(manifestAt)
        }

        /// A segment's box bytes checked against the package: inside its box's segment area, listed by its box's manifest.
        func check(_ s: XboxMSIXVC2.Segment, _ what: String) throws {
            guard s.box < boxData.count else { throw XboxXVD.damaged("\(what) names box \(s.box) the package doesn't list") }
            guard s.boxOffset >= 8, s.boxOffset <= boxEnd[s.box], UInt64(s.boxLength) <= boxEnd[s.box] - s.boxOffset else {
                throw XboxXVD.damaged("\(what) lies outside its box")
            }
            guard listed[s.box].contains(.init(hash: s.hash, length: s.length)) else { throw XboxXVD.damaged("\(what) isn't in its box's manifest") }
        }
        func open(_ s: XboxMSIXVC2.Segment, keyIndex: Int, _ what: String) async throws -> [UInt8] {
            try check(s, what)
            let box = try await r.read(boxData[s.box] + s.boxOffset, s.boxLength)
            if let h = s.boxHash, !h.matches(box) { throw XboxXVD.damaged("\(what) doesn't match its box hash") }
            guard let plain = try keys.open(s, keyIndex: keyIndex, box) else {
                throw s.encrypted && s.boxHash != nil ? ClientError.verificationFailed("Xbox licence key doesn't decrypt this package")
                                                      : XboxXVD.damaged("\(what) doesn't match its hash")
            }
            return plain
        }

        var files: [XboxMSIXVC2File] = [], seen = Set<String>()
        for chunk in meta.chunks {
            let details = try XboxMSIXVC2.chunkFiles(try await whole(try entry("Chunks/\(chunk.id).cbor")), id: chunk.id)
            let names = try XboxMSIXVC2.chunkNames(try await open(chunk.secret, keyIndex: chunk.keyIndex, "chunk \(chunk.id)'s secret"), id: chunk.id)
            guard names.count == details.count else { throw XboxXVD.damaged("chunk \(chunk.id) names \(names.count) of its \(details.count) files") }
            for (name, f) in zip(names, details) {
                let path = try SafePath.normalize(name.replacingOccurrences(of: "\\", with: "/"))
                try WindowsName.check(path: path.split(separator: "/").map(String.init), seen: &seen)
                var total: UInt64 = 0
                for (n, s) in f.segments.enumerated() {
                    try check(s, "\(path) segment \(n)")
                    total += UInt64(s.length)
                }
                guard total == f.length else { throw XboxXVD.damaged("\(path)'s segments make \(total) bytes, not \(f.length)") }
                if f.length == 0, !f.hash.matches([]) { throw XboxXVD.damaged("\(path) doesn't match its hash") }
                files.append(XboxMSIXVC2File(path: path, size: f.length, hash: f.hash, segments: f.segments, keyIndex: chunk.keyIndex))
            }
        }
        guard !files.isEmpty else { throw XboxXVD.damaged("it has no files") }
        return XboxMSIXVC2Package(contentID: meta.contentID, fulfillmentContentID: meta.fulfillmentContentID, version: meta.version,
                                  files: files, metadataBytes: r.bytes, packageHash: SHA256Stream.hash(packageBytes), boxData: boxData, keys: keys)
    }

    /// MicrosoftGame.config's path, when the package has one at its root.
    public var gameConfigPath: String? { files.first { $0.path.lowercased() == "microsoftgame.config" }?.path }

    /// One ContentKit chunk per distinct segment (by package offset), parts in file order.
    public func plan() -> ContentPlan {
        var files: [ContentFile] = [], chunks: [ContentChunk] = [], index: [[UInt8]: Int] = [:], directories = Set<String>()
        for f in self.files.sorted(by: { $0.path < $1.path }) {
            var dir = f.path.split(separator: "/").dropLast()
            while !dir.isEmpty { directories.insert(dir.joined(separator: "/")); dir.removeLast() }
            var parts: [ContentPart] = [], at: UInt64 = 0
            for s in f.segments where s.length > 0 {
                let key = XboxMSIXVC2Chunk(offset: boxData[s.box] + s.boxOffset, boxLength: UInt32(s.boxLength), length: UInt32(s.length),
                                           keyIndex: UInt32(f.keyIndex), hash: s.hash.bytes).key
                let n: Int
                if let have = index[key] { n = have } else {
                    n = chunks.count
                    index[key] = n
                    chunks.append(ContentChunk(key: key, size: UInt32(s.length), compressedSize: UInt32(s.boxLength), check: .none))
                }
                parts.append(ContentPart(chunk: n, length: UInt32(s.length), fileOffset: at))
                at += UInt64(s.length)
            }
            files.append(ContentFile(path: f.path, size: f.size, hash: .none, parts: parts))
        }
        let id = Array("xbox-msixvc2/1".utf8) + Array(contentID.uuidString.lowercased().utf8) + Array(version.utf8) + packageHash
        return ContentPlan(files: files, directories: directories.sorted(), chunks: chunks, identity: SHA1.hash(id))
    }

    /// Checks a staged file against the package's hash for it, and returns its SHA-1.
    func verify(_ f: XboxMSIXVC2File, at url: URL) throws -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ClientError.verificationFailed("\(f.path) is missing") }
        defer { try? handle.close() }
        var sha1 = SHA1Stream(), hash = XboxMSIXVC2.Hash.Stream(f.hash.kind), total: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            total += UInt64(data.count)
            data.withUnsafeBytes { sha1.update($0); hash.update($0) }
        }
        guard total == f.size, hash.finalize() == f.hash.bytes else {
            throw ClientError.verificationFailed("Xbox package file \(f.path) does not match its hash")
        }
        return sha1.finalize()
    }
}

/// A chunk's key: where its box bytes are, their length and its plaintext's, its key
/// index and hash. Unique per distinct segment.
struct XboxMSIXVC2Chunk: Equatable {
    var offset: UInt64
    var boxLength: UInt32
    var length: UInt32
    var keyIndex: UInt32
    var hash: [UInt8]
    var key: [UInt8] {
        var k = Array("v2".utf8)
        k.appendLE(offset); k.appendLE(boxLength); k.appendLE(length); k.appendLE(keyIndex)
        return k + hash
    }
}

/// Segments for the install engine, read with HTTP ranges: each checked against its
/// box hash before it is decrypted, decompressed, then checked against its own hash.
/// A segment whose box bytes fail is fetched once more before the install stops.
final class XboxMSIXVC2Source: ContentChunkSource, @unchecked Sendable {
    let package: XboxMSIXVC2Package
    let remote: any XboxPackageBytes
    let log: Logger
    private let segments: [[UInt8]: (XboxMSIXVC2.Segment, Int)]

    init(package: XboxMSIXVC2Package, remote: any XboxPackageBytes, log: Logger) {
        self.package = package; self.remote = remote; self.log = log
        var table: [[UInt8]: (XboxMSIXVC2.Segment, Int)] = [:]
        for f in package.files {
            for s in f.segments {
                let key = XboxMSIXVC2Chunk(offset: package.boxData[s.box] + s.boxOffset, boxLength: UInt32(s.boxLength),
                                           length: UInt32(s.length), keyIndex: UInt32(f.keyIndex), hash: s.hash.bytes).key
                if table[key] == nil { table[key] = (s, f.keyIndex) }
            }
        }
        segments = table
    }

    func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        guard let (s, keyIndex) = segments[c.key] else { throw ClientError.protocolChanged("not an Xbox package segment") }
        let at = package.boxData[s.box] + s.boxOffset
        for attempt in 0..<2 {
            let box = try await remote.read(at, s.boxLength)
            if let h = s.boxHash, !h.matches(box) {
                if attempt == 0 { log.warn("xbox", "package segment at \(at) failed its box hash; fetching it again"); continue }
                throw ClientError.verificationFailed("Xbox package segment at \(at) does not match the package's hashes")
            }
            if let plain = try package.keys.open(s, keyIndex: keyIndex, box) { return plain }
            if s.encrypted, s.boxHash != nil { throw ClientError.verificationFailed("Xbox licence key doesn't decrypt this package") }
            if attempt == 0 { log.warn("xbox", "package segment at \(at) failed its hash; fetching it again"); continue }
            throw ClientError.verificationFailed("Xbox package segment at \(at) does not match the package's hashes")
        }
        throw ClientError.verificationFailed("Xbox package segment at \(at) does not match the package's hashes")
    }
}

/// The ZIP directory of a package read with ranges (ZIP64 included).
enum XboxZip {
    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var localHeader: UInt64
    }

    static let maxDirectory: UInt64 = 64 << 20

    /// Entries by name, lower-cased, without a leading `/` (OPC part names).
    static func directory(size: UInt64, read: (UInt64, Int) async throws -> [UInt8]) async throws -> [String: Entry] {
        guard size >= 22 else { throw XboxXVD.damaged("it is too small to be a ZIP") }
        // The end record without a comment first (one small read); else search the last 64 KiB.
        var tail = try await read(size - 22, 22)
        if !(tail.readLE32(at: 0) == 0x0605_4B50 && tail.readLE16(at: 20) == 0) {
            tail = try await read(size - min(size, 22 + 0xFFFF), Int(min(size, 22 + 0xFFFF)))
        }
        let tailLength = tail.count
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.readLE32(at: $0) == 0x0605_4B50 && $0 + 22 + Int(tail.readLE16(at: $0 + 20)) == tail.count
        }) else { throw XboxXVD.damaged("it has no ZIP directory") }
        var count = UInt64(tail.readLE16(at: eocd + 10)), length = UInt64(tail.readLE32(at: eocd + 12)), start = UInt64(tail.readLE32(at: eocd + 16))
        let eocdAt = size - UInt64(tailLength) + UInt64(eocd)
        if count == 0xFFFF || length == 0xFFFF_FFFF || start == 0xFFFF_FFFF {
            guard eocdAt >= 20 else { throw XboxXVD.damaged("its ZIP64 directory is missing") }
            let locator = try await read(eocdAt - 20, 20)
            guard locator.readLE32(at: 0) == 0x0706_4B50 else { throw XboxXVD.damaged("its ZIP64 directory is missing") }
            let at = locator.readLE64(at: 8)
            guard at <= eocdAt - 20, eocdAt - 20 - at >= 56 else { throw XboxXVD.damaged("its ZIP64 directory is out of range") }
            let z = try await read(at, 56)
            guard z.readLE32(at: 0) == 0x0606_4B50 else { throw XboxXVD.damaged("its ZIP64 directory is missing") }
            count = z.readLE64(at: 32); length = z.readLE64(at: 40); start = z.readLE64(at: 48)
        }
        guard length <= maxDirectory, start <= eocdAt, length <= eocdAt - start, count <= length / 46 else {
            throw XboxXVD.damaged("its ZIP directory is out of range")
        }
        let d = try await read(start, Int(length))
        var out: [String: Entry] = [:], o = 0
        for _ in 0..<count {
            guard d.count - o >= 46, d.readLE32(at: o) == 0x0201_4B50 else { throw XboxXVD.damaged("its ZIP directory is damaged") }
            let flags = d.readLE16(at: o + 8)
            let nameLength = Int(d.readLE16(at: o + 28)), extraLength = Int(d.readLE16(at: o + 30)), comment = Int(d.readLE16(at: o + 32))
            guard d.count - o - 46 >= nameLength + extraLength + comment else { throw XboxXVD.damaged("its ZIP directory is damaged") }
            var e = Entry(name: String(decoding: d[(o + 46)..<(o + 46 + nameLength)], as: UTF8.self), method: d.readLE16(at: o + 10),
                          crc: d.readLE32(at: o + 16), compressedSize: UInt64(d.readLE32(at: o + 20)), size: UInt64(d.readLE32(at: o + 24)),
                          localHeader: UInt64(d.readLE32(at: o + 42)))
            // The ZIP64 extra field holds, in order, whichever of these were 0xFFFFFFFF.
            var x = o + 46 + nameLength
            let extraEnd = x + extraLength
            while extraEnd - x >= 4 {
                let id = d.readLE16(at: x), n = Int(d.readLE16(at: x + 2))
                guard extraEnd - x - 4 >= n else { break }
                if id == 1 {
                    var p = x + 4
                    func next() throws -> UInt64 {
                        guard p + 8 <= x + 4 + n else { throw XboxXVD.damaged("its ZIP64 field is short") }
                        defer { p += 8 }
                        return d.readLE64(at: p)
                    }
                    if e.size == 0xFFFF_FFFF { e.size = try next() }
                    if e.compressedSize == 0xFFFF_FFFF { e.compressedSize = try next() }
                    if e.localHeader == 0xFFFF_FFFF { e.localHeader = try next() }
                }
                x += 4 + n
            }
            guard flags & 1 == 0 else { throw ClientError.unsupported("Xbox package entry \(e.name) is ZIP-encrypted") }
            guard e.localHeader <= start, e.compressedSize <= start - e.localHeader else { throw XboxXVD.damaged("its ZIP entry \(e.name) is out of range") }
            var key = e.name.lowercased()
            while key.hasPrefix("/") { key.removeFirst() }
            guard out.updateValue(e, forKey: key) == nil else { throw XboxXVD.damaged("its ZIP lists \(e.name) twice") }
            o += 46 + nameLength + extraLength + comment
        }
        return out
    }

    /// Where an entry's bytes start: after its local header, whose name and extra field
    /// lengths may differ from the directory's.
    static func dataOffset(_ e: Entry, size: UInt64, read: (UInt64, Int) async throws -> [UInt8]) async throws -> UInt64 {
        guard e.localHeader <= size, size - e.localHeader >= 30 else { throw XboxXVD.damaged("its ZIP entry \(e.name) is out of range") }
        let h = try await read(e.localHeader, 30)
        guard h.readLE32(at: 0) == 0x0403_4B50 else { throw XboxXVD.damaged("its ZIP entry \(e.name) has no header") }
        let at = e.localHeader + 30 + UInt64(h.readLE16(at: 26)) + UInt64(h.readLE16(at: 28))
        guard at <= size, e.compressedSize <= size - at else { throw XboxXVD.damaged("its ZIP entry \(e.name) runs past the package") }
        return at
    }
}

/// The package's metadata reads, kept in a file beside the stage: a read the file
/// already holds is served from it, any other is fetched and appended. Records are
/// offset (LE64), length (LE32), bytes; a record cut short by a stop is dropped.
final class XboxRangeCache: @unchecked Sendable {
    let remote: any XboxPackageBytes
    let progress: @Sendable (UInt64) -> Void
    var size: UInt64 { remote.size }
    /// Bytes held: the metadata's size.
    private(set) var bytes: UInt64 = 0
    private let handle: FileHandle
    private var index: [Range<UInt64>: UInt64] = [:]
    private var end: UInt64 = 0
    static let magic = Array("XBOXMETA1".utf8)

    init(_ url: URL, remote: any XboxPackageBytes, progress: @escaping @Sendable (UInt64) -> Void) throws {
        self.remote = remote; self.progress = progress
        try InstallFS.makeDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forUpdating: url)
        let data = Array(try handle.readToEnd() ?? Data())
        if data.count < Self.magic.count || Array(data[0..<Self.magic.count]) != Self.magic {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(Self.magic))
            end = UInt64(Self.magic.count)
            return
        }
        var o = Self.magic.count
        while data.count - o >= 12 {
            let at = data.readLE64(at: o), n = Int(data.readLE32(at: o + 8))
            guard data.count - o - 12 >= n, at <= remote.size, UInt64(n) <= remote.size - at else { break }
            index[at..<(at + UInt64(n))] = UInt64(o + 12)
            bytes += UInt64(n)
            o += 12 + n
        }
        end = UInt64(o)
        try handle.truncate(atOffset: end)
    }

    func read(_ offset: UInt64, _ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        guard offset <= size, UInt64(count) <= size - offset else { throw XboxXVD.damaged("a read runs past the package's end") }
        let want = offset..<(offset + UInt64(count))
        if let (range, at) = index.first(where: { $0.key.lowerBound <= want.lowerBound && $0.key.upperBound >= want.upperBound }) {
            try handle.seek(toOffset: at + (offset - range.lowerBound))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw XboxXVD.damaged("its kept metadata is cut short") }
            return Array(data)
        }
        try Task.checkCancellation()
        let got = try await remote.read(offset, count)
        guard got.count == count else { throw XboxXVD.damaged("a read came back short") }
        var record = [UInt8]()
        record.appendLE(offset); record.appendLE(UInt32(count))
        try handle.seek(toOffset: end)
        try handle.write(contentsOf: Data(record + got))
        index[want] = end + 12
        end += 12 + UInt64(count)
        bytes += UInt64(count)
        progress(bytes)
        return got
    }

    func synchronize() throws { try handle.synchronize() }
    func close() { try? handle.close() }
}
