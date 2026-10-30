// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

extension XboxTestServices {
    func serve(_ location: XboxPackageLocation) { self.location = location }
}

/// An installed MSIXVC copy is updated from a synthetic v1/v2 pair of the test package
/// served over HTTP ranges: what is found, what is fetched, what lands.
final class XboxUpdateTests: XCTestCase, @unchecked Sendable {
    let product = "9TESTGAME001"
    let page = 4096
    var v1: XboxTestPackage!
    var cdn: XboxTestCDN!
    var services: XboxTestServices!
    var root: URL!

    override func setUpWithError() throws {
        v1 = XboxTestPackage.standard()
        cdn = try XboxTestCDN(v1.bytes)
        services = XboxTestServices(cdn, size: v1.bytes.count)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-update-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        cdn.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func installer(_ log: Logger = .silent) -> XboxInstaller {
        XboxInstaller(layout: .root(root), services: services, log: log, trust: XboxTestPackage.trust) { location in
            XboxCDNPackage(location, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
    }
    func options(cancelAfter: Int? = nil) -> InstallEngine.Options {
        var o = InstallEngine.Options()
        o.concurrency = 4
        o.cancelAfterChunks = cancelAfter
        o.progressInterval = 0
        return o
    }
    var dir: URL { root.appendingPathComponent("Games/Test Game") }

    func installV1() async throws {
        _ = try await installer().install(product: product, contentID: XboxTestPackage.contentID.uuidString, title: "Test Game", options: options())
    }
    /// The CDN and GetBasePackage now serve `package` as version `version`.
    func publish(_ package: XboxTestPackage, version: String) async {
        cdn.lock.withLock { cdn.body = package.bytes }
        await services.serve(XboxPackageLocation(contentID: XboxTestPackage.contentID.uuidString.lowercased(), version: version,
                                                 fileName: "Playport.TestGame_\(version)_x64__test.msixvc", size: UInt64(package.bytes.count),
                                                 urls: [cdn.url]))
        cdn.reset()
    }
    func update(_ i: XboxInstaller? = nil, cancelAfter: Int? = nil) async throws -> XboxInstaller.UpdateResult {
        try await (i ?? installer()).update(product: product, title: "Test Game", options: options(cancelAfter: cancelAfter))
    }
    /// Package pages the CDN served past the metadata prefix (file data).
    func dataPagesServed(_ package: XboxTestPackage) -> Set<Int> {
        var out = Set<Int>()
        for r in cdn.ranges where r.upperBound >= package.prefixBytes {
            for p in (max(r.lowerBound, package.prefixBytes) / page)...(r.upperBound / page) { out.insert(p) }
        }
        return out
    }
    func pageOf(_ package: XboxTestPackage, _ path: String, _ n: Int) -> Int { package.offsets[path]! / page + n }
    func assertInstalled(_ package: XboxTestPackage, file: StaticString = #filePath, line: UInt = #line) throws {
        for f in package.files {
            let got = Array(try Data(contentsOf: dir.appendingPathComponent(f.path)))
            if f.keep {
                let at = package.offsets[f.path]!, pages = (f.data.count + page - 1) / page
                XCTAssertEqual(got, Array(package.bytes[at..<(at + pages * page)]), "\(f.path) is the new package's encrypted pages", file: file, line: line)
            } else {
                XCTAssertEqual(got, f.data, f.path, file: file, line: line)
            }
        }
        XCTAssertEqual(try installer().verify(product).bad, [], file: file, line: line)
    }
    func inode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(path).path)[.systemFileNumber] as! NSNumber).intValue
    }

