// SPDX-License-Identifier: GPL-3.0-or-later
// GOG's generation-2 content system, as the spike measured it (plan 2.1):
//
//   builds     content-system.gog.com/products/ID/os/windows/builds?generation=2,
//              newest first, each with the link to its build manifest
//   build      zlib JSON: installDirectory, depots by language, bitness and product
//              (the GOG depot holds goggame-ID.info, the play tasks), and the game's
//              own cloud client credentials, which are never kept or logged
//   depot      cdn.gog.com/content-system/v2/meta/aa/bb/HASH, zlib JSON: files, each
//              a list of chunks (md5 of the plain bytes, md5 of the zlib bytes, sizes)
//   chunks     a secure link (signed, expiring) + /aa/bb/<compressed md5>, zlib

import Foundation
import ContentKit

public struct GOGBuild: Codable, Equatable, Sendable {
    public var buildID: String
    public var version: String?
    public var published: String?
    public var link: URL
}

public struct GOGBuildManifest: Sendable {
    public struct Depot: Sendable, Equatable {
        public var manifest: String
        public var languages: [String]
        public var productID: String
        public var size: UInt64
        public var bitness: [String]?
        public var isGogDepot: Bool
    }

    public var buildID: String
    public var baseProductID: String
    public var installDirectory: String
    public var depots: [Depot]
    public var dependencies: [String]

    static func parse(_ json: [UInt8]) throws -> GOGBuildManifest {
        // Decoded field by field: the build also carries the game's cloud
        // clientSecret, which is deliberately not read.
        struct Raw: Decodable {
            struct D: Decodable {
                var manifest: String
                var languages: [String]?
                var productId: String
                var size: UInt64?
                var osBitness: [String]?
                var isGogDepot: Bool?
            }
            var buildId: String?
            var baseProductId: String
            var installDirectory: String
            var depots: [D]
            var dependencies: [String]?
            var version: Int?
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: Data(json)) else {
            throw ClientError.protocolChanged("GOG build manifest: unexpected shape")
        }
        guard r.version == nil || r.version == 2 else { throw ClientError.unsupported("GOG build manifest version \(r.version!)") }
        for d in r.depots where !GOGContent.isHash(d.manifest) { throw ClientError.unsafeContent("GOG depot manifest name \(d.manifest.prefix(40))") }
        return GOGBuildManifest(buildID: r.buildId ?? "", baseProductID: r.baseProductId, installDirectory: r.installDirectory,
                                depots: r.depots.map { .init(manifest: $0.manifest, languages: $0.languages ?? ["*"], productID: $0.productId,
                                                             size: $0.size ?? 0, bitness: $0.osBitness, isGogDepot: $0.isGogDepot ?? false) },
                                dependencies: r.dependencies ?? [])
    }

    /// The depots to install (plan 2.2): the base game's and owned DLCs', Windows
    /// 64-bit or neutral, in the player's language plus the neutral ones, falling
    /// back to English when the game has none in that language.
    public func selected(language: String = "en-US", owned: Set<String> = []) -> [Depot] {
        let products = owned.union([baseProductID])
        let usable = depots.filter { products.contains($0.productID) && ($0.bitness == nil || $0.bitness!.contains("64")) }
        let has = { (l: String) in usable.contains { $0.languages.contains(l) } }
        let lang = has(language) ? language : has("en-US") ? "en-US" : usable.first { !$0.languages.contains("*") }?.languages.first ?? language
        return usable.filter { $0.languages.contains("*") || $0.languages.contains(lang) }
    }
}

/// One depot manifest's files, as kept for verify, repair and updates.
public struct GOGDepotFile: Codable, Equatable, Sendable {
    public struct Chunk: Codable, Equatable, Sendable {
        public var md5: String
        public var size: UInt32
        public var compressedMd5: String
        public var compressedSize: UInt32
    }

    /// `/`-separated, as installed.
    public var path: String
    public var chunks: [Chunk]
    /// The whole file's md5, when GOG lists one (else each chunk is checked).
    public var md5: String?
    /// The product whose depot holds it (a DLC's chunks are under its own secure link).
    public var productID: String? = nil
    public var size: UInt64 { chunks.reduce(0) { $0 + UInt64($1.size) } }
}

