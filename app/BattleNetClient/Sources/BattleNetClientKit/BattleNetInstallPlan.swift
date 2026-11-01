// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// What an install takes: the locale and the region-tagged data to keep (every store region by
/// default, so a later region change downloads nothing). The machine is always the x64 client's
/// (decision 0177).
public struct BattleNetInstallOptions: Sendable, Equatable {
    public var locale: String
    public var regions: [StoreRegion] = StoreRegion.allCases
    /// Data files are cut at this size (the store's offsets are 30 bits).
    public var maxDataFileSize: UInt64 = CASC.maxDataFileSize
    /// One ranged read covers neighbouring objects of an archive up to this many bytes…
    public var maxRequestBytes = 8 << 20
    /// …across gaps (objects not selected) of at most this many bytes.
    public var maxGapBytes = 16 << 10

    public init(locale: String) { self.locale = locale }

    /// The manifest tag query: the x64 client's (TagQuery.client) in the locale and regions.
    public func query(_ product: ProductConfig) -> TagQuery {
        TagQuery.client(product, locale: locale, regions: regions)
    }
}

/// The objects and files an install of a build holds, from its manifests: the download
/// manifest's selection plus the build's own manifests go in the store as the CDN serves them;
/// the install manifest's selection goes in the product folder as plain files.
public struct BattleNetSelection: Sendable {
    public struct Object: Sendable, Equatable {
        public let key: PackedKey
        /// Encoded bytes, as stored.
        public let size: UInt32
    }

    public struct File: Sendable, Equatable {
        /// Under the install root, `/`-separated: `_retail_/Wow.exe`.
        public let path: String
        public let size: UInt64
        public let ckey: TACTHash
        public let ekey: PackedKey
        public let encodedSize: UInt32
    }

    public let query: TagQuery
    public let objects: [Object]
    public let files: [File]

    /// The product config's x64 client among the files, as the install manifest spells it
    /// (`_retail_/Wow.exe` for the config's `WoW.exe`); nil when the selection does not hold it.
    public func client(_ product: ProductConfig) -> File? {
        guard let exe = product.x64Executable else { return nil }
        let want = (product.folder + "/" + exe.replacingOccurrences(of: "\\", with: "/")).lowercased()
        return files.first { $0.path.lowercased() == want }
    }

    public init(build: BattleNetBuild, download: DownloadManifest, install: InstallManifest, encoding: EncodingTable,
                options: BattleNetInstallOptions) throws {
        let config = build.config.config
        query = options.query(build.productConfig)
        var objects = [Object]()
        var seen = Set<PackedKey>()
        func add(_ key: PackedKey, _ size: UInt64, _ what: String) throws {
            guard size > 0, size <= UInt64(UInt32.max) - UInt64(CASC.headerSize) else {
                throw BattleNetError.damaged("\(what): encoded size \(size)")
            }
            if seen.insert(key).inserted { objects.append(Object(key: key, size: UInt32(size))) }
        }
        for i in try download.select(query) { try add(download.ekey(i), download.encodedSize(i), "download manifest entry \(i)") }
        // The build's own manifests (root is in the download manifest, but not always first).
        if let root = config["root"]?.first.flatMap({ TACTHash(hex: $0) }) {
            guard let ekey = encoding.content(root)?.ekeys.first, let e = encoding.encoded(ekey) else {
                throw BattleNetError.damaged("encoding table: no root \(root)")
            }
            try add(PackedKey(ekey), e.encodedSize, "root")
        }
        let manifests = ["encoding", "install", "download", "size", "patch-index", "vfs-root"]
            + config.values.keys.filter { $0.hasPrefix("vfs-") && !$0.hasSuffix("-size") && $0 != "vfs-root" }.sorted()
        for name in manifests where config[name] != nil {
            let pair = try config.keyPair(name, what: "build config")
            let size: UInt64
            if let s = config["\(name)-size"], s.count >= 2, let n = UInt64(s[1]) {
                size = n
            } else if let e = encoding.encoded(pair.ekey) {
                size = e.encodedSize
            } else {
                throw BattleNetError.damaged("build config: no encoded size for \(name)")
            }
            try add(PackedKey(pair.ekey), size, name)
        }
        self.objects = objects

        // Product folder files, each directory spelled as it first appears (the manifest mixes
        // `UTILS` and `Utils`, which a case-sensitive volume would make two folders). The x64 and
        // ARM64 clients share some names under `Utils` with different builds of the file; where
        // one name is selected twice, the x64 one's file is kept.
        var spelling = [String: String]()
        var names = Set<String>()
        var byPath = [String: Int]()
        var chosen = [Int]()
        let preferred = build.productConfig.x64Tags
        for i in try install.selectIndexes(query) {
            let path = install.files[i].name.lowercased()
            if let earlier = byPath[path] {
                if install.files[chosen[earlier]].ckey != install.files[i].ckey, !preferred.isEmpty, install.file(i, has: preferred) {
                    chosen[earlier] = i
                }
                continue
            }
            byPath[path] = chosen.count
            chosen.append(i)
        }
        files = try chosen.map { install.files[$0] }.map { f in
            let parts = try SafePath.normalize(build.productConfig.folder + "\\" + f.name).split(separator: "/").map(String.init)
            var path = [String]()
            for (i, p) in parts.enumerated() {
                if i == parts.count - 1 { path.append(p); break }
                let key = (path + [p]).joined(separator: "/").lowercased()
                path.append(spelling[key] ?? p)
                spelling[key] = spelling[key] ?? p
            }
            try WindowsName.check(path: path, seen: &names)
            guard let ekey = encoding.content(f.ckey)?.ekeys.first, let e = encoding.encoded(ekey) else {
                throw BattleNetError.damaged("encoding table: no \(f.name) (\(f.ckey))")
            }
            guard e.encodedSize <= UInt64(UInt32.max) else { throw BattleNetError.damaged("\(f.name): encoded size \(e.encodedSize)") }
            return File(path: path.joined(separator: "/"), size: f.size, ckey: f.ckey, ekey: PackedKey(ekey), encodedSize: UInt32(e.encodedSize))
        }
    }

