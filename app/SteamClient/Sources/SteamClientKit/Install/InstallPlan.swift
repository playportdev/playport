// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct DepotRef: Sendable, Codable, Equatable, Hashable {
    public var depotID: UInt32
    public var gid: UInt64

    public init(depotID: UInt32, gid: UInt64) {
        self.depotID = depotID
        self.gid = gid
    }
}

/// Every file of a title: the union of the selected depots' manifests in one
/// directory. A later depot overrides an earlier one by path (compared without
/// case, as the Windows guest sees it), Steam's overlay rule. Symlink entries
/// are not materialised; they are counted and reported.
public struct InstallPlan: Sendable {
    public typealias Chunk = ContentManifestPayload.Chunk

    public struct File: Sendable {
        public var path: String
        public var size: UInt64
        public var sha: [UInt8]?
        public var depotID: UInt32
        public var chunks: [Chunk]
        /// Global index of this file's first chunk (the journal's numbering).
        public var firstChunk: Int
    }

    public var appID: UInt32
    public var buildID: UInt32?
    public var depots: [DepotRef]
    public var files: [File]
    public var directories: [String]
    public var skippedSymlinks: [String]
    public var totalBytes: UInt64
    public var chunkCount: Int
    /// SHA-1 over the app, depots and every file's path, size and hash: a
    /// journal written for another plan never replays against this one.
    public var identity: [UInt8]

    public var uniqueChunkCount: Int { Set(files.flatMap { $0.chunks.map(\.sha) }).count }

    public static func make(appID: UInt32, buildID: UInt32?, manifests: [DepotManifest]) throws -> InstallPlan {
        enum Entry { case file(DepotManifest.File, UInt32), directory(String) }
        var order: [String] = []                 // lower-cased keys, first-seen order
        var entries: [String: Entry] = [:]
        var symlinks: [String: String] = [:]
        for m in manifests {
            for f in m.files {
                let key = f.path.lowercased()
                if entries[key] == nil && symlinks[key] == nil { order.append(key) }
                if f.isSymlink {
                    entries[key] = nil
                    symlinks[key] = f.path
                } else {
                    symlinks[key] = nil
                    entries[key] = f.isDirectory ? .directory(f.path) : .file(f, m.depotID)
                }
            }
        }
        var files: [File] = [], dirs: [String] = []
        var filePaths = Set<String>()
        for key in order {
            switch entries[key] {
            case let .file(f, depot)?:
                files.append(File(path: f.path, size: f.size, sha: f.shaContent, depotID: depot, chunks: f.chunks, firstChunk: 0))
                filePaths.insert(key)
            case let .directory(p)?:
                dirs.append(p)
            case nil:
                break
            }
        }
        // A file can not also be a directory another entry lives under.
        for key in order where entries[key] != nil || symlinks[key] != nil {
            var parent = key
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                if filePaths.contains(parent) { throw SteamError.unsafeContent("\(parent) is a file in one depot and a directory in another") }
            }
        }
        files.sort { $0.path < $1.path }
        dirs.sort()
        var next = 0
        for i in files.indices {
            files[i].firstChunk = next
            next += files[i].chunks.count
        }
        let depots = manifests.map { DepotRef(depotID: $0.depotID, gid: $0.gid) }
        var id = SHA1Stream()
        id.update(Array("playport-plan-1 app=\(appID) build=\(buildID.map(String.init) ?? "-")\n".utf8))
        for d in depots { id.update(Array("depot \(d.depotID) \(d.gid)\n".utf8)) }
        for f in files { id.update(Array("\(f.path)\0\(f.size)\0\(f.sha?.hex ?? "-")\0\(f.chunks.count)\n".utf8)) }
        return InstallPlan(appID: appID, buildID: buildID, depots: depots, files: files, directories: dirs,
                           skippedSymlinks: symlinks.values.sorted(), totalBytes: files.reduce(0) { $0 + $1.size },
                           chunkCount: next, identity: id.finalize())
    }

    /// The same plan restricted to some files (repair), renumbered.
    public func restricted(to paths: Set<String>) -> InstallPlan {
        var copy = self
        copy.files = files.filter { paths.contains($0.path) }
        copy.directories = []
        copy.skippedSymlinks = []
        var next = 0
        for i in copy.files.indices {
            copy.files[i].firstChunk = next
            next += copy.files[i].chunks.count
        }
        copy.chunkCount = next
        copy.totalBytes = copy.files.reduce(0) { $0 + $1.size }
        var id = SHA1Stream()
        id.update(identity)
        id.update(Array("restricted\n".utf8))
        for f in copy.files { id.update(Array("\(f.path)\n".utf8)) }
        copy.identity = id.finalize()
        return copy
    }
}

