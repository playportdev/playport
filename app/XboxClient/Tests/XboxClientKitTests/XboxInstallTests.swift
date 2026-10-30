// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// An Xbox copy installs from a package served over HTTP ranges on 127.0.0.1, through
/// the CDN client, the hash tree and ContentKit's engine, into a host stand-in for the
/// phone's layout.
final class XboxInstallTests: XCTestCase, @unchecked Sendable {
    let product = "9TESTGAME001"
    var cdn: XboxTestCDN!
    var package: XboxTestPackage!
    var root: URL!

    override func setUpWithError() throws {
        package = XboxTestPackage.standard()
        cdn = try XboxTestCDN(package.bytes)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-install-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        cdn.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func installer(_ services: XboxTestServices, log: Logger = .silent) -> XboxInstaller {
        XboxInstaller(layout: .root(root), services: services, log: log) { location in
            XboxCDNPackage(location, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
    }
    func options(cancelAfter: Int? = nil) -> InstallEngine.Options {
        var o = InstallEngine.Options()
        o.concurrency = 4
        o.cancelAfterChunks = cancelAfter
        return o
    }
    func run(_ i: XboxInstaller, cancelAfter: Int? = nil) async throws -> XboxInstaller.Result {
        var engine = options(cancelAfter: cancelAfter)
        engine.progressInterval = 0
        return try await i.install(product: product, contentID: XboxTestPackage.contentID.uuidString, title: "Test Game: Edition", options: engine)
    }

    /// Stream-extract: every file lands from ranged reads, plain files decrypted,
    /// kept-encrypted ones as their encrypted pages; nothing but the package is fetched.
    func testAnInstallStreamsPlainFilesDecryptedAndKeepsExesEncrypted() async throws {
        let services = XboxTestServices(cdn, size: package.bytes.count), lines = XboxLines()
        let r = try await run(installer(services, log: lines.logger))
        let rec = r.installed
        XCTAssertEqual(rec.installDir, "Test Game Edition")
        let dir = root.appendingPathComponent("Games/Test Game Edition")
        for f in package.files {
            let got = Array(try Data(contentsOf: dir.appendingPathComponent(f.path)))
            if f.keep {
                let at = package.offsets[f.path]!, pages = (f.data.count + 4095) / 4096
                XCTAssertEqual(got, Array(package.bytes[at..<(at + pages * 4096)]), "\(f.path) stays encrypted, padded to pages")
                XCTAssertNotEqual(Array(got[0..<f.data.count]), f.data)
            } else {
                XCTAssertEqual(got, f.data, f.path)
            }
        }
        // The record carries what a play needs to decrypt a kept file, and nothing secret.
        XCTAssertEqual(rec.contentID, XboxTestPackage.contentID.uuidString.lowercased())
        XCTAssertEqual(rec.version, "1.2.3.0")
        XCTAssertEqual(rec.executable, "Game.exe")
        XCTAssertEqual(rec.scid, XboxTestPackage.scid)
        XCTAssertEqual(rec.titleID, "1234ABCD")
        XCTAssertEqual(rec.encrypted.map(\.path).sorted(), ["Game.exe", "Tools/Crash.exe"])
        for e in rec.encrypted {
            let f = package.files.first { $0.path == e.path }!
            XCTAssertEqual(e.size, UInt64(f.data.count))
            XCTAssertEqual(e.keyID, XboxTestPackage.keyID)
            XCTAssertEqual(e.region, XboxTestPackage.region)
            XCTAssertEqual(e.units, package.units[e.path])
            var bytes = Array(try Data(contentsOf: dir.appendingPathComponent(e.path)))
            try XboxXTS(key: XboxTestPackage.key, region: e.region, vduid: UUID(uuidString: rec.contentID)!).decrypt(&bytes, units: e.units[...])
            XCTAssertEqual(Array(bytes[0..<Int(e.size)]), f.data, "\(e.path) decrypts with the record alone")
        }
        let recordText = String(decoding: try Data(contentsOf: installer(services).recordFile(product)), as: UTF8.self)
        XCTAssertFalse(recordText.contains(Array(XboxTestPackage.key).hex))
        XCTAssertEqual(installer(services).loadRecord(product), rec)
        // The stage, the journal and the metadata prefix are gone; the package was read once.
        XCTAssertFalse(installer(services).hasStage(product))
        XCTAssertLessThanOrEqual(cdn.bytesServed, package.bytes.count)
        XCTAssertFalse(lines.text.contains("127.0.0.1"))
        let report = try installer(services).verify(product)
        XCTAssertEqual(report.bad, [])
        XCTAssertEqual(report.files, package.files.count)
    }

    func testAnInterruptedInstallResumesWhereItStopped() async throws {
        let services = XboxTestServices(cdn, size: package.bytes.count)
        do { _ = try await run(installer(services), cancelAfter: 2); XCTFail("stopped early") } catch ClientError.cancelled {}
        XCTAssertTrue(installer(services).hasStage(product))
        let fetched = cdn.ranges.filter { $0.lowerBound >= package.prefixBytes }
        XCTAssertEqual(fetched.count, 2, "two chunks before the stop")
        cdn.reset()
        cdn.dropNext = 1  // and the connection drops once mid-response: the CDN client retries
        let r = try await run(installer(services))
        XCTAssertTrue(cdn.ranges.allSatisfy { $0.lowerBound >= package.prefixBytes }, "the metadata is not fetched again")
        XCTAssertTrue(fetched.allSatisfy { done in !cdn.ranges.contains(done) }, "nor the chunks finished before the stop")
        XCTAssertEqual(Set(cdn.ranges).count + 1, cdn.ranges.count, "only the dropped response is asked twice")
        XCTAssertEqual(try installer(services).verify(product).bad, [])
        XCTAssertEqual(r.installed.files.count, package.files.count)
    }

    /// A byte flipped on the wire is found before it is decrypted or written; one flipped
    /// on disk afterwards is found by verify.
    func testAFlippedByteIsFound() async throws {
        let services = XboxTestServices(cdn, size: package.bytes.count)
        let dll = package.offsets["Game_Data/Managed/Assembly.dll"]!
        cdn.flip = dll + 4100
        do {
            _ = try await run(installer(services)); XCTFail("installed a damaged page")
        } catch let ClientError.verificationFailed(why) {
            XCTAssertTrue(why.contains("does not match the package's hash tree"), why)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Games/Test Game Edition").path))
        cdn.flip = nil
        let r = try await run(installer(services))
        let exe = root.appendingPathComponent("Games/\(r.installed.installDir)/Tools/Crash.exe")
        var bytes = Array(try Data(contentsOf: exe))
        bytes[123] ^= 0x01
        try Data(bytes).write(to: exe)
        XCTAssertEqual(try installer(services).verify(product).bad, ["Tools/Crash.exe"])
    }

    func testAPackageCutShortOnTheCDNThrows() async throws {
        let services = XboxTestServices(cdn, size: package.bytes.count)
        cdn.body = Array(package.bytes[0..<(package.bytes.count - 4096)])
        do { _ = try await run(installer(services)); XCTFail("installed a truncated package") } catch let error as ClientError {
            XCTAssertNotEqual(error, .cancelled)
        }
        cdn.body = Array(package.bytes[0..<(package.prefixBytes / 2)])
        let truncated = XboxTestServices(cdn, size: package.prefixBytes / 2)
        do { _ = try await run(installer(truncated)); XCTFail("installed a truncated package") } catch let error as ClientError {
            XCTAssertNotEqual(error, .cancelled)
        }
    }

    /// Without SegmentMetadata.bin every .exe is kept encrypted (Xodus's NTFS fallback).
    func testWithoutSegmentMetadataEveryExeStaysEncrypted() async throws {
        let bare = XboxTestPackage.build([
            XboxTestPackage.File(path: "Game.exe", data: XboxTestPackage.content(9, 5000)),
            XboxTestPackage.File(path: "Data/game.bin", data: XboxTestPackage.content(10, 7000)),
            XboxTestPackage.File(path: "MicrosoftGame.Config", data: XboxTestPackage.config(), encrypted: false),
        ], segmentMetadata: false)
        cdn.stop()
        cdn = try XboxTestCDN(bare.bytes)
        let r = try await run(installer(XboxTestServices(cdn, size: bare.bytes.count)))
        XCTAssertEqual(r.installed.encrypted.map(\.path), ["Game.exe"])
        let bin = Array(try Data(contentsOf: root.appendingPathComponent("Games/\(r.installed.installDir)/Data/game.bin")))
        XCTAssertEqual(bin, XboxTestPackage.content(10, 7000))
    }

    func testALicenceRefusalIsItsOwnErrorAndNothingIsDownloaded() async throws {
        let services = XboxTestServices(cdn, size: package.bytes.count)
        await services.refuse(.refused)
        do { _ = try await run(installer(services)); XCTFail("refused") } catch let error as XboxInstallRefusal {
            XCTAssertEqual(error, .licence(.refused))
            XCTAssertEqual(error.description, "Microsoft did not grant a licence for this copy. Check your purchase, subscription and Store region.")
        }
        XCTAssertEqual(cdn.requestCount, 0)
        XCTAssertFalse(installer(services).hasStage(product))
        await services.refuse(.deviceLimit)
        do { _ = try await run(installer(services)); XCTFail("refused") } catch let error as XboxInstallRefusal {
            XCTAssertEqual(error, .licence(.deviceLimit))
        }
    }

    func testAMissingEntitlementIsItsOwnError() async throws {
        let services = XboxTestServices(cdn, size: package.bytes.count)
        await services.fail(XboxInstallRefusal.notEntitled)
        do { _ = try await run(installer(services)); XCTFail("refused") } catch let error as XboxInstallRefusal {
            XCTAssertEqual(error, .notEntitled)
            XCTAssertTrue(error.description.hasPrefix("Microsoft didn't give this account a download for this game."))
        }
        let asked = await services.licences
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(cdn.requestCount, 0)
    }

    /// Remove keeps the copy's saves, or deletes them (every account's, its SCID only).
    func testRemoveKeepsOrDeletesTheCopysSaves() async throws {
        let services = XboxTestServices(cdn, size: package.bytes.count)
        _ = try await run(installer(services))
        let local = root.appendingPathComponent("prefix/drive_c/users/playport/AppData/Local", isDirectory: true)
        let scid = XboxTestPackage.scid, hex = Array(scid.utf8).hex
        let mine = ["XodusGameSave/2535400000000001/\(scid)", "XodusGameSave/2535400000000002/\(scid)",
                    "XodusGameSaveFiles/2535400000000001/\(hex)", "XodusGameSaveFilesCache/2535400000000001/\(hex)"]
        let other = "XodusGameSave/2535400000000001/00000000-0000-0000-0000-0000deadbeef"
        func make() throws {
            for d in mine + [other] {
                let url = local.appendingPathComponent(d, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("save".utf8).write(to: url.appendingPathComponent("save1"))
            }
        }
        try make()
        XCTAssertEqual(Set(XboxSaves.folders(scid: scid, localAppData: local).map { $0.path.replacingOccurrences(of: local.path + "/", with: "") }), Set(mine))
        installer(services).forget(product, keepSaves: true, localAppData: local)
        XCTAssertNil(installer(services).loadRecord(product))
        for d in mine + [other] { XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent(d).path), d) }

        _ = try await run(installer(services))
        installer(services).forget(product, keepSaves: false, localAppData: local)
        for d in mine { XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent(d).path), d) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent(other).path), "another game's saves stay")
        XCTAssertNil(installer(services).loadRecord(product))
    }
}
