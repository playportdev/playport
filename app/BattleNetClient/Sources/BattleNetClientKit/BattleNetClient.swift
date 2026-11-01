// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// A product's current build in a store region: its version row, the CDN to fetch from, and its
/// build and product configs.
public struct BattleNetBuild: Sendable, Equatable {
    public let product: BattleNetProduct
    public let region: StoreRegion
    public let version: VersionRow
    public let cdn: CDNEndpoint
    public let config: BuildConfig
    public let productConfig: ProductConfig
}

/// Whether a build is offered (decisions 0174 and 0177): only while it carries its x64 client, the
/// product config's x64 executable listed in the install manifest with the platform and x64 tags.
public struct BattleNetOffer: Sendable, Equatable {
    public let build: BattleNetBuild
    public let install: InstallManifest
    /// The x64 client's entry, when the build has one.
    public let client: InstallManifest.File?

    public var isOffered: Bool { client != nil }

    public init(build: BattleNetBuild, install: InstallManifest) {
        self.build = build
        self.install = install
        let pc = build.productConfig
        client = pc.x64Executable.flatMap { exe in
            install.files.indices.first {
                install.files[$0].name.caseInsensitiveCompare(exe) == .orderedSame
                    && install.file($0, has: pc.platformTags + pc.x64Tags) && !pc.x64Tags.isEmpty
            }.map { install.files[$0] }
        }
    }
}

/// How big an install is: the stored content to download (encoded, as the store keeps it) and the
/// product folder's plain files. `install` is the space both take, before the store's own indexes.
public struct BattleNetSizes: Sendable, Equatable {
    public let download: UInt64
    public let objects: Int
    public let installFiles: UInt64
    public var install: UInt64 { download + installFiles }

    /// The sizes for one tag query over a build's size and install manifests.
    public init(size: SizeManifest, install: InstallManifest, query: TagQuery) throws {
        (download, objects) = try size.total(query)
        installFiles = try install.select(query).reduce(0) { $0 + $1.size }
    }
}

/// The Battle.net store client: Blizzard's public version endpoint (`{region}.version.battle.net`,
/// HTTPS) and the CDN it names. Configs are checked against their names (their MD5), BLTE objects
/// against their EKeys and decoded content against its CKey. Every request follows `manners`.
public struct BattleNetClient: Sendable {
    public let transport: any BattleNetTransport
    /// Keys for encrypted blocks; a build's own key ring is added when one is fetched.
    public let keys: TACTKeyring
    public let manners: BattleNetManners
    let gate: RequestGate

    public init(transport: any BattleNetTransport, keys: TACTKeyring = TACTKeyring(), manners: BattleNetManners = BattleNetManners()) {
        self.init(transport: transport, keys: keys, manners: manners, gate: RequestGate(limit: manners.maxConcurrent))
    }

    private init(transport: any BattleNetTransport, keys: TACTKeyring, manners: BattleNetManners, gate: RequestGate) {
        self.transport = transport
        self.keys = keys
        self.manners = manners
        self.gate = gate
    }

    /// This client with `more` keys: the same transport, request limit and paused hosts, so a
    /// download with a build's key ring and the store's own requests share one set of manners.
    public func adding(keys more: TACTKeyring) -> BattleNetClient {
        BattleNetClient(transport: transport, keys: keys.merging(more), manners: manners, gate: gate)
    }

    // MARK: discovery

    static func endpoint(_ product: BattleNetProduct, _ region: StoreRegion, _ kind: String) -> URL {
        URL(string: "https://\(region.rawValue).version.battle.net/v2/products/\(product.code)/\(kind)")!
    }

    /// Every row of the product's version endpoint, as the region's server gives it.
    public func versions(_ product: BattleNetProduct, from region: StoreRegion) async throws -> [VersionRow] {
        try VersionRow.parse(try await get(Self.endpoint(product, region, "versions"), what: "\(product.code) versions"),
                             what: "\(product.code) versions")
    }

    public func version(_ product: BattleNetProduct, _ region: StoreRegion) async throws -> VersionRow {
        guard let row = try await versions(product, from: region).first(where: { $0.region == region.rawValue }) else {
            throw BattleNetError.damaged("\(product.code) versions: no \(region.rawValue) row")
        }
        return row
    }

    public func cdns(_ product: BattleNetProduct, from region: StoreRegion) async throws -> [CDNEndpoint] {
        try CDNEndpoint.parse(try await get(Self.endpoint(product, region, "cdns"), what: "\(product.code) cdns"),
                              what: "\(product.code) cdns")
    }