extension InstallPlan {
    /// The plan as the install engine (ContentKit) stages it: each Steam chunk
    /// is one whole part, deduplicated by SHA-1; parts keep this plan's chunk
    /// numbering, so a stage journal from before the engine moved still replays.
    public var content: ContentPlan {
        var chunks: [ContentChunk] = []
        var index: [[UInt8]: Int] = [:]
        let out = files.map { f in
            ContentFile(path: f.path, size: f.size, hash: f.sha.map(FileHash.sha1) ?? .none, parts: f.chunks.map { c in
                let k: Int
                if let have = index[c.sha] {
                    k = have
                } else {
                    k = chunks.count
                    index[c.sha] = k
                    chunks.append(ContentChunk(key: c.sha, size: c.cbOriginal, compressedSize: c.cbCompressed,
                                               check: .sha1(c.sha), group: f.depotID, checksum: c.crc))
                }
                return ContentPart(chunk: k, length: c.cbOriginal, fileOffset: c.offset)
            })
        }
        return ContentPlan(files: out, directories: directories, chunks: chunks, identity: identity)
    }

    /// The file holding global chunk `k` (binary search over `firstChunk`).
    func fileIndex(forChunk k: Int) -> Int? {
        guard k >= 0, k < chunkCount else { return nil }
        var lo = 0, hi = files.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if files[mid].firstChunk <= k { lo = mid } else { hi = mid - 1 }
        }
        let f = files[lo]
        return k < f.firstChunk + f.chunks.count ? lo : nil
    }
}

extension InstallEngine {
    /// Stages a Steam plan from a Steam chunk source.
    public init(tree: URL, journal: URL, source: any ChunkSource, log: Logger, options: Options = Options()) {
        self.init(tree: tree, journal: journal, source: SteamChunks(steam: source) as any ContentChunkSource, log: log, options: options)
    }

    public func run(_ plan: InstallPlan, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        try await run(plan.content, progress: progress)
    }
}

/// A Steam chunk source as the engine asks for chunks: by depot and the
/// manifest's chunk record (SHA-1, Adler-32, sizes).
struct SteamChunks: ContentChunkSource {
    let steam: any ChunkSource

    func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        try await steam.chunk(depotID: c.group, ContentManifestPayload.Chunk(sha: c.key, crc: c.checksum ?? 0, offset: 0,
                                                                             cbOriginal: c.size, cbCompressed: c.compressedSize))
    }
}

/// Steam's stages, retained manifests and receipts, by app ID.
extension InstallLayout {
    public func stagingTree(appID: UInt32, buildID: UInt32?, suffix: String = "") -> URL {
        stagingRoot.appendingPathComponent("\(appID)_\(buildID.map(String.init) ?? "0")\(suffix)", isDirectory: true)
    }

    public func journal(appID: UInt32, buildID: UInt32?, suffix: String = "") -> URL {
        stagingRoot.appendingPathComponent("\(appID)_\(buildID.map(String.init) ?? "0")\(suffix).journal")
    }

    /// The branch a staged download is for, beside its journal, so a resume
    /// with no branch named continues the same one.
    public func stageBranch(appID: UInt32, buildID: UInt32?) -> URL {
        stagingRoot.appendingPathComponent("\(appID)_\(buildID.map(String.init) ?? "0").branch")
    }

