// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// A Play of an installed Xbox copy: its kept-encrypted files' plaintext from the install
/// record and the licence's content key, the bridge's copy from the game's
/// MicrosoftGame.config, and why a launch is refused (sign-in versus licence).
final class XboxPlayTests: XCTestCase, @unchecked Sendable {
    let product = "9TESTGAME001"
    var cdn: XboxTestCDN!
    var package: XboxTestPackage!
    var root: URL!

    override func setUpWithError() throws {
        package = XboxTestPackage.standard()
        cdn = try XboxTestCDN(package.bytes)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-play-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        cdn.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private var key: XboxContentKey { XboxContentKey(id: XboxTestPackage.keyID, key: Secret(XboxTestPackage.key)) }

    private func install() async throws -> XboxInstalled {
        let installer = XboxInstaller(layout: .root(root), services: XboxTestServices(cdn, size: package.bytes.count)) { location in
            XboxCDNPackage(location, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
        return try await installer.install(product: product, contentID: XboxTestPackage.contentID.uuidString, title: "Test Game").installed
    }

    func testEachKeptEncryptedFileGivesItsPlaintextFromTheRecordAndTheContentKey() async throws {
        let rec = try await install()
        let dir = root.appendingPathComponent("Games/\(rec.installDir)")
        let files = try XboxPlayFiles(installed: rec, keys: [key])
        XCTAssertEqual(files.paths.sorted(), ["Game.exe", "Tools/Crash.exe"])
        for path in files.paths {
            let out = root.appendingPathComponent("plain-\(UUID().uuidString)")
            try files.plaintext(path, original: dir.appendingPathComponent(path), out: out)
            let want = package.files.first { $0.path == path }!.data
            XCTAssertEqual(Array(try Data(contentsOf: out)), want, "\(path): the game's own bytes, cut to the file's size")
        }
    }

    func testALicenceWithoutTheCopysKeyIsALicenceRefusalAndAShortOriginalThrows() async throws {
        let rec = try await install()
        let other = XboxContentKey(id: UUID(), key: Secret(XboxTestPackage.key))
        XCTAssertThrowsError(try XboxPlayFiles(installed: rec, keys: [other])) {
            XCTAssertEqual(($0 as? XboxPlayRefusal)?.kind, .licence)
        }
        let files = try XboxPlayFiles(installed: rec, keys: [key])
        let short = root.appendingPathComponent("short.exe")
        try Data(repeating: 0, count: 4096).write(to: short)
        XCTAssertThrowsError(try files.plaintext("Game.exe", original: short, out: root.appendingPathComponent("out")))
        XCTAssertThrowsError(try files.plaintext("Not/Listed.exe", original: short, out: root.appendingPathComponent("out")))
    }

    func testTheBridgeServesTheCopyItsGameConfigDeclares() throws {
        let dir = root.appendingPathComponent("Game", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Its own spelling of the name, as the pilot's MicrosoftGame.Config.
        let config = String(decoding: XboxTestPackage.config(), as: UTF8.self).replacingOccurrences(
            of: "</Game>", with: "  <MSAFullTrust>true</MSAFullTrust>\n  <RelatedProducts><RelatedProduct>9NDLCPRODUCT</RelatedProduct>"
                + "<RelatedProduct>9NSECONDDLC1</RelatedProduct></RelatedProducts>\n</Game>")
        try Data(config.utf8).write(to: dir.appendingPathComponent("MicrosoftGame.Config"))
        let copy = XboxBridgeCopy(productID: product, manifest: try XboxGameManifest.load(folder: dir))
        XCTAssertEqual(copy.productID, product)
        XCTAssertEqual(copy.msaAppID, "0000000040ABCDEF")
        XCTAssertTrue(copy.msaFullTrust)
        XCTAssertEqual(copy.relatedProductIDs, ["9NDLCPRODUCT", "9NSECONDDLC1"])

        // The pilot's shape: no related products, no full trust.
        try XboxTestPackage.config().withUnsafeBytes { try Data($0).write(to: dir.appendingPathComponent("MicrosoftGame.Config")) }
        let plain = XboxBridgeCopy(productID: product, manifest: try XboxGameManifest.load(folder: dir))
        XCTAssertEqual(plain.relatedProductIDs, [])
        XCTAssertFalse(plain.msaFullTrust)
        // A malformed related product is not served.
        let bad = config.replacingOccurrences(of: "9NSECONDDLC1", with: "../../escape")
        try Data(bad.utf8).write(to: dir.appendingPathComponent("MicrosoftGame.Config"))
        XCTAssertEqual(try XboxGameManifest.load(folder: dir).relatedProductIDs, ["9NDLCPRODUCT"])
        // No config: the copy cannot play with the runtime.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("MicrosoftGame.Config"))
        XCTAssertThrowsError(try XboxGameManifest.load(folder: dir))
    }

    /// VC14 is run from the installer the package carries (an Unreal Engine layout), else
    /// nothing: Wine's own VC++ runtime stands in, as for the pilot.
    func testADeclaredVC14RunsThePackagesOwnInstallerWhenItCarriesOne() throws {
        let dir = root.appendingPathComponent("Game", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vc14 = String(decoding: XboxTestPackage.config(), as: UTF8.self).replacingOccurrences(
            of: "</Game>", with: "<DesktopRegistration><DependencyList><KnownDependency Name=\"VC14\" /></DependencyList>"
                + "</DesktopRegistration></Game>")
        try Data(vc14.utf8).write(to: dir.appendingPathComponent("MicrosoftGame.config"))
        let manifest = try XboxGameManifest.load(folder: dir)
        XCTAssertEqual(manifest.knownDependencies, ["VC14"])
        let redist = XboxInstalledFile(path: "Engine/Extras/Redist/en-us/vc_redist.x64.exe", size: 25_000_000,
                                       sha1: String(repeating: "ab", count: 20))
        let exe = XboxInstalledFile(path: "Game.exe", size: 10, sha1: String(repeating: "cd", count: 20))
        XCTAssertEqual(manifest.prerequisites(files: [exe, redist]), [XboxGameManifest.Prerequisite(
            ids: ["VC14 x64:25000000-abababababababab"], name: "Visual C++ 2015-2022 (x64)",
            path: "Engine/Extras/Redist/en-us/vc_redist.x64.exe", arguments: "/install /quiet /norestart")])
        XCTAssertEqual(manifest.prerequisites(files: [exe]), [], "the pilot: no installer in the package")
        try XboxTestPackage.config().withUnsafeBytes { try Data($0).write(to: dir.appendingPathComponent("MicrosoftGame.config")) }
        XCTAssertEqual(try XboxGameManifest.load(folder: dir).prerequisites(files: [exe, redist]), [], "VC14 not declared")
    }

    /// A launch the licence stops says whether it is the sign-in or the licence.
    func testALaunchRefusalSaysSignInOrLicence() {
        func refusal(_ r: XboxLicenceResult) -> XboxPlayRefusal? {
            if case let .failure(f) = XboxPlayRefusal.check(r) { return f }
            return nil
        }
        let signIn: [XboxPlayRefusal?] = [
            .signedOut,
            refusal(.unavailable(.session(.signInRequired))),
            refusal(.unavailable(.session(.deviceRejected))),
        ]
        for r in signIn {
            XCTAssertEqual(r?.kind, .signIn)
            XCTAssertTrue(r?.description.contains("Sign in") == true, r?.description ?? "nil")
            XCTAssertTrue(r?.title.contains("sign-in") == true, r?.title ?? "nil")
        }
        let licence: [XboxPlayRefusal?] = [
            refusal(.refused(.refused)),
            refusal(.refused(.deviceLimit)),
            refusal(.unavailable(.network)),
            refusal(.unavailable(.service(503))),
            refusal(.unavailable(.rejected(403))),
            refusal(.unavailable(.invalidResponse)),
        ]
        for r in licence {
            XCTAssertEqual(r?.kind, .licence)
            XCTAssertTrue(r?.title.contains("licence") == true, r?.title ?? "nil")
            XCTAssertFalse(r?.description.contains("Sign in") == true, r?.description ?? "nil")
        }
        // A refusal is Microsoft's verdict; an outage is not.
        XCTAssertNotEqual(refusal(.refused(.refused))?.title, refusal(.unavailable(.network))?.title)
        let granted = XboxLicence(contentID: XboxTestPackage.contentID.uuidString.lowercased(), keys: [key],
                                  expiresAt: Date(), offlineLease: nil, source: .microsoft)
        guard case .success = XboxPlayRefusal.check(.licensed(granted)) else { return XCTFail("a licence plays") }
    }
}
