// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b's xodus-store-updates patch
// (store_updates.rs: GetBasePackage's version against the installed one, four
// 16-bit numbers compared, anything unverified is "unknown") and src/main/
// game-updates.ts; translated to Swift by the Playport authors, 2026-10-30.
// Modified: the content ID is the install record's, not displaycatalog's; an update
// is installed by comparing the installed copy against the new package's own hashes
// (MSIXVC: page by page against its hash tree; MSIXVC2: segment by segment) and
// fetching only what differs, through ContentKit's resumable engine.
import Foundation
import ContentKit

/// A package version: four dot-separated 16-bit numbers (`1.5.12620.0`), compared
/// number by number.
public struct XboxPackageVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [UInt16]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt16] = []
        for p in parts {
            guard !p.isEmpty, p.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt16(p) else { return nil }
            out.append(n)
        }
        self.parts = out
    }

    public static func < (a: XboxPackageVersion, b: XboxPackageVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

extension XboxInstaller {
    /// The Store's latest package for the installed copy `product` against the
    /// record's version: GetBasePackage for the record's content ID. Throws when the
    /// copy has no record, Microsoft can't be asked, or either version isn't one.
    public func updateCheck(_ product: String) async throws -> XboxPackageUpdateCheck {
        guard let rec = loadRecord(product) else { throw ClientError.notFound("no Xbox install record for \(product)") }
        return try await updateCheck(product, contentID: rec.contentID, installed: rec.version)
    }

    func updateCheck(_ product: String, contentID: String, installed: String) async throws -> XboxPackageUpdateCheck {
        guard let have = XboxPackageVersion(installed) else { throw ClientError.unsupported("the installed Xbox version \(installed) is not a package version") }
        let location = try await services.packageLocation(contentID: contentID)
        guard let latest = XboxPackageVersion(location.version) else {
            throw ClientError.protocolChanged("Xbox packages named no package version")
        }
        log.info("xbox", "\(product): installed \(have), the Store's \(latest)")
        return latest > have ? .available(latest: latest.description) : .current(latest: latest.description)
    }

    public struct UpdateResult: Sendable {
        public var installed: XboxInstalled
        /// Bytes fetched from the CDN: the new package's metadata and what changed.
        public var downloadedBytes: UInt64
        /// Bytes the stage wrote (changed files, whole).
        public var bytesWritten: UInt64
        /// Bytes of the staged files taken from the installed copy rather than fetched.
        public var reusedBytes: UInt64
        /// Files written (changed or new) and removed.
        public var filesChanged: Int
        public var filesRemoved: Int
        /// Installed again whole: the copy's folder was gone.
        public var reinstalled: Bool
    }

    /// Updates the installed copy `product` to the Store's latest package. Every file
    /// the new package has is compared with the installed one at the same path against
    /// the new package's hashes: MSIXVC page by page (its hash tree), MSIXVC2 segment by
    /// segment. A file that matches whole stays as it is; any other is staged whole,
    /// its matching pages or segments copied from the installed file and only the rest
    /// fetched. Staged files then replace the installed ones; files the package no
    /// longer has are removed. An interrupted update leaves the copy as it was and
    /// resumes from its journal. With the copy's folder gone it is installed again.
    public func update(product: String, title: String, options: InstallEngine.Options = .init(),
                       progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> UpdateResult {
        guard let old = loadRecord(product) else { throw ClientError.notFound("no Xbox install record for \(product)") }
        let folder = layout.gamesRoot.appendingPathComponent(old.installDir, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            log.info("xbox", "\(product): its folder is gone; installing it again whole")
            let r = try await install(product: product, contentID: old.contentID, title: title, options: options, progress: progress)
            return UpdateResult(installed: r.installed, downloadedBytes: r.downloadedBytes, bytesWritten: r.bytesWritten, reusedBytes: 0,
                                filesChanged: r.installed.files.count, filesRemoved: 0, reinstalled: true)
        }
        let location = try await services.packageLocation(contentID: old.contentID)
        if let have = XboxPackageVersion(old.version), let latest = XboxPackageVersion(location.version), latest <= have {
            log.info("xbox", "\(product): \(old.version) is the Store's latest (\(location.version)); nothing to update")
            return UpdateResult(installed: old, downloadedBytes: 0, bytesWritten: 0, reusedBytes: 0, filesChanged: 0, filesRemoved: 0, reinstalled: false)
        }
        let keys = try await contentKeys(location.contentID)
        let name = stageName(product, location.version.isEmpty ? "0" : location.version) + "-update"
        let remote = bytes(location)
        let metadata = Self.metadataProgress(location, progress)
        let installed = XboxInstalledCopy(record: old, folder: folder)
        let delta = location.isMSIXVC2
            ? try await deltaMSIXVC2(location, remote: remote, name: name, keys: keys, from: installed, metadata: metadata)
            : try await deltaMSIXVC(location, remote: remote, name: name, keys: keys, from: installed, metadata: metadata)
        let plan = delta.plan
        let reusable = plan.chunks.reduce(UInt64(0)) { $0 + (delta.source.local[$1.key] == nil ? 0 : UInt64($1.size)) }
        log.info("xbox", "\(product) \(old.version) -> \(delta.version): \(plan.files.count) files to write (\(plan.totalBytes) bytes, "
                 + "\(reusable) of them from the installed copy), \(delta.unchanged.count) unchanged")

        let tree = layout.stagingTree(name: name)
        var written: UInt64 = 0
        if !plan.files.isEmpty {
            let engine = InstallEngine(tree: tree, journal: layout.journal(name: name), source: delta.source, log: log, options: options)
            written = try await engine.run(plan, progress: progress).bytes
        }
        var staged = try delta.finish(tree)

        // The staged files replace the installed ones, then the files the package no longer has go.
        for f in plan.files {
            try Task.checkCancellation()
            let src = try InstallFS.resolveInside(tree, f.path, createParents: false)
            let dst = try InstallFS.resolveInside(folder, f.path, createParents: true)
            guard rename(src.path, dst.path) == 0 else { throw ClientError.transport("cannot place \(f.path) (errno \(errno))") }
        }
        let now = Set(delta.paths.map { $0.lowercased() })
        let dropped = old.files.filter { !now.contains($0.path.lowercased()) }
        for f in dropped {
            if let url = try? InstallFS.resolveInside(folder, f.path, createParents: false) { try? FileManager.default.removeItem(at: url) }
        }
        if staged.config == nil, let path = delta.configPath, let url = try? InstallFS.resolveInside(folder, path, createParents: false),
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue <= 4 << 20 {
            staged.config = (try? Data(contentsOf: url)).map(Array.init)
        }
        var byPath: [String: XboxInstalledFile] = [:]
        for f in delta.unchanged + staged.files { byPath[f.path] = f }
        let record = XboxInstalled(productID: product, contentID: location.contentID, version: delta.version, packageName: delta.packageName,
                                   installDir: old.installDir, config: staged.config, files: delta.paths.compactMap { byPath[$0] },
                                   encrypted: staged.encrypted)
        try writeRecord(record)
        log.info("xbox", "\(product) updated to \(delta.version): \(plan.files.count) files written, \(dropped.count) removed, "
                 + "\(delta.source.fetchedBytes) bytes fetched, \(delta.source.localBytes) reused")
        return UpdateResult(installed: record, downloadedBytes: delta.source.fetchedBytes + delta.metadataBytes, bytesWritten: written,
                            reusedBytes: delta.source.localBytes, filesChanged: plan.files.count, filesRemoved: dropped.count, reinstalled: false)
    }

    /// An update's work: the files to stage (from the installed copy where they match,
    /// else the CDN), the files that match whole, and how to check the stage.
    struct Delta {
        var plan: ContentPlan
        var source: XboxDeltaSource
        var unchanged: [XboxInstalledFile]
        /// Every file of the new package, in its order.
        var paths: [String]
        var version: String
        var packageName: String
        var metadataBytes: UInt64
        var configPath: String?
        var finish: (URL) throws -> (files: [XboxInstalledFile], config: [UInt8]?, encrypted: [XboxEncryptedFile])
    }

    /// MSIXVC: each installed page against the new package's level-0 hash entry for it,
    /// as the package stores it (a decrypted page is encrypted again with its data unit).
    func deltaMSIXVC(_ location: XboxPackageLocation, remote: any XboxPackageBytes, name: String, keys: [UUID: [UInt8]],
                     from copy: XboxInstalledCopy, metadata: @escaping @Sendable (UInt64) -> Void) async throws -> Delta {
        let package = try await fetchMSIXVC(location, remote: remote, name: name, metadata: metadata)
        let source = try XboxPackageSource(package: package, prefix: prefixFile(name), remote: remote, keys: keys, log: log)
        let page = UInt64(XboxXVD.page)
        var files: [ContentFile] = [], chunks: [ContentChunk] = [], local: [[UInt8]: XboxDeltaSource.Local] = [:]
        var unchanged: [XboxInstalledFile] = [], directories = Set<String>(), staged: [XboxPackageFile] = []
        for f in package.files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let mode: XboxChunk.Mode = f.keepEncrypted ? .keep : (f.region != nil ? .decrypt : .plain)
            let old = copy.file(f.path, kept: f.keepEncrypted)
            var matched: [Bool] = []
            if let old, let offset = f.offset {
                let scan = try copy.scan(old, pages: Int(f.pages), wholeSize: f.installedSize) { first, bytes in
                    let entries = try source.entries(offset / page + UInt64(first), bytes.count / Int(page))
                    return (0..<entries.count).map { i in
                        source.installedPageMatches(Array(bytes[(i * Int(page))..<((i + 1) * Int(page))]), number: offset / page + UInt64(first + i),
                                                    entry: entries[i], mode: mode)
                    }
                }
                matched = scan.matched
                if let sha1 = scan.sha1, old.path == f.path, !matched.contains(false) {
                    unchanged.append(XboxInstalledFile(path: f.path, size: f.installedSize, sha1: sha1.hex)); continue
                }
            } else if let old, f.offset == nil, old.size == 0, old.path == f.path, copy.exists(old) {
                unchanged.append(XboxInstalledFile(path: f.path, size: 0, sha1: SHA1.hash([]).hex)); continue
            }
            var dir = f.path.split(separator: "/").dropLast()
            while !dir.isEmpty { directories.insert(dir.joined(separator: "/")); dir.removeLast() }
            var parts: [ContentPart] = []
            if let offset = f.offset, f.size > 0 {
                var done = 0
                let pages = Int(f.pages)
                while done < pages {
                    let reuse = matched.isEmpty ? false : matched[done]
                    var n = 1
                    while done + n < pages, n < XboxChunk.maxPages, (matched.isEmpty ? false : matched[done + n]) == reuse { n += 1 }
                    let at = offset + UInt64(done) * page
                    let length = UInt32(min(UInt64(n) * page, f.installedSize - UInt64(done) * page))
                    let fetch = ContentChunk(key: XboxChunk(offset: at, pages: n, mode: mode).key, size: length,
                                             compressedSize: UInt32(n) * UInt32(page), check: .none)
                    var chunk = fetch
                    if reuse, let old {
                        chunk.key = XboxDeltaSource.localKey(file: files.count, offset: UInt64(done) * page, fetch.key)
                        let first = at / page, count = n
                        local[chunk.key] = XboxDeltaSource.Local(url: copy.url(old), offset: UInt64(done) * page, count: n * Int(page), fetch: fetch) { bytes in
                            guard let entries = try? source.entries(first, count) else { return false }
                            return (0..<count).allSatisfy { i in
                                source.installedPageMatches(Array(bytes[(i * Int(page))..<((i + 1) * Int(page))]), number: first + UInt64(i),
                                                            entry: entries[i], mode: mode)
                            }
                        }
                    }
                    parts.append(ContentPart(chunk: chunks.count, length: length, fileOffset: UInt64(done) * page))
                    chunks.append(chunk)
                    done += n
                }
            }
            files.append(ContentFile(path: f.path, size: f.installedSize, hash: .none, parts: parts))
            staged.append(f)
        }
        let delta = XboxDeltaSource(remote: source, local: local, log: log)
        let plan = ContentPlan(files: files, directories: directories.sorted(), chunks: chunks,
                               identity: XboxDeltaSource.identity(package.plan().identity, files: files, chunks: chunks))
        return Delta(plan: plan, source: delta, unchanged: unchanged, paths: package.files.map(\.path), version: package.version,
                     packageName: package.packageName, metadataBytes: package.prefixBytes, configPath: nil) { tree in
            (try Self.checked(staged, in: tree), package.gameConfig, try package.encryptedLayout(source))
        }
    }

    /// MSIXVC2: each segment of a file against the installed file's bytes at the same
    /// offset, by the segment's own hash.
    func deltaMSIXVC2(_ location: XboxPackageLocation, remote: any XboxPackageBytes, name: String, keys: [UUID: [UInt8]],
                      from copy: XboxInstalledCopy, metadata: @escaping @Sendable (UInt64) -> Void) async throws -> Delta {
        let package = try await fetchMSIXVC2(location, remote: remote, name: name, keys: keys, metadata: metadata)
        let source = XboxMSIXVC2Source(package: package, remote: remote, log: log)
        var files: [ContentFile] = [], chunks: [ContentChunk] = [], index: [[UInt8]: Int] = [:], local: [[UInt8]: XboxDeltaSource.Local] = [:]
        var unchanged: [XboxInstalledFile] = [], directories = Set<String>(), staged: [XboxMSIXVC2File] = []
        for f in package.files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let old = copy.file(f.path, kept: false)
            var matched: [Bool] = []
            if let old {
                var sha1 = SHA1Stream(), whole = old.size == f.size && copy.exists(old)
                let handle = try? XboxLocalFile(copy.url(old))
                var at: UInt64 = 0
                for s in f.segments where s.length > 0 {
                    try Task.checkCancellation()
                    var ok = false
                    if let handle, at + UInt64(s.length) <= handle.size, let bytes = try? handle.read(at, s.length) {
                        ok = s.hash.matches(bytes)
                        if whole { bytes.withUnsafeBytes { sha1.update($0) } }
                    }
                    matched.append(ok)
                    at += UInt64(s.length)
                }
                whole = whole && handle != nil && !matched.contains(false)
                if whole, old.path == f.path {
                    unchanged.append(XboxInstalledFile(path: f.path, size: f.size, sha1: sha1.finalize().hex)); continue
                }
            }
            var dir = f.path.split(separator: "/").dropLast()
            while !dir.isEmpty { directories.insert(dir.joined(separator: "/")); dir.removeLast() }
            var parts: [ContentPart] = [], at: UInt64 = 0, n = 0
            for s in f.segments where s.length > 0 {
                let key = XboxMSIXVC2Chunk(offset: package.boxData[s.box] + s.boxOffset, boxLength: UInt32(s.boxLength), length: UInt32(s.length),
                                           keyIndex: UInt32(f.keyIndex), hash: s.hash.bytes).key
                let fetch = ContentChunk(key: key, size: UInt32(s.length), compressedSize: UInt32(s.boxLength), check: .none)
                let chunk: Int
                if n < matched.count, matched[n], let old {
                    let lkey = XboxDeltaSource.localKey(file: files.count, offset: at, key)
                    chunk = chunks.count
                    chunks.append(ContentChunk(key: lkey, size: UInt32(s.length), compressedSize: 0, check: .none))
                    let hash = s.hash
                    local[lkey] = XboxDeltaSource.Local(url: copy.url(old), offset: at, count: s.length, fetch: fetch) { hash.matches($0) }
                } else if let have = index[key] {
                    chunk = have
                } else {
                    chunk = chunks.count
                    index[key] = chunk
                    chunks.append(fetch)
                }
                parts.append(ContentPart(chunk: chunk, length: UInt32(s.length), fileOffset: at))
                at += UInt64(s.length)
                n += 1
            }
            files.append(ContentFile(path: f.path, size: f.size, hash: .none, parts: parts))
            staged.append(f)
        }
        let delta = XboxDeltaSource(remote: source, local: local, log: log)
        let plan = ContentPlan(files: files, directories: directories.sorted(), chunks: chunks,
                               identity: XboxDeltaSource.identity(package.plan().identity, files: files, chunks: chunks))
        return Delta(plan: plan, source: delta, unchanged: unchanged, paths: package.files.map(\.path), version: package.version,
                     packageName: Self.packageName(location), metadataBytes: package.metadataBytes, configPath: package.gameConfigPath) { tree in
            let (files, config) = try Self.checked(staged, of: package, in: tree)
            return (files, config, [])
        }
    }
}

