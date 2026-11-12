// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What each file of a Steam install looked like (size, modification time, inode) when it last matched
/// its manifest's SHA-1: recorded by an install's commit for the files its stage verified, and by every
/// check (Verify, a repair's) for the files that passed. A file that no longer looks so was written
/// since, by anything: `TitleInstaller.recheck` reads only these and hashes only such files, so a copy
/// damaged after it was verified is found without hashing the title (PLA-850: The Witcher 3's
/// `content/metadata.store` stopped matching some time after a branch switch that had verified it,
/// and nothing said so before Play).
struct VerifiedStamps: Codable {
    struct Look: Codable, Equatable {
        var s: UInt64
        /// Modification time, nanoseconds since 1970.
        var m: Int64
        var i: UInt64
    }

    var version = 1
    /// By the manifest's path.
    var files: [String: Look]

    static func look(_ url: URL) -> Look? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        #if canImport(Darwin)
        let t = st.st_mtimespec
        #else
        let t = st.st_mtim
        #endif
        return Look(s: UInt64(st.st_size), m: Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec), i: UInt64(st.st_ino))
    }

    /// Where verify and repair read a manifest file: a swapped steam_api DLL's kept original (SteamAPISwap).
    static func location(_ root: URL, _ path: String) -> URL? {
        try? InstallFS.resolveInside(root, SteamAPISwap.manifestFile(root, path), createParents: false)
    }

    static func load(_ url: URL) -> VerifiedStamps? {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(VerifiedStamps.self, from: data),
              s.version == 1 else { return nil }
        return s
    }

    /// The recorded files that look otherwise now, or are gone.
    func changed(root: URL) -> [String] {
        files.compactMap { path, look in Self.location(root, path).flatMap(Self.look) == look ? nil : path }.sorted()
    }

    /// Whether `path` was recorded and looks otherwise now.
    func written(_ path: String, root: URL) -> Bool {
        guard let look = files[path] else { return false }
        return Self.location(root, path).flatMap(Self.look) != look
    }
}

extension TitleInstaller {
    /// A check of an install by its files' recorded looks (VerifiedStamps).
    public struct Recheck: Sendable {
        /// Files the install lists.
        public var files: Int
        /// Files written since they were verified, or gone: each hashed again.
        public var changed: [String]
        /// Of those, the ones that no longer match the manifest.
        public var bad: [String]
        /// What is wrong with each bad one (VerifyReport.notes).
        public var notes: [String]
    }

    /// Reads each verified file's size, time and inode, and hashes against the manifest only the files
    /// written since; those that still match are recorded again. Nil when nothing was recorded for the
    /// app (no install, or one from before the record). No session needed.
    public func recheck(appID: UInt32) async throws -> Recheck? {
        guard let receipt = loadReceipt(appID), let stamps = VerifiedStamps.load(layout.verifiedFile(appID: appID)) else { return nil }
        let changed = stamps.changed(root: layout.gamesRoot.appendingPathComponent(receipt.installDir, isDirectory: true))
        guard !changed.isEmpty else { return Recheck(files: receipt.files, changed: [], bad: [], notes: []) }
        let v = try await verifyPlan(appID: appID, concurrency: 2, only: Set(changed))
        return Recheck(files: v.plan.files.count, changed: changed, bad: v.report.bad, notes: v.report.notes)
    }

    /// Records `paths` (the manifest's) under `root` as verified now: over the record's entries for
    /// `keeping`, or in a new record. Advisory: a record that cannot be written is logged.
    func recordVerified(appID: UInt32, root: URL, paths: [String], keeping: Set<String>?) {
        var stamps = VerifiedStamps(files: [:])
        if let keeping, let old = VerifiedStamps.load(layout.verifiedFile(appID: appID)) {
            stamps.files = old.files.filter { keeping.contains($0.key) }
        }
        for p in paths {
            stamps.files[p] = VerifiedStamps.location(root, p).flatMap(VerifiedStamps.look)
        }
        do {
            try InstallFS.makeDirectory(layout.installsDir)
            try InstallFS.writeAtomically(layout.verifiedFile(appID: appID), JSONEncoder().encode(stamps))
        } catch {
            log.warn("install", "app \(appID): which files were verified is not recorded (\(error)); the next check hashes them all")
        }
    }

    /// What is wrong with `f`, which failed its hash at `url`, for a log line.
    static func note(_ f: InstallPlan.File, at url: URL, stamps: VerifiedStamps?, root: URL) -> String {
        guard let size = InstallFS.fileSize(url) else { return "\(f.path): missing" }
        let what = size == f.size ? "other content at the manifest's size" : "\(size) bytes, the manifest's \(f.size)"
        return "\(f.path): \(what)" + (stamps?.written(f.path, root: root) == true ? ", written since it was verified" : "")
    }
}
