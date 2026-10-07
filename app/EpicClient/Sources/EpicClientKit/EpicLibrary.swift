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
    /// An ownership token or no offline play is no reason: a Play signs the game in
    /// (decision 0059). Anti-cheat files are found later, in the manifest (`EpicManifest.refusal`).
    public var refusal: String? {
        if let provider = attributes["ThirdPartyManagedProvider"], !provider.isEmpty {
            return provider.lowercased() == "ubisoftconnect"
                ? "This game is installed and started through Ubisoft Connect, which Playport does not run."
                : "This game is installed through another company's launcher, which Playport does not run."
        }
        // Epic's access control (Fortnite) is its anti-cheat's.
        if attributes["UseAccessControl"]?.lowercased() == "true" { return EpicManifest.usesAntiCheat }
        return Self.knownRefusals[id]
    }

    /// Games whose catalogue does not say why they cannot run here (store game sign-in
    /// survey, 2026-10-07), by app name.
    static let knownRefusals: [String: String] = [
        // Elite Dangerous: Frontier's EDLaunch.exe, with a Frontier account.
        "9c203b6ed35846e8a4a9ff1e314f6593": "This game starts through Frontier's launcher and its account, which Playport does not run.",
        // Star Trek Online: Cryptic's launcher (Star Trek Online.exe).
        "0fb6e06aacd14e88b1aaea8f54dd8525": "This game starts through Cryptic's launcher, which Playport does not run.",
        // Marvel Rivals: its own launcher and anti-cheat, with no anti-cheat file by name.
        "575efd0b5dd54429b035ffc8fe2d36d0": EpicManifest.usesAntiCheat,
    ]

    /// The catalogue asks for an ownership token at launch (`-epicovt`).
    public var needsOwnershipToken: Bool { attributes["OwnershipToken"]?.lowercased() == "true" }

    /// Whether the game may start without Epic's sign-in when it cannot be had (offline,
    /// signed out): the catalogue allows offline play and asks for no ownership token.
    public var mayPlayOffline: Bool { attributes["CanRunOffline"]?.lowercased() != "false" && !needsOwnershipToken }
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