    /// v2 of the standard package: two pages of the big decrypted file, one page of the
    /// kept-encrypted .exe and MicrosoftGame.Config's version change; sizes stay, so
    /// every file keeps its place.
    static func samePlaces() -> XboxTestPackage {
        var level = XboxTestPackage.content(2, 1_300_000)
        for p in [100, 300] { for i in 0..<64 { level[p * 4096 + i * 7] ^= 0xA5 } }
        var exe = XboxTestPackage.content(1, 3 * 4096 + 77)
        exe[4096 + 5] ^= 1
        return XboxTestPackage.build([
            XboxTestPackage.File(path: "Game.exe", data: exe, keep: true),
            XboxTestPackage.File(path: "Game_Data/level0", data: level),
            XboxTestPackage.File(path: "Game_Data/Managed/Assembly.dll", data: XboxTestPackage.content(3, 9000)),
            XboxTestPackage.File(path: "Game_Data/empty.txt", data: []),
            XboxTestPackage.File(path: "Tools/Crash.exe", data: XboxTestPackage.content(4, 5000), keep: true),
            XboxTestPackage.File(path: "Logo.png", data: XboxTestPackage.content(5, 6000), encrypted: false),
            XboxTestPackage.File(path: "MicrosoftGame.Config", data: XboxTestPackage.config(version: "1.2.4.0"), encrypted: false),
        ], version: [1, 2, 4, 0])
    }

    // MARK: detection

    func testAPackageVersionIsFourSixteenBitNumbersComparedInTurn() {
        XCTAssertEqual(XboxPackageVersion("1.5.12620.0")?.parts, [1, 5, 12620, 0])
        for bad in ["1.2.3", "1.2.3.65536", "1.2.3.", "1.2.3. 4", "1.2.3.-1", "1.2.3.4.5", "1.5.12620.0.00000000-0000-4000-8000-000000000418"] {
            XCTAssertNil(XboxPackageVersion(bad), bad)
        }
        XCTAssertLessThan(XboxPackageVersion("1.9.0.0")!, XboxPackageVersion("1.10.0.0")!)
        XCTAssertLessThan(XboxPackageVersion("1.2.3.4")!, XboxPackageVersion("1.2.4.0")!)
        XCTAssertEqual(XboxPackageVersion("1.2.3.4"), XboxPackageVersion("1.2.3.4"))
    }

    /// The record's version against GetBasePackage's for the record's content ID.
    func testAnUpdateIsOfferedOnlyWhenTheStoresPackageIsNewer() async throws {
        try await installV1()
        let i = installer()
        let installed = try await i.updateCheck(product)
        XCTAssertEqual(installed, .current(latest: "1.2.3.0"))
        await publish(Self.samePlaces(), version: "1.2.4.0")
        let newer = try await i.updateCheck(product)
        XCTAssertEqual(newer, .available(latest: "1.2.4.0"))
        await publish(v1, version: "1.2.2.9")
        let older = try await i.updateCheck(product)
        XCTAssertEqual(older, .current(latest: "1.2.2.9"))
        XCTAssertEqual(cdn.requestCount, 0, "a check reads no package bytes")
        do { _ = try await i.updateCheck("9OTHERGAME01"); XCTFail("no record") } catch ClientError.notFound {}
        await publish(v1, version: "")
        do { _ = try await i.updateCheck(product); XCTFail("no version") } catch ClientError.protocolChanged {}
    }

    /// The bridge's checker: Checked only for a verified answer, against the version the runtime sends.
    func testTheBridgesUpdateQueriesAreAnsweredFromGetBasePackage() async throws {
        try await installV1()
        await publish(Self.samePlaces(), version: "1.2.4.0")
        let checker = XboxUpdateChecker(installer: installer())
        let available = await checker.check(productID: product, installedVersion: "1.2.3.0")
        XCTAssertEqual(available, .available(latest: "1.2.4.0"))
        let current = await checker.check(productID: product, installedVersion: "1.2.4.0")
        XCTAssertEqual(current, .current(latest: "1.2.4.0"))
        let other = await checker.check(productID: "9OTHERGAME01", installedVersion: "1.2.3.0")
        XCTAssertEqual(other, .unknown, "no installed copy, no content ID")
        let malformed = await checker.check(productID: product, installedVersion: "1.2")
        XCTAssertEqual(malformed, .unknown)

        // Through the bridge: the runtime's request, the reply it accepts only when current.
        let copy = XboxBridgeCopy(productID: product, relatedProductIDs: [], msaAppID: nil)
        let bridge = XboxBridgeService(copy: copy, account: XboxBridgeFakeAccount(), updates: checker, log: .silent)
        let request = XboxBridgeFrame(type: 9, body: Array("<Request><ProductId>\(product)</ProductId><InstalledVersion>1.2.4.0</InstalledVersion></Request>".utf8))
        let reply = try XboxXML.parse((await bridge.handle(request))!.body)
        XCTAssertEqual(reply.value("HResult"), "0")
        XCTAssertEqual(reply.value("Checked"), "true")
        XCTAssertEqual(reply.value("LatestVersion"), "1.2.4.0")

        await services.fail(ClientError.transport("offline"))
        let failed = await checker.check(productID: product, installedVersion: "1.2.3.0")
        XCTAssertEqual(failed, .unknown, "Microsoft unreachable: not verified")
        let failedReply = try XboxXML.parse((await bridge.handle(request))!.body)
        XCTAssertEqual(failedReply.value("Checked"), "false")
    }

