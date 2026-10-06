// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's Steam Cloud files on the phone (docs/plans/finished.md#steam-for-games,
/// phase 4).
///
/// Steam names a cloud file by a root token and a path:
/// `%WinAppDataLocalLow%Team Cherry/Hollow Knight/user1.dat`. A file a game
/// writes through the Steam API itself (ISteamRemoteStorage) has no token;
/// under the emulator it is in `GSE Saves/<appid>/remote/`. Which local files
/// are cloud files comes from PICS `ufs/savefiles` (root, path, pattern,
/// recursive, platforms).
public enum Cloud {
    /// Where each root is in the prefix.
    public struct Roots: Sendable, Equatable {
        /// `C:\users\playport`.
        public var user: URL
        /// The game's folder under `C:\Games`.
        public var gameInstall: URL
        /// The emulator's remote storage for the game: `GSE Saves/<appid>/remote`.
        public var remote: URL

        public init(user: URL, gameInstall: URL, remote: URL) {
            self.user = user
            self.gameInstall = gameInstall
            self.remote = remote
        }

        /// A root token's folder; nil for a root Playport does not map.
        public func folder(_ token: String) -> URL? {
            switch token.lowercased() {
            case "": remote
            case "gameinstall": gameInstall
            case "winmydocuments": user.appendingPathComponent("Documents", isDirectory: true)
            case "winappdatalocal": user.appendingPathComponent("AppData/Local", isDirectory: true)
            case "winappdatalocallow": user.appendingPathComponent("AppData/LocalLow", isDirectory: true)
            case "winappdataroaming": user.appendingPathComponent("AppData/Roaming", isDirectory: true)
            case "winsavedgames": user.appendingPathComponent("Saved Games", isDirectory: true)
            default: nil
            }
        }

        /// The local file for a cloud name; nil when its root is not mapped or
        /// its path leaves the root.
        public func file(_ name: String) -> URL? {
            let (token, rest) = Cloud.split(name)
            guard let base = folder(token) else { return nil }
            let parts = rest.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
            return Cloud.resolve(parts, in: base)
        }
    }

    /// Steam's spelling of a root token, as its file list names a file a
    /// Windows client uploaded: a PICS rule may spell it in another case
    /// (Portal 2's `gameinstall`). A token Playport does not map stays as given.
    static func canonicalRoot(_ token: String) -> String {
        let steam = ["GameInstall", "WinMyDocuments", "WinAppDataLocal", "WinAppDataLocalLow", "WinAppDataRoaming", "WinSavedGames"]
        return steam.first { $0.lowercased() == token.lowercased() } ?? token
    }

    /// The local files under the names Steam already uses. Steam takes cloud
    /// names without case (an upload of a name that differs from a stored one
    /// only in case is refused as a duplicate), and so does the prefix's file
    /// system, so a local name that matches one of `names` without case takes
    /// that spelling; an earlier entry of `names` wins. Local names that become
    /// one keep the file of the first in sorted order.
    public static func named(_ files: [String: URL], like names: [String]) -> [String: URL] {
        var spelling: [String: String] = [:]
        for n in names where spelling[n.lowercased()] == nil { spelling[n.lowercased()] = n }
        var out: [String: URL] = [:]
        for (name, url) in files.sorted(by: { $0.key < $1.key }) {
            let key = spelling[name.lowercased()] ?? name
            if out[key] == nil { out[key] = url }
        }
        return out
    }

    /// `%Token%rest` into the token (empty for none) and the rest.
    static func split(_ name: String) -> (String, String) {
        guard name.hasPrefix("%"), let end = name.dropFirst().firstIndex(of: "%") else { return ("", name) }
        return (String(name[name.index(after: name.startIndex)..<end]), String(name[name.index(after: end)...]))
    }

    /// Each component matched without case against what is on disk, as the
    /// guest sees it; components that do not exist yet are taken as given.
    static func resolve(_ parts: [String], in base: URL) -> URL {
        var at = base
        for p in parts {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []
            at = at.appendingPathComponent(names.first { $0 == p } ?? names.first { $0.lowercased() == p.lowercased() } ?? p)
        }
        return at
    }

    /// One `ufs/savefiles` rule.
    public struct SaveRule: Sendable, Equatable {
        public var root: String
        public var path: String
        public var pattern: String
        public var recursive: Bool
    }

    /// The app's Windows save rules (PICS `ufs/savefiles`; a rule for other
    /// platforms only is skipped).
    public static func rules(_ app: KeyValue) -> [SaveRule] {
        (app.path("ufs", "savefiles")?.children ?? []).compactMap { r in
            let platforms = (r["platforms"]?.children ?? []).compactMap(\.value).map { $0.lowercased() }
            guard platforms.isEmpty || platforms.contains("windows") || platforms.contains("all") else { return nil }
            return SaveRule(root: r["root"]?.value ?? "", path: r["path"]?.value ?? "", pattern: r["pattern"]?.value ?? "*",
                            recursive: r["recursive"]?.value == "1")
        }
    }

