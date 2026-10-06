// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// An owned Epic game, as the library and the catalogue list it.
public struct EpicGame: Codable, Equatable, Sendable, Identifiable {
    /// The app name: the store's ID for the game (`epic-<appName>`).
    public var id: String
    public var namespace: String
    public var catalogItemID: String
    public var title: String
    /// DieselGameBox (16:9) and DieselGameBoxTall: Epic's image CDN, resized by query.
    public var wideArt: String?
    public var tallArt: String?
    /// The catalogue's custom attributes that matter here (the rest are not kept).
    public var attributes: [String: String]

    public init(id: String, namespace: String, catalogItemID: String, title: String, wideArt: String? = nil,
                tallArt: String? = nil, attributes: [String: String] = [:]) {
        self.id = id
        self.namespace = namespace
        self.catalogItemID = catalogItemID
        self.title = title
        self.wideArt = wideArt
        self.tallArt = tallArt
        self.attributes = attributes
    }

    static let keptAttributes: Set<String> = ["FolderName", "CanRunOffline", "OwnershipToken", "AdditionalCommandLine",
                                              "ThirdPartyManagedProvider", "CloudSaveFolder", "NeverUpdate", "UseAccessControl"]

    /// The 16:9 art `width` pixels wide (800 for a tile, 1920 behind a page).
    public func art(width: Int) -> URL? {
        guard let base = wideArt ?? tallArt, var c = URLComponents(string: base), c.scheme == "https" else { return nil }
        c.queryItems = [.init(name: "w", value: String(width)), .init(name: "resize", value: "1")]
        return c.url
    }

    /// The folder the catalogue names for an install (FolderName), else the title.
    public var folderName: String { attributes["FolderName"].flatMap { $0.isEmpty ? nil : $0 } ?? title }

    /// Why Playport does not install it (plan 3.5), from the catalogue: nil when it may.
    /// Anti-cheat is found later, in the manifest's files (`EpicManifest.refusal`).
    public var refusal: String? {
        if attributes["ThirdPartyManagedProvider"].map({ !$0.isEmpty }) ?? false {
            return "This game is installed through another company's launcher, which Playport does not run."
        }
        // Measured (plan 3.1): an ownership token, no offline play, or Epic's access
        // control (Fortnite) all mean the game signs in to Epic at launch.
        if attributes["OwnershipToken"]?.lowercased() == "true" || attributes["CanRunOffline"]?.lowercased() == "false"
            || attributes["UseAccessControl"]?.lowercased() == "true" {
            return EpicGame.needsOnlineSignIn
        }
        return nil
    }

    public static let needsOnlineSignIn = "This game needs Epic online sign-in, which Playport does not support yet."
}

public enum EpicLibrary {
    static let libraryBase = "https://library-service.live.use1a.on.epicgames.com/library/api/public/items"
    static let catalogBase = "https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/"

    /// Every owned Windows game (no DLC, no Unreal Engine assets), by title.
    public static func owned(_ session: EpicSession) async throws -> [EpicGame] {
        var records: [Record] = []
        var cursor: String?
        var pages = 0
        repeat {
            var c = URLComponents(string: libraryBase)!
            c.queryItems = [.init(name: "includeMetadata", value: "true")] + (cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
            let page = try parseLibrary(try await session.authorized(c.url!, maxBytes: 16 << 20, label: "Epic library"))
            records += page.records
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < 200
        let wanted = records.filter { $0.namespace != "ue" && $0.sandboxType?.uppercased() != "PRIVATE" && !$0.appName.isEmpty }
        var games: [EpicGame] = []
        for (ns, group) in Dictionary(grouping: wanted, by: \.namespace) {
            var c = URLComponents(string: catalogBase + ns + "/bulk/items")!
            guard ns.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
            c.queryItems = Array(Set(group.map(\.catalogItemId))).sorted().map { .init(name: "id", value: $0) }
                + [.init(name: "includeDLCDetails", value: "true"), .init(name: "includeMainGameDetails", value: "true"),
                   .init(name: "country", value: "US"), .init(name: "locale", value: "en-US")]
            let items = try parseCatalog(try await session.authorized(c.url!, maxBytes: 16 << 20, label: "Epic catalogue"))
            for r in group { if let g = items[r.catalogItemId].flatMap({ $0.game(r) }) { games.append(g) } }
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    struct Record: Decodable {
        var appName: String
        var namespace: String
        var catalogItemId: String
        var sandboxType: String?
    }

    static func parseLibrary(_ body: [UInt8]) throws -> (records: [Record], next: String?) {
        struct Page: Decodable {
            struct Meta: Decodable { var nextCursor: String? }
            var records: [Record]
            var responseMetadata: Meta?
        }
        guard let p = try? JSONDecoder().decode(Page.self, from: Data(body)) else {
            throw ClientError.protocolChanged("Epic library: unexpected reply")
        }
        return (p.records, p.responseMetadata?.nextCursor.flatMap { $0.isEmpty ? nil : $0 })
    }

    struct CatalogItem: Decodable {
        struct Image: Decodable { var type: String; var url: String }
        struct Attr: Decodable { var value: String? }
        struct Release: Decodable { var platform: [String]? }
        struct Main: Decodable { var id: String? }
        var title: String
        var keyImages: [Image]?
        var customAttributes: [String: Attr]?
        var releaseInfo: [Release]?
        var mainGameItem: Main?

        /// The game, or nil for a DLC or an item with no Windows release.
        func game(_ r: Record) -> EpicGame? {
            guard mainGameItem == nil else { return nil }
            let platforms = Set((releaseInfo ?? []).flatMap { $0.platform ?? [] })
            guard platforms.isEmpty || platforms.contains("Windows") || platforms.contains("Win32") else { return nil }
            let image = { (t: String) in keyImages?.first { $0.type == t }?.url }
            var attrs: [String: String] = [:]
            for (k, v) in customAttributes ?? [:] where EpicGame.keptAttributes.contains(k) { attrs[k] = v.value ?? "" }
            return EpicGame(id: r.appName, namespace: r.namespace, catalogItemID: r.catalogItemId, title: title,
                            wideArt: image("DieselGameBox") ?? image("OfferImageWide"),
                            tallArt: image("DieselGameBoxTall") ?? image("OfferImageTall"), attributes: attrs)
        }
    }

    static func parseCatalog(_ body: [UInt8]) throws -> [String: CatalogItem] {
        guard let items = try? JSONDecoder().decode([String: CatalogItem].self, from: Data(body)) else {
            throw ClientError.protocolChanged("Epic catalogue: unexpected reply")
        }
        return items
    }
}
