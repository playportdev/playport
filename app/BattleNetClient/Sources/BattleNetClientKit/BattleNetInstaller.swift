// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Fetches a plan's chunks: a store run is one ranged read (or one loose object) whose objects
/// are each checked against their EKey and every block's hash, then written with their local
/// headers; a product folder file is its object decoded and checked against its CKey.
struct BattleNetChunkSource: ContentChunkSource {
    let client: BattleNetClient
    let plan: BattleNetInstallPlan
    let attempts = 3

    func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        let run = plan.runs[Int(c.group)]
        switch run.kind {
        case .head:
            return CASC.segmentHeader(dataFile: Int(run.dataFile))
        case .store:
            let body = try await fetch(run, key: plan.stored[Int(run.first)].key)
            var out = [UInt8]()
            out.reserveCapacity(Int(c.size))
            for s in plan.stored[Int(run.first)..<Int(run.first + run.count)] {
                let at = Int(s.archiveOffset - run.offset)
                let blob = Array(body[at..<(at + Int(s.size))])
                try BLTE.verify(blob, ekey: s.key.hash)
                out += CASC.header(s.key, size: blob.count, dataFile: Int(run.dataFile), offset: s.offset)
                out += blob
            }
            return out
        case .file:
            let f = plan.files[Int(run.first)]
            return try BLTE.decode(try await fetch(run, key: f.ekey), ekey: f.ekey.hash, ckey: f.ckey, keys: client.keys)
        }
    }

    /// A store run read back on resume: every header's checksums, key and size, and every
    /// object's EKey and block hashes.
    func matches(_ c: ContentChunk, _ plain: [UInt8]) -> Bool {
        let run = plan.runs[Int(c.group)]
        guard run.kind == .store else { return c.matches(plain) }
        var at = 0
        for s in plan.stored[Int(run.first)..<Int(run.first + run.count)] {
            guard let h = CASC.readHeader(plain[at...], dataFile: Int(run.dataFile), offset: s.offset),
                  h.key == s.key, h.size == Int(s.size), at + CASC.headerSize + h.size <= plain.count,
                  (try? BLTE.verify(Array(plain[(at + CASC.headerSize)..<(at + CASC.headerSize + h.size)]), ekey: s.key.hash)) != nil
            else { return false }
            at += CASC.headerSize + h.size
        }
        return at == plain.count
    }

    /// The run's bytes, a few times over before giving up on the network or a damaged answer.
    func fetch(_ run: BattleNetInstallPlan.Run, key: PackedKey) async throws -> [UInt8] {
        var attempt = 0
        while true {
            do {
                if run.archive < 0 { return try await client.object(key.hash, size: Int(run.length), from: plan.build.cdn) }
                return try await client.archiveRange(plan.archives[Int(run.archive)], offset: UInt64(run.offset), length: Int(run.length),
                                                     from: plan.build.cdn)
            } catch let e as BattleNetError {
                // A missing key, an unsupported format or an outdated install is the same on every try.
                switch e {
                case .missingKey, .unsupported, .outdated: throw e
                case .unreachable, .refused, .damaged: break
                }
                attempt += 1
                guard attempt < attempts else { throw e }
                try await client.manners.sleep(Double(attempt) * client.manners.backoff)
            }
        }
    }
}

/// Installs a WoW product from Blizzard's CDN into the layout the game reads:
///
///     <root>/.build.info                the build, CDN and tags (written last)
///     <root>/Data/config/xx/yy/<hash>   build, CDN and key ring configs
///     <root>/Data/indices/<hash>.index  every CDN index and the archive group
///     <root>/Data/data/data.NNN, *.idx  the store and its sixteen journals
///     <root>/<product folder>/          the install manifest's files (`_retail_/Wow.exe`)
///
/// The work area (`work`, beside the root by default) keeps the CDN's indexes and manifests,
/// ContentKit's stage and its journal, so an interrupted install resumes where it stopped; the
/// finished stage becomes the root by one rename.
public struct BattleNetInstaller: Sendable {
    public let client: BattleNetClient
    public let log: Logger
    /// The engine's options; `concurrency` defaults to the client's request limit.
    public var engine: InstallEngine.Options
    /// The volume query; tests substitute a fixed figure.
    public var freeSpace: (@Sendable (URL) throws -> UInt64)?

