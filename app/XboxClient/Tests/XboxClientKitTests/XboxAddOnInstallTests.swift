// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// An add-on installs through the same installer as its game, into the game's folder
/// (`DLC\<ProductId>`, where the runtime looks), only once the game is installed and only
/// when its package says it is this game's.
final class XboxAddOnInstallTests: XCTestCase, @unchecked Sendable {
    let base = "9TESTGAME001", addOn = "9TESTADDON01"
    var root: URL!
    var cdns: [XboxTestCDN] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-addon-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        cdns.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    /// The add-on's MicrosoftGame.config, as a GDK DLC declares it: no executables, its
    /// game's identity as main package, its game's Store ID allowed.
    static func addOnConfig(store: String = "9TESTADDON01", main: String = "Playport.TestGame", allowed: String = "9TESTGAME001") -> [UInt8] {
        Array(("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Game configVersion=\"1\">\n"
            + "  <Identity Name=\"Playport.TestAddOn\" Publisher=\"CN=Playport\" Version=\"1.0.4.0\" />\n"
            + "  <StoreId>\(store)</StoreId>\n"
            + "  <DesktopRegistration><MainPackageDependency Name=\"\(main)\" /></DesktopRegistration>\n"
            + "  <AllowedProducts><AllowedProduct>\(allowed)</AllowedProduct></AllowedProducts>\n</Game>\n").utf8)
    }
    static let appx = Array(("<?xml version=\"1.0\"?><Package><Identity Name=\"Playport.TestAddOn\" Publisher=\"CN=Playport\" Version=\"1.0.4.0\"/>"
        + "<Dependencies><MainPackageDependency Name=\"Playport.TestGame\"/></Dependencies></Package>").utf8)
    static let layout = Array("<Package><Chunk Id=\"1000\"><FileGroup DestinationPath=\"\\\" SourcePath=\"\\\" Include=\"*\"/></Chunk></Package>".utf8)

    func addOnPackage(config: [UInt8] = addOnConfig(), keep: Bool = false) -> XboxTestPackage {
        XboxTestPackage.build([
            XboxTestPackage.File(path: "MicrosoftGame.config", data: config, encrypted: false),
            XboxTestPackage.File(path: "appxmanifest.xml", data: Self.appx, encrypted: false),
            XboxTestPackage.File(path: "layout_0F1E2D3C4B5A69788796A5B4C3D2E1F0.xml", data: Self.layout, encrypted: false),
            XboxTestPackage.File(path: "Content/whip.pak", data: XboxTestPackage.content(40, 70_000), keep: keep),
        ])
    }

