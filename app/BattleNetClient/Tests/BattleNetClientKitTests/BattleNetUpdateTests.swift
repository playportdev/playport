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

        // The installed build is the current one, and the install has the x64 client: nothing to do.
        let same = try await i.checkUpdate(.wowClassicEra, root: root)
        XCTAssertEqual(same.installed, "1.0.0.1")
        XCTAssertEqual(same.current, "1.0.0.1")
        XCTAssertFalse(same.isNewer)
        XCTAssertFalse(same.lacksClient)
        XCTAssertFalse(same.needsUpdate)

        // Blizzard ships build 2.
        let p2 = FakeProduct.make(on: cdn, productConfig: config, build: 2)
        let before = try snapshot(root)
        let check = try await i.checkUpdate(.wowClassicEra, root: root)
        XCTAssertEqual(check.installed, "1.0.0.1")
        XCTAssertEqual(check.current, "1.0.0.2")
        XCTAssertTrue(check.isNewer)
        XCTAssertFalse(check.lacksClient)
        XCTAssertTrue(check.needsUpdate)

        let prepared = try await i.prepareUpdate(.wowClassicEra, root: root, work: work)
        // The changed and new objects of the install's selection (enUS, x64, every region):
        // 9 and 29 changed (19 is deDE's, 39 the ARM64 client's), 40, 41 and 42 new (43 is
        // deDE's), and build 2's three manifests; the store's other objects are not fetched.
        let fetched = Set(prepared.plan.locations.map(\.key))
        XCTAssertEqual(fetched.count, 5 + 3)
        XCTAssertTrue(fetched.isSuperset(of: [9, 29, 40, 41, 42].map { PackedKey(p2.objects[$0].keys.ekey) }))
        for unchanged in [0, 1, 2, 10, 20, 34] { XCTAssertFalse(fetched.contains(PackedKey(p2.objects[unchanged].keys.ekey)), "\(unchanged)") }
        // Only the changed product folder file; the client is named all the same.
        XCTAssertEqual(prepared.plan.files.map(\.path), ["_classic_era_/Utils/a.dll"])
        XCTAssertEqual(prepared.clientPath, "_classic_era_/WoWClassic.exe")
        XCTAssertEqual(prepared.plan.dataFiles, [1])

        _ = try await i.update(prepared, root: root, work: work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        // Not a reinstall: the store's data file and the unchanged files are as they were.
        let after = try snapshot(root)
        for path in ["/Data/data/data.000", "/_classic_era_/WoWClassic.exe", "/_classic_era_/Utils/b.dll"] {
            XCTAssertNotNil(before[path], path)
            XCTAssertEqual(after[path], before[path], path)
        }
        XCTAssertNotEqual(after["/_classic_era_/Utils/a.dll"], before["/_classic_era_/Utils/a.dll"])
        XCTAssertNotNil(after["/Data/data/data.001"])
        XCTAssertEqual(Set(after.keys.filter { $0.hasSuffix(".idx") }),
                       Set((0..<16).map { "/Data/data/" + CASC.journalName(bucket: $0, generation: 2) }))

        // `.build.info` names build 2 and keeps the install's region and tags.
        let read = try BuildInfo.read([UInt8](try Data(contentsOf: root.appendingPathComponent(".build.info"))), product: "wow_classic_era")
        XCTAssertEqual(read.buildKey, p2.buildConfig)
        XCTAssertEqual(read.cdnKey, p2.cdnConfig)
        XCTAssertEqual(read.version, "1.0.0.2")
        XCTAssertEqual(read.region, .us)
        XCTAssertEqual(read.tags, "Windows x86_64 US? enUS speech?:Windows x86_64 US? enUS text?")
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

    /// A new build without the x64 client Play starts is refused as a fresh install's is, even
    /// though the install's copy of the old client is still on disk.
    func testAnUpdateWithoutItsX64ClientIsRefused() async throws {
        let cdn = FakeCDN()
        let config = try fixture("wow_classic_era-productconfig.json")
        _ = FakeProduct.make(on: cdn, productConfig: config)
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let renamed = String(decoding: config, as: UTF8.self).replacingOccurrences(of: #""relative_path":"WoWClassic.exe""#,
                                                                                    with: #""relative_path":"Elsewhere.exe""#)
        _ = FakeProduct.make(on: cdn, productConfig: Array(renamed.utf8), build: 2)
        let fetched = cdn.requests.count
        await assertThrows(try await installer(client(cdn)).prepareUpdate(.wowClassicEra, root: dir.appendingPathComponent("wow"),
                                                                           work: dir.appendingPathComponent(".wow.update"))) {
            guard case let .unsupported(why) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("x64 client"), why)
        }
        XCTAssertFalse(cdn.requests.dropFirst(fetched).contains { $0.status == 206 })
    }

    /// An install from before decision 0177 holds only the ARM64 client (its `.build.info` tags
    /// name `arm64`, not `x86_64`): the update check says it lacks the x64 client at the same
    /// build, and the update fetches only the x64 client's objects and files, then retags it.
    func testAnInstallWithOnlyTheARM64ClientGetsTheX64OneByAnUpdateAtItsBuild() async throws {
        let cdn = FakeCDN()
        let config = try fixture("wow_classic_era-productconfig.json")
        // The ARM64-only install, as the store made it before 0177: the ARM64 client's machine and executable.
        let arm64Config = String(decoding: config, as: UTF8.self)
            .replacingOccurrences(of: #""tags_64bit":["x86_64"]"#, with: #""tags_64bit":["arm64"]"#)
            .replacingOccurrences(of: #""relative_path":"WoWClassic.exe""#, with: #""relative_path":"WowClassic-arm64.exe""#)
        let p = FakeProduct.make(on: cdn, productConfig: Array(arm64Config.utf8))
        let dir = try temp()
        let (old, _) = try await install(cdn, in: dir)
        XCTAssertEqual(old.clientPath, "_classic_era_/WowClassic-arm64.exe")
        let root = dir.appendingPathComponent("wow"), work = dir.appendingPathComponent(".wow.update")
        func tags() throws -> String {
            try BuildInfo.read([UInt8](try Data(contentsOf: root.appendingPathComponent(".build.info"))), product: "wow_classic_era").tags
        }
        XCTAssertEqual(try tags(), "Windows arm64 US? enUS speech?:Windows arm64 US? enUS text?")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("_classic_era_/WoWClassic.exe").path))

        // The same build, with the product config as Blizzard ships it.
        _ = FakeProduct.make(on: cdn, productConfig: config)
        let i = installer(client(cdn))
        let check = try await i.checkUpdate(.wowClassicEra, root: root)
        XCTAssertEqual(check.installed, "1.0.0.1")
        XCTAssertEqual(check.current, "1.0.0.1")
        XCTAssertFalse(check.isNewer)
        XCTAssertTrue(check.lacksClient)
        XCTAssertTrue(check.needsUpdate)

        let prepared = try await i.prepareUpdate(.wowClassicEra, root: root, work: work)
        // Only the x64 client's objects (4, 12, 20, 28 and 36): the shared ones and the build's
        // manifests are in the store already.
        XCTAssertEqual(Set(prepared.plan.locations.map(\.key)), Set([4, 12, 20, 28, 36].map { PackedKey(p.objects[$0].keys.ekey) }))
        XCTAssertEqual(prepared.plan.files.map(\.path).sorted(),
                       ["_classic_era_/Utils/a.dll", "_classic_era_/Utils/b.dll", "_classic_era_/WoWClassic.exe"])
        XCTAssertEqual(prepared.clientPath, "_classic_era_/WoWClassic.exe")
        XCTAssertEqual(prepared.plan.dataFiles, [1])

        _ = try await i.update(prepared, root: root, work: work)
        XCTAssertEqual(try tags(), "Windows x86_64 US? enUS speech?:Windows x86_64 US? enUS text?")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("_classic_era_/WoWClassic.exe").path))
        let again = try await i.checkUpdate(.wowClassicEra, root: root)
        XCTAssertFalse(again.needsUpdate)
        let fresh = try await installer(client(cdn)).prepare(.wowClassicEra, .us, options: BattleNetInstallOptions(locale: "enUS"), work: try temp())
        let v = try await BattleNetInstaller.verify(root, plan: fresh.plan)
        XCTAssertTrue(v.isIntact, "\(v.damaged) \(v.missing)")
    }

    /// A product folder file whose object the store holds already (it was damaged on disk) is
    /// decoded from its archive, not asked of the CDN as a loose object it is not.
    func testAStoredProductFileIsFetchedFromItsArchive() async throws {
        let cdn = FakeCDN()
        let config = try fixture("wow_classic_era-productconfig.json")
        _ = FakeProduct.make(on: cdn, productConfig: config, filesInStore: true)
        let dir = try temp()
        _ = try await install(cdn, in: dir)
        let root = dir.appendingPathComponent("wow"), work = dir.appendingPathComponent(".wow.update")
        let exe = root.appendingPathComponent("_classic_era_/WoWClassic.exe")
        let good = try Data(contentsOf: exe)
        try Data(repeating: 0x5a, count: good.count).write(to: exe)

        _ = FakeProduct.make(on: cdn, productConfig: config, build: 2, filesInStore: true)
        let i = installer(client(cdn))
        let prepared = try await i.prepareUpdate(.wowClassicEra, root: root, work: work)
        XCTAssertEqual(prepared.plan.files.map(\.path).sorted(), ["_classic_era_/Utils/a.dll", "_classic_era_/WoWClassic.exe"])
        let n = try XCTUnwrap(prepared.plan.files.firstIndex { $0.path.hasSuffix("WoWClassic.exe") })
        let run = try XCTUnwrap(prepared.plan.runs.first { $0.kind == .file && $0.first == Int32(n) })
        XCTAssertEqual(run.archive, 0)
        _ = try await i.update(prepared, root: root, work: work)
        XCTAssertEqual(try Data(contentsOf: exe), good)
    }
}
