// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b src/main/content-catalog.ts
// (contentSkus, desktopContentPackages, the add-on scope), src/main/game-content.ts
// (contentManifest, packageChoice, contentOffers, the launch's related products and
// content roots) and src/main/game-locale.ts (XODUS_PACKAGE_LOCALE); the variables'
// limits from nexus-xgameruntime ab2fac35b500b87fefe51add26a0672a71d11576
// src/System/Store/Entitled.h (entitled_merge_hint) and src/System/Package/Content.h
// (content_discover); translated to Swift by the Playport authors, 2026-10-30.
// Modified: MSIXVC2 packages count; the candidates are the account's licensed products
// the caller names, not every bundle's walked; add-ons install inside the game's
// folder (XboxAddOnInstaller.swift); only the runtime's own locale variable is set.
import Foundation
import ContentKit

/// What an add-on offers the player of its game.
public enum XboxAddOnStatus: String, Codable, Sendable {
    /// One Windows package for this game: installed beside it.
    case available
    /// No package: the game checks the licence through the runtime, nothing to install.
    case licenceOnly
    /// A pack: the add-ons it grants are listed on their own.
    case bundle
    /// No single Windows package for this game that Playport can install.
    case unsupported
    /// Declared by the game, but the account has no licence for it.
    case unlicensed
}

/// One DLC or add-on of a game, as the display catalogue and the account's entitlements describe it.
public struct XboxAddOn: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: XboxAddOnStatus
    /// How the account licenses it; nil when it does not.
    public let access: XboxAccess?
    /// The package to install (`available` only).
    public let package: XboxProductPackage?
    public let packageFamily: String?
}

/// The parts of a package's MicrosoftGame.config that relate a game and its add-ons
/// (and the runtime checks): identity, Store ID, main package, allowed and related
/// products, declared languages.
public struct XboxPackageConfig: Sendable, Equatable {
    public var name: String
    public var publisher: String
    public var version: String
    public var storeID: String
    /// `DesktopRegistration/MainPackageDependency`'s name: the game an add-on belongs to.
    public var dependency: String?
    public var allowed: [String]
    public var related: [String]
    /// `Resources/Resource`'s languages.
    public var languages: [String]

    public static func parse(_ bytes: [UInt8]) throws -> XboxPackageConfig {
        let root = try XboxXML.parse(bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes)
        guard root.local == "Game", let identity = root.child("Identity"),
              let name = identity.attr("Name"), !name.isEmpty, name.count <= 256,
              let publisher = identity.attr("Publisher"), !publisher.isEmpty, publisher.count <= 1024,
              let version = identity.attr("Version"), version.count <= 64 else {
            throw ClientError.protocolChanged("the package's MicrosoftGame.config has no identity")
        }
        func ids(_ section: String, _ tag: String) -> [String] {
            var out: [String] = []
            for node in (root.child(section)?.children ?? []) where node.local == tag {
                let id = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if StoreGameKey.isProductID(id), !out.contains(id) { out.append(id) }
            }
            return Array(out.prefix(256))
        }
        let languages = root.all("Resource").compactMap { $0.attr("Language") }.filter(XboxAddOnEnvironment.isLocale)
        return XboxPackageConfig(name: name, publisher: publisher, version: version, storeID: root.value("StoreId") ?? "",
                                 dependency: root.child("DesktopRegistration")?.child("MainPackageDependency")?.attr("Name"),
                                 allowed: ids("AllowedProducts", "AllowedProduct"), related: ids("RelatedProducts", "RelatedProduct"),
                                 languages: languages)
    }

    /// The config in `folder` (any case), 1 MiB at most.
    public static func load(folder: URL) throws -> XboxPackageConfig {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = names.first(where: { $0.lowercased() == "microsoftgame.config" }),
              let url = try? InstallFS.resolveInside(folder, name, createParents: false),
              let size = InstallFS.fileSize(url), size <= 1 << 20,
              let bytes = try? [UInt8](Data(contentsOf: url)) else {
            throw ClientError.notFound("the package has no MicrosoftGame.config")
        }
        return try parse(bytes)
    }
}

/// Nexus's add-on choice over display-catalogue records: pure, so tests drive it.
enum XboxAddOnCatalog {
    typealias Record = [String: Any]
    static let kinds: Set<String> = ["Durable", "GameAddOn"]
    static let maximum = 128

    private static func list(_ value: Any?) -> [Any] { value as? [Any] ?? [] }