    /// An installer serving `package` from its own CDN on 127.0.0.1.
    func installer(_ package: XboxTestPackage) throws -> (XboxInstaller, XboxTestCDN) {
        let cdn = try XboxTestCDN(package.bytes)
        cdns.append(cdn)
        let services = XboxTestServices(cdn, size: package.bytes.count)
        let i = XboxInstaller(layout: .root(root), services: services, trust: XboxTestPackage.trust) { location in
            XboxCDNPackage(location, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
        return (i, cdn)
    }
    var options: InstallEngine.Options { var o = InstallEngine.Options(); o.concurrency = 4; o.progressInterval = 0; return o }
    var contentID: String { XboxTestPackage.contentID.uuidString }

    func installBase() async throws -> XboxInstalled {
        let (i, _) = try installer(XboxTestPackage.standard())
        return try await i.install(product: base, contentID: contentID, title: "Test Game: Edition", options: options).installed
    }

    func testAnAddOnInstallsInItsGamesFolderWhereTheRuntimeFindsIt() async throws {
        let game = try await installBase()
        let package = addOnPackage()
        let (i, cdn) = try installer(package)
        let r = try await i.installAddOn(addOn, contentID: contentID, base: base, options: options)
        XCTAssertEqual(r.installed.productID, addOn)
        XCTAssertEqual(r.installed.installDir, "DLC/\(addOn)")
        XCTAssertEqual(r.installed.version, "1.2.3.0", "the package's version, as a copy's")
        let dir = root.appendingPathComponent("Games/Test Game Edition/DLC/\(addOn)")
        for f in package.files {
            XCTAssertEqual(Array(try Data(contentsOf: dir.appendingPathComponent(f.path))), f.data, f.path)
        }
        XCTAssertLessThanOrEqual(cdn.bytesServed, package.bytes.count)
        // The record is the game's, beside the game's own; the game's files and record are untouched.
        XCTAssertEqual(i.addOnRecords(base: base), [XboxInstalledAddOn(baseProductID: base, installed: r.installed)])
        XCTAssertEqual(i.loadRecord(base), game)
        XCTAssertNil(i.loadRecord(addOn), "an add-on is no copy of its own")
        XCTAssertEqual(try i.verify(base).bad, [])
        XCTAssertEqual(try i.verifyAddOn(addOn, base: base).bad, [])
        XCTAssertFalse(i.hasStage(addOn))
        // The play's content root: the game's DLC folder as Windows sees it.
        XCTAssertEqual(i.addOnRoots(base: base), ["C:\\Games\\Test Game Edition\\DLC"])

        // A changed file is found; the add-on's own Remove takes its folder and record only.
        try Data("x".utf8).write(to: dir.appendingPathComponent("Content/whip.pak"))
        XCTAssertEqual(try i.verifyAddOn(addOn, base: base).bad, ["Content/whip.pak"])
        try i.removeAddOn(addOn, base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(i.addOnRecords(base: base), [])
        XCTAssertEqual(i.addOnRoots(base: base), [])
        XCTAssertEqual(try i.verify(base).bad, [])
    }

    /// Installing again replaces the add-on in place; forgetting the game forgets its add-ons.
    func testInstallingAgainReplacesItAndForgettingTheGameForgetsItsAddOns() async throws {
        _ = try await installBase()
        let (i, _) = try installer(addOnPackage())
        _ = try await i.installAddOn(addOn, contentID: contentID, base: base, options: options)
        let dir = root.appendingPathComponent("Games/Test Game Edition/DLC/\(addOn)")
        try Data("stale".utf8).write(to: dir.appendingPathComponent("stale.bin"))
        _ = try await i.installAddOn(addOn, contentID: contentID, base: base, options: options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stale.bin").path))
        XCTAssertEqual(try i.verifyAddOn(addOn, base: base).bad, [])

        // The game's folder gone (Remove, or a reinstall into a new folder): its add-ons are no longer there.
        let folder = root.appendingPathComponent("Games/Test Game Edition")
        let aside = root.appendingPathComponent("Games/aside")
        try FileManager.default.moveItem(at: folder, to: aside)
        XCTAssertEqual(i.addOnRecords(base: base), [])
        XCTAssertEqual(i.addOnRoots(base: base), [])
        try FileManager.default.moveItem(at: aside, to: folder)
        XCTAssertEqual(i.addOnRecords(base: base).count, 1)

        // An interrupted add-on stage goes with the game's Remove too.
        let stage = i.layout.stagingRoot.appendingPathComponent("xbox-\(addOn)_1.0.0.0")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        XCTAssertTrue(i.hasStage(addOn))
        try FileManager.default.removeItem(at: folder)
        i.forget(base, keepSaves: true, localAppData: root.appendingPathComponent("AppData"))
        XCTAssertFalse(i.hasStage(addOn))
        XCTAssertFalse(FileManager.default.fileExists(atPath: i.layout.manifestsDir.appendingPathComponent("xbox-\(base).addons").path))
        XCTAssertNil(i.loadRecord(base))
    }

    func testAnAddOnWaitsForItsGameAndNothingIsFetchedBefore() async throws {
        let (i, cdn) = try installer(addOnPackage())
        do {
            _ = try await i.installAddOn(addOn, contentID: contentID, base: base, options: options)
            XCTFail("installed without its game")
        } catch let refusal as XboxAddOnRefusal {
            XCTAssertEqual(refusal, .gameNotInstalled)
        }
        XCTAssertEqual(cdn.requestCount, 0)
        do {
            _ = try await i.installAddOn(base, contentID: contentID, base: base, options: options)
            XCTFail("a game is no add-on of itself")
        } catch is ClientError {}
    }

    /// The package must name this game as its main package and allow its Store ID, carry
    /// the add-on's own Store ID and keep nothing encrypted; otherwise nothing is placed.
    func testAPackageForAnotherGameOrKeepingFilesEncryptedIsRefusedAndNothingIsPlaced() async throws {
        _ = try await installBase()
        let cases: [(XboxTestPackage, XboxAddOnRefusal)] = [
            (addOnPackage(config: Self.addOnConfig(main: "Other.Game")), .notForThisGame),
            (addOnPackage(config: Self.addOnConfig(allowed: "9OTHERGAME01")), .notForThisGame),
            (addOnPackage(config: Self.addOnConfig(store: "9OTHERADDON1")), .notForThisGame),
            (addOnPackage(config: XboxTestPackage.config()), .notForThisGame),
            (addOnPackage(keep: true), .keptEncrypted),
        ]
        for (package, expected) in cases {
            let (i, _) = try installer(package)
            do {
                _ = try await i.installAddOn(addOn, contentID: contentID, base: base, options: options)
                XCTFail("installed \(expected)")
            } catch let refusal as XboxAddOnRefusal {
                XCTAssertEqual(refusal, expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Games/Test Game Edition/DLC/\(addOn)").path))
            XCTAssertEqual(i.addOnRecords(base: base), [])
            XCTAssertFalse(i.hasStage(addOn), "the refused stage is gone")
        }
    }

    /// Licensing's refusal of the add-on is the same refusal as a copy's, before any download.
    func testALicenceRefusalStopsTheAddOnBeforeItsPackage() async throws {
        _ = try await installBase()
        let cdn = try XboxTestCDN(addOnPackage().bytes)
        cdns.append(cdn)
        let services = XboxTestServices(cdn, size: cdn.body.count)
        await services.refuse(.refused)
        let i = XboxInstaller(layout: .root(root), services: services, trust: XboxTestPackage.trust) {
            XboxCDNPackage($0, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
        do {
            _ = try await i.installAddOn(addOn, contentID: contentID, base: base, options: options)
            XCTFail("installed unlicensed")
        } catch let refusal as XboxInstallRefusal {
            XCTAssertEqual(refusal, .licence(.refused))
        }
        XCTAssertEqual(cdn.requestCount, 0)
    }
}
