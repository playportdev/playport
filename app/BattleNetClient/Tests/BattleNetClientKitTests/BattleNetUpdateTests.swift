// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import BattleNetClientKit

/// An installed product updated to the region's current build (PLA-521): the version endpoint
/// says whether there is one, and the update fetches only what the store and product folder do
/// not hold already, into the install, which is never installed again.
extension BattleNetInstallTests {
    func testAnUpdateBetweenTwoBuildsFetchesOnlyWhatChanged() async throws {
        let cdn = FakeCDN()
        let config = try fixture("wow_classic_era-productconfig.json")
        _ = FakeProduct.make(on: cdn, productConfig: config)
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow"), work = dir.appendingPathComponent(".wow.update")
        let i = installer(client(cdn))

        // The installed build is the current one: nothing to do.
        let same = try await i.checkUpdate(.wowClassicEra, root: root)
        XCTAssertEqual(same.installed, "1.0.0.1")
        XCTAssertEqual(same.current, "1.0.0.1")
        XCTAssertFalse(same.isNewer)

        // Blizzard ships build 2.
        let p2 = FakeProduct.make(on: cdn, productConfig: config, build: 2)
        let before = try snapshot(root)
        let check = try await i.checkUpdate(.wowClassicEra, root: root)
        XCTAssertEqual(check.installed, "1.0.0.1")
        XCTAssertEqual(check.current, "1.0.0.2")
        XCTAssertTrue(check.isNewer)

        let prepared = try await i.prepareUpdate(.wowClassicEra, root: root, work: work)
        // The changed and new objects of the install's selection (enUS, ARM64, every region):
        // 9 and 29 changed (19 is deDE's, 39 the x64 client's), 40, 41 and 42 new (43 is
        // deDE's), and build 2's three manifests; the store's other objects are not fetched.
        let fetched = Set(prepared.plan.locations.map(\.key))
        XCTAssertEqual(fetched.count, 5 + 3)
        XCTAssertTrue(fetched.isSuperset(of: [9, 29, 40, 41, 42].map { PackedKey(p2.objects[$0].keys.ekey) }))
        for unchanged in [0, 1, 2, 10, 20, 34] { XCTAssertFalse(fetched.contains(PackedKey(p2.objects[unchanged].keys.ekey)), "\(unchanged)") }
        // Only the changed product folder file.
        XCTAssertEqual(prepared.plan.files.map(\.path), ["_classic_era_/Utils/a-arm64.dll"])
        XCTAssertEqual(prepared.plan.dataFiles, [1])

        _ = try await i.update(prepared, root: root, work: work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        // Not a reinstall: the store's data file and the unchanged files are as they were.
        let after = try snapshot(root)
        for path in ["/Data/data/data.000", "/_classic_era_/WowClassic-arm64.exe", "/_classic_era_/Utils/b-arm64.dll"] {
            XCTAssertNotNil(before[path], path)
            XCTAssertEqual(after[path], before[path], path)
        }
        XCTAssertNotEqual(after["/_classic_era_/Utils/a-arm64.dll"], before["/_classic_era_/Utils/a-arm64.dll"])
        XCTAssertNotNil(after["/Data/data/data.001"])
        XCTAssertEqual(Set(after.keys.filter { $0.hasSuffix(".idx") }),
                       Set((0..<16).map { "/Data/data/" + CASC.journalName(bucket: $0, generation: 2) }))

        // `.build.info` names build 2 and keeps the install's region and tags.
        let read = try BuildInfo.read([UInt8](try Data(contentsOf: root.appendingPathComponent(".build.info"))), product: "wow_classic_era")
        XCTAssertEqual(read.buildKey, p2.buildConfig)
        XCTAssertEqual(read.cdnKey, p2.cdnConfig)
        XCTAssertEqual(read.version, "1.0.0.2")
        XCTAssertEqual(read.region, .us)
        XCTAssertEqual(read.tags, "Windows arm64 US? enUS speech?:Windows arm64 US? enUS text?")
        // Build 2's configs and indexes are in the install, as a fresh install keeps them.
        XCTAssertNotNil(after["/Data/config/\(p2.buildConfig.cdnPath)"])
        XCTAssertNotNil(after["/Data/config/\(p2.cdnConfig.cdnPath)"])
        for key in p2.archives + [p2.archiveGroup] { XCTAssertNotNil(after["/Data/indices/\(key.hex).index"], key.hex) }

        // The updated install holds everything a fresh install of build 2 would.
        let fresh = try await installer(client(cdn)).prepare(.wowClassicEra, .us, options: BattleNetInstallOptions(locale: "enUS"), work: try temp())
        let v = try await BattleNetInstaller.verify(root, plan: fresh.plan)
        XCTAssertTrue(v.isIntact, "\(v.damaged) \(v.missing)")

        // Up to date now: nothing more to fetch.
        let again = try await i.checkUpdate(.wowClassicEra, root: root)
        XCTAssertFalse(again.isNewer)
        let nothing = try await i.prepareUpdate(.wowClassicEra, root: root, work: work)
        XCTAssertEqual(nothing.plan.objects, 0)
        XCTAssertEqual(nothing.plan.files, [])
    }

    /// The space an update needs is its own plan's, not the install's.
    func testAnUpdatesSizeIsWhatItAdds() async throws {
        let cdn = FakeCDN()
        let config = try fixture("wow_classic_era-productconfig.json")
        _ = FakeProduct.make(on: cdn, productConfig: config)
        let dir = try temp()
        let (installed, _) = try await install(cdn, in: dir)
        _ = FakeProduct.make(on: cdn, productConfig: config, build: 2)
        let prepared = try await installer(client(cdn)).prepareUpdate(.wowClassicEra, root: dir.appendingPathComponent("wow"),
                                                                      work: dir.appendingPathComponent(".wow.update"))
        XCTAssertGreaterThan(prepared.plan.content.totalBytes, 0)
        XCTAssertLessThan(prepared.plan.content.totalBytes, installed.plan.content.totalBytes / 2)
    }
}
