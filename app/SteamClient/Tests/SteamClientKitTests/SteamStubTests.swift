// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// A made-up PE32+ (or PE32) image wrapped the way SteamStub 3.1 wraps one:
/// .text, .data, then a .bind section whose entry point follows an encoded
/// stub header. No byte of it comes from a real executable.
struct WrappedImage {
    var appID: UInt32 = 1_654_660
    /// .text's first 32 bytes AES-256-CBC encrypted (`Encrypted`), the first block in the header.
    var codeEncrypted = false
    var is64 = true
    var headerSize = 0xF0
    var bindLast = true
    var overlay: [UInt8] = []
    var flags: UInt32?
    /// The header's original entry point, when not `oep`.
    var headerOEP: UInt64?
    var codeSectionSize: UInt64 = 0x20

    static let fileAlign = 0x200, sectionAlign = 0x1000
    static let text: [UInt8] = [0x48, 0x83, 0xEC, 0x28, 0xE8, 0, 0, 0, 0, 0x48, 0x83, 0xC4, 0x28, 0xC3]
    static let oep: UInt32 = 0x1000
    static let imageBase: UInt64 = 0x40_0000

    /// A known answer from OpenSSL (`openssl enc -aes-256-cbc -nopad`, and
    /// `-aes-256-ecb` for the header's IV): `plain`, .text's first 32 bytes,
    /// encrypted with `key` and the IV a0..af.
    enum Encrypted {
        static let key: [UInt8] = Array(0..<32)
        static let headerIV = hex("dc9f01fd76b87c0d0f4be8850b0bece0")
        static let cipher = hex("42aa1ae31259bbca1716b2774c2621e694a7d58280d2cb6373d87f6bd1527eed")
        static let plain = WrappedImage.text + [0, 0] + [UInt8](repeating: 0xCC, count: 16)

        static func hex(_ s: String) -> [UInt8] {
            var out: [UInt8] = [], it = s.makeIterator()
            while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
            return out
        }
    }

