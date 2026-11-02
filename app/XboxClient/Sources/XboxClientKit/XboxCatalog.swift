// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b src/main/catalog.ts
// (directPackageSupport, bundleReferences, packageSupport, licensedDetails,
// displayImage); translated to Swift by the Playport authors, 2026-10-30.
// Modified: MSIXVC2 counts as GDK (the scope of spec PLA-485); a product with no Store package
// is named as delivered elsewhere (Battle.net, the EA app); bundles keep the games
// they resolve to, so the library can drop an edition whose games it lists.
import Foundation
import ContentKit

/// How Microsoft delivers a licensed product to a Windows PC.
public enum XboxDelivery: String, Codable, Sendable {
    /// A Windows.Desktop MSIXVC or MSIXVC2 package (GDK), directly or through its bundle.
    case gdk
    /// Only other PC packages (UWP Appx/Msix, EAppx) or console packages.
    case otherPackage
    /// No Store package at all: delivered through Battle.net, the EA app or another launcher.
    case elsewhere
    /// An add-on, DLC or pass, not a game.
    case notAGame
}

/// A licensed product as the display catalogue describes it. Kept between
/// refreshes, so a product is looked up once.
public struct XboxProduct: Codable, Sendable, Equatable {
    public let productID: String
    public let title: String
    /// Wide art carrying the game's name (TitledHeroArt; else BoxArt).
    public let tileArt: URL?
    /// Wide art for a page (SuperHeroArt; else TitledHeroArt, Hero).
    public let heroArt: URL?
    public let delivery: XboxDelivery
    /// The games with a GDK package the product installs (itself, or its bundle's).
    public let games: [String]
    /// The Windows.Desktop MSIXVC package a copy installs (its own, else its first game's).
    /// Nil in a cache from before PLA-497 (looked up again) or for anything not GDK.
    public var package: XboxProductPackage? = nil
}

/// A Windows.Desktop GDK package as the display catalogue lists it.
public struct XboxProductPackage: Codable, Sendable, Equatable {
    /// The package's content ID (the XVD's VDUID): GetBasePackage's and licensing's.
    public let contentID: String
    /// MSIXVC or MSIXVC2.
    public let format: String
    /// MaxDownloadSizeInBytes: about what the install needs on the phone.
    public let downloadSize: UInt64
    /// What Install needs free: the download plus the install engine's margin (the
    /// stream-extract keeps no copy of the package, only its metadata).
    public var neededBytes: UInt64 { downloadSize + UInt64(Double(downloadSize) * InstallEngine.Options().marginFraction) }
}

enum XboxCatalog {
    typealias Record = [String: Any]
    static let batch = 20
    static let maxDepth = 6
    static let gdkFormats: Set<String> = ["MSIXVC", "MSIXVC2"]
    static let imageHosts: Set<String> = ["store-images.s-microsoft.com", "store-images.microsoft.com"]

    static func url(_ ids: [String], market: String) -> URL {
        var c = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")!
        c.queryItems = [URLQueryItem(name: "bigIds", value: ids.joined(separator: ",")), URLQueryItem(name: "market", value: market),
                        URLQueryItem(name: "languages", value: "en-us,neutral")]
        return c.url!
    }

