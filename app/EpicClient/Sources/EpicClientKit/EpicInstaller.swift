// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What an Epic install keeps beside its receipt (manifests/epic-<app>.json, and the
/// build's manifest file as Epic served it, epic-<app>.manifest): no secret.
public struct EpicInstalled: Codable, Equatable, Sendable {
    public var appName: String
    public var namespace: String
    public var catalogItemID: String
    public var buildVersion: String
    public var installDir: String
    /// `\`-separated, relative to the folder.
    public var launchExe: String
    public var launchCommand: String
    public var files: Int
    public var bytes: UInt64
}

/// Installs, updates, verifies and repairs an Epic game in C:\Games through
/// ContentKit's engine (plan 3.2), as GOGInstaller does for GOG: a first install
/// stages the whole build and commits it with one rename; an update or a repair
/// stages only the files that differ (by SHA-1), moves each into place and removes
/// the files the build dropped. The caller writes the store receipt.
public struct EpicInstaller: Sendable {
    public let layout: InstallLayout
    let session: EpicSession
    let log: Logger

    public init(layout: InstallLayout, session: EpicSession, log: Logger) {
        self.layout = layout
        self.session = session
        self.log = log
    }

    public struct Result: Sendable {
        public var installed: EpicInstalled
        public var bytesWritten: UInt64
        public var downloadedBytes: UInt64
        public var filesChanged: Int
    }

    func stem(_ app: String) -> String { StoreGameKey(store: .epic, id: app).fileStem }
    public func recordFile(_ app: String) -> URL { layout.manifestsDir.appendingPathComponent(stem(app) + ".json") }
    func manifestFile(_ app: String) -> URL { layout.manifestsDir.appendingPathComponent(stem(app) + ".manifest") }

    public func loadRecord(_ app: String) -> EpicInstalled? {
        (try? Data(contentsOf: recordFile(app))).flatMap { try? JSONDecoder().decode(EpicInstalled.self, from: $0) }
    }

    func loadManifest(_ app: String) throws -> EpicManifest {
        guard let raw = try? Data(contentsOf: manifestFile(app)) else { throw ClientError.notFound("no Epic manifest kept for \(app)") }
        return try EpicManifest.parse([UInt8](raw))
    }

    func save(_ r: EpicInstalled, manifest raw: [UInt8]) throws {
        try InstallFS.makeDirectory(layout.manifestsDir)
        try InstallFS.writeAtomically(manifestFile(r.appName), Data(raw))
        try InstallFS.writeAtomically(recordFile(r.appName), JSONEncoder().encode(r))
    }

    func stageName(_ app: String, _ build: String, _ suffix: String = "") -> String {
        "\(stem(app))_\(build.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }.prefix(64))\(suffix)"
    }

    /// The newest build Epic lists for the game.
    public func newestBuild(_ g: EpicGame) async throws -> String { try await EpicContent.asset(session, g).buildVersion }

    /// Installs the game, or updates it to Epic's live build.
    public func install(_ g: EpicGame, options: InstallEngine.Options = .init(),
                        progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> Result {
        if let why = g.refusal { throw ClientError.unsupported(why) }
        let asset = try await EpicContent.asset(session, g)
        let (manifest, raw) = try await EpicContent.manifest(session, asset)
        if let why = manifest.refusal { throw ClientError.unsupported(why) }
        if !manifest.prerequisites.isEmpty {
            log.info("epic", "\(g.id): the build names prerequisites \(manifest.prerequisites.joined(separator: ", ")); Wine's builtins stand in")
        }
        let source = EpicChunkSource(session: session, bases: asset.locations.map(\.base), log: log)
        if let old = loadRecord(g.id), FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent(old.installDir).path) {
            return try await update(g, manifest: manifest, raw: raw, over: old, source: source, options: options, progress: progress)
        }
        let plan = try EpicContent.plan(manifest)
        let folder = Self.unique(try SafePath.normalize(g.folderName).split(separator: "/").last.map(String.init) ?? g.id, in: layout.gamesRoot)
        let name = stageName(g.id, manifest.buildVersion)
        let engine = InstallEngine(tree: layout.stagingTree(name: name), journal: layout.journal(name: name), source: source,
                                   log: log, options: options)
        log.info("epic", "\(g.id) build \(manifest.buildVersion): \(plan.files.count) files, \(plan.totalBytes) bytes "
                 + "(\(manifest.downloadBytes) to download) into C:\\Games\\\(folder)")
        let r = try await engine.run(plan, progress: progress)
        let final = layout.gamesRoot.appendingPathComponent(folder, isDirectory: true)
        try InstallFS.makeDirectory(layout.gamesRoot)
        guard rename(layout.stagingTree(name: name).path, final.path) == 0 else {
            throw ClientError.transport("cannot move the Epic install into C:\\Games (errno \(errno))")
        }
        try? FileManager.default.removeItem(at: layout.journal(name: name))
        let rec = record(g, manifest, folder: folder)
        try save(rec, manifest: raw)
        discardStages(g.id)
        return Result(installed: rec, bytesWritten: r.bytes, downloadedBytes: r.downloadedBytes, filesChanged: plan.files.count)
    }

    func record(_ g: EpicGame, _ m: EpicManifest, folder: String) -> EpicInstalled {
        EpicInstalled(appName: g.id, namespace: g.namespace, catalogItemID: g.catalogItemID, buildVersion: m.buildVersion,
                      installDir: folder, launchExe: m.launchExe.replacingOccurrences(of: "/", with: "\\"),
                      launchCommand: m.launchCommand, files: m.files.count, bytes: m.installBytes)
    }