    func build() -> [UInt8] {
        let optSize = is64 ? 240 : 224
        let headersEnd = 0x40 + 24 + optSize + 40 * 3
        func pad(_ b: inout [UInt8], to n: Int) { if b.count < n { b += [UInt8](repeating: 0, count: n - b.count) } }
        var sections: [(String, UInt32, [UInt8], UInt32)] = []   // name, rva, raw, characteristics
        // An encrypted .text starts with the second ciphertext block; the first is in the header.
        var textRaw = codeEncrypted ? Array(Encrypted.cipher[16...]) : Self.text; pad(&textRaw, to: Self.fileAlign)
        var dataRaw = [UInt8](repeating: 0x11, count: 0x40); pad(&dataRaw, to: Self.fileAlign)
        // .bind: some stub bytes, the encoded header, then the stub's entry.
        var plain = [UInt8](repeating: 0, count: headerSize)
        SteamStub.put32(&plain, 0, 0x1234_5678)
        SteamStub.put32(&plain, 4, SteamStub.signature)
        put64(&plain, 0x08, Self.imageBase)
        put64(&plain, 0x20, headerOEP ?? UInt64(Self.oep))
        SteamStub.put32(&plain, 0x38, appID)
        SteamStub.put32(&plain, 0x3C, flags ?? (codeEncrypted ? 0 : 6))
        if codeEncrypted {
            put64(&plain, 0x48, 0x1000); put64(&plain, 0x50, codeSectionSize)
            plain.replaceSubrange(0x58..<0x78, with: Encrypted.key)
            plain.replaceSubrange(0x78..<0x88, with: Encrypted.headerIV)
            plain.replaceSubrange(0x88..<0x98, with: Encrypted.cipher[0..<16])
        }
        var bindRaw = [UInt8](repeating: 0xCC, count: 0x100) + SteamStub.encodeHeader(plain) + [0x55, 0x48, 0x89, 0xE5, 0xC3]
        pad(&bindRaw, to: (bindRaw.count + Self.fileAlign - 1) / Self.fileAlign * Self.fileAlign)
        let entry = UInt32(0x3000 + 0x100 + headerSize)
        if bindLast {
            sections = [(".text", 0x1000, textRaw, 0x6000_0020), (".data", 0x2000, dataRaw, 0xC000_0040), (".bind", 0x3000, bindRaw, 0x6000_0000)]
        } else {
            sections = [(".text", 0x1000, textRaw, 0x6000_0020), (".bind", 0x2000, bindRaw, 0x6000_0000), (".data", 0x3000, dataRaw, 0xC000_0040)]
        }
        let bindRVA = sections.first { $0.0 == ".bind" }!.1
        let ep = bindLast ? entry : entry - 0x1000

        var b = [UInt8](repeating: 0, count: 0x40)
        b[0] = 0x4D; b[1] = 0x5A; b[0x3C] = 0x40
        b += [0x50, 0x45, 0, 0]
        var coff = [UInt8](repeating: 0, count: 20)
        coff[0] = is64 ? 0x64 : 0x4C; coff[1] = is64 ? 0x86 : 0x01
        coff[2] = 3; coff[16] = UInt8(optSize); coff[18] = 0x22
        b += coff
        var opt = [UInt8](repeating: 0, count: optSize)
        opt[0] = 0x0B; opt[1] = is64 ? 0x02 : 0x01
        SteamStub.put32(&opt, 16, ep)
        SteamStub.put32(&opt, 32, UInt32(Self.sectionAlign))
        SteamStub.put32(&opt, 36, UInt32(Self.fileAlign))
        SteamStub.put32(&opt, 56, 0x4000)
        SteamStub.put32(&opt, 60, UInt32(Self.fileAlign))
        SteamStub.put32(&opt, 64, 0xDEAD_BEEF)
        SteamStub.put32(&opt, is64 ? 108 : 92, 16)
        b += opt
        var raw = UInt32(Self.fileAlign)
        for (name, rva, data, ch) in sections {
            var s = [UInt8](repeating: 0, count: 40)
            for (i, c) in name.utf8.enumerated() { s[i] = c }
            SteamStub.put32(&s, 8, UInt32(data.count)); SteamStub.put32(&s, 12, rva)
            SteamStub.put32(&s, 16, UInt32(data.count)); SteamStub.put32(&s, 20, raw)
            SteamStub.put32(&s, 36, ch)
            b += s
            raw += UInt32(data.count)
        }
        precondition(b.count == headersEnd)
        pad(&b, to: Self.fileAlign)
        for s in sections { b += s.2 }
        _ = bindRVA
        return b + overlay
    }

    func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
        SteamStub.put32(&b, o, UInt32(truncatingIfNeeded: v)); SteamStub.put32(&b, o + 4, UInt32(v >> 32))
    }
}

/// A made-up PE32 image wrapped the way SteamStub 2.0 wraps one: .text
/// (XOR-chained when `encoded`), .data, then .bind holding the encoded
/// header, the 0xC0DEC0DE marker and the stub's entry, whose first
/// instructions load the header's address and size. No byte of it comes from
/// a real executable.
struct Wrapped20Image {
    var headerSize = 952
    var encoded = true
    var appID: UInt32 = 15100
    var oepVA: UInt32 = 0x40_1000
    var codeSize: UInt32 = 0x200
    var marker: UInt32 = SteamStub.marker20

    static let imageBase: UInt32 = 0x40_0000
    static let key: UInt32 = 0x5091_7C1F
    /// .text as the game built it: code, then int3 padding to the file alignment.
    static let text: [UInt8] = {
        var t: [UInt8] = [0xE8, 0xA6, 0x56, 0, 0, 0xE9, 0x17, 0xFE, 0xFF, 0xFF, 0x51, 0x53, 0x55, 0x56, 0x57, 0xC3]
        t += [UInt8](repeating: 0xCC, count: 0x200 - t.count)
        return t
    }()

