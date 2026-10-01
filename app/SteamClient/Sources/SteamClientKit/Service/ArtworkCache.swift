// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Capsule and hero art from Steam's public store-asset CDN, by the paths PICS
/// gives (`<sha1>/library_capsule.jpg`), cached on disk. No session, token or
/// secret is involved: the same URLs serve anyone. A path that changes on
/// Steam's side is a new file here, so a cached file never goes stale.
public actor ArtworkCache {
    public enum Kind: String, Sendable, CaseIterable {
        case capsule, hero, header

        /// The unhashed legacy name, used when PICS lists no asset path.
        var fallback: String {
            switch self {
            case .capsule: return "library_600x900.jpg"
            case .hero: return "library_hero.jpg"
            case .header: return "header.jpg"
            }
        }
    }

    public static let cdn = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/")!
    public static let maxBytes = 8 << 20

    public let directory: URL
    private let fetch: @Sendable (URL) async throws -> [UInt8]
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(directory: URL, log: Logger) {
        let http = HTTPClient(log: log)
        self.init(directory: directory) { url in
            try await http.get(url, maxBytes: ArtworkCache.maxBytes, label: "store asset \(url.lastPathComponent)")
        }
    }

    /// With an injected fetch, for tests.
    public init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> [UInt8]) {
        self.directory = directory
        self.fetch = fetch
    }

    /// The asset path for `kind`: PICS's hashed path, else the legacy name.
    public static func assetPath(_ app: SteamAppInfo, _ kind: Kind) -> String {
        let p: String?
        switch kind {
        case .capsule: p = app.art.capsule
        case .hero: p = app.art.hero
        case .header: p = app.art.header
        }
        return p.flatMap { isSafe($0) ? $0 : nil } ?? kind.fallback
    }

    /// Only `[A-Za-z0-9_.-]` components, none of them `.` or `..`: a PICS value
    /// can never climb out of the app's directory, here or on the CDN.
    static func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." &&
                part.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "_.-".unicodeScalars.contains($0) }
        }
    }

    public static func remoteURL(appID: UInt32, path: String) -> URL {
        cdn.appendingPathComponent(String(appID)).appendingPathComponent(path)
    }

    public func localURL(appID: UInt32, path: String) -> URL {
        directory.appendingPathComponent(String(appID)).appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    /// The cached file, if already on disk (no network).
    public func cached(_ app: SteamAppInfo, _ kind: Kind) -> URL? {
        let u = localURL(appID: app.appID, path: Self.assetPath(app, kind))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// The local file for the art, fetched once and then served from disk.
    /// Concurrent requests for one file share a download.
    public func image(_ app: SteamAppInfo, _ kind: Kind) async throws -> URL {
        let path = Self.assetPath(app, kind)
        let local = localURL(appID: app.appID, path: path)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let key = local.path
        if let t = inFlight[key] { return try await t.value }
        let remote = Self.remoteURL(appID: app.appID, path: path)
        let fetch = self.fetch
        let t = Task { () throws -> URL in
            let bytes = try await fetch(remote)
            guard bytes.count <= Self.maxBytes, Self.looksLikeImage(bytes) else {
                throw SteamError.unsafeContent("store asset \(path) is not an image")
            }
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: local, options: .atomic)
            return local
        }
        inFlight[key] = t
        defer { inFlight[key] = nil }
        return try await t.value
    }

    /// JPEG or PNG magic.
    static func looksLikeImage(_ b: [UInt8]) -> Bool {
        b.starts(with: [0xFF, 0xD8, 0xFF]) || b.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// Deletes every cached file. Sign-out calls it with the rest of the
    /// cached account data: which apps have art here says what the account owns.
    public func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
