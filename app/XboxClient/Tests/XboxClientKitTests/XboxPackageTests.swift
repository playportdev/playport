// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// The pilot's real metadata (PLA-487's download of Hollow Knight: Voidheart Edition),
/// cut to its header, the hash-tree pages down to MicrosoftGame.Config's page, that
/// page, and the user data and XVC information. Reads outside the cut throw.
struct XboxPilotCut {
    var pieces: [(UInt64, [UInt8])] = []

    init() throws {
        let raw = try Zlib.decompress(xboxFixture("pilot-metadata.cut.zlib"), limit: 1 << 20)
        precondition(Array(raw[0..<6]) == Array("PPCUT1".utf8))
        var o = 12
        for _ in 0..<Int(raw.readLE32(at: 8)) {
            let offset = raw.readLE64(at: o), length = Int(raw.readLE32(at: o + 8))
            pieces.append((offset, Array(raw[(o + 12)..<(o + 12 + length)])))
            o += 12 + length
        }
    }

    func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
        for (at, bytes) in pieces where offset >= at && offset + UInt64(count) <= at + UInt64(bytes.count) {
            return Array(bytes[Int(offset - at)..<(Int(offset - at) + count)])
        }
        throw ClientError.notFound("outside the pilot cut")
    }

    func flipping(_ offset: UInt64) -> XboxPilotCut {
        var copy = self
        for (i, (at, bytes)) in copy.pieces.enumerated() where offset >= at && offset < at + UInt64(bytes.count) {
            copy.pieces[i].1[Int(offset - at)] ^= 0x01
        }
        return copy
    }
}

final class XboxPackageTests: XCTestCase {
    static let microsoftGameConfigPage: UInt64 = 10210

    /// Ground truth: the header the CDN served for 1.5.12620.0 (GetBasePackage said 5,281,849,344 bytes).
    func testThePilotHeaderGivesItsVersionContentIDAndLayout() throws {
        let cut = try XboxPilotCut()
        let header = try XboxXVDHeader.parse(cut.read(0, XboxXVDHeader.size))
        XCTAssertEqual(header.version, "1.5.12620.0")
        XCTAssertEqual(header.vduid, UUID(uuidString: "31f3afa5-02a7-4cd9-ac6e-4f4be4604ab8"))
        XCTAssertEqual(header.volumeFlags, XboxXVDHeader.readOnly | XboxXVDHeader.regionIDInXTS)
        XCTAssertEqual(header.formatVersion, 3)
        XCTAssertEqual(header.contentType, 1)
        XCTAssertEqual(header.driveSize, 5_250_465_792)
        let layout = XboxXVDLayout(header)
        XCTAssertEqual(layout.end * 4096, 5_281_849_344)
        XCTAssertEqual(layout.hashTreeStart, 4)
        XCTAssertEqual(layout.userData, 7591)
        XCTAssertEqual(layout.xvcInfo, 7639)
        XCTAssertEqual(layout.drive, 7662)
        XCTAssertEqual(layout.hashTree.top, 2)
        XCTAssertEqual(layout.hashTree.levelPages(0), 7541)
    }

    /// Header top hash → level 2 → level 1 → level 0 → MicrosoftGame.Config's page, on the real bytes.
    func testThePilotHashTreeVerifiesARealFilePageAndAFlippedByteAnywhereIsFound() throws {
        let cut = try XboxPilotCut()
        func check(_ c: XboxPilotCut) throws -> Bool {
            let header = try XboxXVDHeader.parse(c.read(0, XboxXVDHeader.size))
            let layout = XboxXVDLayout(header)
            let tree = try XboxPackageTree(header: header, layout: layout, read: c.read)
            let page = Self.microsoftGameConfigPage
            let entry = try tree.entries(page, 1, read: c.read)[0]
            return try c.read(page * 4096, 4096).withUnsafeBytes { tree.matches($0, number: page, entry: entry) }
        }
        XCTAssertTrue(try check(cut))
        let header = try XboxXVDHeader.parse(cut.read(0, XboxXVDHeader.size)), layout = XboxXVDLayout(header)
        XCTAssertFalse(try check(cut.flipping(Self.microsoftGameConfigPage * 4096 + 100)), "a data byte")
        let t = layout.hashTree
        let level0 = t.pageOffset(level: 0, (Self.microsoftGameConfigPage - layout.userData) / 170, treeStart: layout.hashTreeStart)
        for (what, offset) in [("the top hash", UInt64(0x240)), ("level 2", t.pageOffset(level: 2, 0, treeStart: 4) + 7),
                               ("level 1", t.pageOffset(level: 1, 0, treeStart: 4) + 30), ("level 0", level0 + 24 * 3)] {
            XCTAssertThrowsError(try check(cut.flipping(offset)), what)
        }
    }