/// The installed copy an update reads from: its record's files in its folder.
struct XboxInstalledCopy {
    let folder: URL
    private let byPath: [String: XboxInstalledFile]
    private let kept: Set<String>

    init(record: XboxInstalled, folder: URL) {
        self.folder = folder
        byPath = Dictionary(record.files.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        kept = Set(record.encrypted.map { $0.path.lowercased() })
    }

    /// The installed file at `path` (any case) when it is stored the same way: kept
    /// encrypted (its pages as the package has them) or decrypted.
    func file(_ path: String, kept wantKept: Bool) -> XboxInstalledFile? {
        guard let f = byPath[path.lowercased()], kept.contains(path.lowercased()) == wantKept else { return nil }
        return f
    }

    func url(_ f: XboxInstalledFile) -> URL { (try? InstallFS.resolveInside(folder, f.path, createParents: false)) ?? folder.appendingPathComponent(f.path) }
    func exists(_ f: XboxInstalledFile) -> Bool { FileManager.default.fileExists(atPath: url(f).path) }

    /// Reads the installed file page by page (pages past its end are missing, a last
    /// partial page is zero-filled), asks `check` which pages of each run match, and
    /// takes its SHA-1 when it is `wholeSize` bytes.
    func scan(_ f: XboxInstalledFile, pages: Int, wholeSize: UInt64,
              check: (Int, [UInt8]) throws -> [Bool]) throws -> (matched: [Bool], sha1: [UInt8]?) {
        guard let handle = try? XboxLocalFile(url(f)) else { return ([Bool](repeating: false, count: pages), nil) }
        let page = XboxXVD.page
        var matched: [Bool] = [], sha1 = SHA1Stream()
        let whole = handle.size == wholeSize
        var first = 0
        while first < pages {
            try Task.checkCancellation()
            let n = min(pages - first, XboxChunk.maxPages)
            let at = UInt64(first * page)
            guard at < handle.size else { matched += [Bool](repeating: false, count: pages - first); break }
            var bytes = try handle.read(at, Int(min(UInt64(n * page), handle.size - at)))
            if whole { bytes.withUnsafeBytes { sha1.update($0) } }
            let have = (bytes.count + page - 1) / page
            bytes += [UInt8](repeating: 0, count: have * page - bytes.count)
            matched += try check(first, bytes)
            matched += [Bool](repeating: false, count: n - have)
            first += n
        }
        return (matched, whole ? sha1.finalize() : nil)
    }
}

extension XboxPackageSource {
    /// Whether an installed page is the package's page `number`: a kept-encrypted or
    /// plain page as it is; a decrypted one encrypted again with its entry's data unit.
    func installedPageMatches(_ installed: [UInt8], number: UInt64, entry: [UInt8], mode: XboxChunk.Mode) -> Bool {
        var bytes = installed
        if mode == .decrypt {
            guard let region = package.regions.first(where: { $0.keyIndex != nil && number >= $0.start && number < $0.end })?.id,
                  let cipher = ciphers[region] else { return false }
            cipher.encrypt(&bytes, units: [entry.readLE32(at: 20)][...])
        }
        return bytes.withUnsafeBytes { package.tree.matches($0, number: number, entry: entry) }
    }
}

/// An update's chunks: those the installed copy holds are read from it and checked
/// again (one that no longer matches is fetched instead); every other one comes from
/// the package. Counts what came from where.
final class XboxDeltaSource: ContentChunkSource, @unchecked Sendable {
    struct Local {
        var url: URL
        var offset: UInt64
        var count: Int
        /// The same bytes from the package.
        var fetch: ContentChunk
        var matches: @Sendable ([UInt8]) -> Bool
    }