    public func cdn(_ product: BattleNetProduct, _ region: StoreRegion) async throws -> CDNEndpoint {
        guard let row = try await cdns(product, from: region).first(where: { $0.region == region.rawValue }) else {
            throw BattleNetError.damaged("\(product.code) cdns: no \(region.rawValue) row")
        }
        guard !row.bases.isEmpty else { throw BattleNetError.damaged("\(product.code) cdns: \(region.rawValue) names no host") }
        return row
    }

    /// The product's current build in the region, with its build and product configs.
    public func build(_ product: BattleNetProduct, _ region: StoreRegion) async throws -> BattleNetBuild {
        async let v = version(product, region)
        async let c = cdn(product, region)
        let (version, cdn) = try await (v, c)
        async let bc = config(version.buildConfig, from: cdn)
        async let pc = productConfig(version.productConfig, from: cdn)
        return BattleNetBuild(product: product, region: region, version: version, cdn: cdn,
                              config: try BuildConfig(try await bc), productConfig: try ProductConfig(try await pc))
    }

    // MARK: CDN objects

    /// A config file (`{path}/config/xx/yy/{hash}`), checked against its name.
    public func config(_ hash: TACTHash, from cdn: CDNEndpoint) async throws -> [UInt8] {
        try await fromCDN(cdn, "\(cdn.path)/config/\(hash.cdnPath)", what: "config \(hash)") { body in
            guard MD5.hash(body) == hash.bytes else { throw BattleNetError.damaged("config \(hash): does not hash to its name") }
            return body
        }
    }

    /// A product config (`{configPath}/xx/yy/{hash}`), checked against its name.
    public func productConfig(_ hash: TACTHash, from cdn: CDNEndpoint) async throws -> [UInt8] {
        try await fromCDN(cdn, "\(cdn.configPath)/\(hash.cdnPath)", what: "product config \(hash)") { body in
            guard MD5.hash(body) == hash.bytes else { throw BattleNetError.damaged("product config \(hash): does not hash to its name") }
            return body
        }
    }

    /// A loose data object (`{path}/data/xx/yy/{ekey}`), decoded and checked against its keys.
    public func data(_ key: KeyPair, from cdn: CDNEndpoint) async throws -> [UInt8] {
        try await fromCDN(cdn, "\(cdn.path)/data/\(key.ekey.cdnPath)", what: "data \(key.ekey)") { body in
            try BLTE.decode(body, ekey: key.ekey, ckey: key.ckey, keys: keys)
        }
    }

    public func installManifest(_ build: BattleNetBuild) async throws -> InstallManifest {
        try InstallManifest(try await data(build.config.install, from: build.cdn))
    }

    public func sizeManifest(_ build: BattleNetBuild) async throws -> SizeManifest {
        guard let key = build.config.size else { throw BattleNetError.unsupported("build \(build.version.versionsName) has no size manifest") }
        return try SizeManifest(try await data(key, from: build.cdn))
    }

    public func encodingTable(_ build: BattleNetBuild) async throws -> EncodingTable {
        try EncodingTable(try await data(build.config.encoding, from: build.cdn))
    }

    /// The build's key ring config, when its version row names one.
    public func keyRing(_ build: BattleNetBuild) async throws -> TACTKeyring {
        guard let ring = build.version.keyRing else { return TACTKeyring() }
        return try TACTKeyring(keyRingConfig: try await config(ring, from: build.cdn))
    }

    public func cdnConfig(_ build: BattleNetBuild) async throws -> (CDNConfig, [UInt8]) {
        let bytes = try await config(build.version.cdnConfig, from: build.cdn)
        return (try CDNConfig(bytes), bytes)
    }

    /// An index (`{path}/data|patch/xx/yy/{key}.index`), checked against its name.
    public func index(_ key: TACTHash, patch: Bool = false, from cdn: CDNEndpoint) async throws -> (ArchiveIndex, [UInt8]) {
        try await fromCDN(cdn, "\(cdn.path)/\(patch ? "patch" : "data")/\(key.cdnPath).index", what: "index \(key)") { body in
            (try ArchiveIndex(body, name: key), body)
        }
    }

    /// A loose object as the CDN serves it, checked against its EKey, every block's hash and
    /// (when given) its size.
    public func object(_ ekey: TACTHash, size: Int?, from cdn: CDNEndpoint) async throws -> [UInt8] {
        try await fromCDN(cdn, "\(cdn.path)/data/\(ekey.cdnPath)", what: "data \(ekey)") { body in
            if let size, body.count != size { throw BattleNetError.damaged("data \(ekey): \(body.count) bytes, not \(size)") }
            try BLTE.verify(body, ekey: ekey)
            return body
        }
    }

