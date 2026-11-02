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

    func testOfferedProductsShowUnderTheBattleNetChipAndInAll() {
        var installed = InstalledTitle(id: "bnet-wow", appID: nil, name: "World of Warcraft", developer: nil, installDir: "World of Warcraft",
                                       executable: #"_retail_\Wow-ARM64.exe"#, buildID: nil, depots: [], sizeBytes: 1, source: .installed,
                                       checksums: nil, note: nil, addedAt: Date(), lastPlayed: nil, lastVerification: nil)
        installed.store = .battlenet
        installed.storeID = "wow"
        let offered = BattleNet.shown([BattleNetListing(product: .wow, region: .us, version: "12", offered: true),
                                       BattleNetListing(product: .wowClassic, region: .us, version: "5", offered: true),
                                       BattleNetListing(product: .wowClassicEra, region: .us, version: "1", offered: true)])
        let entries = LibraryList.entries(titles: [installed], owned: offered)
        XCTAssertEqual(LibraryList.shown(entries, filter: .battlenet, sort: .name).map(\.id),
                       ["bnet-wow", "bnet-wow_classic", "bnet-wow_classic_era"])
        XCTAssertEqual(LibraryList.shown(entries, filter: .all, sort: .name).map(\.id),
                       ["bnet-wow", "bnet-wow_classic", "bnet-wow_classic_era"], "All lists every offered product, installed or not")
        XCTAssertEqual(LibraryList.shown(entries, filter: .battlenet, installedOnly: true, sort: .name).map(\.id), ["bnet-wow"])
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
        XCTAssertEqual(retailLocale(["zh-Hans-HK"]), "zhCN", "the script decides before the country")
        XCTAssertEqual(retailLocale(["zh-Hans-MO"]), "zhCN")
        XCTAssertEqual(retailLocale(["zh-HK"]), "zhTW", "no script: the country")
        XCTAssertEqual(retailLocale(["ja-JP"]), "enUS", "no WoW locale: enUS")
        XCTAssertEqual(retailLocale(["ja-JP", "de-DE"]), "deDE", "the next language the phone prefers")
        XCTAssertEqual(retailLocale([]), "enUS")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["it-IT"], supported: era, replacements: [:]), "enUS",
                       "a locale the product does not ship falls back to enUS")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["it-IT", "fr-FR"], supported: era, replacements: [:]), "frFR")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["de_DE"], supported: [], replacements: [:]), "deDE",
                       "no product config yet: any WoW locale")
        // A Classic product ships enUS and no enGB, and its config replaces nothing: British (or any)
        // English is its US English, never the next language the phone prefers.
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["en-GB", "fr-FR"], supported: era, replacements: [:]), "enUS")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["en-AU", "fr-FR"], supported: era, replacements: [:]), "enUS")
        XCTAssertEqual(BattleNet.locale(preferredLanguages: ["en-GB"], supported: [], replacements: [:]), "enGB",
                       "no product config yet: WoW's own British English")
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

    func testAFinishedInstallIsALibraryTitlePlayedFromItsX64Client() throws {
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
        var arm64 = Direct3D12Tests.pe(plus: true, name: "d3d12.dll")
        arm64[0x84] = 0x64
        arm64[0x85] = 0xAA
        var x64 = Direct3D12Tests.pe(plus: true, name: "d3d12.dll")
        x64[0x84] = 0x64
        x64[0x85] = 0x86
        try arm64.write(to: folder.appendingPathComponent("WowClassic-arm64.exe"))
        try x64.write(to: folder.appendingPathComponent("WowClassic.exe"))
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        // The client's path as the install manifest spells it (BattleNetInstaller.Prepared.clientPath).
        let receipt = BattleNet.receipt(.wowClassicEra, folder: "World of Warcraft Classic Era (Battle.net)", version: "1.15.9.70576",
                                        client: "_classic_era_/WowClassic.exe", files: 12, bytes: 4_959_406_050, at: at)
        try paths.layout.saveReceipt(receipt)
        let c = Adoption.scan(games: games, cohort: Cohort(titles: []), receipts: [], storeReceipts: paths.layout.storeReceipts(),
                              previous: Catalog())
        let t = try XCTUnwrap(c.titles.first { $0.store == .battlenet })
        XCTAssertEqual(t.id, "bnet-wow_classic_era")
        XCTAssertEqual(t.key, BattleNet.key(.wowClassicEra))
        XCTAssertEqual(t.name, "World of Warcraft Classic Era")
        XCTAssertEqual(t.executable, #"_classic_era_\WowClassic.exe"#)
        XCTAssertEqual(t.executableMachine, 0x8664, "the x64 client, never the ARM64 one (decision 0177)")
        XCTAssertEqual(t.storeVersion, "1.15.9.70576")
        XCTAssertEqual(t.source, .installed)
        XCTAssertEqual(c.titles.filter { $0.store == .local }.map(\.installDir), ["world of warcraft classic era"])
    }

    /// PLA-520: an installed product's region and language are its `.build.info`'s; a language
    /// change is an update job in the installed region and the new locale, and its receipt
    /// counts what the install folder holds afterwards.
    func testAnInstalledProductsRegionAndLanguageAndALanguageChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bnet-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(BattleNet.installedChoice(.wowClassicEra, folder: folder))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|"
            + "CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|Product!STRING:0\n"
            + "eu|1|\(String(repeating: "a", count: 32))|\(String(repeating: "b", count: 32))|\(String(repeating: "c", count: 32))|1|tpr/wow|"
            + "eu.cdn.blizzard.com|https://eu.cdn.blizzard.com/?maxhosts=4|Windows x86_64 EU? frFR speech?:Windows x86_64 EU? frFR text?|||1.15.9.70576|wow_classic_era\n"
        try Data(info.utf8).write(to: folder.appendingPathComponent(".build.info"))
        let choice = try XCTUnwrap(BattleNet.installedChoice(.wowClassicEra, folder: folder))
        XCTAssertEqual(choice.region, .eu)
        XCTAssertEqual(choice.locale, "frFR")
        XCTAssertNil(BattleNet.installedChoice(.wow, folder: folder), "another product's row")

        let job = BattleNet.languageJob(.wowClassicEra, region: choice.region, locale: "deDE")
        XCTAssertEqual(job.kind, .update)
        XCTAssertEqual(job.key, BattleNet.key(.wowClassicEra))
        XCTAssertTrue(BattleNet.isLanguageChange(job))
        XCTAssertEqual(BattleNet.jobChoice(job.branch)?.region, .eu)
        XCTAssertEqual(BattleNet.jobChoice(job.branch)?.locale, "deDE")
        XCTAssertFalse(BattleNet.isLanguageChange(DownloadJob(key: BattleNet.key(.wowClassicEra), name: "x", kind: .update)),
                       "an update with no locale is not a language change")

        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let before = BattleNet.receipt(.wowClassicEra, folder: "World of Warcraft Classic Era", version: "1.15.9.70576",
                                       client: "_classic_era_/WowClassic.exe", files: 12, bytes: 4_959_406_050, at: at)
        // The folder holds .build.info and 300 bytes in two more files: the receipt says so,
        // whatever it said before.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Data/data"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: folder.appendingPathComponent("Data/data/data.000"))
        try Data(count: 200).write(to: folder.appendingPathComponent("Data/data/data.001"))
        let measured = await BattleNet.measure(folder)
        XCTAssertEqual(measured.files, 3)
        XCTAssertEqual(measured.bytes, 300 + UInt64(info.utf8.count))
        let after = BattleNet.receipt(before, measured: measured)
        XCTAssertEqual(after.files, 3)
        XCTAssertEqual(after.bytes, measured.bytes)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(after.executable, before.executable)
        XCTAssertEqual(after.installedAt, at)
    }

    /// PLA-521: an update is an update job with no locale, which Downloads shows as Updating, apart
    /// from a language change; its receipt names the new version, the folder's size, not the
    /// old size plus what the update wrote (it replaces files too), and the client it installed:
    /// an install from before decision 0177 named the ARM64 one.
    func testAnUpdateJobIsShownApartFromALanguageChange() {
        let update = BattleNet.updateJob(.wow, bytes: 300_000_000)
        XCTAssertEqual(update.kind, .update)
        XCTAssertEqual(update.key, BattleNet.key(.wow))
        XCTAssertEqual(update.bytes, 300_000_000)
        XCTAssertFalse(BattleNet.isLanguageChange(update))
        XCTAssertNil(BattleNet.jobVerb(update), "Downloads' own Updating")
        XCTAssertEqual(BattleNet.jobVerb(BattleNet.languageJob(.wow, region: .eu, locale: "deDE")), "Changing language")

        var before = BattleNet.receipt(.wow, folder: "World of Warcraft", version: "12.0.1.1", client: "_retail_/Wow.exe",
                                       files: 12, bytes: 1000, at: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(before.executable, #"_retail_\Wow.exe"#)
        before.executable = #"_retail_\Wow-ARM64.exe"#
        let after = BattleNet.receipt(before, measured: (files: 10, bytes: 900), version: "12.0.1.2", client: "_retail_/Wow.exe")
        XCTAssertEqual(after.version, "12.0.1.2")
        XCTAssertEqual(after.files, 10)
        XCTAssertEqual(after.bytes, 900)
        XCTAssertEqual(after.executable, #"_retail_\Wow.exe"#)
        XCTAssertEqual(BattleNet.receipt(after, measured: (files: 10, bytes: 900)).executable, after.executable,
                       "a language change keeps the client")
    }

    /// PLA-521: a Play waiting for its product's update goes on only after that update finished
    /// well; one that failed, was paused or was cancelled drops it, and a language change of the
    /// product never starts it.
    func testAPlayWaitsForItsUpdateOnlyUntilTheUpdateStops() {
        var plays = BattleNet.PlaysAfterUpdate()
        let update = BattleNet.updateJob(.wow, bytes: 1)
        plays.queued(.wow, thenPlay: "bnet-wow")
        XCTAssertNil(plays.finished(BattleNet.languageJob(.wow, region: .eu, locale: "deDE")), "a language change starts no Play")
        XCTAssertNil(plays.finished(update), "the language change dropped it")

        plays.queued(.wow, thenPlay: "bnet-wow")
        plays.stopped(update.key)
        XCTAssertNil(plays.finished(update), "a failed or cancelled update drops its Play")

        plays.queued(.wow, thenPlay: "bnet-wow")
        plays.queued(.wowClassic, thenPlay: "bnet-wow_classic")
        XCTAssertEqual(plays.finished(update), "bnet-wow")
        XCTAssertNil(plays.finished(update), "once")
        XCTAssertEqual(plays.finished(BattleNet.updateJob(.wowClassic)), "bnet-wow_classic")
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
        XCTAssertEqual(BattleNet.reason(BattleNetError.outdated(installed: "12.0.1.1", current: "12.0.1.2")),
                       "The game is on 12.0.1.1 and its region on 12.0.1.2: update it first, then try again.")
        XCTAssertNil(BattleNet.reason(ClientError.insufficientSpace(needed: 1, available: 0)), "not Blizzard's: the store-neutral wording")
    }
}