    func testThePilotsRegionsKeysAndSegmentMetadataKeepOnlyItsExesEncrypted() throws {
        let cut = try XboxPilotCut()
        let header = try XboxXVDHeader.parse(cut.read(0, XboxXVDHeader.size)), layout = XboxXVDLayout(header)
        let tree = try XboxPackageTree(header: header, layout: layout, read: cut.read)
        let reader = XboxVerifiedReader(tree: tree, read: cut.read, available: layout.drive * 4096)
        let info = try XboxXVCInfo.parse(reader.read(layout.xvcInfo * 4096, Int(header.xvcDataLength)), packagePages: layout.end)
        XCTAssertEqual(info.contentID, UUID(uuidString: "b89a741a-0e1b-bc80-c39f-f4218ab99dbf"))
        XCTAssertEqual(info.keys[0], UUID(uuidString: "f054abb4-b287-33ba-c552-01cf741b66fd"), "the licence's key ID")
        XCTAssertEqual(info.regions.count, 7)
        let encrypted = info.regions.filter { $0.keyIndex != nil }
        XCTAssertEqual(encrypted.map(\.id), [0x3E8])
        XCTAssertEqual(encrypted.first?.start, 10768)
        XCTAssertEqual(encrypted.first?.end, layout.end)
        XCTAssertEqual(XboxPackage.prefixPages(info, layout) * 4096, 44_105_728, "Nexus kept the same 44 MB")

        let user = try XboxUserData.files(reader.read(layout.userData * 4096, Int(header.userDataLength)))
        XCTAssertEqual(user.packageName, "TeamCherry.15373CD61C66B_1.5.12620.0_x64__y4jvztpgccj42")
        XCTAssertEqual(Set(user.files.keys), ["P7X", "appxmanifest.xml", "MicrosoftGame.config", "Summary.json", "Metadata.json", "SegmentMetadata.bin"])
        let segments = try XboxSegmentMetadata.parse(user.files["SegmentMetadata.bin"]!)
        XCTAssertEqual(segments.count, 1795)
        XCTAssertEqual(segments.filter { $0.flags & XboxSegment.keepEncryptedOnDisk != 0 }.map(\.path), ["Hollow Knight.exe", "UnityCrashHandler64.exe"])
        XCTAssertEqual(segments.first { $0.path == "Hollow Knight.exe" }?.size, 672_256)
        let config = try XboxGameConfig.parse(user.files["MicrosoftGame.config"]!)
        XCTAssertEqual(config, XboxGameConfig(executable: "Hollow Knight.exe", titleID: "7ABD14DB", msaAppID: "000000004823914A",
                                              scid: "00000000-0000-0000-0000-00007abd14db"))
    }