    /// The local files the rules cover, by cloud name, and the emulator's
    /// remote storage (every file under it).
    public static func localFiles(rules: [SaveRule], roots: Roots, steamID: UInt64) -> [String: URL] {
        var out: [String: URL] = [:]
        for r in rules + [SaveRule(root: "", path: "", pattern: "*", recursive: true)] {
            guard let base = roots.folder(r.root) else { continue }
            let rel = substitute(r.path, steamID: steamID)
                .split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init).filter { $0 != "." }
            guard !rel.contains("..") else { continue }
            let dir = rel.isEmpty ? base : resolve(rel, in: base)
            for file in TitleInstaller.regularFiles(under: dir) {
                let parts = file.split(separator: "/")
                guard r.recursive || parts.count == 1, glob(r.pattern, String(parts.last ?? "")) else { continue }
                let prefix = r.root.isEmpty ? "" : "%\(canonicalRoot(r.root))%"
                let path = (rel + [file]).joined(separator: "/")
                out[prefix + path] = dir.appendingPathComponent(file)
            }
        }
        return out
    }

    /// The path tokens Steam puts in a rule for the account.
    static func substitute(_ path: String, steamID: UInt64) -> String {
        path.replacingOccurrences(of: "{64BitSteamID}", with: String(steamID))
            .replacingOccurrences(of: "{Steam3AccountID}", with: String(steamID & 0xFFFF_FFFF))
    }

    /// `*` and `?` against a file name, without case.
    static func glob(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.lowercased()), n = Array(name.lowercased())
        var memo = [[Bool?]](repeating: [Bool?](repeating: nil, count: n.count + 1), count: p.count + 1)
        func m(_ i: Int, _ j: Int) -> Bool {
            if let v = memo[i][j] { return v }
            let r: Bool
            if i == p.count { r = j == n.count }
            else if p[i] == "*" { r = m(i + 1, j) || (j < n.count && m(i, j + 1)) }
            else { r = j < n.count && (p[i] == "?" || p[i] == n[j]) && m(i + 1, j + 1) }
            memo[i][j] = r
            return r
        }
        return m(0, 0)
    }

    // MARK: what to do

    /// A cloud file as Steam lists it.
    public struct Remote: Sendable, Equatable, Codable {
        public var name: String
        /// SHA-1 of the file's content, hex.
        public var sha: String
        public var size: UInt32
        public var time: UInt64
    }

    /// What the last sync left: Steam's change number and every file's SHA-1.
    public struct Baseline: Sendable, Equatable, Codable {
        public var changeNumber: UInt64
        public var files: [String: String]
    }

    public enum Action: String, Sendable, Equatable, Codable {
        case download, upload, conflict
    }

    /// Per file:
    /// - the same on both sides: nothing;
    /// - changed on one side since the last sync: that side wins;
    /// - changed on both, or different with no last sync to tell: a conflict,
    ///   which the player settles;
    /// - on Steam only: downloaded, unless it was synced before (the phone
    ///   deleted it: deletions are not carried);
    /// - on the phone only: uploaded when it is new or changed since the last
    ///   sync; a game's first sync uploads nothing.
    public static func plan(remote: [String: Remote], local: [String: String], baseline: Baseline?) -> [String: Action] {
        var out: [String: Action] = [:]
        for name in Set(remote.keys).union(local.keys) {
            let r = remote[name]?.sha, l = local[name], b = baseline?.files[name]
            switch (r, l) {
            case let (r?, l?):
                if r == l { continue }
                if b == nil { out[name] = .conflict }
                else if l == b { out[name] = .download }
                else if r == b { out[name] = .upload }
                else { out[name] = .conflict }
            case (_?, nil):
                if b == nil { out[name] = .download }
            case (nil, let l?):
                if baseline != nil, b != l { out[name] = .upload }
            case (nil, nil):
                continue
            }
        }
        return out
    }

    /// A downloaded body as the file's content: as is, or the single entry of
    /// a zip Steam sends when the stored size differs from the raw size. It
    /// must hash to `sha` either way.
    public static func content(_ body: [UInt8], rawSize: UInt32, sha: String) throws -> [UInt8] {
        var data = body
        if body.count != Int(rawSize) || (body.starts(with: [0x50, 0x4B, 0x03, 0x04]) && SHA1.hash(body).hex != sha) {
            data = try ZipSingleEntry.extract(body, maxSize: Int(rawSize) + 1)
        }
        guard data.count == Int(rawSize), SHA1.hash(data).hex == sha else {
            throw SteamError.verificationFailed("cloud file does not match Steam's size and SHA-1")
        }
        return data
    }
}

extension Cloud {
    /// The copies a sync replaced: `<root>/<appid>/<time>/`, one folder per
    /// game and sync (SteamService.syncCloud). The side the player did not
    /// keep in a conflict, and a phone copy a download replaced, stay there
    /// for `keep` (30 days), then `prune` removes them.
    public enum Backups {
        public static let keep: TimeInterval = 30 * 24 * 3600

        /// A sync's folder name: its time in ISO 8601, with `-` for `:` (Files shows no colons).
        public static func folderName(for date: Date) -> String {
            ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        }

        /// The time a folder name carries; nil for a name `folderName` did not make.
        public static func date(ofFolder name: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ssXXXXX"
            return f.date(from: name)
        }

        /// The sync folders under `root` older than `keep` at `now`. A folder
        /// whose name carries no time goes by its modification date.
        public static func expired(in root: URL, now: Date = Date(), keep: TimeInterval = Backups.keep) -> [URL] {
            let fm = FileManager.default
            let apps = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            var out: [URL] = []
            for app in apps.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let syncs = (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for sync in syncs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let made = date(ofFolder: sync.lastPathComponent)
                        ?? (try? sync.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    if let made, now.timeIntervalSince(made) > keep { out.append(sync) }
                }
            }
            return out
        }

        /// Removes the expired sync folders, and a game's folder left empty;
        /// returns what it removed.
        @discardableResult
        public static func prune(_ root: URL, now: Date = Date(), keep: TimeInterval = Backups.keep) -> [URL] {
            let fm = FileManager.default
            var removed: [URL] = []
            for url in expired(in: root, now: now, keep: keep) where (try? fm.removeItem(at: url)) != nil {
                removed.append(url)
                let app = url.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: app.path))?.isEmpty == true { try? fm.removeItem(at: app) }
            }
            return removed
        }
    }
}