    /// Every EKey the install reads from the CDN.
    public var wanted: Set<PackedKey> { Set(objects.map(\.key)).union(files.map(\.ekey)) }
    /// The EKeys to find in the CDN indexes when the store holds `present` already: the objects
    /// it lacks, and every product folder file, which is decoded from the CDN even when the store
    /// holds its object (a file damaged on disk, or one moved to another path).
    public func wanted(besides present: Set<PackedKey>) -> Set<PackedKey> {
        Set(objects.map(\.key)).subtracting(present).union(files.map(\.ekey))
    }

    init(query: TagQuery, objects: [Object], files: [File]) {
        self.query = query
        self.objects = objects
        self.files = files
    }

    /// The selection without the product folder files `installed` says are there already.
    public func without(files installed: (File) -> Bool) -> BattleNetSelection {
        BattleNetSelection(query: query, objects: objects, files: files.filter { !installed($0) })
    }
}

/// Where each wanted object is on the CDN, from the archive indexes: an archive and a range.
/// An object no index lists is fetched whole by its EKey.
public struct ArchiveLocations: Sendable {
    public struct Location: Sendable, Equatable {
        public let archive: Int
        public let offset: UInt32
        public let size: UInt32
    }

    public private(set) var map = [PackedKey: Location]()

    public init() {}

    /// Records the `wanted` objects `index` lists, `index` being archive `archive`'s.
    public mutating func add(_ index: ArchiveIndex, archive: Int, wanted: Set<PackedKey>) {
        index.forEach(archive: archive) { e in
            guard let a = e.archive, map[e.key] == nil, wanted.contains(e.key) else { return }
            map[e.key] = Location(archive: a, offset: e.offset, size: e.size)
        }
    }

    public subscript(_ key: PackedKey) -> Location? { map[key] }
}

/// An install as a ContentKit plan: the store's data files, each its 480-byte head and then
/// runs of objects with their local headers (one run is one ranged read of neighbouring objects
/// in an archive, or one loose object), and the product folder's plain files. Every object's
/// place is fixed here, so the journals are a function of the plan.
public struct BattleNetInstallPlan: Sendable {
    enum Kind: UInt8, Sendable { case head, store, file }

    struct Run: Sendable {
        var kind: Kind
        /// The archive (its place in the CDN config's list), or -1 for a loose object.
        var archive: Int32
        var offset: UInt32
        var length: UInt32
        /// `stored` indexes for a store run, `files` index for a file.
        var first: Int32
        var count: Int32
        var dataFile: Int32
    }

    struct Stored: Sendable {
        var key: PackedKey
        var size: UInt32
        var archiveOffset: UInt32
        /// The local header's offset in its data file.
        var offset: UInt32
    }

