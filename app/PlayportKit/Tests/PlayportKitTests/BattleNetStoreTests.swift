// SPDX-License-Identifier: GPL-3.0-or-later
import BattleNetClientKit
import SteamClientKit
import XCTest
@testable import PlayportKit

/// The Battle.net store in the library (PLA-519): its identity, the products it lists, the store
/// region and WoW locale it starts from, the space an install needs and what a failure says.
final class BattleNetStoreTests: XCTestCase {
    func testABattleNetCopyIsTheStoreAndItsTACTProductCode() throws {
        let key = BattleNet.key(.wowClassicEra)
        XCTAssertEqual(key, StoreGameKey(store: .battlenet, id: "wow_classic_era"))
        XCTAssertEqual(key.titleID, "bnet-wow_classic_era")
        XCTAssertEqual(StoreGameKey(titleID: "bnet-wow_classic_era"), key)
        XCTAssertEqual(StoreGameKey(titleID: "bnet-wow")?.store, .battlenet)
        XCTAssertNil(StoreGameKey(titleID: "bnet-"))
        XCTAssertEqual(Store.battlenet.label, "Battle.net")
        XCTAssertEqual(key.fileStem, "battlenet-wow_classic_era", "the receipt is installs/battlenet-<code>.json")
        // Kept apart from the other stores' copies of a game of the same name.
        let entries = LibraryList.entries(titles: [], owned: [
            .init(key: key, name: "World of Warcraft Classic Era"),
            .init(key: StoreGameKey(store: .epic, id: "wow_classic_era"), name: "World of Warcraft Classic Era"),
        ])
        XCTAssertEqual(entries.map(\.id), ["bnet-wow_classic_era", "epic-wow_classic_era"])
        XCTAssertEqual(LibraryList.duplicateSourceIDs(entries), ["bnet-wow_classic_era", "epic-wow_classic_era"])
        XCTAssertEqual(LibraryList.shown(entries, filter: .battlenet, sort: .name).map(\.id), ["bnet-wow_classic_era"])
    }

    func testTheStoreRegionStartsFromThePhonesRegion() {
        // Americas → us, Europe → eu, Korea → kr, Taiwan → tw (the spec's four).
        for phone in ["US", "CA", "MX", "BR", "AR", "CL"] { XCTAssertEqual(BattleNet.region(phoneRegion: phone), .us, phone) }
        for phone in ["DE", "FR", "GB", "PL", "ES", "IT", "SE", "IE"] { XCTAssertEqual(BattleNet.region(phoneRegion: phone), .eu, phone) }
        XCTAssertEqual(BattleNet.region(phoneRegion: "KR"), .kr)
        XCTAssertEqual(BattleNet.region(phoneRegion: "TW"), .tw)
        // Elsewhere, Blizzard's own grouping: Oceania and Southeast Asia play in the Americas region,
        // Russia, the Middle East and Africa in Europe's; Hong Kong and Macau in Taiwan's.
        XCTAssertEqual(BattleNet.region(phoneRegion: "AU"), .us)
        XCTAssertEqual(BattleNet.region(phoneRegion: "SG"), .us)
        XCTAssertEqual(BattleNet.region(phoneRegion: "RU"), .eu)
        XCTAssertEqual(BattleNet.region(phoneRegion: "AE"), .eu)
        XCTAssertEqual(BattleNet.region(phoneRegion: "ZA"), .eu)
        XCTAssertEqual(BattleNet.region(phoneRegion: "HK"), .tw)
        XCTAssertEqual(BattleNet.region(phoneRegion: "de"), .eu, "case aside")
        XCTAssertEqual(BattleNet.region(phoneRegion: nil), .us, "no region set: the Americas region")
        XCTAssertEqual(BattleNet.region(phoneRegion: "001"), .us, "a UN M.49 area is no country")
    }