    let remote: any ContentChunkSource
    let local: [[UInt8]: Local]
    let log: Logger
    private let lock = NSLock()
    private var fetched: UInt64 = 0, reused: UInt64 = 0

    init(remote: any ContentChunkSource, local: [[UInt8]: Local], log: Logger) {
        self.remote = remote; self.local = local; self.log = log
    }

    var fetchedBytes: UInt64 { lock.withLock { fetched } }
    /// Bytes taken from the installed copy.
    var localBytes: UInt64 { lock.withLock { reused } }

    static func localKey(file: Int, offset: UInt64, _ fetch: [UInt8]) -> [UInt8] {
        var k = Array("local".utf8); k.appendLE(UInt32(file)); k.appendLE(offset)
        return k + fetch
    }

    static func identity(_ package: [UInt8], files: [ContentFile], chunks: [ContentChunk]) -> [UInt8] {
        var id = Array("xbox-update/1".utf8) + package
        for f in files { id += Array(f.path.utf8) + [0] }
        for c in chunks { id += c.key }
        return SHA1.hash(id)
    }

    func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        var want = c
        if let l = local[c.key] {
            if let handle = try? XboxLocalFile(l.url), l.offset < handle.size,
               var bytes = try? handle.read(l.offset, Int(min(UInt64(l.count), handle.size - l.offset))) {
                bytes += [UInt8](repeating: 0, count: l.count - bytes.count)
                if l.matches(bytes) {
                    bytes.removeLast(bytes.count - Int(c.size))
                    lock.withLock { reused += UInt64(c.size) }
                    return bytes
                }
            }
            log.warn("xbox", "an installed file changed since the update read it; fetching its part from the package")
            want = l.fetch
        }
        let bytes = try await remote.chunk(want)
        lock.withLock { fetched += UInt64(want.compressedSize) }
        return bytes
    }
}

/// The bridge's package update check (STORE_PACKAGE_UPDATES_REQUEST): the running
/// copy's record names its content ID, GetBasePackage its latest version, compared
/// with the version the runtime sends. Anything not verified is `.unknown`.
public struct XboxUpdateChecker: XboxPackageUpdates {
    let installer: XboxInstaller
    let timeout: TimeInterval

    /// `timeout`: Xodus Nexus's 60 seconds.
    public init(installer: XboxInstaller, timeout: TimeInterval = 60) {
        self.installer = installer; self.timeout = timeout
    }

    public func check(productID: String, installedVersion: String) async -> XboxPackageUpdateCheck {
        guard let rec = installer.loadRecord(productID), XboxPackageVersion(installedVersion) != nil else { return .unknown }
        let installer = self.installer, seconds = timeout
        do {
            return try await withThrowingTaskGroup(of: XboxPackageUpdateCheck.self) { group in
                group.addTask { try await installer.updateCheck(productID, contentID: rec.contentID, installed: installedVersion) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw ClientError.transport("the Xbox update check timed out")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? .unknown
            }
        } catch {
            installer.log.warn("xbox", "\(productID): update check not verified: \(error)")
            return .unknown
        }
    }
}
