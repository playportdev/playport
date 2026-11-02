// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// A content hash as TACT writes it: 16 bytes, 32 lowercase hex digits. Config files are named by
/// the MD5 of their bytes; BLTE objects by their EKey.
public struct TACTHash: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(hex: Substring) {
        guard hex.utf8.count == 32 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(16)
        var it = hex.utf8.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let h = Self.nibble(hi), let l = Self.nibble(lo) else { return nil }
            out.append(h << 4 | l)
        }
        bytes = out
    }

    public init?(hex: String) { self.init(hex: Substring(hex)) }

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16)
        self.bytes = bytes
    }

    static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    public var hex: String { bytes.hex }
    public var description: String { hex }
    /// The CDN path piece: `xx/yy/hash`.
    public var cdnPath: String { "\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex)" }

    public static func < (a: TACTHash, b: TACTHash) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
}

/// Blizzard's pipe-separated tables (the version and CDN endpoints): a header of
/// `Name!TYPE:size` columns, `##` comment lines (the sequence number), then rows. Columns are
/// found by name, never by position; empty cells are legal.
public struct PSVTable: Sendable {
    public let columns: [String]
    public let rows: [[String]]
    public let seqn: Int?

    public init(_ bytes: [UInt8], what: String) throws {
        guard let text = String(validating: bytes, as: UTF8.self) else { throw BattleNetError.damaged("\(what): not UTF-8") }
        var header: [String]?
        var rows = [[String]]()
        var seqn: Int?
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("##") {
                if let r = line.range(of: "seqn = ") { seqn = Int(line[r.upperBound...].trimmingCharacters(in: .whitespaces)) }
                continue
            }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let h = header else {
                let names = try cells.map { cell -> String in
                    guard let bang = cell.firstIndex(of: "!"), bang != cell.startIndex,
                          cell[cell.index(after: bang)...].contains(":") else {
                        throw BattleNetError.damaged("\(what): header cell '\(cell.prefix(40))' is not Name!TYPE:size")
                    }
                    return cell[..<bang].lowercased()
                }
                header = names
                continue
            }
            guard cells.count == h.count else {
                throw BattleNetError.damaged("\(what): a row has \(cells.count) cells, the header \(h.count)")
            }
            rows.append(cells)
        }
        guard let header else { throw BattleNetError.damaged("\(what): no header") }
        columns = header
        self.rows = rows
        self.seqn = seqn
    }

    /// The column's index by name (case-insensitive), or a damaged-content error.
    public func column(_ name: String, what: String) throws -> Int {
        guard let i = columns.firstIndex(of: name.lowercased()) else { throw BattleNetError.damaged("\(what): no \(name) column") }
        return i
    }
}

/// One row of a product's version endpoint: the build a region gets.
public struct VersionRow: Sendable, Equatable {
    public let region: String
    public let buildConfig: TACTHash
    public let cdnConfig: TACTHash
    public let keyRing: TACTHash?
    public let buildID: Int
    public let versionsName: String
    public let productConfig: TACTHash

    static func parse(_ bytes: [UInt8], what: String) throws -> [VersionRow] {
        let t = try PSVTable(bytes, what: what)
        let region = try t.column("Region", what: what), build = try t.column("BuildConfig", what: what)
        let cdn = try t.column("CDNConfig", what: what), ring = try t.column("KeyRing", what: what)
        let id = try t.column("BuildId", what: what), name = try t.column("VersionsName", what: what)
        let product = try t.column("ProductConfig", what: what)
        return try t.rows.map { r in
            func hash(_ i: Int) throws -> TACTHash {
                guard let h = TACTHash(hex: r[i]) else { throw BattleNetError.damaged("\(what): \(t.columns[i]) '\(r[i].prefix(40))' is not a hash") }
                return h
            }
            guard let buildID = Int(r[id]), buildID > 0 else { throw BattleNetError.damaged("\(what): BuildId '\(r[id].prefix(20))'") }
            return VersionRow(region: r[region], buildConfig: try hash(build), cdnConfig: try hash(cdn),
                              keyRing: r[ring].isEmpty ? nil : try hash(ring), buildID: buildID,
                              versionsName: r[name], productConfig: try hash(product))
        }
    }
}