    func build() -> [UInt8] {
        let fileAlign = 0x200
        func pad(_ b: inout [UInt8], to n: Int) { if b.count < n { b += [UInt8](repeating: 0, count: n - b.count) } }
        var plain = [UInt8](repeating: 0, count: headerSize)
        let base = headerSize == 856 ? 0x14 : 0x18
        SteamStub.put32(&plain, 0, 0x2B91_4CC7)
        SteamStub.put32(&plain, base, encoded ? 0x05 : 0x01)
        SteamStub.put32(&plain, base + 0x14, oepVA)
        SteamStub.put32(&plain, base + 0x18, Self.imageBase + 0x1000)
        SteamStub.put32(&plain, base + 0x1C, codeSize)
        SteamStub.put32(&plain, base + 0x20, Self.key)
        SteamStub.put32(&plain, base + 0x24, appID)
        // .bind: 0x10 bytes of stub, the header, the marker, then the entry.
        let headerRVA: UInt32 = 0x3010
        var bind = [UInt8](repeating: 0xCC, count: 0x10) + SteamStub.encodeHeader(plain)
        bind += [0, 0, 0, 0]; SteamStub.put32(&bind, bind.count - 4, marker)
        let entry = UInt32(0x3000 + bind.count)
        bind += SteamStub.prologue20 + [0, 0, 0, 0, 0xB9, 0, 0, 0, 0, 0xC3]
        SteamStub.put32(&bind, bind.count - 10, Self.imageBase + headerRVA)
        SteamStub.put32(&bind, bind.count - 5, UInt32(headerSize / 4))
        pad(&bind, to: (bind.count + fileAlign - 1) / fileAlign * fileAlign)
        let text = encoded ? SteamStub.encodeCode20(Self.text, key: Self.key) : Self.text
        var data = [UInt8](repeating: 0x11, count: 0x40); pad(&data, to: fileAlign)
        let sections: [(String, UInt32, [UInt8], UInt32)] = [(".text", 0x1000, text, 0x6000_0020),
            (".data", 0x2000, data, 0xC000_0040), (".bind", 0x3000, bind, 0x6000_0040)]

        var b = [UInt8](repeating: 0, count: 0x40)
        b[0] = 0x4D; b[1] = 0x5A; b[0x3C] = 0x40
        b += [0x50, 0x45, 0, 0]
        var coff = [UInt8](repeating: 0, count: 20)
        coff[0] = 0x4C; coff[1] = 0x01; coff[2] = 3; coff[16] = 224; coff[18] = 0x02
        b += coff
        var opt = [UInt8](repeating: 0, count: 224)
        opt[0] = 0x0B; opt[1] = 0x01
        SteamStub.put32(&opt, 16, entry)
        SteamStub.put32(&opt, 28, Self.imageBase)
        SteamStub.put32(&opt, 32, 0x1000)
        SteamStub.put32(&opt, 36, UInt32(fileAlign))
        SteamStub.put32(&opt, 56, 0x3000 + UInt32(bind.count))
        SteamStub.put32(&opt, 60, UInt32(fileAlign))
        SteamStub.put32(&opt, 92, 16)
        b += opt
        var raw = UInt32(fileAlign)
        for (name, rva, d, ch) in sections {
            var s = [UInt8](repeating: 0, count: 40)
            for (i, c) in name.utf8.enumerated() { s[i] = c }
            SteamStub.put32(&s, 8, UInt32(d.count)); SteamStub.put32(&s, 12, rva)
            SteamStub.put32(&s, 16, UInt32(d.count)); SteamStub.put32(&s, 20, raw)
            SteamStub.put32(&s, 36, ch)
            b += s
            raw += UInt32(d.count)
        }
        pad(&b, to: fileAlign)
        for s in sections { b += s.2 }
        return b
    }
}