    /// `length` bytes from `offset` in an archive (a ranged GET; HTTP 206 with exactly that
    /// range). The objects in it are the caller's to check.
    public func archiveRange(_ archive: TACTHash, offset: UInt64, length: Int, from cdn: CDNEndpoint) async throws -> [UInt8] {
        let range = "bytes=\(offset)-\(offset + UInt64(length) - 1)"
        let what = "archive \(archive) \(range)"
        return try await fromCDN(cdn, "\(cdn.path)/data/\(archive.cdnPath)", what: what, headers: ["Range": range], accept: [206]) { body in
            guard body.count == length else { throw BattleNetError.damaged("\(what): \(body.count) bytes") }
            return body
        }
    }

    // MARK: offer

    /// Whether the product's current build in the region is offered: five small requests
    /// (versions, cdns, product config, build config, install manifest).
    public func offer(_ product: BattleNetProduct, _ region: StoreRegion) async throws -> BattleNetOffer {
        let build = try await build(product, region)
        return BattleNetOffer(build: build, install: try await installManifest(build))
    }

    /// The download and install sizes of an offered build's x64 client in one locale and region.
    public func sizes(_ offer: BattleNetOffer, locale: String) async throws -> BattleNetSizes {
        let query = TagQuery.client(offer.build.productConfig, locale: locale, regions: [offer.build.region])
        return try BattleNetSizes(size: try await sizeManifest(offer.build), install: offer.install, query: query)
    }

    // MARK: transport

    /// One GET with the manners: Playport's User-Agent, at most `maxConcurrent` in flight, and
    /// on a 429 the host paused for its `Retry-After` (else a doubling back-off) and asked
    /// again. A thrown transport error is `unreachable`, a status outside `accept` `refused`; a
    /// 206 must carry the asked range in `Content-Range`.
    func get(_ url: URL, what: String, headers: [String: String] = [:], accept: Set<Int> = [200]) async throws -> [UInt8] {
        let host = url.host ?? "?"
        var headers = headers
        headers["User-Agent"] = manners.userAgent
        var attempt = 0, backedOff = false
        while true {
            // Another request's 429 paused the host: wait it out first (this request's own
            // back-off has just been waited).
            if !backedOff {
                let paused = await gate.pause(of: host)
                if paused > 0 { try await manners.sleep(paused) }
            }
            backedOff = false
            await gate.acquire()
            let response: BattleNetResponse
            do {
                response = try await transport.get(url, headers: headers)
                await gate.release()
            } catch {
                await gate.release()
                if let e = error as? BattleNetError { throw e }
                if error is CancellationError { throw error }
                throw BattleNetError.unreachable("\(what): \(host): \(error.localizedDescription)")
            }
            if response.status == 429, attempt < manners.retries {
                let backoff = min(manners.maxBackoff, manners.backoff * Double(1 << attempt))
                // A Retry-After that is not a finite, non-negative number of seconds is ignored;
                // a huge one waits at most `maxBackoff`.
                let wait = response.headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    .flatMap { $0.isFinite && $0 >= 0 ? min($0, manners.maxBackoff) : nil } ?? backoff
                attempt += 1
                await gate.pause(host, for: wait)
                try await manners.sleep(wait)
                backedOff = true
                continue
            }
            guard accept.contains(response.status) else { throw BattleNetError.refused(status: response.status, "\(what) from \(host)") }
            if response.status == 206, let asked = headers["Range"], let got = response.headers["content-range"],
               !got.hasPrefix(asked.replacingOccurrences(of: "=", with: " ") + "/") {
                throw BattleNetError.damaged("\(what): \(host) sent \(got)")
            }
            return response.body
        }
    }

    /// An object from the first CDN base that gives it whole: a base that fails (no answer, a
    /// refusal, a damaged body) is passed over. When every base fails, damage wins over the
    /// network's failures, since some host did answer with the wrong bytes. A missing key or an
    /// unsupported format is the same on every host and ends the search.
    func fromCDN<T>(_ cdn: CDNEndpoint, _ path: String, what: String, headers: [String: String] = [:], accept: Set<Int> = [200],
                    _ check: ([UInt8]) throws -> T) async throws -> T {
        var network: BattleNetError?
        var damaged: BattleNetError?
        for base in cdn.bases {
            try Task.checkCancellation()
            do {
                return try check(try await get(base.appendingPathComponent(path), what: what, headers: headers, accept: accept))
            } catch let e as BattleNetError {
                switch e {
                case .unreachable, .refused: network = network ?? e
                case .damaged: damaged = damaged ?? e
                case .missingKey, .unsupported, .outdated: throw e
                }
            }
        }
        throw damaged ?? network ?? BattleNetError.damaged("\(what): no CDN host")
    }
}