/// One row of a product's CDN endpoint: where a region's content is.
public struct CDNEndpoint: Sendable, Equatable {
    public struct Server: Sendable, Equatable {
        public let base: URL
        public let maxHosts: Int?
        public let fallback: Bool
    }

    public let region: String
    /// The product's directory on the CDN (`tpr/wow`).
    public let path: String
    public let hosts: [String]
    public let servers: [Server]
    /// The servers as the endpoint writes them (with their `?maxhosts=` flags), for `.build.info`.
    public let serverText: [String]
    /// Where product configs are (`tpr/configs/data`).
    public let configPath: String

    /// The bases to try, in order: HTTPS before HTTP (the phone's transport security refuses plain
    /// HTTP), primaries before `fallback=1` servers, otherwise in the endpoint's order. Only hosts
    /// the endpoint names; plain-HTTP hosts when it lists no servers.
    public var bases: [URL] {
        let ranked = servers.enumerated().sorted { a, b in
            func rank(_ s: Server) -> Int { (s.base.scheme == "https" ? 0 : 2) + (s.fallback ? 1 : 0) }
            return (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element.base)
        if !ranked.isEmpty { return ranked }
        return hosts.compactMap { URL(string: "http://\($0)") }
    }

    static func parse(_ bytes: [UInt8], what: String) throws -> [CDNEndpoint] {
        let t = try PSVTable(bytes, what: what)
        let name = try t.column("Name", what: what), path = try t.column("Path", what: what)
        let hosts = try t.column("Hosts", what: what), configPath = try t.column("ConfigPath", what: what)
        let servers = t.columns.firstIndex(of: "servers")
        return try t.rows.map { r in
            guard !r[path].isEmpty, !r[configPath].isEmpty else { throw BattleNetError.damaged("\(what): \(r[name]) has no path") }
            let text = (servers.map { r[$0] } ?? "").split(separator: " ").map(String.init)
            let list: [Server] = try text.map { s in
                guard let c = URLComponents(string: s), let scheme = c.scheme, scheme == "http" || scheme == "https",
                      let host = c.host, !host.isEmpty, let base = URL(string: "\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")") else {
                    throw BattleNetError.damaged("\(what): server '\(s.prefix(60))'")
                }
                let q = c.queryItems ?? []
                return Server(base: base, maxHosts: q.first { $0.name == "maxhosts" }?.value.flatMap { Int($0) },
                              fallback: q.contains { $0.name == "fallback" && $0.value == "1" })
            }
            return CDNEndpoint(region: r[name], path: r[path], hosts: r[hosts].split(separator: " ").map(String.init),
                               servers: list, serverText: text, configPath: r[configPath])
        }
    }
}

/// A TACT `key = value value…` config (build and CDN configs, the key ring). `#` lines are comments.
public struct TACTConfig: Sendable, Equatable {
    public let values: [String: [String]]

    public init(_ bytes: [UInt8], what: String) throws {
        guard let text = String(validating: bytes, as: UTF8.self) else { throw BattleNetError.damaged("\(what): not UTF-8") }
        var values = [String: [String]]()
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.range(of: " = ") ?? line.range(of: "=") else {
                throw BattleNetError.damaged("\(what): line '\(line.prefix(40))' has no '='")
            }
            let key = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw BattleNetError.damaged("\(what): a value without a key") }
            values[key] = line[eq.upperBound...].split(separator: " ").map(String.init)
        }
        guard !values.isEmpty else { throw BattleNetError.damaged("\(what): empty") }
        self.values = values
    }

    public subscript(_ key: String) -> [String]? { values[key] }

    /// A `CKey EKey` pair (install, size, encoding, …).
    public func keyPair(_ key: String, what: String) throws -> KeyPair {
        guard let v = values[key], v.count >= 2, let c = TACTHash(hex: v[0]), let e = TACTHash(hex: v[1]) else {
            throw BattleNetError.damaged("\(what): no '\(key) = CKey EKey'")
        }
        return KeyPair(ckey: c, ekey: e)
    }
}

