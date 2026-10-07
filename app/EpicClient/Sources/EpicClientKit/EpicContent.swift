// SPDX-License-Identifier: GPL-3.0-or-later
// Epic's content (plan 3.1, measured):
//
//   asset     launcher-public-service-prod06…/assets/v2/platform/Windows/namespace/NS/
//             catalogItem/ID/app/APP/label/Live: the build version, the SHA-1 of the
//             manifest file, and the manifest on several CDNs, each URL with its own token
//   manifest  the URL with its query; binary (EpicManifest)
//   chunks    under each manifest URL's folder, with no query: ChunksV4/GG/HASH_GUID.chunk

import Foundation
import ContentKit

public struct EpicAsset: Sendable, Equatable {
    public struct Location: Sendable, Equatable {
        /// The manifest URL with its signed query: fetched, never logged or kept.
        public var manifest: URL
        /// The folder the chunks are under (no query).
        public var base: URL
    }

    public var buildVersion: String
    /// The SHA-1 of the manifest file.
    public var hash: [UInt8]?
    public var locations: [Location]
    /// Public, build-scoped EOS identity from the Live asset's sidecar.
    public var deploymentID: String? = nil
    public var sidecarRvn: Int? = nil
}

public enum EpicContent {
    static func safeID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    static func safeDeploymentID(_ s: String) -> Bool { s.utf8.count == 32 && hex(s) != nil }

    public static func asset(_ session: EpicSession, _ g: EpicGame) async throws -> EpicAsset {
        guard safeID(g.id), safeID(g.namespace), safeID(g.catalogItemID) else { throw ClientError.unsafeContent("Epic game IDs") }
        let url = URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/v2/platform/Windows/"
                      + "namespace/\(g.namespace)/catalogItem/\(g.catalogItemID)/app/\(g.id)/label/Live")!
        return try parseAsset(try await session.authorized(url, maxBytes: 1 << 20, label: "Epic asset \(g.id)"))
    }

    static func parseAsset(_ body: [UInt8]) throws -> EpicAsset {
        struct Raw: Decodable {
            struct Element: Decodable {
                struct M: Decodable {
                    struct Q: Decodable { var name: String; var value: String }
                    var uri: String
                    var queryParams: [Q]?
                }
                struct Sidecar: Decodable {
                    var config: String?
                    var rvn: Int?
                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: CodingKeys.self)
                        config = try? c.decode(String.self, forKey: .config)
                        rvn = try? c.decode(Int.self, forKey: .rvn)
                    }
                    enum CodingKeys: String, CodingKey { case config, rvn }
                }
                var buildVersion: String
                var hash: String?
                var manifests: [M]
                var sidecar: Sidecar?
            }
            var elements: [Element]
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: Data(body)), let e = r.elements.first else {
            throw ClientError.protocolChanged("Epic asset: unexpected reply")
        }
        let locations = e.manifests.compactMap { m -> EpicAsset.Location? in
            guard var c = URLComponents(string: m.uri), c.scheme == "https", c.host != nil else { return nil }
            c.query = nil
            guard let plain = c.url else { return nil }
            if let q = m.queryParams, !q.isEmpty { c.queryItems = q.map { URLQueryItem(name: $0.name, value: $0.value) } }
            guard let full = c.url else { return nil }
            return .init(manifest: full, base: plain.deletingLastPathComponent())
        }
        guard !locations.isEmpty else { throw ClientError.notFound("Epic lists no manifest for this game") }
        let hash = e.hash.flatMap { $0.count == 40 ? hex($0) : nil }
        struct Config: Decodable { var deploymentId: String? }
        let deployment = e.sidecar?.config.flatMap {
            (try? JSONDecoder().decode(Config.self, from: Data($0.utf8)))?.deploymentId
        }.flatMap { safeDeploymentID($0) ? $0 : nil }
        return EpicAsset(buildVersion: e.buildVersion, hash: hash, locations: locations,
                         deploymentID: deployment, sidecarRvn: e.sidecar?.rvn)
    }

    /// The manifest from the first CDN that has it, checked against the asset's SHA-1.
    /// Returns the file's bytes too, kept beside the install for verify and updates.
    public static func manifest(_ session: EpicSession, _ a: EpicAsset) async throws -> (EpicManifest, [UInt8]) {
        var last: Error = ClientError.notFound("Epic manifest")
        for l in a.locations {
            do {
                let raw = try await session.plain(l.manifest, maxBytes: 256 << 20, label: "Epic manifest from \(l.base.host ?? "?")")
                if let h = a.hash, SHA1.hash(raw) != h { throw ClientError.verificationFailed("Epic manifest does not match the asset's SHA-1") }
                return (try EpicManifest.parse(raw), raw)
            } catch ClientError.cancelled {
                throw ClientError.cancelled
            } catch {
                last = error
            }
        }
        throw last
    }

    /// The manifest's files as ContentKit's plan: each chunk keyed by GUID and
    /// SHA-1-checked, each file's parts slices of chunks, each file SHA-1-checked.
    /// Symlinks are skipped (none seen); `only` limits it to those paths (an update, a repair).
    public static func plan(_ m: EpicManifest, only: Set<String>? = nil) throws -> ContentPlan {
        let chosen = m.files.filter { $0.symlinkTarget.isEmpty && (only?.contains($0.path.lowercased()) ?? true) }.sorted { $0.path < $1.path }
        var seen = Set<String>()
        var dirs = Set<String>()
        for f in chosen {
            guard seen.insert(f.path.lowercased()).inserted else { throw ClientError.unsafeContent("\(f.path) is listed twice") }
            let parts = f.path.split(separator: "/")
            for i in 1..<max(1, parts.count) { dirs.insert(parts[0..<i].joined(separator: "/").lowercased()) }
        }
        for d in dirs where seen.contains(d) { throw ClientError.unsafeContent("\(d) is a file and a folder") }
        var chunks: [ContentChunk] = []
        var index: [Int: Int] = [:]
        var id = SHA1Stream()
        id.update(Array("playport-epic-1 app=\(m.appName) build=\(m.buildVersion)\n".utf8))
        let files = chosen.map { f -> ContentFile in
            var at: UInt64 = 0
            let parts = f.parts.map { p -> ContentPart in
                let k: Int
                if let have = index[p.chunk] { k = have } else {
                    let c = m.chunks[p.chunk]
                    k = chunks.count
                    index[p.chunk] = k
                    chunks.append(ContentChunk(key: c.guid, size: c.window, compressedSize: UInt32(clamping: c.fileSize), check: .sha1(c.sha1),
                                               group: UInt32(c.group), locator: m.chunkPath(c)))
                }
                defer { at += UInt64(p.size) }
                return ContentPart(chunk: k, offsetInChunk: p.offset, length: p.size, fileOffset: at)
            }
            id.update(Array("\(f.path)\0\(f.size)\0\(f.sha1.hex)\n".utf8))
            return ContentFile(path: f.path, size: f.size, hash: .sha1(f.sha1), parts: parts)
        }
        let dirList = Set(chosen.flatMap { f -> [String] in
            let parts = f.path.split(separator: "/")
            return (1..<max(1, parts.count)).map { parts[0..<$0].joined(separator: "/") }
        })
        return ContentPlan(files: files, directories: dirList.sorted(), chunks: chunks, identity: id.finalize())
    }

    static func hex(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var it = s.utf8.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let x = nib(a), let y = nib(b) else { return nil }
            out.append(x << 4 | y)
        }
        return out
    }

    private static func nib(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 65...70: c - 55
        case 97...102: c - 87
        default: nil
        }
    }
}