    func update(_ g: EpicGame, manifest: EpicManifest, raw: [UInt8], over old: EpicInstalled, source: EpicChunkSource,
                options: InstallEngine.Options, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> Result {
        let before = (try? loadManifest(g.id)).map { Dictionary($0.files.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { _, b in b }) } ?? [:]
        let changed = Set(manifest.files.filter { before[$0.path.lowercased()]?.sha1 != $0.sha1 }.map { $0.path.lowercased() })
        let now = Set(manifest.files.map { $0.path.lowercased() })
        let dropped = before.filter { !now.contains($0.key) }.map(\.value.path)
        log.info("epic", "\(g.id): update \(old.buildVersion) -> \(manifest.buildVersion): \(changed.count) files to fetch, \(dropped.count) to remove")
        let r = try await stageAndPlace(g.id, tag: manifest.buildVersion, manifest: manifest, only: changed, into: old.installDir,
                                        source: source, options: options, progress: progress)
        let dir = layout.gamesRoot.appendingPathComponent(old.installDir, isDirectory: true)
        for p in dropped { if let u = try? InstallFS.resolveInside(dir, p, createParents: false) { try? FileManager.default.removeItem(at: u) } }
        let rec = record(g, manifest, folder: old.installDir)
        try save(rec, manifest: raw)
        discardStages(g.id)
        return Result(installed: rec, bytesWritten: r?.bytes ?? 0, downloadedBytes: r?.downloadedBytes ?? 0, filesChanged: changed.count + dropped.count)
    }

    /// Stages the files `only` names and moves each into `folder`, replacing what is there.
    func stageAndPlace(_ app: String, tag: String, manifest: EpicManifest, only: Set<String>, into folder: String, source: EpicChunkSource,
                       options: InstallEngine.Options, progress: @escaping @Sendable (InstallEngine.Progress) -> Void) async throws -> InstallEngine.Result? {
        guard !only.isEmpty else { return nil }
        let plan = try EpicContent.plan(manifest, only: only)
        let name = stageName(app, tag, ".part")
        let tree = layout.stagingTree(name: name)
        let engine = InstallEngine(tree: tree, journal: layout.journal(name: name), source: source, log: log, options: options)
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

    /// Every file of the kept manifest, by size then SHA-1.
    public func verify(_ app: String) async throws -> VerifyReport {
        guard let rec = loadRecord(app) else { throw ClientError.notFound("no Epic install record for \(app)") }
        let m = try loadManifest(app)
        let dir = layout.gamesRoot.appendingPathComponent(rec.installDir, isDirectory: true)
        var bad: [String] = []
        let files = m.files.filter { $0.symlinkTarget.isEmpty }
        for f in files {
            try Task.checkCancellation()
            guard let u = try? InstallFS.resolveInside(dir, f.path, createParents: false),
                  InstallEngine.fileMatches(u, size: f.size, hash: .sha1(f.sha1)) else { bad.append(f.path); continue }
        }
        return VerifyReport(files: files.count, bad: bad)
    }

    /// Fetches the files that fail verify again (from the CDNs Epic names now).
    public func repair(_ g: EpicGame, options: InstallEngine.Options = .init(),
                       progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in }) async throws -> VerifyReport {
        guard let rec = loadRecord(g.id) else { throw ClientError.notFound("no Epic install record for \(g.id)") }
        let report = try await verify(g.id)
        if !report.bad.isEmpty {
            let m = try loadManifest(g.id)
            let asset = try await EpicContent.asset(session, g)
            let source = EpicChunkSource(session: session, bases: asset.locations.map(\.base), log: log)
            _ = try await stageAndPlace(g.id, tag: rec.buildVersion + "-repair", manifest: m, only: Set(report.bad.map { $0.lowercased() }),
                                        into: rec.installDir, source: source, options: options, progress: progress)
        }
        discardStages(g.id)
        return try await verify(g.id)
    }

    /// The records and every stage of the game (uninstall's part; the folder is the library's).
    public func forget(_ app: String) {
        try? FileManager.default.removeItem(at: recordFile(app))
        try? FileManager.default.removeItem(at: manifestFile(app))
        discardStages(app)
    }

    public func discardStages(_ app: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []
        for n in names where n.hasPrefix(stem(app) + "_") {
            try? FileManager.default.removeItem(at: layout.stagingRoot.appendingPathComponent(n))
        }
    }

    public func hasStage(_ app: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []).contains { $0.hasPrefix(stem(app) + "_") }
    }

    /// The arguments a launch passes (plan 3.4): the manifest's launch command, the
    /// catalogue's extra command line, then Epic's non-secret ones. No exchange code.
    public static func arguments(_ r: EpicInstalled, game: EpicGame?, locale: String = "en") -> [String] {
        split(r.launchCommand) + split(game?.attributes["AdditionalCommandLine"] ?? "")
            + ["-epicapp=\(r.appName)", "-epicenv=Prod", "-EpicPortal", "-epiclocale=\(locale)"]
    }

    /// Words, with double quotes grouping.
    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, any = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); any = true } else if ch == " " && !quoted {
                if any || !cur.isEmpty { out.append(cur) }
                cur = ""; any = false
            } else { cur.append(ch) }
        }
        if any || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// `name`, or `name (Epic)`, `name (Epic) 2`…: a folder not yet in C:\Games (without case).
    static func unique(_ name: String, in games: URL) -> String {
        let have = Set(((try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []).map { $0.lowercased() })
        if !have.contains(name.lowercased()) { return name }
        let tagged = "\(name) (Epic)"
        if !have.contains(tagged.lowercased()) { return tagged }
        var n = 2
        while have.contains("\(tagged) \(n)".lowercased()) { n += 1 }
        return "\(tagged) \(n)"
    }
}