final class SteamStubTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws { dir = try scratchDir("steamstub") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    func testTheHeaderIsAnXORChain() {
        var plain = [UInt8](repeating: 0, count: 16)
        SteamStub.put32(&plain, 0, 0xA5A5_0001); SteamStub.put32(&plain, 4, SteamStub.signature)
        SteamStub.put32(&plain, 8, 42); SteamStub.put32(&plain, 12, 7)
        let enc = SteamStub.encodeHeader(plain)
        XCTAssertEqual(SteamStub.u32(enc, 0), 0xA5A5_0001, "the key is stored as is")
        XCTAssertEqual(SteamStub.u32(enc, 4), SteamStub.signature ^ 0xA5A5_0001)
        XCTAssertEqual(SteamStub.u32(enc, 8), 42 ^ SteamStub.u32(enc, 4), "each dword is XORed with the stored one before it")
        XCTAssertEqual(SteamStub.decodeHeader(enc), plain)
    }

    func testInspectReadsA31x64Stub() throws {
        let url = try write("Game.exe", WrappedImage().build())
        let info = try XCTUnwrap(SteamStub.inspect(url))
        XCTAssertEqual(info, .init(variant: "3.1", arch: "x64", appID: 1_654_660, originalEntryPoint: 0x1000, encrypted: false, flags: 6))
        XCTAssertNil(info.unsupported)
        XCTAssertEqual(info.label, "SteamStub 3.1 x64")
    }

    func testAnImageWithoutAStubIsNone() throws {
        let plain = try write("plain.exe", peImage(machine: 0x8664, tag: "no stub"))
        XCTAssertNil(SteamStub.inspect(plain))
        let text = try write("text.exe", Array("MZ but not really".utf8))
        XCTAssertNil(SteamStub.inspect(text))
        var bad = WrappedImage().build()
        bad[0x704] ^= 0xFF   // the encoded signature (.bind at 0x600, the header 0x100 into it)
        XCTAssertNil(SteamStub.inspect(try write("broken.exe", bad)))
    }

    func testUnwrapRestoresTheEntryPointAndDropsTheLastBindSection() throws {
        let src = try write("Game.exe", WrappedImage().build())
        let dst = dir.appendingPathComponent("Game.unwrapped.exe")
        try SteamStub.unwrap(src, to: dst)
        XCTAssertNil(SteamStub.inspect(dst))
        let h = try FileHandle(forReadingFrom: dst)
        let pe = try PEImage.read(h)
        try h.close()
        XCTAssertEqual(pe.entryPoint, 0x1000)
        XCTAssertEqual(pe.sections.map(\.name), [".text", ".data"])
        let out = [UInt8](try Data(contentsOf: dst))
        XCTAssertEqual(out.count, 3 * WrappedImage.fileAlign, "the headers, .text and .data; .bind is gone")
        XCTAssertEqual(Array(out[0x200..<0x200 + WrappedImage.text.count]), WrappedImage.text, "the code is untouched")
        XCTAssertEqual(SteamStub.u32(out, 0x40 + 24 + 56), 0x3000, "SizeOfImage ends after .data")
        XCTAssertEqual(SteamStub.u32(out, 0x40 + 24 + 64), 0, "CheckSum cleared")
        XCTAssertNotNil(SteamStub.inspect(src), "the source is not changed")
    }

    func testABindSectionThatIsNotLastStaysInPlace() throws {
        let src = try write("Game.exe", WrappedImage(bindLast: false).build())
        let dst = dir.appendingPathComponent("out.exe")
        try SteamStub.unwrap(src, to: dst)
        let h = try FileHandle(forReadingFrom: dst)
        let pe = try PEImage.read(h)
        try h.close()
        XCTAssertEqual(pe.entryPoint, 0x1000)
        XCTAssertEqual(pe.sections.map(\.name), [".text", ".bind", ".data"])
        XCTAssertEqual(try Data(contentsOf: dst).count, try Data(contentsOf: src).count)
    }