    // MARK: MSIXVC updates

    /// Only the changed pages come from the CDN; every other page of a changed file is
    /// copied from the installed one; unchanged files are left in place.
    func testAnMSIXVCUpdateFetchesOnlyTheChangedPages() async throws {
        try await installV1()
        let assembly = try inode("Game_Data/Managed/Assembly.dll"), crash = try inode("Tools/Crash.exe")
        let v2 = Self.samePlaces()
        await publish(v2, version: "1.2.4.0")
        let lines = XboxLines()
        let r = try await update(installer(lines.logger))

        try assertInstalled(v2)
        XCTAssertEqual(dataPagesServed(v2), [pageOf(v2, "Game_Data/level0", 100), pageOf(v2, "Game_Data/level0", 300), pageOf(v2, "Game.exe", 1)])
        XCTAssertEqual(r.filesChanged, 3, "level0, Game.exe and MicrosoftGame.Config")
        XCTAssertEqual(r.filesRemoved, 0)
        XCTAssertFalse(r.reinstalled)
        XCTAssertEqual(r.reusedBytes, UInt64(1_300_000 - 2 * page + 3 * page), "level0 less its two pages, and Game.exe's pages 0, 2 and 3")
        XCTAssertEqual(try inode("Game_Data/Managed/Assembly.dll"), assembly, "an unchanged file is not rewritten")
        XCTAssertEqual(try inode("Tools/Crash.exe"), crash)
        let rec = r.installed
        XCTAssertEqual(rec.version, "1.2.4.0")
        XCTAssertEqual(rec.packageName, "Playport.TestGame_1.2.4.0_x64__test")
        XCTAssertEqual(rec.installDir, "Test Game")
        XCTAssertEqual(rec.files.map(\.path).sorted(), v2.files.map(\.path).sorted())
        for e in rec.encrypted { XCTAssertEqual(e.units, v2.units[e.path], e.path) }
        XCTAssertEqual(installer().loadRecord(product), rec)
        XCTAssertFalse(installer().hasStage(product))
        XCTAssertTrue(lines.text.contains("4 unchanged"), lines.text)
        let current = try await installer().updateCheck(product)
        XCTAssertEqual(current, .current(latest: "1.2.4.0"))
    }

