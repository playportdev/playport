// SPDX-License-Identifier: GPL-3.0-or-later
// The Battle.net store in the library (PLA-519, decision 0168): no sign-in, a fixed list of
// World of Warcraft products (BattleNetClientKit.BattleNetProduct), each listed while its build
// carries its ARM64 client. A copy is `(battlenet, TACT product code)`, title ID
// `bnet-<code>`. The app's side (UI/BattleNetStore.swift) asks Blizzard and runs the installs;
// what it decides with is here, so the host tests reach it.

import BattleNetClientKit
import Foundation
import SteamClientKit

public enum BattleNet {
    /// A product's store identity.
    public static func key(_ product: BattleNetProduct) -> StoreGameKey {
        StoreGameKey(store: .battlenet, id: product.code)
    }

    /// The product a key names: nil for another store's key and for a code not on the fixed
    /// list (other Battle.net games are never offered).
    public static func product(_ key: StoreGameKey) -> BattleNetProduct? {
        key.store == .battlenet ? BattleNetProduct(rawValue: key.id) : nil
    }

    /// The store's tiles: the offered products (a build carrying its ARM64 client), in the
    /// fixed list's order.
    public static func shown(_ listings: [BattleNetListing]) -> [LibraryList.Owned] {
        let offered = Set(listings.filter(\.offered).map(\.product))
        return BattleNetProduct.allCases.filter(offered.contains).map { p in
            LibraryList.Owned(key: key(p), name: p.name, installSize: listings.first { $0.product == p }?.sizes?.install)
        }
    }

    // MARK: install

    /// A job's branch: the store region and locale it was started with (`eu/deDE`), so a
    /// resume, after a restart too, continues the same install.
    public static func jobBranch(region: StoreRegion, locale: String) -> String { "\(region.rawValue)/\(locale)" }

