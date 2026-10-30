// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// An MSIXVC2 copy installs from the synthetic package served over HTTP ranges on
/// 127.0.0.1, through the CDN client, the package's hashes and ContentKit's engine.
final class XboxMSIXVC2InstallTests: XCTestCase, @unchecked Sendable {
    let product = "9TESTGAME002"
    var body: [UInt8]!
    var cdn: XboxTestCDN!
    var root: URL!

    actor Services: XboxInstallServices {
        let location: XboxPackageLocation
        var licenceResult: XboxLicenceResult
        init(_ cdn: XboxTestCDN, size: Int, key: [UInt8] = XboxMSIXVC2Fixture.key) {
            location = XboxPackageLocation(contentID: XboxMSIXVC2Fixture.contentID, version: "1.2.3.0",
                                           fileName: "Playport.TestGame_1.2.3.0_x64__test.msixvc2", size: UInt64(size), urls: [cdn.url])
            licenceResult = .licensed(XboxLicence(contentID: XboxMSIXVC2Fixture.contentID,
                                                  keys: [XboxContentKey(id: XboxMSIXVC2Fixture.keyID, key: Secret(key))],
                                                  expiresAt: .distantFuture, offlineLease: nil, source: .microsoft))
        }
        func packageLocation(contentID: String) async throws -> XboxPackageLocation { location }
        func licence(contentID: String, market: String) async throws -> XboxLicenceResult { licenceResult }
    }

    override func setUpWithError() throws {
        body = try XboxMSIXVC2Fixture.bytes()
        cdn = try XboxTestCDN(body)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-msixvc2-install-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        cdn.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func installer(_ log: Logger = .silent) -> XboxInstaller {
        XboxInstaller(layout: .root(root), services: Services(cdn, size: body.count), log: log) { location in
            XboxCDNPackage(location, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
    }
    func run(_ i: XboxInstaller, cancelAfter: Int? = nil) async throws -> XboxInstaller.Result {
        var o = InstallEngine.Options()
        o.concurrency = 4
        o.cancelAfterChunks = cancelAfter
        o.progressInterval = 0
        return try await i.install(product: product, contentID: XboxMSIXVC2Fixture.contentID, title: "Test Game 2", options: o)
    }
    var gameDir: URL { root.appendingPathComponent("Games/Test Game 2") }

    /// Every file lands decrypted and uncompressed with the bytes the package was made
    /// from; nothing is kept encrypted; the record has MicrosoftGame.config's fields.
    func testAnMSIXVC2CopyInstallsEveryFileDecrypted() async throws {
        let lines = XboxLines()
        let r = try await run(installer(lines.logger))
        let rec = r.installed
        XCTAssertEqual(rec.installDir, "Test Game 2")
        for (path, size, sha256) in XboxMSIXVC2Fixture.files {
            let got = Array(try Data(contentsOf: gameDir.appendingPathComponent(path)))
            XCTAssertEqual(UInt64(got.count), size, path)
            XCTAssertEqual(SHA256Stream.hash(got).hex, sha256, path)
        }
        XCTAssertEqual(rec.encrypted, [])
        XCTAssertEqual(rec.contentID, XboxMSIXVC2Fixture.contentID)
        XCTAssertEqual(rec.version, "1.2.3.0")
        XCTAssertEqual(rec.packageName, "Playport.TestGame_1.2.3.0_x64__test")
        XCTAssertEqual(rec.executable, "Game.exe")
        XCTAssertEqual(rec.titleID, "1234ABCD")
        XCTAssertEqual(rec.msaAppID, "0000000012345678")
        XCTAssertEqual(rec.scid, "00000000-0000-0000-0000-00001234abcd")
        XCTAssertEqual(rec.files.map(\.path).sorted(), XboxMSIXVC2Fixture.files.map(\.0))
        XCTAssertEqual(rec.bytes, XboxMSIXVC2Fixture.files.reduce(0) { $0 + $1.1 })
        XCTAssertEqual(installer().loadRecord(product), rec)
        XCTAssertFalse(installer().hasStage(product), "the stage, the journal and the kept metadata are gone")
        XCTAssertLessThanOrEqual(cdn.bytesServed, body.count, "the package is read at most once")
        XCTAssertFalse(lines.text.contains("127.0.0.1"))
        XCTAssertFalse(lines.text.contains(XboxMSIXVC2Fixture.key.hex))
        XCTAssertEqual(try installer().verify(product).bad, [])
    }

    func testAnInterruptedMSIXVC2InstallResumesWithoutFetchingTheMetadataAgain() async throws {
        do { _ = try await run(installer(), cancelAfter: 2); XCTFail("stopped early") } catch ClientError.cancelled {}
        XCTAssertTrue(installer().hasStage(product))
        let first = cdn.ranges
        cdn.reset()
        let r = try await run(installer())
        let second = cdn.ranges
        XCTAssertFalse(second.isEmpty)
        // Every read in the second run is a segment the first didn't finish: no metadata
        // (the ZIP's end, its entries, the box manifests) is asked for again.
        XCTAssertFalse(second.contains { $0.upperBound == body.count - 1 }, "the ZIP directory was fetched again")
        XCTAssertLessThan(second.count, 8)
        XCTAssertEqual(Set(first).intersection(second).count, 0, "nothing finished before the stop is fetched again")
        XCTAssertEqual(try installer().verify(product).bad, [])
        XCTAssertEqual(r.installed.files.count, XboxMSIXVC2Fixture.files.count)
    }

    /// A byte flipped on the wire inside a segment fails its box hash before it is
    /// decrypted: fetched once more, then the install stops and nothing is committed.
    func testAFlippedSegmentByteIsFoundBeforeItIsWritten() async throws {
        let box0 = XboxMSIXVC2Fixture.entry("Boxes/box0", in: body)
        cdn.flip = box0.lowerBound + 8 + 100  // Game.exe's first segment
        let lines = XboxLines()
        do {
            _ = try await run(installer(lines.logger)); XCTFail("installed a damaged segment")
        } catch let ClientError.verificationFailed(why) {
            XCTAssertTrue(why.contains("does not match the package's hashes"), why)
        }
        XCTAssertTrue(lines.text.contains("failed its box hash; fetching it again"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gameDir.path))
        cdn.flip = nil
        let r = try await run(installer())
        let exe = gameDir.appendingPathComponent("Game.exe")
        var bytes = Array(try Data(contentsOf: exe))
        bytes[10] ^= 1
        try Data(bytes).write(to: exe)
        XCTAssertEqual(try installer().verify(product).bad, ["Game.exe"])
        XCTAssertEqual(r.installed.encrypted, [])
    }

    /// The licence's key is not this package's: refused before any file is staged.
    func testAWrongLicenceKeyStopsTheInstall() async throws {
        let wrong = XboxInstaller(layout: .root(root), services: Services(cdn, size: body.count, key: [UInt8](repeating: 9, count: 32))) { location in
            XboxCDNPackage(location, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
        do { _ = try await run(wrong); XCTFail("wrong key") } catch let ClientError.verificationFailed(why) {
            XCTAssertEqual(why, "Xbox licence key doesn't decrypt this package")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gameDir.path))
    }
}