    func testAnOverlayAfterBindKeepsTheSection() throws {
        let src = try write("Game.exe", WrappedImage(overlay: [UInt8](repeating: 7, count: 100)).build())
        let dst = dir.appendingPathComponent("out.exe")
        try SteamStub.unwrap(src, to: dst)
        XCTAssertEqual(try Data(contentsOf: dst).count, try Data(contentsOf: src).count, "the overlay stays where it was")
    }

    func testA31x86StubIsUnwrappedAndKeepsItsBindSection() throws {
        let src = try write("castle.exe", WrappedImage(is64: false).build())
        let info = try XCTUnwrap(SteamStub.inspect(src))
        XCTAssertEqual(info, .init(variant: "3.1", arch: "x86", appID: 1_654_660, originalEntryPoint: 0x1000, encrypted: false, flags: 6))
        XCTAssertNil(info.unsupported)
        let dst = dir.appendingPathComponent("out.exe")
        try SteamStub.unwrap(src, to: dst)
        XCTAssertNil(SteamStub.inspect(dst))
        let h = try FileHandle(forReadingFrom: dst)
        let pe = try PEImage.read(h)
        try h.close()
        XCTAssertFalse(pe.is64)
        XCTAssertEqual(pe.entryPoint, 0x1000)
        XCTAssertEqual(pe.sections.map(\.name), [".text", ".data", ".bind"], "an x86 .bind stays")
        XCTAssertEqual(try Data(contentsOf: dst).count, try Data(contentsOf: src).count)
    }

    func testAnEntryPointGivenAsAnAddressIsReadAsAnRVA() throws {
        let src = try write("Game.exe", WrappedImage(is64: false, headerOEP: WrappedImage.imageBase + 0x1000).build())
        XCTAssertEqual(SteamStub.inspect(src)?.originalEntryPoint, 0x1000)
        let bad = try write("bad.exe", WrappedImage(headerOEP: 0x9000).build())
        XCTAssertEqual(SteamStub.inspect(bad)?.unsupported, "SteamStub 3.1 x64: the original entry point is not in an executable section")
    }

    func testEncryptedCodeIsDecrypted() throws {
        for is64 in [true, false] {
            let src = try write("enc\(is64).exe", WrappedImage(codeEncrypted: true, is64: is64).build())
            let info = try XCTUnwrap(SteamStub.inspect(src))
            XCTAssertTrue(info.encrypted)
            XCTAssertNil(info.unsupported)
            XCTAssertEqual(info.label, "SteamStub 3.1 \(is64 ? "x64" : "x86") with encrypted code")
            let dst = dir.appendingPathComponent("dec\(is64).exe")
            try SteamStub.unwrap(src, to: dst)
            let out = [UInt8](try Data(contentsOf: dst))
            XCTAssertEqual(Array(out[0x200..<0x220]), WrappedImage.Encrypted.plain, "the code as it was before encryption")
            XCTAssertEqual(Array(out[0x220..<0x400]), [UInt8](repeating: 0, count: 0x1E0), "past the encrypted size, the section is as it was")
            XCTAssertNil(SteamStub.inspect(dst))
        }
    }

    func testTheNoEncryptionFlagLeavesTheCodeAlone() throws {
        let src = try write("Game.exe", WrappedImage(codeEncrypted: true, flags: SteamStub.noEncryptionFlag).build())
        XCTAssertEqual(SteamStub.inspect(src)?.encrypted, false)
        let dst = dir.appendingPathComponent("out.exe")
        try SteamStub.unwrap(src, to: dst)
        XCTAssertEqual(Array([UInt8](try Data(contentsOf: dst))[0x200..<0x210]), Array(WrappedImage.Encrypted.cipher[16..<32]))
    }

