// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// A made-up PE32+ image wrapped the way SteamStub 3.1 x64 wraps one: .text,
/// .data, then a .bind section whose entry point follows an encoded stub
/// header. No byte of it comes from a real executable.
struct WrappedImage {
    var appID: UInt32 = 1_654_660
    var codeEncrypted = false
    var is64 = true
    var headerSize = 0xF0
    var bindLast = true
    var overlay: [UInt8] = []

    static let fileAlign = 0x200, sectionAlign = 0x1000
    static let text: [UInt8] = [0x48, 0x83, 0xEC, 0x28, 0xE8, 0, 0, 0, 0, 0x48, 0x83, 0xC4, 0x28, 0xC3]
    static let oep: UInt32 = 0x1000

    func build() -> [UInt8] {
        let optSize = is64 ? 240 : 224
        let headersEnd = 0x40 + 24 + optSize + 40 * 3
        func pad(_ b: inout [UInt8], to n: Int) { if b.count < n { b += [UInt8](repeating: 0, count: n - b.count) } }
        var sections: [(String, UInt32, [UInt8], UInt32)] = []   // name, rva, raw, characteristics
        var textRaw = Self.text; pad(&textRaw, to: Self.fileAlign)
        var dataRaw = [UInt8](repeating: 0x11, count: 0x40); pad(&dataRaw, to: Self.fileAlign)
        // .bind: some stub bytes, the encoded header, then the stub's entry.
        var plain = [UInt8](repeating: 0, count: headerSize)
        SteamStub.put32(&plain, 0, 0x1234_5678)
        SteamStub.put32(&plain, 4, SteamStub.signature)
        SteamStub.put32(&plain, 0x20, Self.oep)
        SteamStub.put32(&plain, 0x38, appID)
        SteamStub.put32(&plain, 0x3C, codeEncrypted ? 0 : 6)
        if codeEncrypted { SteamStub.put32(&plain, 0x48, 0x1000); SteamStub.put32(&plain, 0x50, 0x200) }
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

    func testWhatIsNotCheckedOnARealExecutableIsRefused() throws {
        let enc = try write("enc.exe", WrappedImage(codeEncrypted: true).build())
        XCTAssertEqual(SteamStub.inspect(enc)?.unsupported, "SteamStub 3.1 x64 with encrypted code is not supported yet")
        let v30 = try write("v30.exe", WrappedImage(headerSize: 0xD0).build())
        XCTAssertEqual(SteamStub.inspect(v30)?.variant, "3.0")
        XCTAssertNotNil(SteamStub.inspect(v30)?.unsupported)
        let x86 = try write("x86.exe", WrappedImage(is64: false).build())
        XCTAssertEqual(SteamStub.inspect(x86)?.arch, "x86")
        XCTAssertThrowsError(try SteamStub.unwrap(enc, to: dir.appendingPathComponent("x.exe")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.exe").path))
    }

    func testRemoveAndRestoreInAGameFolder() throws {
        let root = dir.appendingPathComponent("Game")
        let wrapped = WrappedImage().build()
        _ = try write("Game/Launcher.exe", peImage(machine: 0x8664, tag: "launcher"))
        _ = try write("Game/Bin/Game-Shipping.exe", wrapped)
        _ = try write("Game/Bin/Other.exe", WrappedImage(codeEncrypted: true).build())
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
        XCTAssertFalse(pe.sections.contains { $0.name == ".bind" })
        print("sample: unwrapped \(try Data(contentsOf: src).count) -> \(try Data(contentsOf: dst).count) bytes, sections \(pe.sections.map(\.name))")
    }
}
