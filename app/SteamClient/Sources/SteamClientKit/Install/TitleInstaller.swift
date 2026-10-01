// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A whole title from Steam to `<games>/<installdir>`: depot selection, depot
/// keys, manifests (retained on disk), the plan, the staged download, then one
/// rename into place and an install record. Verify re-hashes an install
/// against its retained manifests with no session; repair re-downloads the
/// files that fail into a side stage and renames each one over the broken
/// copy. Uninstall moves the title aside with one rename, then deletes it and
/// its record. A steam_api DLL swapped for the Steam API emulator is verified
/// and repaired as the game's own copy, kept beside it (SteamAPISwap). The
/// app's UI calls this.
public struct TitleInstaller: Sendable {
    public let layout: InstallLayout
    /// Install and repair need one; verify, uninstall and stage upkeep do not.
    let session: SteamSession?
    let log: Logger

    public init(layout: InstallLayout, session: SteamSession?, log: Logger) {
        self.layout = layout
        self.session = session
        self.log = log
    }

    private func requireSession() throws -> SteamSession {
        guard let session else { throw SteamError.notLoggedOn }
        return session
    }

    public struct Request: Sendable {
        public var appID: UInt32
        public var selection: DepotSelection.Options
        /// The directory name under games; PICS `installdir` by default.
        public var destName: String?
        /// The Steam branch; nil continues the branch of a paused download or
        /// of the install, else public.
        public var branch: String?
        public var engine: InstallEngine.Options
        /// How many of the best content servers the job spreads over.
        public var servers = 8

        public init(appID: UInt32, selection: DepotSelection.Options = .init(), destName: String? = nil,
                    branch: String? = nil, engine: InstallEngine.Options = .init()) {
            self.appID = appID
            self.selection = selection
            self.destName = destName
            self.branch = branch
            self.engine = engine
        }
    }

    public struct Outcome: Sendable {
        public var receipt: InstallReceipt
        public var stage: InstallEngine.Result?
        public var installedTo: URL
        public var alreadyInstalled: Bool
    }

    public struct VerifyReport: Sendable {
        public var files: Int
        public var bytes: UInt64
        /// Missing, wrong size or wrong hash, by path.
        public var bad: [String]
        /// Regular files under the install that no plan entry names (left alone).
        public var unlisted: [String]
        public var seconds: Double
        public var repaired: Int?
    }

    // MARK: install

    /// `progress` gets the engine's figures as they come (the UI's bar); `say`
    /// gets the same as lines, with every other step.
    public func install(_ r: Request, progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in },
                        say: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let session = try requireSession()
        let branch = r.branch ?? stagedBranch(appID: r.appID) ?? loadReceipt(r.appID)?.branch ?? Branch.publicName
        let app = try await Library(session: session).depots(appID: r.appID).onBranch(branch)
        var options = r.selection
        if options.ownedDepots == nil, options.explicit == nil {
            options.ownedDepots = await ownedDepots(session, say: say)
        }
        let selection = try DepotSelection.select(app, options)
        say("app \(r.appID) \(app.name) branch=\(branch) buildid=\(app.publicBuildID.map(String.init) ?? "?") installdir=\(app.installDir ?? "-")")
        for d in selection.depots {
            say("  depot \(d.depotID) selected: gid \(d.publicManifestGID!) size=\(d.publicManifestSize.map(String.init) ?? "?")")
        }
        for s in selection.skipped { say("  depot \(s.depotID) skipped: \(s.reason)") }

        let name = try Self.destinationName(r.destName ?? app.installDir ?? "app\(r.appID)")
        let refs = selection.depots.map { DepotRef(depotID: $0.depotID, gid: $0.publicManifestGID!) }
        let (final, replacing) = try destination(name, appID: r.appID)
        sweepStaging(appID: r.appID, buildID: app.publicBuildID)
        if replacing, var old = loadReceipt(r.appID), old.depots == refs, old.buildID == app.publicBuildID {
            let follows = branch == Branch.publicName ? nil : branch
            if old.branch != follows || (app.launchExecutable != nil && old.executable != app.launchExecutable) {
                // Same content: only which branch it follows, or the launch executable, changes.
                old.branch = follows
                old.executable = app.launchExecutable ?? old.executable
                try saveReceipt(old)
            }
            say("install: already installed at Games/\(name) (build \(old.buildID.map(String.init) ?? "?")); run verify to check it")
            return Outcome(receipt: old, stage: nil, installedTo: final, alreadyInstalled: true)
        }
        try InstallFS.makeDirectory(layout.stagingRoot)
        try InstallFS.writeAtomically(layout.stageBranch(appID: r.appID, buildID: app.publicBuildID), Data(branch.utf8))