    func testTheInstallLanguageIsThePhonesLanguageAsAWoWLocale() {
        // wow's and wow_classic_era's product configs, 2026-10-30 (BattleNetClient fixtures).
        let retail = ["enUS", "esMX", "ptBR", "deDE", "esES", "frFR", "itIT", "ruRU", "koKR", "zhTW", "zhCN"]
        let retailReplacing = ["enCN": "zhCN", "enGB": "enUS", "enSG": "enUS", "enTW": "zhTW", "ptPT": "ptBR"]
        let era = ["enUS", "esMX", "ptBR", "deDE", "esES", "frFR", "ruRU", "koKR", "zhTW", "zhCN"]
        func retailLocale(_ phone: [String]) -> String {
            BattleNet.locale(preferredLanguages: phone, supported: retail, replacements: retailReplacing)
        }
        XCTAssertEqual(retailLocale(["en-US"]), "enUS")
        XCTAssertEqual(retailLocale(["en-GB"]), "enUS", "the product config replaces enGB with enUS")
        XCTAssertEqual(retailLocale(["de-DE"]), "deDE")
        XCTAssertEqual(retailLocale(["de-AT"]), "deDE")
        XCTAssertEqual(retailLocale(["fr-CA"]), "frFR")
        XCTAssertEqual(retailLocale(["es-ES"]), "esES")
        XCTAssertEqual(retailLocale(["es-MX"]), "esMX")
        XCTAssertEqual(retailLocale(["es-419"]), "esMX", "Latin American Spanish")
        XCTAssertEqual(retailLocale(["es-AR"]), "esMX")
        XCTAssertEqual(retailLocale(["pt-BR"]), "ptBR")
        XCTAssertEqual(retailLocale(["pt-PT"]), "ptBR", "replaced as the product config says")
        XCTAssertEqual(retailLocale(["it-IT"]), "itIT")
        XCTAssertEqual(retailLocale(["ru-RU"]), "ruRU")
        XCTAssertEqual(retailLocale(["ko-KR"]), "koKR")
        XCTAssertEqual(retailLocale(["zh-Hant-TW"]), "zhTW")
        XCTAssertEqual(retailLocale(["zh-Hant-HK"]), "zhTW")
        XCTAssertEqual(retailLocale(["zh-Hans-CN"]), "zhCN")
        XCTAssertEqual(retailLocale(["zh-TW"]), "zhTW")
        XCTAssertEqual(retailLocale(["ja-JP"]), "enUS", "no WoW locale: enUS")
        XCTAssertEqual(retailLocale(["ja-JP", "de-DE"]), "deDE", "the next language the phone prefers")
        XCTAssertEqual(retailLocale([]), "enUS")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["it-IT"], supported: era, replacements: [:]), "enUS",
                       "a locale the product does not ship falls back to enUS")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["it-IT", "fr-FR"], supported: era, replacements: [:]), "frFR")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["de_DE"], supported: [], replacements: [:]), "deDE",
                       "no product config yet: any WoW locale")
    }

    func testTheStoreListsOnlyOfferedWoWProducts() {
        func listing(_ p: BattleNetProduct, offered: Bool) -> BattleNetListing {
            BattleNetListing(product: p, region: .eu, version: "1.15.9.70576", offered: offered)
        }
        let listings = [listing(.wowAnniversary, offered: true), listing(.wow, offered: false),
                        listing(.wowClassicEra, offered: true), listing(.wowClassic, offered: true)]
        let shown = BattleNet.shown(listings)
        XCTAssertEqual(shown.map(\.key.titleID), ["bnet-wow_classic", "bnet-wow_classic_era", "bnet-wow_anniversary"],
                       "a build without its ARM64 client is not listed; the rest in the fixed list's order")
        XCTAssertEqual(shown.map(\.name), ["World of Warcraft Classic", "World of Warcraft Classic Era",
                                           "World of Warcraft Classic Anniversary"])
        XCTAssertEqual(BattleNet.shown([]), [], "nothing listed until Blizzard says what is offered")
        // Other Battle.net games are never products: no page, no install.
        XCTAssertEqual(BattleNet.product(StoreGameKey(store: .battlenet, id: "wow_classic_era")), .wowClassicEra)
        XCTAssertNil(BattleNet.product(StoreGameKey(store: .battlenet, id: "pro")), "Overwatch's code")
        XCTAssertNil(BattleNet.product(StoreGameKey(store: .battlenet, id: "d4")), "Diablo IV's code")
        XCTAssertNil(BattleNet.product(StoreGameKey(store: .epic, id: "wow")), "another store's copy")
        // The listing is cached as JSON, so the store lists offline.
        let data = try! JSONEncoder().encode(listings)
        XCTAssertEqual(try! JSONDecoder().decode([BattleNetListing].self, from: data), listings)
    }

    func testTheSpaceAnInstallNeedsAndARefusalThatSaysHowMuch() {
        // wow_classic_era us enUS (offer evidence, 2026-10-30): 4.73 GB to download, 4.96 GB installed, 145431 objects.
        let sizes = BattleNetListing.Sizes(locale: "enUS", download: 4_732_119_402, install: 4_959_406_050, objects: 145_431)
        let needed = BattleNet.spaceNeeded(sizes)
        // The install and a 30-byte local header per object (4 963 768 980), ContentKit's 5% margin
        // over them (248 188 449), and 256 MB for the store's CDN indexes.
        XCTAssertEqual(needed, 5_467_957_429)
        XCTAssertNil(BattleNet.refusal(needed: needed, free: 64_000_000_000))
        XCTAssertNil(BattleNet.refusal(needed: needed, free: needed))
        XCTAssertEqual(BattleNet.refusal(needed: needed, free: 2_000_000_000),
                       "Not enough free space: 5.47 GB needed, 2.00 GB free.")
    }

    func testAJobCarriesTheRegionAndLocaleItWasStartedWith() {
        let branch = BattleNet.jobBranch(region: .eu, locale: "deDE")
        XCTAssertEqual(branch, "eu/deDE")
        XCTAssertEqual(BattleNet.jobChoice(branch)?.region, .eu)
        XCTAssertEqual(BattleNet.jobChoice(branch)?.locale, "deDE")
        XCTAssertNil(BattleNet.jobChoice(nil))
        XCTAssertNil(BattleNet.jobChoice("cn/zhCN"), "not a store region")
        XCTAssertNil(BattleNet.jobChoice("eu"))
    }

    func testAFinishedInstallIsALibraryTitlePlayedFromItsARM64Client() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bnet-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = PlayportPaths.container(home: root)
        let games = paths.layout.gamesRoot
        // Nothing in C:\Games while it downloads: the stage is under the staging root.
        XCTAssertFalse(BattleNet.workArea(.wowClassicEra, layout: paths.layout).path.hasPrefix(games.path))
        XCTAssertEqual(BattleNet.folder(.wowClassicEra, in: games), "World of Warcraft Classic Era")
        try FileManager.default.createDirectory(at: games.appendingPathComponent("world of warcraft classic era"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(BattleNet.folder(.wowClassicEra, in: games), "World of Warcraft Classic Era (Battle.net)",
                       "another folder of that name is left alone")

        let folder = games.appendingPathComponent("World of Warcraft Classic Era (Battle.net)/_classic_era_")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pe = Direct3D12Tests.pe(plus: true, name: "d3d12.dll")
        pe[0x84] = 0x64
        pe[0x85] = 0xAA
        try pe.write(to: folder.appendingPathComponent("WowClassic-arm64.exe"))
        try pe.write(to: folder.appendingPathComponent("WowClassic.exe"))
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let receipt = BattleNet.receipt(.wowClassicEra, folder: "World of Warcraft Classic Era (Battle.net)", version: "1.15.9.70576",
                                        productFolder: "_classic_era_", arm64Executable: "WowClassic-arm64.exe",
                                        files: 12, bytes: 4_959_406_050, at: at)
        try paths.layout.saveReceipt(receipt)
        let c = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], storeReceipts: paths.layout.storeReceipts(),
                              previous: Catalog())
        let t = try XCTUnwrap(c.titles.first { $0.store == .battlenet })
        XCTAssertEqual(t.id, "bnet-wow_classic_era")
        XCTAssertEqual(t.key, BattleNet.key(.wowClassicEra))
        XCTAssertEqual(t.name, "World of Warcraft Classic Era")
        XCTAssertEqual(t.executable, #"_classic_era_\WowClassic-arm64.exe"#)
        XCTAssertEqual(t.executableMachine, 0xAA64, "the ARM64 client, never the x64 one")
        XCTAssertEqual(t.storeVersion, "1.15.9.70576")
        XCTAssertEqual(t.source, .installed)
        XCTAssertEqual(c.titles.filter { $0.store == .local }.map(\.installDir), ["world of warcraft classic era"])
    }

    func testBlizzardsCDNUnreachableOrRefusingIsSaidPlainly() {
        XCTAssertEqual(BattleNet.reason(BattleNetError.unreachable("versions: us.version.battle.net: offline")),
                       "Blizzard's servers can't be reached. Check the connection, then try again.")
        XCTAssertEqual(BattleNet.reason(BattleNetError.refused(status: 403, "data from level3.blizzard.com")),
                       "Blizzard's servers refused the download (HTTP 403). Try again later.")
        XCTAssertEqual(BattleNet.reason(BattleNetError.refused(status: 429, "data from level3.blizzard.com")),
                       "Blizzard's servers are asking Playport to slow down (HTTP 429). Try again later.")
        XCTAssertEqual(BattleNet.reason(BattleNetError.damaged("install manifest: bad magic")),
                       "Blizzard's servers sent damaged data. Try again later.")
        XCTAssertEqual(BattleNet.reason(BattleNetError.missingKey("FA505078126ACB3E")),
                       "Playport can't read this build yet.")
        XCTAssertNil(BattleNet.reason(ClientError.insufficientSpace(needed: 1, available: 0)), "not Blizzard's: the store-neutral wording")
    }
}