    /// The SKUs a PC copy can have: not a trial, not a pre-order.
    static func contentSKUs(_ record: Record) -> [Record] {
        list(record["DisplaySkuAvailabilities"]).compactMap { (($0 as? Record)?["Sku"] as? Record)?["Properties"] as? Record }
            .filter { $0["IsTrial"] as? Bool == false && $0["IsPreOrder"] as? Bool != true }
    }

    /// Their Windows.Desktop x64 GDK packages.
    static func desktopPackages(_ record: Record) -> [Record] {
        contentSKUs(record).flatMap { list($0["Packages"]).compactMap { $0 as? Record } }.filter { p in
            XboxCatalog.gdkFormats.contains(((p["PackageFormat"] as? String) ?? "").uppercased())
                && list(p["Architectures"]).contains { ($0 as? String) == "x64" }
                && list(p["PlatformDependencies"]).contains { (($0 as? Record)?["PlatformName"] as? String) == "Windows.Desktop" }
        }
    }

    static func relationships(_ record: Record, _ kind: String) -> [String] {
        list(record["MarketProperties"]).flatMap { list(($0 as? Record)?["RelatedProducts"]) }.compactMap { $0 as? Record }
            .filter { $0["RelationshipType"] as? String == kind }.compactMap { $0["RelatedProductId"] as? String }
            .filter(StoreGameKey.isProductID)
    }

    /// The game's package families an add-on can name as its main package: those of its
    /// identity when the config is known, else all of its desktop packages'.
    static func families(_ base: Record?, name: String?) -> Set<String> {
        let all = base.map(desktopPackages)?.compactMap { $0["PackageFamilyName"] as? String } ?? []
        return Set(name.map { n in all.filter { $0.hasPrefix(n + "_") } } ?? all)
    }

    static func title(_ record: Record?, _ id: String) -> String {
        let t = (list(record?["LocalizedProperties"]).first as? Record)?["ProductTitle"] as? String
        let trimmed = t?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : String(trimmed.prefix(300))
    }

    /// The game's add-ons among `records`, each with what the account can do with it.
    static func offers(base: String, config: XboxPackageConfig?, records: [String: Record], licensed: [String: XboxAccess]) -> [XboxAddOn] {
        let families = families(records[base], name: config?.name)
        let declared = Set(config?.related ?? [])
        func inScope(_ id: String, _ record: Record) -> Bool {
            guard id != base, kinds.contains(record["ProductType"] as? String ?? "") else { return false }
            return declared.contains(id) || relationships(record, "addOnParent").contains(base)
                || desktopPackages(record).contains { families.contains($0["MainPackageFamilyNameForDlc"] as? String ?? "") }
        }
        var out: [XboxAddOn] = []
        for (id, record) in records where inScope(id, record) {
            let name = title(record, id)
            guard let access = licensed[id] else {
                out.append(XboxAddOn(id: id, title: name, status: .unlicensed, access: nil, package: nil, packageFamily: nil))
                continue
            }
            let skus = contentSKUs(record), durable = record["ProductType"] as? String == "Durable"
            if durable, skus.contains(where: { !list($0["BundledSkus"]).isEmpty }) {
                out.append(XboxAddOn(id: id, title: name, status: .bundle, access: access, package: nil, packageFamily: nil))
            } else if durable, !skus.isEmpty, skus.allSatisfy({ $0["Packages"] is NSNull || ($0["Packages"] as? [Any])?.isEmpty == true }) {
                out.append(XboxAddOn(id: id, title: name, status: .licenceOnly, access: access, package: nil, packageFamily: nil))
            } else if let (package, family) = choice(record, families: families) {
                out.append(XboxAddOn(id: id, title: name, status: .available, access: access, package: package, packageFamily: family))
            } else {
                out.append(XboxAddOn(id: id, title: name, status: .unsupported, access: access, package: nil, packageFamily: nil))
            }
        }
        return Array(out.sorted { ($0.title.localizedLowercase, $0.id) < ($1.title.localizedLowercase, $1.id) }.prefix(maximum))
    }