    func testWhatCannotBeUnwrappedIsRefused() throws {
        let odd = try write("odd.exe", WrappedImage(codeEncrypted: true, codeSectionSize: 0x18).build())
        XCTAssertEqual(SteamStub.inspect(odd)?.unsupported,
                       "SteamStub 3.1 x64 with encrypted code: the encrypted code size 24 does not fit its section (512 bytes)")
        let big = try write("big.exe", WrappedImage(codeEncrypted: true, codeSectionSize: 0x400).build())
        XCTAssertNotNil(SteamStub.inspect(big)?.unsupported)
        let v30 = try write("v30.exe", WrappedImage(headerSize: 0xD0).build())
        XCTAssertEqual(SteamStub.inspect(v30)?.variant, "3.0")
        XCTAssertEqual(SteamStub.inspect(v30)?.unsupported, "SteamStub 3.0 x64 is not supported yet")
        XCTAssertEqual(SteamStub.inspect(v30)?.label, "SteamStub 3.0 x64")
        let v30x86 = try write("v30x86.exe", WrappedImage(is64: false, headerSize: 0xD0).build())
        XCTAssertEqual(SteamStub.inspect(v30x86)?.arch, "x86")
        XCTAssertNotNil(SteamStub.inspect(v30x86)?.unsupported)
        XCTAssertThrowsError(try SteamStub.unwrap(odd, to: dir.appendingPathComponent("x.exe")))
        XCTAssertThrowsError(try SteamStub.unwrap(v30, to: dir.appendingPathComponent("x.exe")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.exe").path))
    }

    func testA20x86StubIsReadAndItsCodeDecoded() throws {
        for size in [952, 884, 856] {
            let src = try write("ac\(size).exe", Wrapped20Image(headerSize: size).build())
            let info = try XCTUnwrap(SteamStub.inspect(src))
            XCTAssertEqual(info, .init(variant: "2.0", arch: "x86", appID: 15100, originalEntryPoint: 0x1000, encrypted: true, flags: 5))
            XCTAssertNil(info.unsupported)
            XCTAssertEqual(info.label, "SteamStub 2.0 x86 with encrypted code")
            let dst = dir.appendingPathComponent("out\(size).exe")
            try SteamStub.unwrap(src, to: dst)
            XCTAssertNil(SteamStub.inspect(dst))
            let h = try FileHandle(forReadingFrom: dst)
            let pe = try PEImage.read(h)
            try h.close()
            XCTAssertEqual(pe.entryPoint, 0x1000)
            XCTAssertEqual(pe.sections.map(\.name), [".text", ".data", ".bind"], "an x86 .bind stays")
            let out = [UInt8](try Data(contentsOf: dst))
            XCTAssertEqual(Array(out[0x200..<0x400]), Wrapped20Image.text, "the code as the game built it")
            XCTAssertEqual(out.count, try Data(contentsOf: src).count)
        }
    }

    func testA20StubWithoutEncodedCodeKeepsItsCode() throws {
        let src = try write("plain20.exe", Wrapped20Image(encoded: false).build())
        XCTAssertEqual(SteamStub.inspect(src)?.encrypted, false)
        let dst = dir.appendingPathComponent("out.exe")
        try SteamStub.unwrap(src, to: dst)
        XCTAssertEqual(Array([UInt8](try Data(contentsOf: dst))[0x200..<0x400]), Wrapped20Image.text)
    }

    func testA20StubThatCannotBeUnwrappedIsRefused() throws {
        let odd = try write("odd.exe", Wrapped20Image(headerSize: 900).build())
        XCTAssertEqual(SteamStub.inspect(odd)?.unsupported, "SteamStub 2.0 x86: the stub header is not one of the known sizes")
        let far = try write("far.exe", Wrapped20Image(oepVA: 0x40_2000).build())
        XCTAssertEqual(SteamStub.inspect(far)?.unsupported, "SteamStub 2.0 x86 with encrypted code: the original entry point is not in an executable section")
        let big = try write("big.exe", Wrapped20Image(codeSize: 0x400).build())
        XCTAssertNotNil(SteamStub.inspect(big)?.unsupported)
        XCTAssertNil(SteamStub.inspect(try write("nomark.exe", Wrapped20Image(marker: 0).build())), "no marker, no stub")
        XCTAssertThrowsError(try SteamStub.unwrap(odd, to: dir.appendingPathComponent("x.exe")))
    }

    func testRemoveAndRestoreInAGameFolder() throws {
        let root = dir.appendingPathComponent("Game")
        let wrapped = WrappedImage().build()
        _ = try write("Game/Launcher.exe", peImage(machine: 0x8664, tag: "launcher"))
        _ = try write("Game/Bin/Game-Shipping.exe", wrapped)
        _ = try write("Game/Bin/Other.exe", WrappedImage(headerSize: 0xD0).build())
        let sites = try SteamStub.remove(in: root)
        XCTAssertEqual(sites.map(\.path), ["Bin/Game-Shipping.exe", "Bin/Other.exe"])
        XCTAssertEqual(sites.map(\.removed), [true, false], "an unsupported stub is left alone")
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("Bin/Game-Shipping.exe.orig"))), wrapped)
        XCTAssertNil(SteamStub.inspect(root.appendingPathComponent("Bin/Game-Shipping.exe")))
        // Again: nothing to do, and the site still reads as the game's stub.
        let again = try SteamStub.remove(in: root)
        XCTAssertEqual(again.first?.info.appID, 1_654_660)
        XCTAssertEqual(again.first?.removed, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Bin/Game-Shipping.exe.orig.orig").path))

        XCTAssertEqual(try SteamStub.restore(in: root), 1)
        XCTAssertEqual([UInt8](try Data(contentsOf: root.appendingPathComponent("Bin/Game-Shipping.exe"))), wrapped)
        XCTAssertEqual(SteamStub.sites(in: root).map(\.removed), [false, false])
    }