    public let build: BattleNetBuild
    public let archives: [TACTHash]
    public let selection: BattleNetSelection
    public let options: BattleNetInstallOptions
    public let content: ContentPlan
    let runs: [Run]
    let stored: [Stored]
    /// The data files' numbers.
    public let dataFiles: [Int]
    /// Objects in the store, and their encoded bytes.
    public let objects: Int
    public let storedBytes: UInt64
    /// Requests and bytes to fetch (ranged reads include the gaps they span).
    public let requests: Int
    public let fetchBytes: UInt64

    public var files: [BattleNetSelection.File] { selection.files }
    /// The x64 client Play starts, when the plan installs it.
    public var client: BattleNetSelection.File? { selection.client(build.productConfig) }

    /// `present` objects are already in the store and are left out; data files are numbered
    /// from `firstDataFile` (an update appends to a store, PLA-521).
    public init(build: BattleNetBuild, archives: [TACTHash], selection: BattleNetSelection, locations: ArchiveLocations,
                options: BattleNetInstallOptions, present: Set<PackedKey> = [], firstDataFile: Int = 0) throws {
        self.build = build
        self.archives = archives
        self.selection = selection
        self.options = options
        var archived = [(BattleNetSelection.Object, ArchiveLocations.Location)]()
        var loose = [BattleNetSelection.Object]()
        for o in selection.objects where !present.contains(o.key) {
            if let l = locations[o.key] {
                guard l.size == o.size else {
                    throw BattleNetError.damaged("\(o.key): \(l.size) bytes in archive \(archives[l.archive]), \(o.size) in the manifest")
                }
                archived.append((o, l))
            } else {
                loose.append(o)
            }
        }
        archived.sort { ($0.1.archive, $0.1.offset) < ($1.1.archive, $1.1.offset) }

        // Group neighbours into ranged reads, each small enough for one request and one data file.
        var groups = [(archive: Int32, objects: [(BattleNetSelection.Object, UInt32)])]()
        var start: UInt64 = 0, end: UInt64 = 0, storedSize: UInt64 = 0
        let room = options.maxDataFileSize - UInt64(CASC.segmentHeaderSize)
        for (o, l) in archived {
            let a = Int32(l.archive)
            let entry = UInt64(CASC.headerSize) + UInt64(l.size)
            if let last = groups.last, last.archive == a, UInt64(l.offset) >= end,
               UInt64(l.offset) - end <= UInt64(options.maxGapBytes),
               UInt64(l.offset) + UInt64(l.size) - start <= UInt64(options.maxRequestBytes),
               storedSize + entry <= room {
                groups[groups.count - 1].objects.append((o, l.offset))
                storedSize += entry
            } else {
                groups.append((a, [(o, l.offset)]))
                start = UInt64(l.offset)
                storedSize = entry
            }
            end = UInt64(l.offset) + UInt64(l.size)
        }
        groups += loose.map { (archive: Int32(-1), objects: [($0, UInt32(0))]) }

        // Lay the runs out in data files, each starting with its head.
        var runs = [Run](), stored = [Stored](), dataFiles = [Int]()
        var cursor: UInt64 = 0
        var chunks = [ContentChunk](), dataParts = [[ContentPart]]()
        func newDataFile() {
            let n = firstDataFile + dataFiles.count
            dataFiles.append(n)
            let head = CASC.segmentHeader(dataFile: n)
            runs.append(Run(kind: .head, archive: -1, offset: 0, length: 0, first: 0, count: 0, dataFile: Int32(n)))
            chunks.append(ContentChunk(key: Array("head".utf8) + [UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)],
                                       size: UInt32(head.count), compressedSize: 0, check: .md5(MD5.hash(head)),
                                       group: UInt32(runs.count - 1)))
            dataParts.append([ContentPart(chunk: chunks.count - 1, length: UInt32(head.count), fileOffset: 0)])
            cursor = UInt64(CASC.segmentHeaderSize)
        }
        var objectBytes: UInt64 = 0, fetch: UInt64 = 0
        for g in groups {
            let bytes = g.objects.reduce(UInt64(0)) { $0 + UInt64(CASC.headerSize) + UInt64($1.0.size) }
            guard UInt64(CASC.segmentHeaderSize) + bytes <= options.maxDataFileSize else {
                throw BattleNetError.unsupported("\(g.objects[0].0.key): \(bytes) bytes do not fit a data file")
            }
            if dataFiles.isEmpty || cursor + bytes > options.maxDataFileSize { newDataFile() }
            let first = g.objects[0].1
            let last = g.objects[g.objects.count - 1]
            let length = g.archive < 0 ? g.objects[0].0.size : last.1 - first + last.0.size
            let dataFile = Int32(dataFiles[dataFiles.count - 1])
            let run = Run(kind: .store, archive: g.archive, offset: first, length: length, first: Int32(stored.count),
                          count: Int32(g.objects.count), dataFile: dataFile)
            var at = cursor
            for (o, offset) in g.objects {
                stored.append(Stored(key: o.key, size: o.size, archiveOffset: offset, offset: UInt32(at)))
                at += UInt64(CASC.headerSize) + UInt64(o.size)
                objectBytes += UInt64(o.size)
            }
            runs.append(run)
            chunks.append(ContentChunk(key: g.objects[0].0.key.bytes, size: UInt32(bytes), compressedSize: length, check: .none,
                                       group: UInt32(runs.count - 1)))
            dataParts[dataParts.count - 1].append(ContentPart(chunk: chunks.count - 1, length: UInt32(bytes), fileOffset: cursor))
            cursor += bytes
            fetch += UInt64(length)
        }
        var contentFiles = dataParts.enumerated().map { i, parts in
            ContentFile(path: String(format: "Data/data/data.%03d", dataFiles[i]),
                        size: parts.last.map { UInt64($0.fileOffset) + UInt64($0.length) } ?? 0, hash: .none, parts: parts)
        }