    /// Exactly one package (one content ID, one family) whose main package is this game's.
    static func choice(_ record: Record, families: Set<String>) -> (XboxProductPackage, String)? {
        var byContent: [String: (XboxProductPackage, String)] = [:]
        for p in desktopPackages(record) {
            guard families.contains(p["MainPackageFamilyNameForDlc"] as? String ?? ""),
                  let raw = p["ContentId"] as? String, let uuid = UUID(uuidString: raw),
                  let family = p["PackageFamilyName"] as? String, (1...256).contains(family.utf8.count),
                  family.utf8.allSatisfy({ isFamilyByte($0) }) else { continue }
            let size = (p["MaxDownloadSizeInBytes"] as? NSNumber)?.uint64Value ?? 0
            let id = uuid.uuidString.lowercased()
            byContent[id] = (XboxProductPackage(contentID: id, format: ((p["PackageFormat"] as? String) ?? "").uppercased(), downloadSize: size), family)
        }
        guard byContent.count == 1, let only = byContent.values.first else { return nil }
        return only
    }

    private static func isFamilyByte(_ c: UInt8) -> Bool {
        (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x2E || c == 0x5F || c == 0x2D
    }
}

/// Finds a game's add-ons: the public display catalogue (no credentials) for the game,
/// what its config declares and the account's licensed candidates.
public struct XboxAddOnFinder: Sendable {
    private let http: any XboxHTTP
    private let log: Logger
    private let market: String

    public init(http: any XboxHTTP = XboxURLSessionHTTP(limit: 8 << 20), log: Logger = .silent, market: String = "US") {
        self.http = http; self.log = log
        self.market = market.utf8.count == 2 && market.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) ? market : "US"
    }

    /// `licensed`: the account's licensed products that may be add-ons (its library's
    /// non-game products), with their access. `config`: the installed game's, when it is.
    public func addOns(of base: String, config: XboxPackageConfig?, licensed: [String: XboxAccess]) async throws -> [XboxAddOn] {
        guard StoreGameKey.isProductID(base) else { throw ClientError.unsupported("not an Xbox Product ID") }
        var ids = [base], seen: Set<String> = [base]
        for id in (config?.related ?? []) + licensed.keys.sorted() where StoreGameKey.isProductID(id) && seen.insert(id).inserted { ids.append(id) }
        guard ids.count <= XboxEntitlements.maximum else { throw ClientError.protocolChanged("Xbox add-on candidates are too many") }
        let batches = stride(from: 0, to: ids.count, by: XboxCatalog.batch).map { Array(ids[$0..<min($0 + XboxCatalog.batch, ids.count)]) }
        let pages = try await withThrowingTaskGroup(of: (Set<String>, [UInt8]).self) { group in
            var pages: [(Set<String>, [UInt8])] = [], next = 0
            func add() {
                let batch = batches[next]; next += 1
                group.addTask { (Set(batch), try await self.page(batch)) }
            }
            while next < min(4, batches.count) { add() }
            while let page = try await group.next() {
                pages.append(page)
                if next < batches.count { add() }
            }
            return pages
        }
        var records: [String: XboxCatalog.Record] = [:]
        for (asked, body) in pages { records.merge(try XboxCatalog.parse(body, asked: asked)) { a, _ in a } }
        let found = XboxAddOnCatalog.offers(base: base, config: config, records: records, licensed: licensed)
        let counts = Dictionary(grouping: found, by: \.status).mapValues(\.count)
        log.info("xbox", "\(base): \(found.count) add-ons (\(counts[.available] ?? 0) to install, \(counts[.licenceOnly] ?? 0) licence only, "
                 + "\(counts[.unlicensed] ?? 0) not licensed)")
        return found
    }

    private func page(_ batch: [String]) async throws -> [UInt8] {
        let response: XboxHTTPResponse
        do {
            response = try await http.send(XboxHTTPRequest(url: XboxCatalog.url(batch, market: market), method: "GET",
                                                           headers: ["Accept": Secret("application/json")], body: Secret([])))
        } catch let error as ClientError { throw error }
        catch is CancellationError { throw ClientError.cancelled }
        catch { throw ClientError.transport("Xbox request failed; check your connection") }
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox catalogue returned HTTP \(response.status)") }
        return response.body.value
    }
}

/// The variables a play's runtime reads for a game's add-ons and language
/// (nexus-xgameruntime): `NEXUS_RELATED_PRODUCT_IDS`, the Store IDs it may ask
/// licences for beyond the config's RelatedProducts (hints, never rights: each needs
/// Microsoft's signed token); `XODUS_CONTENT_ROOTS`, the folders whose children are
/// installed add-on packages; `XODUS_PACKAGE_LOCALE`, `XPackageGetUserLocale`'s answer.
public enum XboxAddOnEnvironment {
    /// The runtime's limits: 256 IDs, 64 roots of under 258 characters each.
    static let maxRelated = 256, maxRoots = 64, maxRoot = 257, maxRootsLength = 16_000