    func testVerifySeesTheKeptExecutable() async throws {
        let root = dir.appendingPathComponent("Game")
        let wrapped = WrappedImage().build()
        _ = try write("Game/Bin/Game-Shipping.exe", wrapped)
        let list = dir.appendingPathComponent("sums")
        try "\(SHA256Stream.hash(wrapped).hex)  Bin/Game-Shipping.exe\n".write(to: list, atomically: true, encoding: .utf8)
        try SteamStub.remove(in: root)
        let r = try await TitleInstaller.verifySHA256List(dir: root, list: list)
        XCTAssertEqual(r.bad, [])
        XCTAssertEqual(r.unlisted, [])
    }

    /// The real check: an executable SteamStub wrapped, when one is given
    /// (`STEAMSTUB_SAMPLE=<exe>`). Its bytes never enter the repository.
    func testARealSample() throws {
        guard let path = ProcessInfo.processInfo.environment["STEAMSTUB_SAMPLE"] else {
            throw XCTSkip("STEAMSTUB_SAMPLE is not set")
        }
        let src = URL(fileURLWithPath: path)
        let info = try XCTUnwrap(SteamStub.inspect(src))
        print("sample: \(info.label), app \(info.appID), OEP \(String(info.originalEntryPoint, radix: 16)), encrypted \(info.encrypted), flags \(info.flags)")
        XCTAssertNil(info.unsupported)
        let dst = dir.appendingPathComponent("sample.exe")
        try SteamStub.unwrap(src, to: dst)
        XCTAssertNil(SteamStub.inspect(dst))
        let h = try FileHandle(forReadingFrom: dst)
        let pe = try PEImage.read(h)
        try h.close()
        XCTAssertEqual(pe.entryPoint, info.originalEntryPoint)
        if pe.is64 { XCTAssertFalse(pe.sections.contains { $0.name == ".bind" }) }
        print("sample: unwrapped \(try Data(contentsOf: src).count) -> \(try Data(contentsOf: dst).count) bytes, sections \(pe.sections.map(\.name))")
    }
}
