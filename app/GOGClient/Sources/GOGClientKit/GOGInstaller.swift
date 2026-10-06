// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What a GOG install keeps beside its receipt (manifests/gog-<id>.json): the build
/// and every file with its chunks, for verify, repair and the next update. No secret.
public struct GOGInstalled: Codable, Equatable, Sendable {
    public var productID: String
    public var buildID: String
    public var version: String?
    public var installDir: String
    public var files: [GOGDepotFile]
}

/// Installs, updates, verifies and repairs a GOG game in C:\Games through
/// ContentKit's engine (plan 2.2). A first install stages the whole build and
/// commits it with one rename; an update or a repair stages only the files that
/// differ, then moves each into place and removes the files the build dropped.
/// The caller writes the store receipt (it reads goggame-ID.info's play task).
public struct GOGInstaller: Sendable {
    public let layout: InstallLayout
    let session: GOGSession
    let log: Logger

    public init(layout: InstallLayout, session: GOGSession, log: Logger) {
        self.layout = layout
        self.session = session
        self.log = log
    }

    public struct Result: Sendable {
        public var installed: GOGInstalled
        public var bytesWritten: UInt64
        public var downloadedBytes: UInt64
        public var filesChanged: Int
    }

    public func recordFile(_ productID: String) -> URL { layout.manifestsDir.appendingPathComponent("gog-\(productID).json") }

    public func loadRecord(_ productID: String) -> GOGInstalled? {
        (try? Data(contentsOf: recordFile(productID))).flatMap { try? JSONDecoder().decode(GOGInstalled.self, from: $0) }
    }

    func saveRecord(_ r: GOGInstalled) throws {
        try InstallFS.makeDirectory(layout.manifestsDir)
        try InstallFS.writeAtomically(recordFile(r.productID), JSONEncoder().encode(r))
    }

    func stageName(_ productID: String, _ buildID: String, _ suffix: String = "") -> String { "gog-\(productID)_\(buildID)\(suffix)" }

    /// The newest build, or `buildID`'s.
    public func build(_ productID: String, buildID: String? = nil) async throws -> GOGBuild {
        let builds = try await GOGContent.builds(session, productID: productID)
        guard let b = buildID.map({ id in builds.first { $0.buildID == id } }) ?? builds.first else {
            throw ClientError.notFound("GOG has no Windows build \(buildID ?? "") of \(productID) this client can install")
        }
        return b
    }

    /// Installs the game, or updates it to `buildID` (default: the newest).
    public func install(productID: String, buildID: String? = nil, owned: Set<String> = [], language: String = "en-US",
                        options: InstallEngine.Options = .init(),
                        progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> Result {
        let build = try await self.build(productID, buildID: buildID)
        let manifest = try await GOGContent.buildManifest(session, build)
        var files: [GOGDepotFile] = []
        let depots = manifest.selected(language: language, owned: owned)
        guard !depots.isEmpty else { throw ClientError.notFound("GOG lists no Windows depot this client can install") }
        for d in depots { files += try await GOGContent.depot(session, d) }
        if !manifest.dependencies.isEmpty {
            log.info("gog", "\(productID): the build names redistributables \(manifest.dependencies.joined(separator: ", ")); Wine's builtins stand in")
        }
        let plan = try GOGContent.plan(productID: productID, buildID: build.buildID, files: files)
        let union = plan.files.map { f in files.last { $0.path.lowercased() == f.path.lowercased() }! }
        if let old = loadRecord(productID), FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent(old.installDir).path) {
            return try await apply(productID: productID, build: build, files: union, over: old, options: options, progress: progress)
        }
        let folder = Self.unique(try SafePath.normalize(manifest.installDirectory).split(separator: "/").last.map(String.init) ?? productID,
                                 in: layout.gamesRoot)
        let name = stageName(productID, build.buildID)
        let engine = InstallEngine(tree: layout.stagingTree(name: name), journal: layout.journal(name: name),
                                   source: GOGChunkSource(session: session, log: log), log: log, options: options)
        log.info("gog", "\(productID) build \(build.buildID) (\(build.version ?? "?")): \(plan.files.count) files, \(plan.totalBytes) bytes into C:\\Games\\\(folder)")
        let r = try await engine.run(plan, progress: progress)
        let final = layout.gamesRoot.appendingPathComponent(folder, isDirectory: true)
        try InstallFS.makeDirectory(layout.gamesRoot)
        guard rename(layout.stagingTree(name: name).path, final.path) == 0 else {
            throw ClientError.transport("cannot move the GOG install into C:\\Games (errno \(errno))")
        }
        try? FileManager.default.removeItem(at: layout.journal(name: name))
        let rec = GOGInstalled(productID: productID, buildID: build.buildID, version: build.version, installDir: folder, files: union)
        try saveRecord(rec)
        discardStages(productID)
        return Result(installed: rec, bytesWritten: r.bytes, downloadedBytes: r.downloadedBytes, filesChanged: plan.files.count)
    }