    public static func values(base: String, related: [String], contentRoots: [String], locale: String?) -> [String: Secret<String>] {
        var env: [String: Secret<String>] = [:]
        var ids: [String] = [], seen: Set<String> = [base]
        for id in related where StoreGameKey.isProductID(id) && ids.count < maxRelated && seen.insert(id).inserted { ids.append(id) }
        if !ids.isEmpty { env["NEXUS_RELATED_PRODUCT_IDS"] = Secret(ids.joined(separator: ",")) }
        var roots: [String] = []
        for root in contentRoots where isRoot(root) && !roots.contains(root) && roots.count < maxRoots { roots.append(root) }
        let joined = roots.joined(separator: ";")
        if !roots.isEmpty, joined.utf16.count <= maxRootsLength { env["XODUS_CONTENT_ROOTS"] = Secret(joined) }
        if let locale, isLocale(locale) { env.merge(localeValues(locale)) { _, new in new } }
        return env
    }

    /// Nexus's game-locale.ts: the runtime's `XODUS_PACKAGE_LOCALE`, Wine's `WINEUSERLOCALE`,
    /// and, for a tag with a region, the Unix side's `LANG`, `LANGUAGE` and `LC_*`
    /// (`pl_PL.UTF-8`; a Latin or Cyrillic script as `@latin`/`@cyrillic`).
    static func localeValues(_ tag: String) -> [String: Secret<String>] {
        var env = ["XODUS_PACKAGE_LOCALE": Secret(tag), "WINEUSERLOCALE": Secret(tag)]
        let parts = tag.split(separator: "-").map(String.init)
        let language = parts[0].lowercased()
        let script = parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        guard let region = parts.dropFirst().first(where: { ($0.count == 2 && $0.allSatisfy(\.isLetter)) || ($0.count == 3 && $0.allSatisfy(\.isNumber)) })
        else { return env }
        let modifier = switch script?.lowercased() { case "latn": "@latin"; case "cyrl": "@cyrillic"; case let s?: "@" + s; case nil: "" }
        let unix = "\(language)_\(region.uppercased()).UTF-8\(modifier)"
        env["LANG"] = Secret(unix)
        env["LANGUAGE"] = Secret("\(language)_\(region.uppercased())\(modifier):\(language)")
        for name in ["LC_ALL", "LC_MESSAGES", "LC_CTYPE", "LC_TIME", "LC_COLLATE", "LC_MONETARY", "LC_NUMERIC", "LC_PAPER"] {
            env[name] = Secret(unix)
        }
        return env
    }

    /// An absolute `X:\` path the runtime splits on `;` and nothing else.
    static func isRoot(_ path: String) -> Bool {
        let s = Array(path.utf8)
        guard s.count >= 3, s.count <= maxRoot, (0x41...0x5A).contains(s[0] & 0xDF), s[1] == 0x3A, s[2] == 0x5C else { return false }
        return !path.unicodeScalars.contains { $0 == ";" || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A BCP-47 tag as Windows names locales: a 2–3 letter language, then subtags.
    static func isLocale(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard tag.utf8.count <= 84, let first = parts.first, (2...3).contains(first.count),
              first.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else { return false }
        return parts.dropFirst().allSatisfy { (1...8).contains($0.count) && $0.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) } }
    }

    /// The phone's language as the package declares it (exact, then the same language),
    /// else the phone's own first well-formed one.
    public static func locale(preferred: [String], declared: [String]) -> String? {
        let wanted = preferred.filter(isLocale)
        for tag in wanted {
            if let d = declared.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return d }
        }
        func language(_ tag: String) -> String { String(tag.split(separator: "-")[0]).lowercased() }
        for tag in wanted {
            if let d = declared.first(where: { language($0) == language(tag) }) { return d }
        }
        return wanted.first
    }
}

extension XboxBridgeCopy {
    /// The same copy with its add-ons' Store IDs also allowed in licence-token requests.
    public func adding(related ids: [String]) -> XboxBridgeCopy {
        var all = relatedProductIDs
        for id in ids where StoreGameKey.isProductID(id) && id != productID && !all.contains(id) { all.append(id) }
        return XboxBridgeCopy(productID: productID, relatedProductIDs: all, msaAppID: msaAppID, msaFullTrust: msaFullTrust)
    }
}