/// A content key and its encoded key: what a decoded file hashes to, and the BLTE object's name.
public struct KeyPair: Sendable, Equatable, Hashable {
    public let ckey: TACTHash
    public let ekey: TACTHash
}

/// A build config: the keys of the build's manifests.
public struct BuildConfig: Sendable, Equatable {
    public let config: TACTConfig
    public let install: KeyPair
    public let encoding: KeyPair
    /// The size manifest (download totals per tag); absent in older builds.
    public let size: KeyPair?
    public let buildName: String?

    public init(_ bytes: [UInt8]) throws {
        let what = "build config"
        config = try TACTConfig(bytes, what: what)
        install = try config.keyPair("install", what: what)
        encoding = try config.keyPair("encoding", what: what)
        size = config["size"] == nil ? nil : try config.keyPair("size", what: what)
        buildName = config["build-name"]?.joined(separator: " ")
    }
}

/// A CDN config: the archives the content is packed in.
public struct CDNConfig: Sendable, Equatable {
    public let config: TACTConfig
    public let archives: [TACTHash]
    /// The total size of the archive indexes (the list's order differs from `archives`).
    public let archiveIndexBytes: UInt64
    public let archiveGroup: TACTHash?
    public let fileIndex: TACTHash?

    public init(_ bytes: [UInt8]) throws {
        let what = "CDN config"
        config = try TACTConfig(bytes, what: what)
        archives = try (config["archives"] ?? []).map {
            guard let h = TACTHash(hex: $0) else { throw BattleNetError.damaged("\(what): archive '\($0.prefix(40))'") }
            return h
        }
        guard !archives.isEmpty else { throw BattleNetError.damaged("\(what): no archives") }
        archiveIndexBytes = try (config["archives-index-size"] ?? []).reduce(0) {
            guard let n = UInt64($1) else { throw BattleNetError.damaged("\(what): archive index size '\($1.prefix(20))'") }
            let (sum, overflow) = $0.addingReportingOverflow(n)
            guard !overflow else { throw BattleNetError.damaged("\(what): archive index sizes add up past 64 bits") }
            return sum
        }
        archiveGroup = config["archive-group"]?.first.flatMap { TACTHash(hex: $0) }
        fileIndex = config["file-index"]?.first.flatMap { TACTHash(hex: $0) }
    }
}

/// The product config (JSON): the product folder, the game's executables per machine, the
/// manifest tags per machine, the launch arguments and the locales.
public struct ProductConfig: Sendable, Equatable {
    /// The game's folder in the install root (`_retail_`).
    public let folder: String
    public let x64Executable: String?
    public let arm64Executable: String?
    public let launchArguments: [String]
    /// The platform tags (`Windows`) and the per-machine tags (`x86_64`, `arm64`).
    public let platformTags: [String]
    public let x64Tags: [String]
    public let arm64Tags: [String]
    public let supportedLocales: [String]
    public let replacementLocales: [String: String]

    public init(_ bytes: [UInt8]) throws {
        let what = "product config"
        guard let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            throw BattleNetError.damaged("\(what): not a JSON object")
        }
        func dig(_ path: String...) -> Any? {
            path.reduce(root as Any?) { ($0 as? [String: Any])?[$1] }
        }
        func strings(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }
        guard let folder = dig("all", "config", "shared_container_default_subfolder") as? String, !folder.isEmpty else {
            throw BattleNetError.damaged("\(what): no product folder")
        }
        self.folder = folder
        let game = dig("platform", "win", "config", "binaries", "game") as? [String: Any]
        x64Executable = game?["relative_path"] as? String
        arm64Executable = (game?["relative_path_arm64"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        launchArguments = strings(game?["launch_arguments"])
        platformTags = strings(dig("platform", "win", "config", "tags"))
        x64Tags = strings(dig("platform", "win", "config", "tags_64bit"))
        arm64Tags = strings(dig("platform", "win", "config", "tags_arm64"))
        supportedLocales = strings(dig("all", "config", "supported_locales"))
        replacementLocales = (dig("all", "config", "replacement_locales") as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }
}
