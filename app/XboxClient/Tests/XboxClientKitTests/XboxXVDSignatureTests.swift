// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// An MSIXVC is installed only with a header Microsoft's retail key signed: the CDN is
/// plain HTTP, and the header's top hash anchors every page of the package.
final class XboxXVDSignatureTests: XCTestCase {
    func pilotHeader() throws -> [UInt8] { try XboxPilotCut().read(0, XboxXVDHeader.size) }

    /// The real header the CDN served for the pilot (Hollow Knight: Voidheart Edition 1.5.12620.0).
    func testThePilotHeaderIsSignedByMicrosoftsRetailKey() throws {
        let header = try pilotHeader()
        XCTAssertNoThrow(try XboxXVDSignature.verify(header, trust: .retail))
        // The signed bytes, as xvdtool hashes them (0x200..<0x1000).
        XCTAssertEqual(SHA256Stream.hash(Array(header[XboxXVDSignature.signed])).hex,
                       "0e3cac6e2caf31c398c453d2556ccfe90a42d6448ba04a6f626bd807d101b6e0")
        // The keys are xvdtool's GreenGamesPublicKey and GreenXvdPublicKey, by its hashes of them.
        let hashes = XboxXVDTrust.retail.keys.map { k -> String in
            var blob: [UInt8] = [0x52, 0x53, 0x41, 0x31]
            for v in [UInt32(4096), 3, 512, 0, 0] { blob.appendLE(v) }
            return SHA256Stream.hash(blob + k.e + k.n).hex
        }
        XCTAssertEqual(hashes, ["183f0ae05431e4ad91554e88946967c872997227dbe6c85116f5fd2fd2d1229e",
                                "618c5fb1193040af8bc1c0199b850b4b5c42e43ce388129180284e4ef0b18082"])
    }

    func testAChangedHeaderByteOrSignatureIsRefused() throws {
        let header = try pilotHeader()
        // The signature, the flags, the content ID, the top hash, the last signed byte.
        for offset in [0x100, 0x1FF, 0x208, 0x220, 0x240, 0x25F, 0xFFF] {
            var changed = header
            changed[offset] ^= 0x01
            XCTAssertThrowsError(try XboxXVDSignature.verify(changed, trust: .retail), String(format: "0x%X", offset)) {
                XCTAssertTrue("\($0)".contains("not signed by Microsoft"), "\($0)")
            }
        }
        var after = header
        after[0x1000] ^= 0x01
        XCTAssertNoThrow(try XboxXVDSignature.verify(after, trust: .retail), "past the signed header")
    }

    func testAnUnsignedTestSignedOrDecryptedPackageIsRefused() throws {
        var unsigned = try pilotHeader()
        unsigned.replaceSubrange(0x20..<0x200, with: [UInt8](repeating: 0, count: 0x1E0))
        XCTAssertThrowsError(try XboxXVDSignature.verify(unsigned, trust: .retail)) {
            XCTAssertTrue("\($0)".contains("not signed"), "\($0)")
        }
        // Signed, but with a key that is not Microsoft's retail one (as the SDK's test key is not).
        var test = try pilotHeader()
        XboxTestPackage.sign(&test)
        XCTAssertNoThrow(try XboxXVDSignature.verify(test, trust: XboxTestPackage.trust))
        XCTAssertThrowsError(try XboxXVDSignature.verify(test, trust: .retail)) {
            XCTAssertTrue("\($0)".contains("not signed by Microsoft"), "\($0)")
        }
        // Properly signed with its encryption disabled: refused all the same.
        var decrypted = try pilotHeader()
        decrypted[0x208] |= UInt8(XboxXVDHeader.encryptionDisabled)
        XboxTestPackage.sign(&decrypted)
        XCTAssertThrowsError(try XboxXVDSignature.verify(decrypted, trust: XboxTestPackage.trust)) {
            XCTAssertTrue("\($0)".contains("encryption disabled"), "\($0)")
        }
        XCTAssertThrowsError(try XboxXVDSignature.verify(Array(test[0..<0xFFF]), trust: XboxTestPackage.trust), "cut short")
    }

    /// The install fetches the header first: a package not signed by the installer's trust
    /// is refused before anything else is fetched or written.
    func testAnInstallRefusesAPackageItsTrustDidNotSign() async throws {
        let package = XboxTestPackage.standard()
        let cdn = try XboxTestCDN(package.bytes)
        defer { cdn.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-sig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = XboxInstaller(layout: .root(root), services: XboxTestServices(cdn, size: package.bytes.count), trust: .retail) {
            XboxCDNPackage($0, client: XboxRangeClient(allows: { $0 == "127.0.0.1" }))
        }
        do {
            _ = try await installer.install(product: "9TESTGAME001", contentID: XboxTestPackage.contentID.uuidString, title: "Test Game")
            XCTFail("installed a package Microsoft did not sign")
        } catch {
            XCTAssertTrue("\(error)".contains("not signed by Microsoft"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Games/Test Game").path))
        XCTAssertLessThanOrEqual(cdn.bytesServed, package.prefixBytes, "only metadata fetched")
    }
}