        // Product folder files: each decoded whole from its object.
        var fileChunk = [TACTHash: Int]()
        for (i, f) in selection.files.enumerated() {
            guard f.size > 0 else {
                contentFiles.append(ContentFile(path: f.path, size: 0, hash: .md5(f.ckey.bytes), parts: []))
                continue
            }
            guard f.size <= UInt64(UInt32.max) else { throw BattleNetError.unsupported("\(f.path): \(f.size) bytes") }
            let chunk: Int
            if let c = fileChunk[f.ckey] {
                chunk = c
            } else {
                let l = locations[f.ekey]
                runs.append(Run(kind: .file, archive: Int32(l?.archive ?? -1), offset: l?.offset ?? 0, length: f.encodedSize,
                                first: Int32(i), count: 1, dataFile: -1))
                chunks.append(ContentChunk(key: f.ckey.bytes + [0x01], size: UInt32(f.size), compressedSize: f.encodedSize,
                                           check: .md5(f.ckey.bytes), group: UInt32(runs.count - 1)))
                chunk = chunks.count - 1
                fileChunk[f.ckey] = chunk
                fetch += UInt64(f.encodedSize)
            }
            contentFiles.append(ContentFile(path: f.path, size: f.size, hash: .md5(f.ckey.bytes),
                                            parts: [ContentPart(chunk: chunk, length: UInt32(f.size), fileOffset: 0)]))
        }

        var identity = Array("battlenet-store-1".utf8) + build.version.buildConfig.bytes + build.version.cdnConfig.bytes
        identity += Array("\(selection.query.tags)|\(selection.query.excluded)|\(options.maxDataFileSize)|\(options.maxRequestBytes)|\(options.maxGapBytes)|\(firstDataFile)|\(present.count)".utf8)
        content = ContentPlan(files: contentFiles, directories: [], chunks: chunks, identity: SHA1.hash(identity))
        self.runs = runs
        self.stored = stored
        self.dataFiles = dataFiles
        objects = stored.count
        storedBytes = objectBytes
        requests = runs.filter { $0.kind != .head }.count
        fetchBytes = fetch
    }

    /// Every stored object's place, as the journals record it.
    public var locations: [CASC.Location] {
        var out = [CASC.Location]()
        out.reserveCapacity(stored.count)
        for r in runs where r.kind == .store {
            for s in stored[Int(r.first)..<Int(r.first + r.count)] {
                out.append(CASC.Location(key: s.key, dataFile: Int(r.dataFile), offset: s.offset, size: UInt32(CASC.headerSize) + s.size))
            }
        }
        return out
    }

    /// The sixteen journals naming every object and every data file's head.
    public func journals() -> [[UInt8]] { CASC.journals(objects: locations, dataFiles: dataFiles) }
}
