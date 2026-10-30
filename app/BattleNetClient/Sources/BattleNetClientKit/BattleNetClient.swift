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

/// Whether a build is offered (decision 0168): only while it carries its ARM64 client, the
/// product config's ARM64 executable listed in the install manifest with the platform and ARM64
/// tags.
public struct BattleNetOffer: Sendable, Equatable {
    public let build: BattleNetBuild
    public let install: InstallManifest
    /// The ARM64 client's entry, when the build has one.
    public let arm64Client: InstallManifest.File?

    public var isOffered: Bool { arm64Client != nil }

    public init(build: BattleNetBuild, install: InstallManifest) {
        self.build = build
        self.install = install
        let pc = build.productConfig
        arm64Client = pc.arm64Executable.flatMap { exe in
            install.files.indices.first {
                install.files[$0].name.caseInsensitiveCompare(exe) == .orderedSame
                    && install.file($0, has: pc.platformTags + pc.arm64Tags) && !pc.arm64Tags.isEmpty
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
/// against their EKeys and decoded content against its CKey.
public struct BattleNetClient: Sendable {
    public let transport: any BattleNetTransport
    /// Keys for encrypted blocks; a build's own key ring is added when one is fetched.
    public let keys: TACTKeyring

    public init(transport: any BattleNetTransport, keys: TACTKeyring = TACTKeyring()) {
        self.transport = transport
        self.keys = keys
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

    // MARK: offer

    /// Whether the product's current build in the region is offered: five small requests
    /// (versions, cdns, product config, build config, install manifest).
    public func offer(_ product: BattleNetProduct, _ region: StoreRegion) async throws -> BattleNetOffer {
        let build = try await build(product, region)
        return BattleNetOffer(build: build, install: try await installManifest(build))
    }

    /// The download and install sizes of an offered build's ARM64 client in one locale and region.
    public func sizes(_ offer: BattleNetOffer, locale: String) async throws -> BattleNetSizes {
        let query = TagQuery.arm64(offer.build.productConfig, locale: locale, regions: [offer.build.region])
        return try BattleNetSizes(size: try await sizeManifest(offer.build), install: offer.install, query: query)
    }

    // MARK: transport

    /// One GET: a thrown transport error is `unreachable`, a status other than 200 `refused`.
    func get(_ url: URL, what: String) async throws -> [UInt8] {
        let response: BattleNetResponse
        do {
            response = try await transport.get(url, headers: [:])
        } catch let e as BattleNetError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BattleNetError.unreachable("\(what): \(url.host ?? "?"): \(error.localizedDescription)")
        }
        guard response.status == 200 else { throw BattleNetError.refused(status: response.status, "\(what) from \(url.host ?? "?")") }
        return response.body
    }

    /// An object from the first CDN base that gives it whole: a base that fails (no answer, a
    /// refusal, a damaged body) is passed over. When every base fails, damage wins over the
    /// network's failures, since some host did answer with the wrong bytes. A missing key or an
    /// unsupported format is the same on every host and ends the search.
    func fromCDN<T>(_ cdn: CDNEndpoint, _ path: String, what: String, _ accept: ([UInt8]) throws -> T) async throws -> T {
        var network: BattleNetError?
        var damaged: BattleNetError?
        for base in cdn.bases {
            try Task.checkCancellation()
            do {
                return try accept(try await get(base.appendingPathComponent(path), what: what))
            } catch let e as BattleNetError {
                switch e {
                case .unreachable, .refused: network = network ?? e
                case .damaged: damaged = damaged ?? e
                case .missingKey, .unsupported: throw e
                }
            }
        }
        throw damaged ?? network ?? BattleNetError.damaged("\(what): no CDN host")
    }
}