        let content = await ContentClient(session: session)
        let servers = try await content.servers(appID: r.appID)
        say("content servers: \(servers.count) usable; spreading over \(min(servers.count, r.servers))")
        var keys: [UInt32: AES256Decryptor] = [:]
        var manifests: [DepotManifest] = []
        for ref in refs {
            let key = try await content.depotKey(appID: r.appID, depotID: ref.depotID)
            keys[ref.depotID] = try AES256Decryptor(key: key.value)
            let m = try await manifest(ref, appID: r.appID, branch: branch, key: key, content: content, servers: servers, say: say)
            manifests.append(m)
        }
        say("depot keys: \(keys.count) obtained (redacted)")
        let plan = try InstallPlan.make(appID: r.appID, buildID: app.publicBuildID, manifests: manifests)
        say("plan: \(plan.files.count) files, \(plan.directories.count) directories, \(plan.totalBytes) bytes, \(plan.chunkCount) chunks (\(plan.uniqueChunkCount) unique)"
            + (plan.skippedSymlinks.isEmpty ? "" : ", \(plan.skippedSymlinks.count) symlink entries not installed"))

        let tree = layout.stagingTree(appID: r.appID, buildID: app.publicBuildID)
        let pool = ServerPool(servers, use: r.servers, log: log)
        let engine = InstallEngine(tree: tree, journal: layout.journal(appID: r.appID, buildID: app.publicBuildID),
                                   source: CDNChunkSource(content: content, keys: keys, pool: pool, log: log),
                                   log: log, options: r.engine)
        let result = try await engine.run(plan) { p in progress(p); say(Self.progressLine(p)) }
        say(Self.stageLine(result))