    /// The independent known answers: IEEE P1619 vector 1 (zero keys, zero tweak) and a
    /// page Python's `cryptography` (OpenSSL AES-XTS) encrypted with Xodus's key split.
    func testXTSMatchesIEEE1619AndOpenSSL() throws {
        let zero = try XboxXTS(key: [UInt8](repeating: 0, count: 32), region: 0, vduid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        var page = [UInt8](repeating: 0, count: 4096)
        zero.encrypt(&page, units: [0][...])
        XCTAssertEqual(Array(page[0..<32]).hex, "917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e")

        let key = (0..<32).map { UInt8($0) }
        let vduid = UUID(uuidString: "31f3afa5-02a7-4cd9-ac6e-4f4be4604ab8")!
        let xts = try XboxXTS(key: key, region: 0x3E8, vduid: vduid)
        XCTAssertEqual(xts.tweak(unit: 0x2E18_C68C).hex, "8cc6182ee8030000a5aff331a702d94c")
        var plain = (0..<4096).map { UInt8($0 % 251) }
        let original = plain
        xts.encrypt(&plain, units: [0x2E18_C68C][...])
        XCTAssertEqual(Array(plain[0..<32]).hex, XboxPackageTests.opensslFirst32)
        XCTAssertEqual(SHA256Stream.hash(plain).hex, XboxPackageTests.opensslSHA256)
        xts.decrypt(&plain, units: [0x2E18_C68C][...])
        XCTAssertEqual(plain, original)
    }
    static let opensslFirst32 = "03f2f80e6b7baba2b10c8844e5a8bbaf8afcc238d663f2c864a37872f6ea1146"
    static let opensslSHA256 = "e2493f5d5eeb8e045ad396e85d3ffe94ede30acbbd5fcd9e5a91c40ad5c31e01"

    /// Every cut of a real header, XVC information, user data and segment metadata, and
    /// random damage to each, throws or parses; nothing traps.
    func testTruncatedOrDamagedMetadataThrowsAndNeverCrashes() throws {
        let cut = try XboxPilotCut()
        let header = try cut.read(0, XboxXVDHeader.size)
        let h = try XboxXVDHeader.parse(header), layout = XboxXVDLayout(h)
        let xvc = try cut.read(layout.xvcInfo * 4096, Int(h.xvcDataLength))
        let user = try cut.read(layout.userData * 4096, Int(h.userDataLength))
        let segments = try XboxUserData.files(user).files["SegmentMetadata.bin"]!
        let package = XboxTestPackage.standard()
        var rng = SystemRandomNumberGenerator()
        let parsers: [(String, [UInt8], ([UInt8]) throws -> Void)] = [
            ("header", header, { _ = try XboxXVDHeader.parse($0) }),
            ("xvc", Array(xvc[0..<(3496 + 7 * 128)]), { _ = try XboxXVCInfo.parse($0, packagePages: layout.end) }),
            ("user", Array(user[0..<30_000]), { _ = try XboxUserData.files($0) }),
            ("segments", Array(segments[0..<5000]), { _ = try XboxSegmentMetadata.parse($0) }),
        ]
        for (name, bytes, parse) in parsers {
            for n in stride(from: 0, to: bytes.count, by: max(1, bytes.count / 300)) {
                XCTAssertThrowsError(try parse(Array(bytes[0..<n])), "\(name) cut to \(n) bytes")
            }
            for _ in 0..<300 {
                var damaged = bytes
                for _ in 0..<Int.random(in: 1...8, using: &rng) {
                    damaged[Int.random(in: 0..<damaged.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
                _ = try? parse(damaged)
            }
        }
        // The NTFS walker on a synthetic drive: cut and damaged MFT records throw or parse.
        let drive = try XboxPackage.load(read: { off, n in Array(package.bytes[Int(off)..<(Int(off) + n)]) },
                                         available: UInt64(package.prefixBytes), file: nil)
        let volume = Int(drive.layout.drive * 4096) + 4 * 4096
        let raw = Array(package.bytes[volume..<package.prefixBytes])
        for _ in 0..<300 {
            var damaged = raw
            for _ in 0..<Int.random(in: 1...16, using: &rng) {
                damaged[Int.random(in: 0..<min(damaged.count, 4096 * 32), using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = try? XboxNTFS.volumeFiles(read: { off, n in
                guard off <= UInt64(damaged.count), UInt64(n) <= UInt64(damaged.count) - off else { throw ClientError.notFound("past") }
                return Array(damaged[Int(off)..<(Int(off) + n)])
            }, start: 0, length: UInt64(damaged.count))
        }
    }

    /// A package truncated anywhere, or with a byte flipped in its metadata, is refused.
    func testATruncatedOrFlippedPackageIsRefused() throws {
        let package = XboxTestPackage.standard()
        func load(_ bytes: [UInt8], available: Int) throws -> XboxPackage {
            try XboxPackage.load(read: { off, n in
                guard off <= UInt64(bytes.count), UInt64(n) <= UInt64(bytes.count) - off else { throw XboxXVD.damaged("past the end") }
                return Array(bytes[Int(off)..<(Int(off) + n)])
            }, available: UInt64(available), file: nil)
        }
        XCTAssertNoThrow(try load(package.bytes, available: package.prefixBytes))
        for n in stride(from: 0, to: package.prefixBytes, by: 4096 * 3 + 517) {
            XCTAssertThrowsError(try load(Array(package.bytes[0..<n]), available: n), "cut to \(n)")
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var damaged = package.bytes
            let at = Int.random(in: 0x200..<package.prefixBytes, using: &rng)
            damaged[at] ^= UInt8.random(in: 1...255, using: &rng)
            // Every byte of the prefix is covered by the hash tree or the header it checks,
            // except the header's own signature and unused fields: those may still load.
            if let loaded = try? load(damaged, available: package.prefixBytes) {
                XCTAssertEqual(loaded.files.map(\.path), try load(package.bytes, available: package.prefixBytes).files.map(\.path), "flip at \(at)")
            }
        }
    }
}
