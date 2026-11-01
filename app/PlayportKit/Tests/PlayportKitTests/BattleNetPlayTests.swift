// SPDX-License-Identifier: GPL-3.0-or-later
import BattleNetClientKit
import SteamClientKit
import XCTest
@testable import PlayportKit

/// Play for a Battle.net copy (PLA-514, decisions 0175 and 0177): the ban-risk notice once per
/// product, remembered with the copy, then the update check, then the product's x64 client
/// through FEX.
final class BattleNetPlayTests: XCTestCase {
    private var root: URL!
    private var layout: InstallLayout { InstallLayout.root(root.appendingPathComponent("container")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bnet-play-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A product installed as the store installs it: its folder with the x64 client, its receipt.
    private func install(_ p: BattleNetProduct, folder: String) throws -> StoreReceipt {
        let exe = layout.gamesRoot.appendingPathComponent("\(folder)/_retail_/Wow.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        return BattleNet.receipt(p, folder: folder, version: "12.0.0.1", client: "_retail_/Wow.exe", files: 1, bytes: 2, at: Date())
    }

    private func scan(_ receipts: [StoreReceipt], previous: Catalog) -> Catalog {
        Adoption.scan(games: layout.gamesRoot, cohort: Cohort(titles: []), receipts: [], storeReceipts: receipts, previous: previous)
    }

    func testTheNoticeIsAcknowledgedPerProductAndRememberedWithTheCopy() throws {
        let wow = try install(.wow, folder: "World of Warcraft")
        let era = try install(.wowClassicEra, folder: "World of Warcraft Classic Era")
        var c = scan([wow, era], previous: Catalog())
        XCTAssertEqual(c.titles.map(\.riskNoticeAccepted), [nil, nil], "no copy has seen the notice")

        let accepted = Date(timeIntervalSince1970: 1_800_000_000)
        c.update("bnet-wow") { $0.riskNoticeAccepted = accepted }
        // Saved and read back (catalog.json), then a library scan.
        let store = CatalogStore(url: root.appendingPathComponent("catalog.json"))
        try store.save(c)
        let saved = store.load()
        c = scan([wow, era], previous: saved)
        XCTAssertEqual(c.title(id: "bnet-wow")?.riskNoticeAccepted, accepted, "kept across saves and scans")
        XCTAssertNil(c.title(id: "bnet-wow_classic_era")?.riskNoticeAccepted, "one product's acceptance is not another's")

        // Removed, then installed again: a new copy asks again.
        try FileManager.default.removeItem(at: layout.gamesRoot.appendingPathComponent("World of Warcraft"))
        c = scan([era], previous: c)
        XCTAssertNil(c.title(id: "bnet-wow"))
        let again = try install(.wow, folder: "World of Warcraft")
        c = scan([again, era], previous: c)
        XCTAssertNil(c.title(id: "bnet-wow")?.riskNoticeAccepted)
    }

    /// An acceptance given while a library scan runs (LibraryModel.adopted): the live catalogue's
    /// acceptance wins over the scan's copy of the catalogue from when it started.
    func testAnAcceptanceGivenDuringAScanSurvivesIt() throws {
        let wow = try install(.wow, folder: "World of Warcraft")
        let started = scan([wow], previous: Catalog())
        var live = started
        let accepted = Date(timeIntervalSince1970: 1_800_000_000)
        live.update("bnet-wow") { $0.riskNoticeAccepted = accepted }
        let scanned = scan([wow], previous: started)
        XCTAssertNil(scanned.title(id: "bnet-wow")?.riskNoticeAccepted, "the scan's snapshot predates the acceptance")
        XCTAssertEqual(scanned.keepingEdits(of: live).title(id: "bnet-wow")?.riskNoticeAccepted, accepted)
    }

    /// A copy as adoption leaves it: the store's receipt, the client's PE machine.
    private func copy(_ p: BattleNetProduct, machine: UInt16? = 0x8664, exe: String = #"_retail_\Wow.exe"#,
                      accepted: Date? = nil) -> InstalledTitle {
        var t = InstalledTitle(id: BattleNet.key(p).titleID, appID: nil, name: p.name, developer: nil, installDir: p.name,
                               executable: exe, buildID: nil, depots: [], sizeBytes: 1, source: .installed, checksums: nil,
                               note: nil, addedAt: Date(), lastPlayed: nil, lastVerification: nil)
        t.store = .battlenet
        t.storeID = p.code
        t.executableMachine = machine
        t.riskNoticeAccepted = accepted
        return t
    }

    func testPlayShowsTheNoticeUntilItIsAcceptedThenStartsTheX64ClientOnDirect3D12OverVulkan() {
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wow))), .notice(.wow), "first Play: the notice, nothing starts")
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wowClassicEra))), .notice(.wowClassicEra))
        let launch = BattleNetPlay.decide(.init(copy: copy(.wow, accepted: Date()), update: .current))
        XCTAssertEqual(launch, .launch(.init(graphics: .vulkan, arguments: ["-d3d12"])),
                       "accepted: the x64 client through FEX, Direct3D 12 through vkd3d-proton on Vulkan")
        // The launch screen stays up to the client's first window (about 250 s on the phone),
        // not the 30 s after which another Play uncovers its black screen.
        guard case let .launch(l)? = launch else { return XCTFail("no launch") }
        XCTAssertEqual(l.uncoverWithoutFrame, 600)
        XCTAssertGreaterThan(l.uncoverWithoutFrame, LaunchProgress.uncoverWithoutFrame)
    }

    // MARK: the update check (PLA-521)

    func testEveryPlayChecksForAnUpdateAfterTheNotice() {
        // The notice still comes first, whatever the check would say.
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wow))), .notice(.wow))
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wow), update: .available(version: "12.0.1.2", bytes: 1))), .notice(.wow))
        // Accepted, not asked yet: the version endpoint is asked before anything starts.
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wow, accepted: Date()))), .checkUpdate(.wow))
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wowClassicEra, accepted: Date()))), .checkUpdate(.wowClassicEra))
        // A copy with only the ARM64 client is checked too: the update is what brings the x64 one.
        let arm64 = copy(.wow, machine: 0xAA64, exe: #"_retail_\Wow-ARM64.exe"#, accepted: Date())
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: arm64)), .checkUpdate(.wow))
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: arm64, update: .available(version: "12.0.0.1", bytes: 1))),
                       .update(.wow, version: "12.0.0.1"))
    }

    func testAnAvailableUpdateThatFitsIsDownloadedThenTheGameStarts() {
        let t = copy(.wow, accepted: Date())
        // 1 GB to write: with the engine's 5 % and the CDN indexes' 256 MB, 1.306 GB is needed.
        let update = BattleNetPlay.Update.available(version: "12.0.1.2", bytes: 1_000_000_000)
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: t, update: update, freeBytes: 1_400_000_000)), .update(.wow, version: "12.0.1.2"))
        // Free space unknown: the update goes on, and Downloads stops it if the phone fills.
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: t, update: update)), .update(.wow, version: "12.0.1.2"))
        // Once it is done, the game starts, with nothing to report.
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: t, update: .updated, freeBytes: 0)),
                       .launch(.init(graphics: .vulkan, arguments: ["-d3d12"])))
    }

    func testAnUpdateThatDoesNotFitIsRefusedBeforeItStarts() {
        let t = copy(.wow, accepted: Date())
        let step = BattleNetPlay.decide(.init(copy: t, update: .available(version: "12.0.1.2", bytes: 1_000_000_000), freeBytes: 1_200_000_000))
        guard case let .refuse(why) = step else { return XCTFail("\(String(describing: step))") }
        XCTAssertTrue(why.contains("Not enough free space"), why)
        XCTAssertTrue(why.contains("12.0.1.2"), why)
    }

    func testAnUnreachableVersionCheckIsReportedAndTheGameStarts() {
        let t = copy(.wow, accepted: Date())
        let why = "Blizzard's servers can't be reached. Check the connection, then try again."
        guard case let .launch(launch)? = BattleNetPlay.decide(.init(copy: t, update: .unreachable(why))) else {
            return XCTFail("the game did not start")
        }
        XCTAssertEqual(launch.graphics, .vulkan)
        XCTAssertEqual(launch.arguments, ["-d3d12"])
        let report = launch.report ?? ""
        XCTAssertTrue(report.hasPrefix("Couldn't check for an update"), report)
        XCTAssertTrue(report.contains(why), report)
        XCTAssertTrue(report.contains("starts the installed version"), report)
    }

    func testAClientThatIsNotTheX64OneIsNotStarted() {
        // An install from before decision 0177 (the ARM64 client), or a copy whose client is gone or unread.
        let others = [copy(.wow, machine: 0xAA64, exe: #"_retail_\Wow-ARM64.exe"#, accepted: Date()), copy(.wow, machine: nil, accepted: Date())]
        for t in others {
            for update in [BattleNetPlay.Update.current, .updated] {
                guard case let .refuse(why) = BattleNetPlay.decide(.init(copy: t, update: update)) else {
                    return XCTFail("\(t.executable ?? "none") started after \(update)")
                }
                XCTAssertTrue(why.contains("x64 client"), why)
                XCTAssertTrue(why.contains("Check for update on the game's page downloads it"), why)
            }
            guard case let .refuse(why) = BattleNetPlay.decide(.init(copy: t, update: .unreachable("No connection."))) else {
                return XCTFail("\(t.executable ?? "none") started after a failed check")
            }
            XCTAssertTrue(why.contains("x64 client"), why)
            XCTAssertTrue(why.contains("must be downloaded"), why)
            XCTAssertTrue(why.contains("servers couldn't be reached"), why)
        }
        // The notice still comes first.
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wow, machine: 0xAA64))), .notice(.wow))
    }

    func testOnlyBattleNetCopiesHaveThisPlay() {
        var other = copy(.wow)
        other.store = .epic
        other.storeID = "wow"
        XCTAssertNil(BattleNetPlay.decide(.init(copy: other)))
        other.store = .battlenet
        other.storeID = "d3"
        XCTAssertNil(BattleNetPlay.decide(.init(copy: other)), "a product not on the store's list")
    }

    func testTheNoticeSaysWhatThePlayerRisksAndWhatPlayportDoesNotKeep() {
        let n = BattleNetPlay.notice(.wow)
        XCTAssertEqual(n.title, "Before you play World of Warcraft")
        for words in ["Blizzard does not support Playport", "action against your Battle.net account",
                      "stores no Battle.net email, password or session", "changes none of the game's files",
                      "none of its code in memory", "Blizzard's x64 Windows client through an x86-64 translator (FEX)"] {
            XCTAssertTrue(n.text.contains(words), words)
        }
        XCTAssertFalse(n.text.contains("rewrites"), "the runtime no longer adapts the game's code in memory (0177)")
        XCTAssertFalse(n.text.contains("changes nothing in the game"))
        XCTAssertTrue(BattleNetPlay.notice(.wowClassic).text.contains("World of Warcraft Classic"))
    }
}