public enum GOGContent {
    static func isHash(_ s: String) -> Bool { s.count == 32 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    public static func builds(_ session: GOGSession, productID: String) async throws -> [GOGBuild] {
        guard productID.allSatisfy(\.isNumber) else { throw ClientError.unsafeContent("GOG product ID \(productID)") }
        let url = URL(string: "https://content-system.gog.com/products/\(productID)/os/windows/builds?generation=2")!
        return try parseBuilds(try await session.authorized(url, maxBytes: 4 << 20, label: "GOG builds \(productID)"))
    }

    static func parseBuilds(_ body: [UInt8]) throws -> [GOGBuild] {
        struct Raw: Decodable {
            struct Item: Decodable {
                var build_id: String
                var version_name: String?
                var date_published: String?
                var generation: Int
                var link: String
            }
            var items: [Item]
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: Data(body)) else { throw ClientError.protocolChanged("GOG builds: unexpected reply") }
        return r.items.filter { $0.generation == 2 }.compactMap { i in
            guard let u = URL(string: i.link), u.scheme == "https" else { return nil }
            return GOGBuild(buildID: i.build_id, version: i.version_name, published: i.date_published, link: u)
        }
    }

    public static func buildManifest(_ session: GOGSession, _ build: GOGBuild) async throws -> GOGBuildManifest {
        try GOGBuildManifest.parse(try Zlib.json(try await session.plain(build.link, maxBytes: 16 << 20, label: "GOG build manifest")))
    }

    public static func depot(_ session: GOGSession, _ d: GOGBuildManifest.Depot) async throws -> [GOGDepotFile] {
        var files = try await depot(session, d.manifest)
        for i in files.indices { files[i].productID = d.productID }
        return files
    }

    public static func depot(_ session: GOGSession, _ hash: String) async throws -> [GOGDepotFile] {
        guard isHash(hash) else { throw ClientError.unsafeContent("GOG depot manifest name") }
        let url = URL(string: "https://cdn.gog.com/content-system/v2/meta/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")!
        return try parseDepot(try Zlib.json(try await session.plain(url, maxBytes: 64 << 20, label: "GOG depot manifest")))
    }

    /// The files of a depot manifest, checked: paths safe, chunk hashes and sizes sane.
    static func parseDepot(_ json: [UInt8]) throws -> [GOGDepotFile] {
        struct Raw: Decodable {
            struct Depot: Decodable {
                struct Item: Decodable {
                    struct C: Decodable {
                        var md5: String
                        var size: UInt32
                        var compressedMd5: String
                        var compressedSize: UInt32
                    }
                    var type: String
                    var path: String
                    var chunks: [C]?
                    var md5: String?
                }
                var items: [Item]
            }
            var depot: Depot
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: Data(json)) else { throw ClientError.protocolChanged("GOG depot manifest: unexpected shape") }
        return try r.depot.items.compactMap { item in
            guard item.type == "DepotFile" else { return nil }      // DepotDirectory, DepotLink: nothing to write
            let path = try SafePath.normalize(item.path)
            let chunks = try (item.chunks ?? []).map { c -> GOGDepotFile.Chunk in
                guard isHash(c.md5), isHash(c.compressedMd5), c.size <= 64 << 20, c.compressedSize <= 64 << 20 else {
                    throw ClientError.unsafeContent("GOG chunk of \(path)")
                }
                return .init(md5: c.md5, size: c.size, compressedMd5: c.compressedMd5, compressedSize: c.compressedSize)
            }
            return GOGDepotFile(path: path, chunks: chunks, md5: item.md5.flatMap { isHash($0) ? $0 : nil })
        }
    }

    /// The union of the depots' files as ContentKit's plan: a later depot wins
    /// a path (compared without case), each chunk a whole part, md5-checked.
    public static func plan(productID: String, buildID: String, files: [GOGDepotFile]) throws -> ContentPlan {
        var byKey: [String: GOGDepotFile] = [:]
        var order: [String] = []
        for f in files {
            let k = f.path.lowercased()
            if byKey[k] == nil { order.append(k) }
            byKey[k] = f
        }
        let chosen = order.compactMap { byKey[$0] }.sorted { $0.path < $1.path }
        let paths = Set(chosen.map { $0.path.lowercased() })
        var dirs = Set<String>()
        for f in chosen {
            var parent = f.path.lowercased()
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                if paths.contains(parent) { throw ClientError.unsafeContent("\(parent) is a file and a folder") }
            }
            let parts = f.path.split(separator: "/")
            for i in 1..<max(1, parts.count) { dirs.insert(parts[0..<i].joined(separator: "/")) }
        }
        var chunks: [ContentChunk] = []
        var index: [String: Int] = [:]
        var id = SHA1Stream()
        id.update(Array("playport-gog-1 product=\(productID) build=\(buildID)\n".utf8))
        let out = chosen.map { f -> ContentFile in
            var at: UInt64 = 0
            let parts = f.chunks.map { c -> ContentPart in
                let k: Int
                if let have = index[c.md5] { k = have } else {
                    k = chunks.count
                    index[c.md5] = k
                    chunks.append(ContentChunk(key: hex(c.md5), size: c.size, compressedSize: c.compressedSize,
                                               check: .md5(hex(c.md5)), group: UInt32(f.productID ?? productID) ?? 0,
                                               locator: c.compressedMd5))
                }
                defer { at += UInt64(c.size) }
                return ContentPart(chunk: k, length: c.size, fileOffset: at)
            }
            // A one-chunk file's md5 is its chunk's.
            let whole = f.md5 ?? (f.chunks.count == 1 ? f.chunks[0].md5 : nil)
            id.update(Array("\(f.path)\0\(f.size)\0\(f.chunks.map(\.md5).joined(separator: ","))\n".utf8))
            return ContentFile(path: f.path, size: f.size, hash: whole.map { .md5(hex($0)) } ?? .none, parts: parts)
        }
        return ContentPlan(files: out, directories: dirs.sorted(), chunks: chunks, identity: id.finalize())
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = s.utf8.makeIterator()
        while let a = it.next(), let b = it.next() {
            func v(_ c: UInt8) -> UInt8 { c >= 97 ? c - 87 : c >= 65 ? c - 55 : c - 48 }
            out.append(v(a) << 4 | v(b))
        }
        return out
    }
}