    public static func jobChoice(_ branch: String?) -> (region: StoreRegion, locale: String)? {
        guard let parts = branch?.split(separator: "/").map(String.init), parts.count == 2,
              let region = StoreRegion(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return (region, parts[1])
    }

    /// Where an install stages, resumes and keeps the CDN's indexes until it is done: under
    /// the staging root, so C:\Games has nothing of it (and no Play) before it is complete.
    public static func workArea(_ product: BattleNetProduct, layout: InstallLayout) -> URL {
        layout.stagingTree(name: key(product).fileStem)
    }

    /// The folder under C:\Games for a new install: the product's name, else tagged
    /// `(Battle.net)` and numbered, so another folder of that name is left alone.
    public static func folder(_ product: BattleNetProduct, in games: URL) -> String {
        let have = Set(((try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []).map { $0.lowercased() })
        if !have.contains(product.name.lowercased()) { return product.name }
        let tagged = "\(product.name) (\(Store.battlenet.label))"
        if !have.contains(tagged.lowercased()) { return tagged }
        var n = 2
        while have.contains("\(tagged) \(n)".lowercased()) { n += 1 }
        return "\(tagged) \(n)"
    }

    /// The receipt adoption reads: the product folder's ARM64 client is what Play starts.
    public static func receipt(_ product: BattleNetProduct, folder: String, version: String, productFolder: String,
                               arm64Executable: String, files: Int, bytes: UInt64, at: Date) -> StoreReceipt {
        StoreReceipt(store: .battlenet, storeID: product.code, name: product.name, installDir: folder, version: version,
                     executable: productFolder + "\\" + arm64Executable, arguments: nil, workingDir: nil,
                     files: files, bytes: bytes, installedAt: at)
    }

    // MARK: installed: region and language (PLA-520)

    /// An installed product's store region and language, as its `.build.info` (in its folder
    /// under C:\Games) says; nil when there is none or it has no row for the product.
    public static func installedChoice(_ product: BattleNetProduct, folder: URL) -> (region: StoreRegion, locale: String)? {
        guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(".build.info")),
              let info = try? BuildInfo.read([UInt8](bytes), product: product.code), let locale = info.locale else { return nil }
        return (info.region, locale)
    }

    /// A language change: an update of the installed build that downloads only `locale`'s data
    /// (the region stays the install's), run by Downloads.
    public static func languageJob(_ product: BattleNetProduct, region: StoreRegion, locale: String, bytes: UInt64? = nil) -> DownloadJob {
        DownloadJob(key: key(product), name: product.name, kind: .update, branch: jobBranch(region: region, locale: locale), bytes: bytes)
    }

    /// Whether `job` is a language change (an update naming a region and locale).
    public static func isLanguageChange(_ job: DownloadJob) -> Bool { job.kind == .update && jobChoice(job.branch) != nil }

    /// The receipt after a language change added `files` files of `bytes` bytes.
    public static func receipt(_ r: StoreReceipt, adding files: Int, bytes: UInt64) -> StoreReceipt {
        var r = r
        r.files += files
        r.bytes += bytes
        return r
    }

    // MARK: space

    /// Room for the store's CDN indexes and archive group, which the install keeps beside the
    /// data (about 125 MB for retail on 2026-10-30).
    public static let indexAllowance: UInt64 = 256_000_000
    /// Each stored object's local header in the data files.
    static let localHeader: UInt64 = 30
    /// ContentKit's install engine margin (InstallEngine.Options.marginFraction).
    static let marginFraction = 0.05

    /// The free space an install needs before it starts: the install with a local header per
    /// object, the engine's margin over them, and the CDN indexes. At least what the engine
    /// asks for, so an install the page lets start does not stop at once for space.
    public static func spaceNeeded(_ sizes: BattleNetListing.Sizes) -> UInt64 {
        let files = sizes.install + UInt64(sizes.objects) * localHeader
        return files + UInt64(Double(files) * marginFraction) + indexAllowance
    }

    /// What the page says instead of installing, or nil when it fits.
    public static func refusal(needed: UInt64, free: UInt64) -> String? {
        free >= needed ? nil : "Not enough free space: \(ByteCount.format(needed)) needed, \(ByteCount.format(free)) free."
    }

    // MARK: failures

    /// What the player is told when Blizzard's servers fail: unreachable, refusing, or sending
    /// damaged data. Nil for a failure that is not the store client's (the store-neutral wording
    /// then, as a full disk).
    public static func reason(_ error: Error) -> String? {
        guard let e = error as? BattleNetError else { return nil }
        switch e {
        case .unreachable: return "Blizzard's servers can't be reached. Check the connection, then try again."
        case .refused(429, _): return "Blizzard's servers are asking Playport to slow down (HTTP 429). Try again later."
        case let .refused(status, _): return "Blizzard's servers refused the download (HTTP \(status)). Try again later."
        case .damaged: return "Blizzard's servers sent damaged data. Try again later."
        case .missingKey, .unsupported: return "Playport can't read this build yet."
        }
    }

    // MARK: store region

    /// Countries that play in the Europe region: Europe, Russia and its neighbours, the Middle
    /// East and Africa (Blizzard's grouping). ISO 3166-1 alpha-2.
    static let europeRegion: Set<String> = [
        // Europe
        "AD", "AL", "AT", "AX", "BA", "BE", "BG", "BY", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FO", "FR", "GB",
        "GG", "GI", "GR", "HR", "HU", "IE", "IM", "IS", "IT", "JE", "LI", "LT", "LU", "LV", "MC", "MD", "ME", "MK", "MT",
        "NL", "NO", "PL", "PT", "RO", "RS", "RU", "SE", "SI", "SJ", "SK", "SM", "UA", "VA", "XK",
        // the Caucasus and Central Asia
        "AM", "AZ", "GE", "KG", "KZ", "TJ", "TM", "UZ",
        // the Middle East
        "AE", "BH", "IL", "IQ", "IR", "JO", "KW", "LB", "OM", "PS", "QA", "SA", "SY", "TR", "YE",
        // Africa
        "AO", "BF", "BI", "BJ", "BW", "CD", "CF", "CG", "CI", "CM", "CV", "DJ", "DZ", "EG", "EH", "ER", "ET", "GA", "GH",
        "GM", "GN", "GQ", "GW", "KE", "KM", "LR", "LS", "LY", "MA", "MG", "ML", "MR", "MU", "MW", "MZ", "NA", "NE", "NG",
        "RE", "RW", "SC", "SD", "SL", "SN", "SO", "SS", "ST", "SZ", "TD", "TG", "TN", "TZ", "UG", "YT", "ZA", "ZM", "ZW",
    ]

    /// The store region an install starts from: the phone's region (`Locale.current.region`)
    /// mapped as Blizzard groups countries. Korea is kr; Taiwan, Hong Kong and Macau tw; the
    /// Europe region's countries eu; the Americas, Oceania, Asia's other countries and a phone
    /// with no country set us.
    public static func region(phoneRegion: String?) -> StoreRegion {
        switch phoneRegion?.uppercased() {
        case "KR"?: return .kr
        case "TW"?, "HK"?, "MO"?: return .tw
        case let code? where europeRegion.contains(code): return .eu
        default: return .us
        }
    }

    // MARK: install language

    /// The fallback, and the locale every product ships.
    public static let defaultLocale = "enUS"
    /// WoW's locales (before a product config says which a product ships).
    static let wowLocales: Set<String> = ["enUS", "enGB", "esMX", "esES", "ptBR", "ptPT", "deDE", "frFR", "itIT", "ruRU",
                                          "koKR", "zhTW", "zhCN"]
    /// Spanish outside Spain is WoW's Latin American Spanish.
    static let spainSpanish: Set<String> = ["ES"]

    /// The install's locale: the first of the phone's preferred languages (`Locale.preferredLanguages`,
    /// `de-DE`, `zh-Hant-TW`, `es-419`) that is a WoW locale the product ships (`supported`, after
    /// the product config's `replacements`, enGB → enUS), else enUS. With no product config yet
    /// (`supported` empty), any WoW locale.
    public static func locale(preferredLanguages: [String], supported: [String], replacements: [String: String]) -> String {
        for language in preferredLanguages {
            guard var wow = wowLocale(language) else { continue }
            wow = replacements[wow] ?? wow
            if supported.isEmpty ? wowLocales.contains(wow) : supported.contains(wow) { return wow }
        }
        return defaultLocale
    }

    /// `de-AT` → deDE: the language, and the country only where WoW has two locales of it.
    static func wowLocale(_ language: String) -> String? {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let lang = parts.first?.lowercased() else { return nil }
        // The country: a two-letter or three-digit part after the language (and any script).
        let country = parts.dropFirst().first { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }?.uppercased()
        let script = parts.dropFirst().first { $0.count == 4 }?.lowercased()
        switch lang {
        case "en": return country == "GB" ? "enGB" : "enUS"
        case "de": return "deDE"
        case "fr": return "frFR"
        case "it": return "itIT"
        case "ru": return "ruRU"
        case "ko": return "koKR"
        case "es": return country == nil || spainSpanish.contains(country!) ? "esES" : "esMX"
        case "pt": return country == "PT" ? "ptPT" : "ptBR"
        case "zh":
            if script == "hant" || ["TW", "HK", "MO"].contains(country ?? "") { return "zhTW" }
            return "zhCN"
        default: return nil
        }
    }
}

/// What the store knows of one product in one store region: its build, whether it is offered,
/// the locales it ships and, once asked for a locale, its sizes. Cached as JSON by the app, so
/// the store lists offline.
public struct BattleNetListing: Codable, Equatable, Sendable {
    public struct Sizes: Codable, Equatable, Sendable {
        public var locale: String
        /// The stored objects to download, encoded.
        public var download: UInt64
        /// The download plus the product folder's files.
        public var install: UInt64
        public var objects: Int

