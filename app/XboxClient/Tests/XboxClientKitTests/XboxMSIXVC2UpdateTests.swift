// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// An installed MSIXVC2 copy is updated from the synthetic v1/v2 pair the fixture script
/// writes (`msixvc2-fixture.py` and `--v2`): segments compared by their hashes.
final class XboxMSIXVC2UpdateTests: XCTestCase, @unchecked Sendable {
    let product = "9TESTGAME002"
    var v1: [UInt8]!
    var v2: [UInt8]!
    var cdn: XboxTestCDN!
    var services: Services!
    var root: URL!

    /// Path, size, SHA-256 of every v2 file as `msixvc2-fixture.py --v2` printed them.
    static let v2Files: [(String, UInt64, String)] = [
        ("Data/Sub/shared.bin", 5000, "bb963871b9ed1a04f3ca3f8915d3f94ce7e57ab822a861dd8fe1043a52ab1a2e"),
        ("Data/empty.txt", 0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("Data/level1.bin", 28000, "45293087ac8111ff010792f2c193ea3c07c53e6dd7c60230de00ebdda77436a2"),
        ("Data/new.bin", 2560, "116c6fe362983b50ac326d220db926e19f26acb60c68be4078ebd0ba7cc7bb4a"),
        ("Game.exe", 9004, "978e8c67c3e846624391334e39786df3ebca59e5efaf7af9ebe1c0fc61dcc04c"),
        ("MicrosoftGame.config", 411, "cddc26ddb07587d8d7e3c72139361b00a6b20c8edbed357b4b92e1753fb1842b"),
    ]

    actor Services: XboxInstallServices {
        var location: XboxPackageLocation
        let url: URL
        init(_ cdn: XboxTestCDN, size: Int) {
            url = cdn.url
            location = Self.location(url, version: "1.2.3.0", size: size)
        }
        static func location(_ url: URL, version: String, size: Int) -> XboxPackageLocation {
            XboxPackageLocation(contentID: XboxMSIXVC2Fixture.contentID, version: version,
                                fileName: "Playport.TestGame_\(version)_x64__test.msixvc2", size: UInt64(size), urls: [url])
        }
        func serve(version: String, size: Int) { location = Self.location(url, version: version, size: size) }
        func packageLocation(contentID: String) async throws -> XboxPackageLocation { location }
        func licence(contentID: String, market: String) async throws -> XboxLicenceResult {
            .licensed(XboxLicence(contentID: XboxMSIXVC2Fixture.contentID, keys: [XboxContentKey(id: XboxMSIXVC2Fixture.keyID, key: Secret(XboxMSIXVC2Fixture.key))],
                                  expiresAt: .distantFuture, offlineLease: nil, source: .microsoft))
        }
    }

    override func setUpWithError() throws {
        v1 = try XboxMSIXVC2Fixture.bytes()
        v2 = try xboxFixture("msixvc2-synthetic-v2.msixvc2")
        cdn = try XboxTestCDN(v1)
        services = Services(cdn, size: v1.count)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-msixvc2-update-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        cdn.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func installer() -> XboxInstaller {
        XboxInstaller(layout: .root(root), services: services) { location in
            XboxCDNPackage(location, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
    }
    func options() -> InstallEngine.Options {
        var o = InstallEngine.Options()
        o.concurrency = 4
        o.progressInterval = 0
        return o
    }
    var dir: URL { root.appendingPathComponent("Games/Test Game 2") }

    /// Each v2 segment's box bytes in the package, by file and segment number.
    func segmentRanges() async throws -> [String: [ClosedRange<Int>]] {
        let package = try await XboxMSIXVC2Package.fetch(XboxMemoryPackage(v2), into: root.appendingPathComponent("v2.package"),
                                                         licence: XboxMSIXVC2Fixture.licence)
        var out: [String: [ClosedRange<Int>]] = [:]
        for f in package.files {
            out[f.path] = f.segments.map { s in
                let at = Int(package.boxData[s.box] + s.boxOffset)
                return at...(at + s.boxLength - 1)
            }
        }
        return out
    }

    /// Changed segments come from the CDN, the others from the installed files; files
    /// that match whole stay; the removed file goes; the record is v2's.
    func testAnMSIXVC2UpdateFetchesOnlyTheChangedSegments() async throws {
        _ = try await installer().install(product: product, contentID: XboxMSIXVC2Fixture.contentID, title: "Test Game 2", options: options())
        let shared = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("Data/Sub/shared.bin").path)[.systemFileNumber] as! NSNumber
        let check = try await installer().updateCheck(product)
        XCTAssertEqual(check, .current(latest: "1.2.3.0"))
        cdn.lock.withLock { cdn.body = v2 }
        await services.serve(version: "1.2.4.0", size: v2.count)
        let available = try await installer().updateCheck(product)
        XCTAssertEqual(available, .available(latest: "1.2.4.0"))
        cdn.reset()

        let r = try await installer().update(product: product, title: "Test Game 2", options: options())

        for (path, size, sha256) in Self.v2Files {
            let got = Array(try Data(contentsOf: dir.appendingPathComponent(path)))
            XCTAssertEqual(UInt64(got.count), size, path)
            XCTAssertEqual(SHA256Stream.hash(got).hex, sha256, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Data/Sub/readme.txt").path))
        let segments = try await segmentRanges()
        let served = Set(cdn.ranges)
        for (path, n) in [("Game.exe", 1), ("Data/level1.bin", 2), ("MicrosoftGame.config", 0), ("Data/new.bin", 0)] {
            XCTAssertTrue(served.contains(segments[path]![n]), "\(path) segment \(n) changed: fetched")
        }
        for (path, n) in [("Game.exe", 0), ("Game.exe", 2), ("Data/level1.bin", 0), ("Data/level1.bin", 1), ("Data/Sub/shared.bin", 0)] {
            XCTAssertFalse(served.contains(segments[path]![n]), "\(path) segment \(n) is unchanged: copied")
        }
        XCTAssertEqual(r.filesChanged, 4)
        XCTAssertEqual(r.filesRemoved, 1)
        XCTAssertEqual(r.reusedBytes, 4000 + 2004 + 12000 + 5000, "Game.exe's first and last segments, level1.bin's first two")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("Data/Sub/shared.bin").path)[.systemFileNumber] as! NSNumber,
                       shared, "an unchanged file is not rewritten")
        let rec = r.installed
        XCTAssertEqual(rec.version, "1.2.4.0")
        XCTAssertEqual(rec.packageName, "Playport.TestGame_1.2.4.0_x64__test")
        XCTAssertEqual(rec.executable, "Game.exe")
        XCTAssertEqual(rec.scid, "00000000-0000-0000-0000-00001234abcd")
        XCTAssertEqual(rec.encrypted, [])
        XCTAssertEqual(rec.files.map(\.path).sorted(), Self.v2Files.map(\.0))
        XCTAssertEqual(rec.bytes, Self.v2Files.reduce(0) { $0 + $1.1 })
        XCTAssertEqual(installer().loadRecord(product), rec)
        XCTAssertEqual(try installer().verify(product).bad, [])
        XCTAssertFalse(installer().hasStage(product))
    }
}