    /// Files added and removed, one grown: every file moves in the package and the
    /// encrypted region's data units with it, yet a decrypted file's pages still match
    /// (encrypted again with their new units); a kept-encrypted file's don't.
    func testAnUpdateThatMovesEveryFileStillReusesDecryptedPages() async throws {
        try await installV1()
        let v2 = XboxTestPackage.build([
            XboxTestPackage.File(path: "Game.exe", data: XboxTestPackage.content(1, 3 * page + 77), keep: true),
            XboxTestPackage.File(path: "Game_Data/level0", data: XboxTestPackage.content(2, 1_300_000)),
            XboxTestPackage.File(path: "Game_Data/Managed/Assembly.dll", data: XboxTestPackage.content(3, 9000) + XboxTestPackage.content(30, 5000)),
            XboxTestPackage.File(path: "Game_Data/empty.txt", data: []),
            XboxTestPackage.File(path: "Game_Data/new.bin", data: XboxTestPackage.content(9, 7000)),
            XboxTestPackage.File(path: "Logo.png", data: XboxTestPackage.content(5, 6000), encrypted: false),
            XboxTestPackage.File(path: "MicrosoftGame.Config", data: XboxTestPackage.config(version: "1.3.0.0"), encrypted: false),
        ], version: [1, 3, 0, 0])
        XCTAssertNotEqual(v2.offsets["Game_Data/level0"], v1.offsets["Game_Data/level0"])
        await publish(v2, version: "1.3.0.0")
        let r = try await update()

        try assertInstalled(v2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tools/Crash.exe").path), "removed from the package")
        XCTAssertEqual(r.filesRemoved, 1)
        let served = dataPagesServed(v2)
        let level0 = Set((0..<318).map { pageOf(v2, "Game_Data/level0", $0) })
        XCTAssertTrue(served.isDisjoint(with: level0), "level0 comes from the installed copy")
        XCTAssertTrue(served.isSuperset(of: (0..<4).map { pageOf(v2, "Game.exe", $0) }), "Game.exe's pages are encrypted with new units")
        XCTAssertTrue(served.isSuperset(of: (0..<2).map { pageOf(v2, "Game_Data/new.bin", $0) }))
        XCTAssertFalse(served.contains(pageOf(v2, "Game_Data/Managed/Assembly.dll", 0)), "the grown file's first pages are reused")
        XCTAssertTrue(served.contains(pageOf(v2, "Game_Data/Managed/Assembly.dll", 2)), "its old last page was partial")
        XCTAssertEqual(r.installed.files.map(\.path).sorted(), v2.files.map(\.path).sorted())
        XCTAssertEqual(r.installed.encrypted.map(\.path), ["Game.exe"])
        XCTAssertEqual(r.installed.encrypted.first?.units, v2.units["Game.exe"])
    }

    /// Stopped part-way, the copy is still v1 and plays as v1; asked again, the update
    /// finishes from its journal.
    func testAnInterruptedUpdateLeavesTheCopyAsItWasAndResumes() async throws {
        try await installV1()
        let v2 = Self.samePlaces()
        await publish(v2, version: "1.2.4.0")
        do { _ = try await update(cancelAfter: 1); XCTFail("stopped early") } catch ClientError.cancelled {}
        XCTAssertEqual(installer().loadRecord(product)?.version, "1.2.3.0")
        XCTAssertEqual(try installer().verify(product).bad, [], "the installed files are untouched")
        XCTAssertTrue(installer().hasStage(product))
        let r = try await update()
        try assertInstalled(v2)
        XCTAssertEqual(r.installed.version, "1.2.4.0")
        XCTAssertFalse(installer().hasStage(product))
    }

    /// An installed page that no longer matches (damaged on disk) is fetched, not copied.
    func testADamagedInstalledPageIsFetchedNotCopied() async throws {
        try await installV1()
        let url = dir.appendingPathComponent("Game_Data/Managed/Assembly.dll")
        var bytes = Array(try Data(contentsOf: url))
        bytes[5000] ^= 0x10
        try Data(bytes).write(to: url)
        let v2 = Self.samePlaces()
        await publish(v2, version: "1.2.4.0")
        let r = try await update()
        try assertInstalled(v2)
        XCTAssertTrue(dataPagesServed(v2).contains(pageOf(v2, "Game_Data/Managed/Assembly.dll", 1)))
        XCTAssertFalse(dataPagesServed(v2).contains(pageOf(v2, "Game_Data/Managed/Assembly.dll", 0)))
        XCTAssertEqual(r.filesChanged, 4)
    }

    func testNothingIsFetchedWhenTheCopyIsCurrent() async throws {
        try await installV1()
        cdn.reset()
        let r = try await update()
        XCTAssertEqual(r.filesChanged, 0)
        XCTAssertEqual(r.downloadedBytes, 0)
        XCTAssertEqual(cdn.requestCount, 0)
        XCTAssertEqual(r.installed, installer().loadRecord(product))
    }

    /// With the copy's folder gone there is nothing to compare: installed again whole.
    func testWithItsFolderGoneTheCopyIsInstalledAgainWhole() async throws {
        try await installV1()
        try FileManager.default.removeItem(at: dir)
        let v2 = Self.samePlaces()
        await publish(v2, version: "1.2.4.0")
        let r = try await update()
        XCTAssertTrue(r.reinstalled)
        XCTAssertEqual(r.installed.version, "1.2.4.0")
        try assertInstalled(v2)
    }
}