        public init(locale: String, download: UInt64, install: UInt64, objects: Int) {
            self.locale = locale
            self.download = download
            self.install = install
            self.objects = objects
        }

        public init(_ sizes: BattleNetSizes, locale: String) {
            self.init(locale: locale, download: sizes.download, install: sizes.install, objects: sizes.objects)
        }
    }

    public var product: BattleNetProduct
    public var region: StoreRegion
    /// The build's version name (`1.15.9.70576`).
    public var version: String
    /// The build carries its ARM64 client (BattleNetOffer.isOffered).
    public var offered: Bool
    public var supportedLocales: [String]
    public var replacementLocales: [String: String]
    public var sizes: Sizes?

    public init(product: BattleNetProduct, region: StoreRegion, version: String, offered: Bool,
                supportedLocales: [String] = [], replacementLocales: [String: String] = [:], sizes: Sizes? = nil) {
        self.product = product
        self.region = region
        self.version = version
        self.offered = offered
        self.supportedLocales = supportedLocales
        self.replacementLocales = replacementLocales
        self.sizes = sizes
    }

    public init(_ offer: BattleNetOffer) {
        let b = offer.build
        self.init(product: b.product, region: b.region, version: b.version.versionsName, offered: offer.isOffered,
                  supportedLocales: b.productConfig.supportedLocales, replacementLocales: b.productConfig.replacementLocales)
    }
}