    /// One response, keyed by Product ID; only the products asked for.
    static func parse(_ bytes: [UInt8], asked: Set<String>) throws -> [String: Record] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? Record, let products = root["Products"] as? [Any] else {
            throw ClientError.protocolChanged("Xbox catalogue has an unexpected shape")
        }
        var records: [String: Record] = [:]
        for case let record as Record in products {
            if let id = (record["ProductId"] as? String)?.uppercased(), asked.contains(id) { records[id] = record }
        }
        return records
    }

    private static func skuProperties(_ record: Record) -> [Record] {
        ((record["DisplaySkuAvailabilities"] as? [Any]) ?? []).compactMap { (($0 as? Record)?["Sku"] as? Record)?["Properties"] as? Record }
    }

    /// Package formats on Windows.Desktop, upper-cased; and whether the product has any package at all.
    static func formats(_ record: Record) -> (desktop: Set<String>, any: Bool) {
        var desktop = Set<String>(), any = false
        for package in packages(record) {
            any = true
            if package.desktop { desktop.insert(package.format) }
        }
        return (desktop, any)
    }

    private static func packages(_ record: Record) -> [(format: String, desktop: Bool, record: Record)] {
        var out: [(format: String, desktop: Bool, record: Record)] = []
        for properties in skuProperties(record) {
            for case let package as Record in (properties["Packages"] as? [Any]) ?? [] {
                let platforms = ((package["PlatformDependencies"] as? [Any]) ?? []).compactMap { ($0 as? Record)?["PlatformName"] as? String }
                out.append((((package["PackageFormat"] as? String) ?? "UNKNOWN").uppercased(), platforms.contains("Windows.Desktop"), package))
            }
        }
        return out
    }

    /// The first Windows.Desktop MSIXVC/MSIXVC2 package with a GUID content ID (Xodus's choice).
    static func gdkPackage(_ record: Record) -> XboxProductPackage? {
        for p in packages(record) where p.desktop && gdkFormats.contains(p.format) {
            guard let id = p.record["ContentId"] as? String, let uuid = UUID(uuidString: id) else { continue }
            let size = (p.record["MaxDownloadSizeInBytes"] as? NSNumber)?.uint64Value ?? 0
            return XboxProductPackage(contentID: uuid.uuidString.lowercased(), format: p.format, downloadSize: size)
        }
        return nil
    }

    /// A bundle's products, primary when any SKU marks it so.
    static func references(_ record: Record) -> [(id: String, primary: Bool)] {
        var order: [String] = [], primary: [String: Bool] = [:]
        for properties in skuProperties(record) {
            for case let sku as Record in (properties["BundledSkus"] as? [Any]) ?? [] {
                guard let id = (sku["BigId"] as? String)?.uppercased(), StoreGameKey.isProductID(id) else { continue }
                if primary[id] == nil { order.append(id) }
                primary[id] = primary[id] == true || sku["IsPrimary"] as? Bool == true
            }
        }
        return order.map { ($0, primary[$0]!) }
    }

    /// The products still to look up for this one: a bundle's, unless it has its own desktop package.
    static func children(_ record: Record) -> [String] {
        formats(record).desktop.isEmpty ? references(record).map(\.id) : []
    }

    enum Support: Equatable { case gdk(Set<String>), other, elsewhere, unknown }

    /// Nexus's packageSupport: a direct desktop package decides; a bundle of several
    /// products is GDK when any is; a bundle of one, or with one primary, is what
    /// that product is. Missing records stay unknown (looked up again next time).
    static func support(_ id: String, _ records: [String: Record], visited: Set<String> = []) -> Support {
        guard visited.count <= maxDepth, let record = records[id] else { return .unknown }
        let formats = formats(record)
        if !formats.desktop.isEmpty { return formats.desktop.isDisjoint(with: gdkFormats) ? .other : .gdk([id]) }
        guard !visited.contains(id) else { return .other }
        let next = visited.union([id]), references = references(record)
        if references.count > 1 {
            let all = references.map { support($0.id, records, visited: next) }
            let games = all.reduce(into: Set<String>()) { if case let .gdk(g) = $1 { $0.formUnion(g) } }
            if !games.isEmpty { return .gdk(games) }
            if all.contains(.unknown) { return .unknown }
            return all.contains(.other) ? .other : .elsewhere
        }
        guard let only = references.first else { return formats.any ? .other : .elsewhere }
        return support(only.id, records, visited: next)
    }

    static func product(_ id: String, _ records: [String: Record]) -> XboxProduct? {
        guard let record = records[id], let localized = (record["LocalizedProperties"] as? [Any])?.first as? Record,
              let title = (localized["ProductTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        let images = ((localized["Images"] as? [Any]) ?? []).compactMap { $0 as? Record }
        func art(_ purposes: [String]) -> URL? {
            for purpose in purposes {
                for image in images where image["ImagePurpose"] as? String == purpose {
                    if let url = safeImage(image["Uri"] as? String) { return url }
                }
            }
            return nil
        }
        let delivery: XboxDelivery, games: [String]
        if record["ProductType"] as? String != "Game" {
            delivery = .notAGame; games = []
        } else {
            switch support(id, records) {
            case .unknown: return nil
            case .other: delivery = .otherPackage; games = []
            case .elsewhere: delivery = .elsewhere; games = []
            case let .gdk(found):
                delivery = .gdk
                games = found.filter { records[$0]?["ProductType"] as? String == "Game" }.sorted()
            }
        }
        let package = delivery == .gdk ? gdkPackage(record) ?? games.lazy.compactMap({ records[$0].flatMap(gdkPackage) }).first : nil
        return XboxProduct(productID: id, title: String(title.prefix(512)), tileArt: art(["TitledHeroArt", "BoxArt"]),
                           heroArt: art(["SuperHeroArt", "TitledHeroArt", "Hero"]), delivery: delivery, games: games, package: package)
    }

    /// Microsoft's image hosts over HTTPS only; protocol-relative URIs become HTTPS.
    static func safeImage(_ raw: String?) -> URL? {
        guard var raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.count <= 8192 else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), imageHosts.contains(host) else { return nil }
        return url
    }
}