    public func manifestFile(_ d: DepotRef) -> URL { manifestsDir.appendingPathComponent("\(d.depotID)_\(d.gid).json") }
    public func receiptFile(appID: UInt32) -> URL { installsDir.appendingPathComponent("\(appID).json") }
}


/// What is installed where: written after the commit rename, read by verify
/// and repair, and by the catalogue later. Not a secret.
public struct InstallReceipt: Sendable, Codable, Equatable {
    public var appID: UInt32
    public var name: String
    public var installDir: String
    public var buildID: UInt32?
    public var depots: [DepotRef]
    public var files: Int
    public var bytes: UInt64
    public var skippedDepots: [String]
    public var skippedSymlinks: Int
    public var installedAt: String
    /// The Steam branch installed; nil (a record from before branches) is public.
    public var branch: String? = nil
    /// Steam's Windows launch executable, relative to the install folder; nil
    /// in a record from before it was kept, or when Steam lists none.
    public var executable: String? = nil
}

/// The parsed manifest kept on disk (§6.2 G11): paths, sizes and hashes, no
/// key. Re-validated on load like a download, since the file is outside the
/// signed CDN reply.
struct RetainedManifest: Codable {
    struct F: Codable {
        var p: String
        var s: UInt64
        var f: UInt32
        var h: String?
        var l: String?
        /// `sha:adler32:offset:original:compressed` per chunk.
        var c: [String]
    }

    var version = 1
    var depotID: UInt32
    var gid: UInt64
    var creationTime: UInt32?
    var files: [F]

    init(_ m: DepotManifest) {
        depotID = m.depotID
        gid = m.gid
        creationTime = m.creationTime
        files = m.files.map { f in
            F(p: f.path, s: f.size, f: f.flags, h: f.shaContent?.hex, l: f.linkTarget,
              c: f.chunks.map { "\($0.sha.hex):\($0.crc):\($0.offset):\($0.cbOriginal):\($0.cbCompressed)" })
        }
    }

    func manifest() throws -> DepotManifest {
        guard version == 1 else { throw SteamError.unsupported("retained manifest version \(version)") }
        let parsed: [DepotManifest.File] = try files.map { f in
            let chunks: [ContentManifestPayload.Chunk] = try f.c.map { s in
                let p = s.split(separator: ":")
                guard p.count == 5, let sha = Self.unhex(p[0]), let crc = UInt32(p[1]), let off = UInt64(p[2]),
                      let orig = UInt32(p[3]), let comp = UInt32(p[4]) else {
                    throw SteamError.unsafeContent("retained manifest chunk entry is malformed")
                }
                return ContentManifestPayload.Chunk(sha: sha, crc: crc, offset: off, cbOriginal: orig, cbCompressed: comp)
            }
            var sha: [UInt8]?
            if let h = f.h {
                guard let v = Self.unhex(Substring(h)) else { throw SteamError.unsafeContent("retained manifest hash is malformed") }
                sha = v
            }
            return DepotManifest.File(path: f.p, size: f.s, flags: f.f, shaContent: sha, chunks: chunks, linkTarget: f.l)
        }
        return try DepotManifest(depotID: depotID, gid: gid, creationTime: creationTime, files: parsed)
    }

    static func unhex(_ s: Substring) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8](), hi: UInt8?
        out.reserveCapacity(s.count / 2)
        for ch in s.utf8 {
            let v: UInt8
            switch ch {
            case 0x30...0x39: v = ch - 0x30
            case 0x61...0x66: v = ch - 0x61 + 10
            case 0x41...0x46: v = ch - 0x41 + 10
            default: return nil
            }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        return out
    }

    static func save(_ m: DepotManifest, to url: URL) throws {
        try InstallFS.makeDirectory(url.deletingLastPathComponent())
        try InstallFS.writeAtomically(url, JSONEncoder().encode(RetainedManifest(m)))
    }

    static func load(_ url: URL) throws -> DepotManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(RetainedManifest.self, from: data).manifest()
    }
}
