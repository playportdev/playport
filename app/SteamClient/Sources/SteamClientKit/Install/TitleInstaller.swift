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
/// its record. A folder another Steam app's record names (Steam's shared
/// installdir, SharedInstallDir) is joined file by file instead: only the files
/// the other apps do not list are downloaded and renamed in, and uninstalling
/// removes only this app's own files. A steam_api DLL swapped for the Steam API
/// emulator is verified and repaired as the game's own copy, kept beside it
/// (SteamAPISwap). The app's UI calls this.
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
        /// Depots the record left out that Steam's depot list may have installed in the folder
        /// (InstallReceipt.depotsToRecheck): a repair asks Steam and downloads those it would.
        public var depotsToRecheck: [UInt32] = []

        /// Whether a repair has something to do: a bad file, or a depot to check again.
        public var ok: Bool { bad.isEmpty && depotsToRecheck.isEmpty }
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
        let (final, replacing, sharing) = try destination(name, appID: r.appID)
        sweepStaging(appID: r.appID, buildID: app.publicBuildID)
        if replacing, var old = loadReceipt(r.appID), old.depots == refs, old.buildID == app.publicBuildID {
            let follows = branch == Branch.publicName ? nil : branch
            let launchChanged = app.launchExecutable != nil
                && (old.executable != app.launchExecutable || old.arguments != app.launchArguments)
            if old.branch != follows || launchChanged {
                // Same content: only which branch it follows, or the launch entry, changes.
                old.branch = follows
                if launchChanged {
                    old.executable = app.launchExecutable
                    old.arguments = app.launchArguments
                }
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
            let keyApp = app.keyAppID(depot: ref.depotID)
            let key = try await depotKey(content, appID: keyApp, depotID: ref.depotID, for: r.appID)
            keys[ref.depotID] = try AES256Decryptor(key: key.value)
            let m = try await manifest(ref, appID: keyApp, branch: branch, key: key, content: content, servers: servers, say: say)
            manifests.append(m)
        }
        say("depot keys: \(keys.count) obtained (redacted)")
        let plan = try InstallPlan.make(appID: r.appID, buildID: app.publicBuildID, manifests: manifests)
        say("plan: \(plan.files.count) files, \(plan.directories.count) directories, \(plan.totalBytes) bytes, \(plan.chunkCount) chunks (\(plan.uniqueChunkCount) unique)"
            + (plan.skippedSymlinks.isEmpty ? "" : ", \(plan.skippedSymlinks.count) symlink entries not installed"))
        var stagePlan = plan
        var others: SharedInstallDir.Others?
        if !sharing.isEmpty {
            let o = try SharedInstallDir.Others(sharing.map { try retainedPlan($0) })
            stagePlan = plan.restricted(to: try SharedInstallDir.pathsToStage(plan, others: o, folder: name))
            others = o
            say("shared folder: Games/\(name) also holds app(s) \(o.appIDs.map(String.init).joined(separator: ", ")); "
                + "\(plan.files.count - stagePlan.files.count) of \(plan.files.count) files are theirs too, \(stagePlan.files.count) to download")
        }

        let tree = layout.stagingTree(appID: r.appID, buildID: app.publicBuildID)
        let pool = ServerPool(servers, use: r.servers, log: log)
        let engine = InstallEngine(tree: tree, journal: layout.journal(appID: r.appID, buildID: app.publicBuildID),
                                   source: CDNChunkSource(content: content, keys: keys, pool: pool, log: log),
                                   log: log, options: r.engine)
        var result: InstallEngine.Result?
        if !stagePlan.files.isEmpty {
            let staged = try await engine.run(stagePlan) { p in progress(p); say(Self.progressLine(p)) }
            say(Self.stageLine(staged))
            result = staged
        }

        let receipt = InstallReceipt(appID: r.appID, name: app.name, installDir: name, buildID: app.publicBuildID, depots: refs,
                                     files: plan.files.count, bytes: plan.totalBytes,
                                     skippedDepots: selection.skipped.map { "\($0.depotID): \($0.reason)" },
                                     skippedSymlinks: plan.skippedSymlinks.count,
                                     installedAt: ISO8601DateFormatter().string(from: Date()),
                                     branch: branch == Branch.publicName ? nil : branch,
                                     executable: app.launchExecutable, arguments: app.launchArguments)
        if let others {
            try commitShared(tree, plan: plan, staged: stagePlan, to: final, others: others, receipt: receipt)
        } else {
            try commit(tree, to: final, replacing: replacing, receipt: receipt)
        }
        try? FileManager.default.removeItem(at: engine.journalURL)
        try? FileManager.default.removeItem(at: layout.stageBranch(appID: r.appID, buildID: app.publicBuildID))
        say(others == nil ? "install: committed to Games/\(name) with one rename; record written"
                          : "install: \(stagePlan.files.count) files renamed into the shared Games/\(name); record written")
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

    /// A depot's key, asked for `appID` (the source app of a depot that shares
    /// the install folder). Refused for a source app's depot, the error says
    /// which app the account needs.
    func depotKey(_ content: ContentClient, appID: UInt32, depotID: UInt32, for title: UInt32) async throws -> Secret<[UInt8]> {
        do {
            return try await content.depotKey(appID: appID, depotID: depotID)
        } catch let SteamError.eresult(code, context) where appID != title {
            throw SteamError.eresult(code, context: "\(context): depot \(depotID) is app \(appID)'s content, which this account cannot download")
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
            InstallEngine.fileMatches(c.1, size: c.2, hash: c.3.map(FileHash.sha1) ?? .none) ? nil : c.0
        }
        var unlisted: [String] = []
        if only == nil {
            let known = Set(plan.files.map { $0.path.lowercased() })
            unlisted = Self.regularFiles(under: root).filter { !known.contains($0.lowercased()) && !SteamAPISwap.isSwapFile(root, $0) }
        }
        let report = VerifyReport(files: entries.count, bytes: entries.reduce(0) { $0 + $1.size }, bad: bad.sorted(),
                                  unlisted: unlisted, seconds: Date().timeIntervalSince(started), repaired: nil,
                                  depotsToRecheck: only == nil ? receipt.depotsToRecheck : [])
        return (report, plan, receipt, root)
    }

    /// Verify, then re-download what fails: staged beside the install, each
    /// file checked, then renamed over the broken copy. Needs a logged-on
    /// session with access to the install's depots.
    public func repair(appID: UInt32, engine options: InstallEngine.Options = .init(), servers use: Int = 8,
                       progress: @escaping @Sendable (InstallEngine.Progress) -> Void = { _ in },
                       say: @escaping @Sendable (String) -> Void) async throws -> VerifyReport {
        let session = try requireSession()
        var (first, plan, receipt, root) = try await verifyPlan(appID: appID, concurrency: max(2, options.concurrency / 2))
        say(Self.verifyLine(first))
        for p in first.bad.prefix(20) { say("  BAD \(p)") }
        guard !first.ok else { return first }

        let content = await ContentClient(session: session)
        let servers = try await content.servers(appID: appID)
        // Another app's depot installed in the folder has its source app's key (Counter-Strike's Half-Life engine).
        var app = try? await Library(session: session).depots(appID: appID)
        if !first.depotsToRecheck.isEmpty {
            guard let listed = app else { throw SteamError.notFound("app \(appID)'s depot list is unreadable; its depots \(first.depotsToRecheck) are not checked") }
            app = listed
            let added = try await addRecheckedDepots(listed, receipt: receipt, root: root, content: content, servers: servers, say: say)
            if let added {
                receipt = added.receipt
                plan = added.plan
                first.bad = (Set(first.bad).union(added.missing)).sorted()
                first.files = plan.files.count
                first.bytes = plan.totalBytes
            }
            first.depotsToRecheck = []
            guard !first.bad.isEmpty else { return first }
        }

        let sub = plan.restricted(to: Set(first.bad))
        var keys: [UInt32: AES256Decryptor] = [:]
        let depots = Set(sub.files.map(\.depotID))
        for depot in depots {
            let keyApp = app?.keyAppID(depot: depot) ?? appID
            keys[depot] = try AES256Decryptor(key: try await depotKey(content, appID: keyApp, depotID: depot, for: appID).value)
        }
        let source = CDNChunkSource(content: content, keys: keys, pool: ServerPool(servers, use: use, log: log), log: log)
        return try await replace(first, plan: sub, receipt: receipt, root: root, source: source, options: options,
                                 progress: progress, say: say)
    }

    /// A repair's check of the depots an earlier record left out as shared installs
    /// (VerifyReport.depotsToRecheck), against Steam's depot list now: those the selection now
    /// installs in the folder join the record, which is saved at once, with their files (those not
    /// already there as the plan has them) returned as missing for the repair to download; the
    /// others are recorded with their reasons now. Nil when none joins. Only at the record's build:
    /// another build is an update.
    func addRecheckedDepots(_ listed: AppDepots, receipt: InstallReceipt, root: URL, content: ContentClient,
                            servers: [GetServersForSteamPipeResponse.Server], say: @escaping @Sendable (String) -> Void) async throws
        -> (receipt: InstallReceipt, plan: InstallPlan, missing: [String])? {
        let branch = receipt.branch ?? Branch.publicName
        let app = try listed.onBranch(branch)
        guard app.publicBuildID == receipt.buildID else {
            throw SteamError.unsupported("app \(receipt.appID) is at build \(app.publicBuildID.map(String.init) ?? "?") on Steam, "
                                         + "\(receipt.buildID.map(String.init) ?? "?") here: update it rather than repair")
        }
        var options = DepotSelection.Options()
        options.ownedDepots = await ownedDepots(try requireSession(), say: say)
        let selection = try DepotSelection.select(app, options)
        let have = Set(receipt.depots.map(\.depotID))
        let joining = selection.depots.filter { !have.contains($0.depotID) && receipt.depotsToRecheck.contains($0.depotID) }
        var updated = receipt
        let recheck = Set(receipt.depotsToRecheck)
        // The rechecked depots' entries as the selection gives them now; every other entry is kept.
        updated.skippedDepots = receipt.skippedDepots.filter { e in
            DepotSelection.sharedInstall(skipped: e).map { !recheck.contains($0.depotID) } ?? true
        } + selection.skipped.filter { recheck.contains($0.depotID) }.map { "\($0.depotID): \($0.reason)" }
        for s in selection.skipped where recheck.contains(s.depotID) { say("  depot \(s.depotID) still skipped: \(s.reason)") }
        guard !joining.isEmpty else {
            try saveReceipt(updated)
            return nil
        }
        var manifests: [DepotManifest] = []
        for ref in receipt.depots {
            guard let m = try RetainedManifest.load(layout.manifestFile(ref)) else {
                throw SteamError.notFound("retained manifest \(ref.depotID)_\(ref.gid) is missing")
            }
            manifests.append(m)
        }
        var added: [DepotRef] = []
        for d in joining {
            let ref = DepotRef(depotID: d.depotID, gid: d.publicManifestGID!)
            say("  depot \(d.depotID) joins the install: gid \(ref.gid) size=\(d.publicManifestSize.map(String.init) ?? "?") (from app \(d.depotFromApp.map(String.init) ?? "-"))")
            let keyApp = app.keyAppID(depot: ref.depotID)
            let key = try await depotKey(content, appID: keyApp, depotID: ref.depotID, for: receipt.appID)
            manifests.append(try await manifest(ref, appID: keyApp, branch: branch, key: key, content: content, servers: servers, say: say))
            added.append(ref)
        }
        // Steam's install order, the selection's: a later depot overrides an earlier one by path.
        let order = selection.depots.map(\.depotID)
        manifests.sort { (order.firstIndex(of: $0.depotID) ?? Int.max) < (order.firstIndex(of: $1.depotID) ?? Int.max) }
        let plan = try InstallPlan.make(appID: receipt.appID, buildID: receipt.buildID, manifests: manifests)
        let joined = Set(added.map(\.depotID))
        let missing = try plan.files.filter { f in
            guard joined.contains(f.depotID) else { return false }
            let url = try InstallFS.resolveInside(root, SteamAPISwap.manifestFile(root, f.path), createParents: false)
            return !InstallEngine.fileMatches(url, size: f.size, hash: f.sha.map(FileHash.sha1) ?? .none)
        }.map(\.path)
        for d in plan.directories { try InstallFS.makeDirectory(try InstallFS.resolveInside(root, d, createParents: true)) }
        updated.depots = manifests.map { DepotRef(depotID: $0.depotID, gid: $0.gid) }
        updated.files = plan.files.count
        updated.bytes = plan.totalBytes
        try saveReceipt(updated)
        say("repair: depot(s) \(added.map(\.depotID)) added to the record, \(missing.count) files to download")
        return (updated, plan, missing)
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

    /// Where the title goes, whether it replaces this app's own earlier
    /// install, and the other Steam apps whose records name the same folder
    /// (then it is joined file by file, SharedInstallDir). An existing
    /// directory of the same name (compared without case, as the guest sees
    /// it) that is neither this app's nor another Steam app's install is never
    /// touched.
    func destination(_ name: String, appID: UInt32) throws -> (URL, replacing: Bool, sharing: [InstallReceipt]) {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: layout.gamesRoot.path)) ?? []
        guard let clash = existing.first(where: { $0.lowercased() == name.lowercased() }) else {
            return (layout.gamesRoot.appendingPathComponent(name, isDirectory: true), false, [])
        }
        let sharing = receipts(sharing: clash, except: appID)
        let own = loadReceipt(appID).map { $0.installDir == clash } ?? false
        guard own || !sharing.isEmpty else {
            throw SteamError.unsafeContent("Games/\(clash) already exists and is not this app's Playport install; refusing to install over it")
        }
        return (layout.gamesRoot.appendingPathComponent(clash, isDirectory: true), own, sharing)
    }

    /// The other Steam apps' records that name `folder` (compared without case).
    func receipts(sharing folder: String, except appID: UInt32) -> [InstallReceipt] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.installsDir.path)) ?? []
        return names.sorted().compactMap { n -> InstallReceipt? in
            guard n.hasSuffix(".json"), let id = UInt32(n.dropLast(5)), id != appID, let r = loadReceipt(id),
                  r.installDir.lowercased() == folder.lowercased() else { return nil }
            return r
        }
    }

    /// A record's plan from its retained manifests; throws when one is missing.
    func retainedPlan(_ r: InstallReceipt) throws -> InstallPlan {
        var manifests: [DepotManifest] = []
        for ref in r.depots {
            guard let m = try RetainedManifest.load(layout.manifestFile(ref)) else {
                throw SteamError.notFound("app \(r.appID)'s retained manifest \(ref.depotID)_\(ref.gid) is missing")
            }
            manifests.append(m)
        }
        return try InstallPlan.make(appID: r.appID, buildID: r.buildID, manifests: manifests)
    }

    /// Joins a folder other apps share: renames each staged file into place
    /// (over this app's previous copy), records the install, then removes the
    /// files this app's previous build listed that neither its new build nor
    /// another app lists. Not one rename: a kill part-way leaves files of both
    /// builds and the previous record, which the next install completes.
    func commitShared(_ tree: URL, plan: InstallPlan, staged: InstallPlan, to final: URL, others: SharedInstallDir.Others,
                      receipt: InstallReceipt) throws {
        let previous = loadReceipt(receipt.appID).flatMap { $0.installDir.lowercased() == receipt.installDir.lowercased() ? $0 : nil }
        var previousPaths: [String]?
        if let previous {
            do { previousPaths = try retainedPlan(previous).files.map(\.path) } catch {
                log.warn("install", "app \(receipt.appID): the previous build's files stay in Games/\(receipt.installDir) (\(error))")
            }
        }
        for d in plan.directories { try InstallFS.makeDirectory(try InstallFS.resolveInside(final, d, createParents: true)) }
        for f in staged.files {
            let src = try InstallFS.resolveInside(tree, f.path, createParents: false)
            let dst = try InstallFS.resolveInside(final, SteamAPISwap.manifestFile(final, f.path), createParents: true)
            guard rename(src.path, dst.path) == 0 else { throw SteamError.transport("shared commit rename \(f.path) errno \(errno)") }
        }
        try saveReceipt(receipt)
        if let previousPaths {
            let now = Set(plan.files.map { $0.path.lowercased() })
            let stale = SharedInstallDir.removable(previousPaths.filter { !now.contains($0.lowercased()) }, others: others)
            removeFiles(stale, directories: [], in: final, keep: { dir in
                others.needs(directory: dir) || now.contains { $0.hasPrefix(dir.lowercased() + "/") }
            })
        }
        try? FileManager.default.removeItem(at: tree)
    }

    /// Unlinks `paths` under `root` (and a swapped DLL's kept original), then
    /// every directory left empty among `directories` and the removed files'
    /// parents, deepest first, unless `keep` names it. The number of files removed.
    @discardableResult
    func removeFiles(_ paths: [String], directories: [String], in root: URL, keep: (String) -> Bool) -> Int {
        var removed = 0
        var dirs = Set(directories)
        for p in paths {
            for candidate in Set([p, SteamAPISwap.manifestFile(root, p)]) {
                guard let url = try? InstallFS.resolveInside(root, candidate, createParents: false) else { continue }
                if unlink(url.path) == 0, candidate == p { removed += 1 }
            }
            var parent = p
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                dirs.insert(parent)
            }
        }
        for d in dirs.sorted(by: { $0.count > $1.count }) where !keep(d) {
            guard let url = try? InstallFS.resolveInside(root, d, createParents: false) else { continue }
            _ = rmdir(url.path)    // fails, and keeps it, when anything is left in it
        }
        return removed
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
    /// under the prefix's user profile are outside the folder and stay. A
    /// folder another Steam app's record names keeps that app's files
    /// (uninstallShared). A retained manifest another record names stays.
    public func uninstall(installDir: String, appID: UInt32?) throws {
        let name = try Self.destinationName(installDir)
        let dir = layout.gamesRoot.appendingPathComponent(name, isDirectory: true)
        if let appID, let own = loadReceipt(appID), own.installDir.lowercased() == name.lowercased() {
            let sharing = receipts(sharing: name, except: appID)
            if !sharing.isEmpty {
                uninstallShared(own, sharing: sharing)
                return
            }
        }
        if FileManager.default.fileExists(atPath: dir.path) {
            try InstallFS.makeDirectory(layout.stagingRoot)
            let aside = layout.stagingRoot.appendingPathComponent("removed-\(UUID().uuidString)")
            guard rename(dir.path, aside.path) == 0 else {
                throw SteamError.transport("cannot move Games/\(name) out for removal (errno \(errno))")
            }
            try? FileManager.default.removeItem(at: aside)
        }
        guard let appID else { return }
        if let r = loadReceipt(appID), r.installDir.lowercased() == name.lowercased() { forget(r) }
        discardStage(appID: appID)
    }

    /// Leaves a folder other Steam apps share: removes the files of this app's
    /// plan that no other app's plan lists, and the directories that leaves
    /// empty, then its record. When a retained manifest of this app or another
    /// is missing, which files are whose is unknown: every file stays and only
    /// the record goes (logged), since a game's files are worth more than the
    /// space. Not one rename, as a whole-folder uninstall is: a kill part-way
    /// leaves the record, and the next uninstall finishes.
    func uninstallShared(_ own: InstallReceipt, sharing: [InstallReceipt]) {
        let root = layout.gamesRoot.appendingPathComponent(own.installDir, isDirectory: true)
        let ids = sharing.map { String($0.appID) }.joined(separator: ", ")
        do {
            let plan = try retainedPlan(own)
            let others = SharedInstallDir.Others(try sharing.map { try retainedPlan($0) })
            let gone = SharedInstallDir.removable(plan.files.map(\.path), others: others)
            let removed = removeFiles(gone, directories: plan.directories, in: root, keep: { others.needs(directory: $0) })
            log.info("uninstall", "app \(own.appID): \(removed) of its \(plan.files.count) files removed from the shared Games/\(own.installDir); "
                     + "the rest are app(s) \(ids)'s too")
        } catch {
            log.warn("uninstall", "app \(own.appID): every file stays in Games/\(own.installDir), shared with app(s) \(ids): \(error); only its record goes")
        }
        forget(own)
        discardStage(appID: own.appID)
    }

    /// Deletes a record and its retained manifests that no other record names.
    func forget(_ r: InstallReceipt) {
        try? FileManager.default.removeItem(at: layout.receiptFile(appID: r.appID))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.installsDir.path)) ?? []
        let kept = Set(names.compactMap { n -> UInt32? in n.hasSuffix(".json") ? UInt32(n.dropLast(5)) : nil }
            .compactMap { loadReceipt($0)?.depots }.joined())
        for ref in r.depots where !kept.contains(ref) { try? FileManager.default.removeItem(at: layout.manifestFile(ref)) }
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
            + (r.depotsToRecheck.isEmpty ? "" : "; depots to check with Steam: \(r.depotsToRecheck.map(String.init).joined(separator: ", "))")
    }
}
