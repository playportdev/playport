// SPDX-License-Identifier: GPL-3.0-or-later
import BattleNetClientKit
import SteamClientKit
import XCTest
@testable import PlayportKit

/// Play for a Battle.net copy (PLA-514, decision 0169): the ban-risk notice once per product,
/// remembered with the copy, then the product's ARM64 client as a native ARM64 child.
final class BattleNetPlayTests: XCTestCase {
    private var root: URL!
    private var layout: InstallLayout { InstallLayout.root(root.appendingPathComponent("container")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bnet-play-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A product installed as the store installs it: its folder with the ARM64 client, its receipt.
    private func install(_ p: BattleNetProduct, folder: String) throws -> StoreReceipt {
        let exe = layout.gamesRoot.appendingPathComponent("\(folder)/_retail_/Wow-ARM64.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        return BattleNet.receipt(p, folder: folder, version: "12.0.0.1", productFolder: "_retail_", arm64Executable: "Wow-ARM64.exe",
                                 files: 1, bytes: 2, at: Date())
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

    /// A copy as adoption leaves it: the store's receipt, the client's PE machine.
    private func copy(_ p: BattleNetProduct, machine: UInt16? = 0xAA64, exe: String = #"_retail_\Wow-ARM64.exe"#,
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

    func testPlayShowsTheNoticeUntilItIsAcceptedThenStartsTheARM64ClientOnDirect3D12OverVulkan() {
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wow))), .notice(.wow), "first Play: the notice, nothing starts")
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wowClassicEra))), .notice(.wowClassicEra))
        let launch = BattleNetPlay.decide(.init(copy: copy(.wow, accepted: Date())))
        XCTAssertEqual(launch, .launch(.init(graphics: .vulkan, arguments: ["-d3d12"])),
                       "accepted: the client as a native ARM64 child, Direct3D 12 through vkd3d-proton on Vulkan")
    }

    func testAClientThatIsNotTheARM64OneIsNotStarted() {
        // The player's pick of the x86-64 client, or a copy whose client is gone or unread.
        for t in [copy(.wow, machine: 0x8664, exe: #"_retail_\Wow.exe"#, accepted: Date()), copy(.wow, machine: nil, accepted: Date())] {
            guard case let .refuse(why) = BattleNetPlay.decide(.init(copy: t)) else { return XCTFail("\(t.executable ?? "none") started") }
            XCTAssertTrue(why.contains("ARM64"), why)
        }
        // The notice still comes first.
        XCTAssertEqual(BattleNetPlay.decide(.init(copy: copy(.wow, machine: 0x8664))), .notice(.wow))
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
                      "stores no Battle.net email, password or session", "changes nothing in the game"] {
            XCTAssertTrue(n.text.contains(words), words)
        }
        XCTAssertTrue(BattleNetPlay.notice(.wowClassic).text.contains("World of Warcraft Classic"))
    }
}
