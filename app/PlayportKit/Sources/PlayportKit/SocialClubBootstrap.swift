// SPDX-License-Identifier: GPL-3.0-or-later
// Whether a Play holds the Social Club layout (decision 0169 as amended by 0183, PLA-840): only when what
// the Play starts is a Rockstar bootstrap Playport verified by hash, a program that starts Rockstar's
// launcher or the launcher that starts the Social Club helper. A title or launcher key plays no part,
// and the helper itself cannot decide it: SocialClubHelper.exe lives in the shared prefix, missing until
// the launcher's first run, and the layout must be known before the runtime starts, since libcef's range
// at 0x7000000000 comes from wine_host.c's hold at exec. The app checks at Play, before the runtime
// starts, and sets PLAYPORT_SC_LAYOUT=1 for wine_host.c and ntdll (madeira-unix 0225) only then.
//
// - A game's Play: its install folder. RDR2's Steam copy's bootstrap is PlayRDR2.exe (Rockstar Games
//   Launcher Redirector) with the launcher's installer it runs when the launcher is missing,
//   `Redistributables/Rockstar-Games-Launcher.exe` from depot 1899671: both are in the game's folder
//   from its install on, so its first run is covered, while Launcher.exe is in the shared prefix.
// - The Open of Rockstar's launcher (Settings › Launchers): the launcher's install folder in the prefix,
//   whose Launcher.exe the Open starts.
// A folder without every file of an entry, or with one unverified (a Steam update replaces
// PlayRDR2.exe, the launcher updates itself), holds no Social Club range. A file's hash is kept with
// its size and modification time (HashCache), so the 111 MB installer is read once per version, not at
// every Play; a file whose size no entry has is hashed only for a dev build's log, which names what to
// add here.

import Foundation
import SteamClientKit

public struct SocialClubBootstrap: Equatable, Sendable {
    /// Which folder an entry's files are in.
    public enum Place: Equatable, Sendable {
        /// The game's install folder.
        case game
        /// The install folder of the publisher's launcher the Open starts.
        case launcher

        var folder: String { self == .game ? "the game's folder" : "the launcher's folder" }
    }

    public struct File: Equatable, Sendable {
        /// Relative to the entry's folder, `/`-separated.
        public let path: String
        public let size: UInt64
        /// Lowercase hex.
        public let sha256: String

        public init(path: String, size: UInt64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public let name: String
    public let place: Place
    /// Every one must be in the folder with its size and hash.
    public let files: [File]

    public init(name: String, place: Place, files: [File]) {
        self.name = name
        self.place = place
        self.files = files
    }

    /// Red Dead Redemption 2's Steam copy (app 1174180, buildid 13773296): the phone's PlayRDR2.exe
    /// (docs/evidence/2026-10-18-rockstar-desktop-comparison.md) and depot 1899671's installer 1.0.109.3031
    /// (docs/evidence/2026-10-15-rockstar-launcher-recon.md, byte-identical to Rockstar's download).
    public static let rdr2Steam = SocialClubBootstrap(name: "Red Dead Redemption 2 (Steam)", place: .game, files: [
        File(path: "PlayRDR2.exe", size: 507_888,
             sha256: "028db16cbd90c7ab07358a7d6dfc981800b6fd4f1583d9b39fe5ea0441d9483d"),
        File(path: "Redistributables/Rockstar-Games-Launcher.exe", size: 111_419_512,
             sha256: "321886457b7e4ab727a27671c17a815684a3943579eedf7e2248a3b9f0973746"),
    ])

    /// Rockstar Games Launcher 1.0.109.3031's Launcher.exe, as that installer and the launcher's first
    /// self-update left it in Stage R's prefixes (2026-10-15, PLA-291); the phone's runs since then map an
    /// image of its size.
    public static let rockstarLauncher = SocialClubBootstrap(name: "Rockstar Games Launcher 1.0.109.3031", place: .launcher,
                                                             files: [
        File(path: "Launcher.exe", size: 29_920_888,
             sha256: "d47e8c82c6b422724ab89866cd635ba247c50290ec70ac2bf765518e4af894cf"),
    ])

    /// The bootstraps that engage the layout.
    public static let verified: [SocialClubBootstrap] = [rdr2Steam, rockstarLauncher]

    /// Each file's SHA-256 as last computed, keyed by its full path and valid while its size and
    /// modification time are unchanged. The app keeps it between Plays.
    public struct HashCache: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var size: UInt64
            public var modified: Double
            public var sha256: String
        }

        public var entries: [String: Entry] = [:]

        public init() {}
    }

    /// A file of the table found in the folder.
    public struct Observation: Equatable, Sendable {
        public let path: String
        public let size: UInt64
        /// Nil when not read: no entry has its size and the check hashes no mismatch.
        public let sha256: String?
        /// Some entry lists this path with this size and hash.
        public let verified: Bool
    }

    public struct Verdict: Equatable, Sendable {
        public let place: Place
        /// The verified bootstrap the folder holds; nil holds no layout.
        public let bootstrap: SocialClubBootstrap?
        /// Every file of the place's entries found in the folder, in the table's order.
        public let observed: [Observation]

        public var engaged: Bool { bootstrap != nil }

        /// The Play's log lines; `hashes` adds an unverified file's SHA-256 (a dev build's).
        public func logLines(hashes: Bool) -> [String] {
            if let b = bootstrap {
                return ["the Social Club layout is on: verified Rockstar bootstrap \(b.name) ("
                        + b.files.map(\.path).joined(separator: ", ") + ")"]
            }
            guard !observed.isEmpty else { return ["the Social Club layout is off: no Rockstar bootstrap in \(place.folder)"] }
            return ["the Social Club layout is off: the Rockstar bootstrap in \(place.folder) is not one Playport verified"]
                + observed.map { o in
                    "bootstrap \(o.path): \(o.size) B, "
                        + (o.verified ? "verified" : (hashes ? o.sha256.map { "sha256 \($0), " } ?? "" : "") + "not in the table")
                }
        }
    }

    /// The folder's verdict against `table`'s entries for `place`. Reads only their files, and hashes
    /// one only when its size is an entry's (or `hashMismatches`) and `cache` has no hash for its size
    /// and modification time; `cache` gets every hash computed. Reads files: not on the main thread.
    public static func check(folder: URL, place: Place, table: [SocialClubBootstrap] = verified,
                             cache: inout HashCache, hashMismatches: Bool) -> Verdict {
        let entries = table.filter { $0.place == place }
        let files = entries.flatMap(\.files)
        var paths: [String] = []
        for f in files where !paths.contains(f.path) { paths.append(f.path) }
        var observed: [Observation] = []
        for path in paths {
            let url = path.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            let listed = files.filter { $0.path == path }
            var sha: String?
            if let c = cache.entries[url.path], c.size == size, c.modified == modified {
                sha = c.sha256
            } else if hashMismatches || listed.contains(where: { $0.size == size }), let digest = InstallFS.sha256(url) {
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                cache.entries[url.path] = .init(size: size, modified: modified, sha256: hex)
                sha = hex
            }
            observed.append(Observation(path: path, size: size, sha256: sha,
                                        verified: listed.contains { $0.size == size && $0.sha256 == sha }))
        }
        let bootstrap = entries.first { b in
            b.files.allSatisfy { f in observed.contains { $0.path == f.path && $0.size == f.size && $0.sha256 == f.sha256 } }
        }
        return Verdict(place: place, bootstrap: bootstrap, observed: observed)
    }
}