        let receipt = InstallReceipt(appID: r.appID, name: app.name, installDir: name, buildID: app.publicBuildID, depots: refs,
                                     files: plan.files.count, bytes: plan.totalBytes,
                                     skippedDepots: selection.skipped.map { "\($0.depotID): \($0.reason)" },
                                     skippedSymlinks: plan.skippedSymlinks.count,
                                     installedAt: ISO8601DateFormatter().string(from: Date()),
                                     branch: branch == Branch.publicName ? nil : branch,
                                     executable: app.launchExecutable)
        try commit(tree, to: final, replacing: replacing, receipt: receipt)
        try? FileManager.default.removeItem(at: engine.journalURL)
        try? FileManager.default.removeItem(at: layout.stageBranch(appID: r.appID, buildID: app.publicBuildID))
        say("install: committed to Games/\(name) with one rename; record written")
        return Outcome(receipt: receipt, stage: result, installedTo: final, alreadyInstalled: false)
    }

    /// The depots the account's packages list, or nil (anonymous, or not
    /// fetched: then every depot is tried, and an unowned one stops the install).
    func ownedDepots(_ session: SteamSession, say: @Sendable (String) -> Void) async -> Set<UInt32>? {
        do {
            let licenses = try await session.awaitLicenses(timeout: 20)
            guard !licenses.isEmpty else { return nil }
            let owned = try await Library(session: session).ownedDepotIDs(packages: licenses.map { ($0.packageID, $0.accessToken) })
            return owned.isEmpty ? nil : owned
        } catch {
            say("owned depots unknown (\(error)); every selected depot is tried")
            return nil
        }
    }

    /// The retained parse when one is on disk, else the CDN's (then retained).
    func manifest(_ ref: DepotRef, appID: UInt32, branch: String, key: Secret<[UInt8]>, content: ContentClient,
                  servers: [GetServersForSteamPipeResponse.Server], say: @Sendable (String) -> Void) async throws -> DepotManifest {
        let url = layout.manifestFile(ref)
        do {
            if let m = try RetainedManifest.load(url) {
                say("manifest: depot \(ref.depotID) gid \(ref.gid) files=\(m.files.count) total=\(m.totalSize) bytes (retained copy)")
                return m
            }
        } catch {
            log.warn("install", "retained manifest \(ref.depotID)_\(ref.gid) unreadable (\(error)); fetching it again")
        }
        let (m, rawSHA) = try await content.manifest(appID: appID, depotID: ref.depotID, gid: ref.gid, depotKey: key, servers: servers,
                                                          branch: branch)
        try RetainedManifest.save(m, to: url)
        say("manifest: depot \(ref.depotID) gid \(ref.gid) files=\(m.files.count) total=\(m.totalSize) bytes sha1(raw)=\(rawSHA.prefix(16)) (validated, retained)")
        return m
    }

    // MARK: verify and repair

    /// Re-hashes an install against its retained manifests. No session needed.
    public func verify(appID: UInt32, concurrency: Int = 4) async throws -> VerifyReport {
        try await verifyPlan(appID: appID, concurrency: concurrency).report
    }

    func verifyPlan(appID: UInt32, concurrency: Int, only: Set<String>? = nil) async throws
        -> (report: VerifyReport, plan: InstallPlan, receipt: InstallReceipt, root: URL) {
        guard let receipt = loadReceipt(appID) else { throw SteamError.notFound("no Playport install record for app \(appID)") }
        var manifests: [DepotManifest] = []
        for ref in receipt.depots {
            guard let m = try RetainedManifest.load(layout.manifestFile(ref)) else {
                throw SteamError.notFound("retained manifest \(ref.depotID)_\(ref.gid) is missing")
            }
            manifests.append(m)
        }
        let plan = try InstallPlan.make(appID: appID, buildID: receipt.buildID, manifests: manifests)
        let root = layout.gamesRoot.appendingPathComponent(receipt.installDir, isDirectory: true)
        let started = Date()
        let entries = plan.files.filter { only?.contains($0.path) ?? true }
        // A steam_api DLL swapped for the emulator is checked as its kept original (SteamAPISwap).
        let checks = try entries.map { f in
            (f.path, try InstallFS.resolveInside(root, SteamAPISwap.manifestFile(root, f.path), createParents: false), f.size, f.sha)
        }
        let bad = await Self.parallel(checks, width: concurrency) { c in
            InstallEngine.fileMatches(c.1, size: c.2, sha: c.3) ? nil : c.0
        }
        var unlisted: [String] = []
        if only == nil {
            let known = Set(plan.files.map { $0.path.lowercased() })
            unlisted = Self.regularFiles(under: root).filter { !known.contains($0.lowercased()) && !SteamAPISwap.isSwapFile(root, $0) }
        }
        let report = VerifyReport(files: entries.count, bytes: entries.reduce(0) { $0 + $1.size }, bad: bad.sorted(),
                                  unlisted: unlisted, seconds: Date().timeIntervalSince(started), repaired: nil)
        return (report, plan, receipt, root)
    }

    /// Verify, then re-download what fails: staged beside the install, each
    /// file checked, then renamed over the broken copy. Needs a logged-on
    /// session with access to the install's depots.
    public func repair(appID: UInt32, engine options: InstallEngine.Options = .init(), servers use: Int = 8,
                       progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in },
                       say: @escaping @Sendable (String) -> Void) async throws -> VerifyReport {
        let session = try requireSession()
        let (first, plan, receipt, root) = try await verifyPlan(appID: appID, concurrency: max(2, options.concurrency / 2))
        say(Self.verifyLine(first))
        for p in first.bad.prefix(20) { say("  BAD \(p)") }
        guard !first.bad.isEmpty else { return first }

        let sub = plan.restricted(to: Set(first.bad))
        let content = await ContentClient(session: session)
        let servers = try await content.servers(appID: appID)
        var keys: [UInt32: AES256Decryptor] = [:]
        for depot in Set(sub.files.map(\.depotID)) {
            keys[depot] = try AES256Decryptor(key: try await content.depotKey(appID: appID, depotID: depot).value)
        }
        let source = CDNChunkSource(content: content, keys: keys, pool: ServerPool(servers, use: use, log: log), log: log)
        return try await replace(first, plan: sub, receipt: receipt, root: root, source: source, options: options,
                                 progress: progress, say: say)
    }

    /// Stages `sub` (the files that failed) beside the install and renames each
    /// verified file over the broken copy, then re-verifies them.
    func replace(_ first: VerifyReport, plan sub: InstallPlan, receipt: InstallReceipt, root: URL, source: any ChunkSource,
                 options: InstallEngine.Options, progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in },
                 say: @escaping @Sendable (String) -> Void) async throws -> VerifyReport {
        let appID = receipt.appID
        let tree = layout.stagingTree(appID: appID, buildID: receipt.buildID, suffix: ".repair")
        let engine = InstallEngine(tree: tree, journal: layout.journal(appID: appID, buildID: receipt.buildID, suffix: ".repair"),
                                   source: source, log: log, options: options)
        let result = try await engine.run(sub) { p in progress(p); say(Self.progressLine(p)) }
        say(Self.stageLine(result))
        for f in sub.files {
            let src = try InstallFS.resolveInside(tree, f.path, createParents: false)
            let dst = try InstallFS.resolveInside(root, SteamAPISwap.manifestFile(root, f.path), createParents: true)
            guard rename(src.path, dst.path) == 0 else { throw SteamError.transport("repair rename \(f.path) errno \(errno)") }
        }
        try? FileManager.default.removeItem(at: tree)
        try? FileManager.default.removeItem(at: engine.journalURL)
        var after = try await verifyPlan(appID: appID, concurrency: 4, only: Set(first.bad)).report
        after.repaired = first.bad.count - after.bad.count
        say("repair: \(after.repaired!) of \(first.bad.count) files replaced and re-verified; \(after.bad.count) still bad")
        guard after.bad.isEmpty else { throw SteamError.verificationFailed("\(after.bad.count) files still fail after repair") }
        var full = first
        full.bad = []
        full.repaired = after.repaired
        return full
    }

    /// An adopted title with no session: every file of a `sha256sum` list
    /// (`<hex>  <path>`), hashed by streaming, plus files the list does not name.
    public static func verifySHA256List(dir: URL, list: URL, concurrency: Int = 4) async throws -> VerifyReport {
        let text = try String(contentsOf: list, encoding: .utf8)
        var rows: [(String, [UInt8])] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 64, let digest = RetainedManifest.unhex(parts[0]) else {
                throw SteamError.unsupported("sha256 list line is not `<hex>  <path>`")
            }
            var path = String(parts[1])
            if path.hasPrefix(" ") || path.hasPrefix("*") { path.removeFirst() }
            rows.append((try SafePath.normalize(path), digest))
        }
        let started = Date()
        let checks = try rows.map { ($0.0, try InstallFS.resolveInside(dir, SteamAPISwap.manifestFile(dir, $0.0), createParents: false), $0.1) }
        let bad = await parallel(checks, width: concurrency) { c in InstallFS.sha256(c.1) == c.2 ? nil : c.0 }
        let known = Set(rows.map { $0.0 })
        let unlisted = regularFiles(under: dir).filter { !known.contains($0) && !SteamAPISwap.isSwapFile(dir, $0) }
        let bytes = checks.reduce(UInt64(0)) { $0 + (InstallFS.fileSize($1.1) ?? 0) }
        return VerifyReport(files: rows.count, bytes: bytes, bad: bad.sorted(), unlisted: unlisted,
                            seconds: Date().timeIntervalSince(started), repaired: nil)
    }

    // MARK: destination, commit, records

    /// One path component: the directory under games.
    static func destinationName(_ raw: String) throws -> String {
        let n = try SafePath.normalize(raw)
        guard !n.contains("/") else { throw SteamError.unsafeContent("install directory \(n) must be a single name") }
        return n
    }

    /// Where the title goes, and whether it replaces this app's own earlier
    /// install. An existing directory of the same name (compared without case,
    /// as the guest sees it) that is not this app's install is never touched.
    func destination(_ name: String, appID: UInt32) throws -> (URL, replacing: Bool) {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: layout.gamesRoot.path)) ?? []
        guard let clash = existing.first(where: { $0.lowercased() == name.lowercased() }) else {
            return (layout.gamesRoot.appendingPathComponent(name, isDirectory: true), false)
        }
        guard let own = loadReceipt(appID), own.installDir == clash else {
            throw SteamError.unsafeContent("Games/\(clash) already exists and is not this app's Playport install; refusing to install over it")
        }
        return (layout.gamesRoot.appendingPathComponent(clash, isDirectory: true), true)
    }

    /// Renames the stage into place and records it before the previous
    /// install, moved aside, is deleted; an aside left by a kill is swept by
    /// the next install.
    func commit(_ tree: URL, to final: URL, replacing: Bool, receipt: InstallReceipt) throws {
        try InstallFS.makeDirectory(layout.gamesRoot)
        if replacing {
            let aside = layout.stagingRoot.appendingPathComponent("replaced-\(UUID().uuidString)")
            guard rename(final.path, aside.path) == 0 else { throw SteamError.transport("cannot move the previous install aside (errno \(errno))") }
            guard rename(tree.path, final.path) == 0 else {
                let e = errno
                _ = rename(aside.path, final.path)
                throw SteamError.transport("commit rename failed (errno \(e))")
            }
            try saveReceipt(receipt)
            try? FileManager.default.removeItem(at: aside)
        } else {
            guard rename(tree.path, final.path) == 0 else {
                if errno == EXDEV { throw SteamError.unsupported("staging and games are on different volumes; the commit must be one rename") }
                throw SteamError.transport("commit rename failed (errno \(errno))")
            }
            try saveReceipt(receipt)
        }
    }

    /// Removes previous installs and uninstalled titles left moved aside, and
    /// this app's stages and journals for any other build (not its repair stage).
    func sweepStaging(appID: UInt32, buildID: UInt32?) {
        let keep = [layout.stagingTree(appID: appID, buildID: buildID).lastPathComponent,
                     layout.journal(appID: appID, buildID: buildID).lastPathComponent,
                     layout.stageBranch(appID: appID, buildID: buildID).lastPathComponent]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? [] {
            let stale = n.hasPrefix("replaced-") || n.hasPrefix("removed-")
                || (n.hasPrefix("\(appID)_") && !keep.contains(n) && !n.hasSuffix(".repair") && !n.hasSuffix(".repair.journal"))
            if stale { try? FileManager.default.removeItem(at: layout.stagingRoot.appendingPathComponent(n)) }
        }
    }

    // MARK: uninstall and paused stages

    /// A download of this app stopped part-way (paused, cancelled or killed):
    /// its stage is on disk and the same install resumes it.
    public func hasStage(appID: UInt32) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []
        return names.contains { $0.hasPrefix("\(appID)_") && $0.hasSuffix(".journal") && !$0.hasSuffix(".repair.journal") }
    }

    /// The branch of this app's paused download, if one is on disk.
    public func stagedBranch(appID: UInt32) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? []
        guard let n = names.first(where: { $0.hasPrefix("\(appID)_") && $0.hasSuffix(".branch") }),
              let data = try? Data(contentsOf: layout.stagingRoot.appendingPathComponent(n)),
              let b = String(data: data, encoding: .utf8), !b.isEmpty else { return nil }
        return b
    }

    /// Deletes this app's stages and journals, repair ones included.
    public func discardStage(appID: UInt32) {
        for n in (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? [] where n.hasPrefix("\(appID)_") {
            try? FileManager.default.removeItem(at: layout.stagingRoot.appendingPathComponent(n))
        }
    }

    /// Removes `Games/<installDir>`: one rename out of games, so no half-deleted
    /// title is ever adopted, then its record and retained manifests when
    /// `appID`'s record names that folder, its stages, and the tree itself. A
    /// tree left moved aside by a kill is swept by the next install. Saves
    /// under the prefix's user profile are outside the folder and stay.
    public func uninstall(installDir: String, appID: UInt32?) throws {
        let name = try Self.destinationName(installDir)
        let dir = layout.gamesRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try InstallFS.makeDirectory(layout.stagingRoot)
            let aside = layout.stagingRoot.appendingPathComponent("removed-\(UUID().uuidString)")
            guard rename(dir.path, aside.path) == 0 else {
                throw SteamError.transport("cannot move Games/\(name) out for removal (errno \(errno))")
            }
            try? FileManager.default.removeItem(at: aside)
        }
        guard let appID else { return }
        if let r = loadReceipt(appID), r.installDir.lowercased() == name.lowercased() {
            try? FileManager.default.removeItem(at: layout.receiptFile(appID: appID))
            for ref in r.depots { try? FileManager.default.removeItem(at: layout.manifestFile(ref)) }
        }
        discardStage(appID: appID)
    }

    public func loadReceipt(_ appID: UInt32) -> InstallReceipt? {
        guard let data = try? Data(contentsOf: layout.receiptFile(appID: appID)) else { return nil }
        return try? JSONDecoder().decode(InstallReceipt.self, from: data)
    }

    func saveReceipt(_ r: InstallReceipt) throws {
        try InstallFS.makeDirectory(layout.installsDir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try InstallFS.writeAtomically(layout.receiptFile(appID: r.appID), enc.encode(r))
    }

    // MARK: helpers

    static func regularFiles(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        let base = root.standardizedFileURL.path
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(base + "/") else { continue }
            out.append(String(p.dropFirst(base.count + 1)))
        }
        return out.sorted()
    }

    /// Runs `body` over `items` with at most `width` in flight; collects non-nil results.
    static func parallel<T: Sendable, R: Sendable>(_ items: [T], width: Int, _ body: @escaping @Sendable (T) -> R?) async -> [R] {
        await withTaskGroup(of: R?.self) { group in
            var out: [R] = [], next = 0, running = 0
            while next < items.count || running > 0 {
                while running < max(1, width), next < items.count {
                    let item = items[next]
                    next += 1
                    running += 1
                    group.addTask { body(item) }
                }
                if let r = await group.next() {
                    running -= 1
                    if let r { out.append(r) }
                }
            }
            return out
        }
    }

    public static func progressLine(_ p: InstallEngine.Progress) -> String {
        let pct = p.bytesTotal == 0 ? 100 : Double(p.bytesDone) / Double(p.bytesTotal) * 100
        let rate = p.seconds > 0 ? Double(p.downloadedBytes) / p.seconds / 1e6 : 0
        return String(format: "progress: %.2f/%.2f GB (%.1f%%), %d/%d chunks downloaded, %.1f MB/s, files verified %d/%d, t+%.0fs",
                      Double(p.bytesDone) / 1e9, Double(p.bytesTotal) / 1e9, pct, p.chunksDownloaded, p.chunksToDownload,
                      rate, p.filesVerified, p.filesTotal, p.seconds)
    }

    public static func stageLine(_ r: InstallEngine.Result) -> String {
        let rate = r.seconds > 0 ? Double(r.downloadedBytes) / r.seconds / 1e6 : 0
        return String(format: "stage: %d files (%d SHA-1-verified now, %d verified before resume), %llu bytes; %d chunks downloaded (%llu bytes), %d deduplicated, %d resumed after re-hash, %d rejected on re-hash; %.1f s, %.1f MB/s, peak RSS %.0f MiB",
                      r.files, r.filesVerified, r.filesResumed, r.bytes, r.chunksDownloaded, r.downloadedBytes, r.chunksDeduped,
                      r.chunksResumed, r.chunksRejected, r.seconds, rate, Double(r.peakRSSBytes) / 1_048_576)
    }

    public static func verifyLine(_ r: VerifyReport) -> String {
        String(format: "verify: %d files, %llu bytes, %d bad, %d unlisted, %.1f s", r.files, r.bytes, r.bad.count, r.unlisted.count, r.seconds)
    }
}