    public init(client: BattleNetClient, log: Logger = .silent) {
        self.client = client
        self.log = log
        engine = InstallEngine.Options()
        engine.concurrency = client.manners.maxConcurrent
    }

    /// A plan, and what its commit writes besides the plan's files.
    public struct Prepared: Sendable {
        public let plan: BattleNetInstallPlan
        public let cdnConfig: CDNConfig
        /// The build's own configs by hash: build, CDN and key ring.
        public let configs: [TACTHash]
        /// Every CDN index the store keeps, by name.
        public let indexes: [TACTHash]
        public let installSize: UInt64
        /// The client with the build's key ring added.
        public let client: BattleNetClient
        /// The x64 client Play starts, under the install root as the install manifest spells it
        /// (`_retail_/Wow.exe`): from the build's whole selection, so an update that leaves the
        /// client's file alone (it is on disk already) names it too.
        public let clientPath: String
    }

    public struct Result: Sendable {
        public let engine: InstallEngine.Result
        /// Whether the archive group built here hashes to the CDN config's name for it (it is
        /// written only then).
        public let archiveGroup: Bool
        public let seconds: Double
    }

    static func workArea(for root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent).install")
    }

    // MARK: prepare

    /// Asks for the product's current build in `region` and plans its install: the build's
    /// configs, manifests and every CDN index are fetched into `work` (kept for a resume).
    public func prepare(_ product: BattleNetProduct, _ region: StoreRegion, options: BattleNetInstallOptions,
                        work: URL) async throws -> Prepared {
        let build = try await client.build(product, region)
        let r = try await read(build, work: work)
        let selection = try BattleNetSelection(build: build, download: r.download, install: r.install, encoding: r.encoding, options: options)
        // Play starts only the x64 client (decision 0177): a build whose selection lacks it is
        // refused here, before any of it is downloaded.
        let clientPath = try Self.clientPath(selection, build)
        let cdnConfig = r.cdnConfig, meta = r.meta

        log.info("battlenet", "\(cdnConfig.archives.count) archive indexes")
        let locations = try await locate(selection.wanted, cdnConfig.archives, meta: meta, build: build)
        let others = try await otherIndexes(cdnConfig, meta: meta, build: build)
        let plan = try BattleNetInstallPlan(build: build, archives: cdnConfig.archives, selection: selection, locations: locations,
                                            options: options)
        return Prepared(plan: plan, cdnConfig: cdnConfig, configs: r.configs, indexes: cdnConfig.archives + others,
                        installSize: Self.installSize(build), client: r.client, clientPath: clientPath)
    }

    /// The x64 client's path in `selection` (Prepared.clientPath); a selection without it is
    /// refused, since Play starts nothing else.
    static func clientPath(_ selection: BattleNetSelection, _ build: BattleNetBuild) throws -> String {
        guard let client = selection.client(build.productConfig) else {
            throw BattleNetError.unsupported("\(build.product.code) \(build.version.versionsName): the build has no x64 client "
                                             + "(\(build.productConfig.x64Executable ?? "none named"))")
        }
        return client.path
    }

    /// The build's patch archive indexes and its file and patch file indexes, which the store
    /// keeps beside the archive indexes: fetched into `meta` unless `installed` has them.
    func otherIndexes(_ cdnConfig: CDNConfig, meta: URL, build: BattleNetBuild, installed: URL? = nil) async throws -> [TACTHash] {
        let patchArchives = (cdnConfig.config["patch-archives"] ?? []).compactMap { TACTHash(hex: $0) }
        try await forEachIndex(patchArchives, patch: true, meta: meta, build: build, installed: installed) { _, _ in }
        var others = [TACTHash]()
        for (name, patch) in [("file-index", false), ("patch-file-index", true)] {
            guard let key = cdnConfig.config[name]?.first.flatMap({ TACTHash(hex: $0) }) else { continue }
            try await forEachIndex([key], patch: patch, meta: meta, build: build, installed: installed) { _, _ in }
            others.append(key)
        }
        return patchArchives + others
    }

    /// The install size the build config names (`IM Size` in `.build.info`).
    static func installSize(_ build: BattleNetBuild) -> UInt64 {
        build.config.config["install-size"].flatMap { $0.count >= 2 ? UInt64($0[1]) : nil } ?? 0
    }

    /// What a plan is made from: the build's configs (kept in `meta`), the client with its key
    /// ring, and its install, download and encoding manifests.
    struct Reading {
        let meta: URL
        let client: BattleNetClient
        let cdnConfig: CDNConfig
        let configs: [TACTHash]
        let install: InstallManifest
        let download: DownloadManifest
        let encoding: EncodingTable
    }

    /// Reads `build`'s configs and manifests, from `work` when a checked copy is there, else
    /// from the CDN (kept in `work`).
    func read(_ build: BattleNetBuild, work: URL) async throws -> Reading {
        guard build.config.config["build-file-db"] == nil else {
            throw BattleNetError.unsupported("\(build.product.code) \(build.version.versionsName) is a containerless build")
        }
        let meta = work.appendingPathComponent("meta")
        try InstallFS.makeDirectory(meta)
        var configs = [build.version.buildConfig, build.version.cdnConfig]
        try save(meta, build.version.buildConfig, try await client.config(build.version.buildConfig, from: build.cdn))
        let (cdnConfig, cdnBytes) = try await client.cdnConfig(build)
        try save(meta, build.version.cdnConfig, cdnBytes)
        var client = self.client
        if let ring = build.version.keyRing {
            let bytes = try await client.config(ring, from: build.cdn)
            try save(meta, ring, bytes)
            configs.append(ring)
            client = client.adding(keys: try TACTKeyring(keyRingConfig: bytes))
        }

        let config = build.config.config
        func manifest(_ name: String) async throws -> [UInt8] {
            let pair = try config.keyPair(name, what: "build config")
            let size = config["\(name)-size"].flatMap { $0.count >= 2 ? Int($0[1]) : nil }
            let url = meta.appendingPathComponent(pair.ekey.hex)
            if let cached = try? [UInt8](Data(contentsOf: url)), (try? BLTE.verify(cached, ekey: pair.ekey)) != nil {
                return try BLTE.decode(cached, ekey: pair.ekey, ckey: pair.ckey, keys: client.keys)
            }
            let raw = try await client.object(pair.ekey, size: size, from: build.cdn)
            try InstallFS.writeAtomically(url, Data(raw))
            return try BLTE.decode(raw, ekey: pair.ekey, ckey: pair.ckey, keys: client.keys)
        }
        log.info("battlenet", "\(build.product.code) \(build.region.rawValue) \(build.version.versionsName): reading the manifests")
        return Reading(meta: meta, client: client, cdnConfig: cdnConfig, configs: configs, install: try InstallManifest(try await manifest("install")),
                       download: try DownloadManifest(try await manifest("download")), encoding: try EncodingTable(try await manifest("encoding")))
    }

    /// Where the `wanted` objects are in `archives`, by their indexes (an installed store's
    /// copies of them in `installed/Data/indices` are read before the CDN is asked).
    func locate(_ wanted: Set<PackedKey>, _ archives: [TACTHash], meta: URL, build: BattleNetBuild,
                installed: URL? = nil) async throws -> ArchiveLocations {
        var locations = ArchiveLocations()
        try await forEachIndex(archives, patch: false, meta: meta, build: build, installed: installed) { i, index in
            locations.add(index, archive: i, wanted: wanted)
        }
        return locations
    }

    func save(_ meta: URL, _ hash: TACTHash, _ bytes: [UInt8]) throws {
        try InstallFS.writeAtomically(meta.appendingPathComponent(hash.hex), Data(bytes))
    }

    /// Each index, from `meta` or an installed store's `Data/indices` when a checked copy is
    /// there, else from the CDN (kept in `meta`), handed to `body` in list order; at most the
    /// client's request limit in flight.
    func forEachIndex(_ keys: [TACTHash], patch: Bool, meta: URL, build: BattleNetBuild, installed: URL? = nil,
                      _ body: (Int, ArchiveIndex) throws -> Void) async throws {
        let client = self.client
        try await withThrowingTaskGroup(of: (Int, ArchiveIndex).self) { group in
            var next = 0, running = 0
            var ready = [Int: ArchiveIndex](), emitted = 0
            while emitted < keys.count {
                while running < max(1, client.manners.maxConcurrent), next < keys.count {
                    let i = next, key = keys[i]
                    next += 1
                    running += 1
                    group.addTask {
                        let url = meta.appendingPathComponent(key.hex + ".index")
                        for copy in [url] + (installed.map { [$0.appendingPathComponent("Data/indices/\(key.hex).index")] } ?? []) {
                            if let cached = try? [UInt8](Data(contentsOf: copy)), let index = try? ArchiveIndex(cached, name: key) {
                                return (i, index)
                            }
                        }
                        let (index, bytes) = try await client.index(key, patch: patch, from: build.cdn)
                        try InstallFS.writeAtomically(url, Data(bytes))
                        return (i, index)
                    }
                }
                guard let (i, index) = try await group.next() else { break }
                running -= 1
                ready[i] = index
                while let r = ready.removeValue(forKey: emitted) {
                    try body(emitted, r)
                    emitted += 1
                }
            }
        }
    }

    // MARK: install

    /// Installs `prepared` into `root` (which must not hold anything else): stages the plan
    /// through ContentKit, then writes the configs, indexes, journals and `.build.info`, and
    /// renames the stage to `root`. Run again after an interruption, it resumes.
    public func install(_ prepared: Prepared, into root: URL, work: URL,
                        progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> Result {
        let started = Date()
        let fm = FileManager.default
        let plan = prepared.plan
        if fm.fileExists(atPath: root.path) {
            guard (try fm.contentsOfDirectory(atPath: root.path)).isEmpty else {
                throw ClientError.unsafeContent("\(root.lastPathComponent) is not empty")
            }
            try fm.removeItem(at: root)
        }
        let tree = work.appendingPathComponent("tree")
        var engine = InstallEngine(tree: tree, journal: work.appendingPathComponent("stage.journal"),
                                   source: BattleNetChunkSource(client: prepared.client, plan: plan), log: log, options: engine)
        if let freeSpace { engine.freeSpace = freeSpace }
        let staged = try await engine.run(plan.content, progress: progress)

        // The rest of the layout, into the stage.
        let meta = work.appendingPathComponent("meta")
        for hash in prepared.configs {
            let to = try InstallFS.resolveInside(tree, "Data/config/\(hash.cdnPath)", createParents: true)
            try place(meta.appendingPathComponent(hash.hex), at: to)
        }
        for key in prepared.indexes {
            let to = try InstallFS.resolveInside(tree, "Data/indices/\(key.hex).index", createParents: true)
            try place(meta.appendingPathComponent(key.hex + ".index"), at: to)
        }
        let groupWritten = try writeArchiveGroup(prepared.cdnConfig, meta: meta, into: tree)
        for (bucket, journal) in plan.journals().enumerated() {
            let url = try InstallFS.resolveInside(tree, "Data/data/" + CASC.journalName(bucket: bucket, generation: 1), createParents: true)
            try InstallFS.writeAtomically(url, Data(journal))
        }
        let pc = plan.build.productConfig
        try InstallFS.writeAtomically(try InstallFS.resolveInside(tree, "\(pc.folder)/.flavor.info", createParents: true),
                                      Data("Product Flavor!STRING:0\n\(plan.build.product.code)\n".utf8))
        try InstallFS.writeAtomically(tree.appendingPathComponent(".build.info"), Data(Self.buildInfo(prepared).text.utf8))

        try fm.moveItem(at: tree, to: root)
        try? fm.removeItem(at: work)
        return Result(engine: staged, archiveGroup: groupWritten, seconds: Date().timeIntervalSince(started))
    }

    /// The `.build.info` row for an install: the store region, the build's keys, its CDN and the
    /// install's tags (the x64 client's machine).
    public static func buildInfo(_ prepared: Prepared) -> BuildInfo {
        let plan = prepared.plan, b = plan.build
        return BuildInfo(region: b.region, buildKey: b.version.buildConfig, cdnKey: b.version.cdnConfig,
                         installKey: b.config.install.ekey, installSize: prepared.installSize, cdnPath: b.cdn.path,
                         cdnHosts: b.cdn.hosts, cdnServers: b.cdn.serverText,
                         tags: BuildInfo.tags(platform: b.productConfig.platformTags, machines: b.productConfig.x64Tags,
                                              region: b.region, locale: plan.options.locale),
                         version: b.version.versionsName, product: b.product.code)
    }

    /// A hard link where the volume allows one, else a copy.
    func place(_ from: URL, at to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
    }

    /// Writes the archive group into `dest`'s `Data/indices` when the CDN config names one and
    /// the group built here hashes to that name; whether it was written.
    func writeArchiveGroup(_ cdnConfig: CDNConfig, meta: URL, into dest: URL, installed: URL? = nil) throws -> Bool {
        guard let name = cdnConfig.archiveGroup else { return false }
        let group = try Self.archiveGroup(cdnConfig.archives, meta: meta, installed: installed)
        guard MD5.hash(Array(group.suffix(ArchiveIndex.footerSize))) == name.bytes else {
            log.warn("battlenet", "the archive group built here does not hash to \(name); left for the game to build")
            return false
        }
        try InstallFS.writeAtomically(try InstallFS.resolveInside(dest, "Data/indices/\(name.hex).index", createParents: true), Data(group))
        return true
    }

    /// The archive group: every archive index's entries merged in key order, each with its
    /// archive's place in the CDN config's list (the first archive listing a key keeps it). Each
    /// index is read from `meta`, else from the `installed` store's `Data/indices`.
    static func archiveGroup(_ archives: [TACTHash], meta: URL, installed: URL? = nil) throws -> [UInt8] {
        var entries = [ArchiveIndex.Entry]()
        for (i, key) in archives.enumerated() {
            var url = meta.appendingPathComponent(key.hex + ".index")
            if let installed, InstallFS.fileSize(url) == nil { url = installed.appendingPathComponent("Data/indices/\(key.hex).index") }
            let index = try ArchiveIndex([UInt8](try Data(contentsOf: url)), name: key)
            index.forEach(archive: i) { entries.append($0) }
        }
        entries.sort { ($0.key, $0.archive ?? 0) < ($1.key, $1.archive ?? 0) }
        var unique = [ArchiveIndex.Entry]()
        unique.reserveCapacity(entries.count)
        for e in entries where unique.last?.key != e.key { unique.append(e) }
        return ArchiveIndex.build(unique, offsetBytes: 6)
    }

    // MARK: verify

    public struct Verification: Sendable {
        public var objects = 0
        public var bytes: UInt64 = 0
        public var files = 0
        /// What is wrong, one line each.
        public var damaged = [String]()
        /// Planned objects or files the install lacks.
        public var missing = [String]()
        public var isIntact: Bool { damaged.isEmpty && missing.isEmpty }
    }

    /// Each bucket's newest journal in a store's `Data/data`: its generation and name. A name of
    /// a bucket the store does not have is not a journal.
    static func latestJournals(_ dataDir: URL) throws -> [Int: (generation: UInt32, name: String)] {
        var latest = [Int: (generation: UInt32, name: String)]()
        for name in try FileManager.default.contentsOfDirectory(atPath: dataDir.path) where name.hasSuffix(".idx") && name.count == 14 {
            guard let bucket = Int(name.prefix(2), radix: 16), bucket < CASC.buckets,
                  let gen = UInt32(name.dropFirst(2).prefix(8), radix: 16) else { continue }
            if gen >= latest[bucket]?.generation ?? 0 { latest[bucket] = (gen, name) }
        }
        return latest
    }

    /// Reads the whole install back: every journal entry's local header (both checksums, its
    /// key and size) and object (EKey and every block's hash), that every planned object is in
    /// a journal, and every product folder file against its CKey.
    public static func verify(_ root: URL, plan: BattleNetInstallPlan, concurrency: Int = 8) async throws -> Verification {
        let dataDir = root.appendingPathComponent("Data/data")
        let latest = try latestJournals(dataDir)
        var report = Verification()
        var byFile = [Int: [CASC.Location]]()
        var indexed = Set<PackedKey>()
        for bucket in 0..<CASC.buckets {
            guard let (_, name) = latest[bucket] else {
                report.missing.append("journal \(bucket)")
                continue
            }
            let (b, locations) = try CASC.readJournal([UInt8](try Data(contentsOf: dataDir.appendingPathComponent(name))))
            if b != bucket { report.damaged.append("\(name): names journal \(b)") }
            for l in locations {
                byFile[l.dataFile, default: []].append(l)
                indexed.insert(l.key)
            }
        }
        for s in plan.stored where !indexed.contains(PackedKey(Array(s.key.bytes.prefix(9)) + [UInt8](repeating: 0, count: 7))) {
            report.missing.append("object \(s.key)")
        }

        let results = try await withThrowingTaskGroup(of: Verification.self) { group in
            var out = [Verification]()
            var pending = byFile.sorted { $0.key < $1.key }[...]
            var running = 0
            while !pending.isEmpty || running > 0 {
                while running < concurrency, let (file, locations) = pending.popFirst() {
                    running += 1
                    group.addTask { verifyDataFile(dataDir, file, locations) }
                }
                if let r = try await group.next() {
                    out.append(r)
                    running -= 1
                }
            }
            return out
        }
        for r in results {
            report.objects += r.objects
            report.bytes += r.bytes
            report.damaged += r.damaged
            report.missing += r.missing
        }
        for f in plan.files {
            let url = root.appendingPathComponent(f.path)
            report.files += 1
            if InstallFS.fileSize(url) == nil {
                report.missing.append(f.path)
            } else if !InstallEngine.fileMatches(url, size: f.size, hash: .md5(f.ckey.bytes)) {
                report.damaged.append("\(f.path): does not match \(f.ckey)")
            }
        }
        return report
    }

    static func verifyDataFile(_ dir: URL, _ file: Int, _ locations: [CASC.Location]) -> Verification {
        var r = Verification()
        let name = String(format: "data.%03d", file)
        let fd = sysOpen(dir.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC, 0)
        guard fd >= 0 else {
            r.missing.append(name)
            return r
        }
        defer { _ = sysClose(fd) }
        for l in locations.sorted(by: { $0.offset < $1.offset }) {
            var buf = [UInt8](repeating: 0, count: Int(l.size))
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(l.size), off_t(l.offset)) }
            let at = "\(name)+\(l.offset)"
            guard n == Int(l.size), let h = CASC.readHeader(buf[...], dataFile: file, offset: l.offset) else {
                r.damaged.append("\(at): unreadable or damaged local header")
                continue
            }
            guard h.key.key9 == l.key.key9, CASC.headerSize + h.size == Int(l.size) else {
                r.damaged.append("\(at): header names \(h.key) of \(h.size) bytes")
                continue
            }
            if h.size == 0 { continue }
            do {
                try BLTE.verify(Array(buf[CASC.headerSize...]), ekey: h.key.hash)
                r.objects += 1
                r.bytes += UInt64(h.size)
            } catch {
                r.damaged.append("\(at): \(error)")
            }
        }
        return r
    }
}