    /// An update: stages the files whose chunks changed, moves them in, drops the removed ones.
    func apply(productID: String, build: GOGBuild, files: [GOGDepotFile], over old: GOGInstalled, options: InstallEngine.Options,
               progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> Result {
        let before = Dictionary(old.files.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { _, b in b })
        let changed = files.filter { f in before[f.path.lowercased()].map { $0.chunks.map(\.md5) != f.chunks.map(\.md5) } ?? true }
        let now = Set(files.map { $0.path.lowercased() })
        let dropped = old.files.filter { !now.contains($0.path.lowercased()) }
        log.info("gog", "\(productID): update \(old.buildID) -> \(build.buildID): \(changed.count) files to fetch, \(dropped.count) to remove")
        let r = try await stageAndPlace(productID: productID, tag: build.buildID, files: changed, into: old.installDir,
                                        options: options, progress: progress)
        let dir = layout.gamesRoot.appendingPathComponent(old.installDir, isDirectory: true)
        for f in dropped { if let u = try? InstallFS.resolveInside(dir, f.path, createParents: false) { try? FileManager.default.removeItem(at: u) } }
        let rec = GOGInstalled(productID: productID, buildID: build.buildID, version: build.version, installDir: old.installDir, files: files)
        try saveRecord(rec)
        discardStages(productID)
        return Result(installed: rec, bytesWritten: r?.bytes ?? 0, downloadedBytes: r?.downloadedBytes ?? 0, filesChanged: changed.count + dropped.count)
    }

    /// Stages `files` and moves each into `folder`, replacing what is there.
    func stageAndPlace(productID: String, tag: String, files: [GOGDepotFile], into folder: String, options: InstallEngine.Options,
                       progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> InstallEngine.Result? {
        guard !files.isEmpty else { return nil }
        let plan = try GOGContent.plan(productID: productID, buildID: tag + "+part", files: files)
        let name = stageName(productID, tag, ".part")
        let tree = layout.stagingTree(name: name)
        let engine = InstallEngine(tree: tree, journal: layout.journal(name: name),
                                   source: GOGChunkSource(session: session, log: log), log: log, options: options)
        let r = try await engine.run(plan, progress: progress)
        let dir = layout.gamesRoot.appendingPathComponent(folder, isDirectory: true)
        for f in plan.files {
            let src = try InstallFS.resolveInside(tree, f.path, createParents: false)
            let dst = try InstallFS.resolveInside(dir, f.path, createParents: true)
            guard rename(src.path, dst.path) == 0 else { throw ClientError.transport("cannot place \(f.path) (errno \(errno))") }
        }
        try? FileManager.default.removeItem(at: tree)
        try? FileManager.default.removeItem(at: layout.journal(name: name))
        return r
    }

    public struct VerifyReport: Sendable {
        public var files: Int
        public var bad: [String]
    }

    /// Every file of the kept record, by size then md5 (the file's, or each chunk's).
    public func verify(productID: String) async throws -> VerifyReport {
        guard let rec = loadRecord(productID) else { throw ClientError.notFound("no GOG install record for \(productID)") }
        let dir = layout.gamesRoot.appendingPathComponent(rec.installDir, isDirectory: true)
        var bad: [String] = []
        for f in rec.files {
            try Task.checkCancellation()
            if !(try Self.matches(dir, f)) { bad.append(f.path) }
        }
        return VerifyReport(files: rec.files.count, bad: bad)
    }

    static func matches(_ dir: URL, _ f: GOGDepotFile) throws -> Bool {
        guard let url = try? InstallFS.resolveInside(dir, f.path, createParents: false), InstallFS.fileSize(url) == f.size else { return false }
        if let md5 = f.md5 { return InstallFS.md5(url, expectedSize: f.size) == GOGContent.hex(md5) }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        for c in f.chunks {
            guard let d = try h.read(upToCount: Int(c.size)), d.count == Int(c.size), MD5.hash([UInt8](d)) == GOGContent.hex(c.md5) else { return false }
        }
        return true
    }

    /// Fetches the files that fail verify again.
    public func repair(productID: String, options: InstallEngine.Options = .init(),
                       progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> VerifyReport {
        guard let rec = loadRecord(productID) else { throw ClientError.notFound("no GOG install record for \(productID)") }
        let report = try await verify(productID: productID)
        let bad = Set(report.bad)
        _ = try await stageAndPlace(productID: productID, tag: rec.buildID + "-repair", files: rec.files.filter { bad.contains($0.path) },
                                    into: rec.installDir, options: options, progress: progress)
        discardStages(productID)
        return try await verify(productID: productID)
    }

    /// The record and every stage of the game (uninstall's part; the folder is the library's).
    public func forget(productID: String) {
        try? FileManager.default.removeItem(at: recordFile(productID))
        discardStages(productID)
    }

    public func discardStages(_ productID: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []
        for n in names where n.hasPrefix("gog-\(productID)_") {
            try? FileManager.default.removeItem(at: layout.stagingRoot.appendingPathComponent(n))
        }
    }

    public func hasStage(_ productID: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []).contains { $0.hasPrefix("gog-\(productID)_") }
    }

    /// `name`, or `name (GOG)`, `name (GOG) 2`…: a folder not yet in C:\Games (without case).
    static func unique(_ name: String, in games: URL) -> String {
        let have = Set(((try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []).map { $0.lowercased() })
        if !have.contains(name.lowercased()) { return name }
        let tagged = "\(name) (GOG)"
        if !have.contains(tagged.lowercased()) { return tagged }
        var n = 2
        while have.contains("\(tagged) \(n)".lowercased()) { n += 1 }
        return "\(tagged) \(n)"
    }
}
