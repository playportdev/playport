// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Steam's DRM wrapper (SteamStub) taken off a game's executable, and put
/// back (docs/plans/finished.md#steam-for-games, phase 2). A wrapped
/// executable starts in a `.bind` section whose stub checks for a running
/// Steam client before it jumps to the game's own entry point; with no Steam
/// on the phone the game exits there.
///
/// Written from the format: the stub header sits just before the entry point
/// and is XOR-chained dword by dword, its first dword being the key; a
/// variant 3 header decrypts to the signature 0xC0DEC0DF. The header names
/// the original entry point, the app ID and, when the stub also encrypts the
/// game's code, the code section's AES key. Only what a real executable has
/// been checked against is unwrapped: variant 3.1, x64, code not encrypted
/// (En Garde!: docs/evidence/2026-09-27-gbe-steam-api-build.md,
/// docs/plans/finished.md#en-garde). Others are recognised and reported,
/// and left alone.
///
/// Like SteamAPISwap, the game's executable is kept as `<name>.orig` and a
/// copy without the stub takes its place (an APFS clone plus a few header
/// bytes), and `restore` puts the game's back; verify and repair see the kept
/// original.
public enum SteamStub {
    public static let signature: UInt32 = 0xC0DE_C0DF

    public struct Info: Sendable, Equatable {
        /// "3.1" or "3.0", from the header's size.
        public var variant: String
        /// "x64" or "x86".
        public var arch: String
        public var appID: UInt32
        /// The game's own entry point (an RVA).
        public var originalEntryPoint: UInt32
        /// The stub also encrypts the game's code section.
        public var encrypted: Bool
        public var flags: UInt32

        /// What Playport can take off; nil when it can, else why not.
        public var unsupported: String? {
            if variant != "3.1" || arch != "x64" { return "SteamStub \(variant) \(arch) is not supported yet" }
            if encrypted { return "SteamStub \(variant) \(arch) with encrypted code is not supported yet" }
            return nil
        }

        public var label: String { "SteamStub \(variant) \(arch)" }
    }

    /// An executable's SteamStub, read from its headers and the stub header
    /// only; nil when it has none.
    public static func inspect(_ url: URL) -> Info? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let pe = try? PEImage.read(h), let bind = pe.section(containingRVA: pe.entryPoint),
              bind.name == ".bind" else { return nil }
        let epOffset = UInt64(bind.rawPointer) + UInt64(pe.entryPoint - bind.virtualAddress)
        for (size, variant) in [(0xF0, "3.1"), (0xD0, "3.0")] where epOffset >= UInt64(size) {
            guard (try? h.seek(toOffset: epOffset - UInt64(size))) != nil,
                  let raw = try? h.read(upToCount: size), raw.count == size else { continue }
            let head = decodeHeader([UInt8](raw))
            guard u32(head, 4) == signature else { continue }
            if !pe.is64 {
                return Info(variant: variant, arch: "x86", appID: 0, originalEntryPoint: 0, encrypted: true, flags: 0)
            }
            // The 3.1 x64 layout; a 3.0 header is recognised but not read further.
            guard variant == "3.1" else {
                return Info(variant: variant, arch: "x64", appID: 0, originalEntryPoint: 0, encrypted: true, flags: 0)
            }
            let oep = u64(head, 0x20)
            return Info(variant: variant, arch: "x64", appID: u32(head, 0x38),
                        originalEntryPoint: UInt32(truncatingIfNeeded: oep),
                        encrypted: u64(head, 0x48) != 0 || u64(head, 0x50) != 0, flags: u32(head, 0x3C))
        }
        return nil
    }

    /// The header's dwords XOR-chained back: each is XORed with the one before
    /// it as stored, the first being the key.
    static func decodeHeader(_ raw: [UInt8]) -> [UInt8] {
        var out = raw
        var key = u32(raw, 0)
        for i in stride(from: 4, to: raw.count - 3, by: 4) {
            let stored = u32(raw, i)
            put32(&out, i, stored ^ key)
            key = stored
        }
        return out
    }

    /// The inverse of decodeHeader, for building test images.
    static func encodeHeader(_ plain: [UInt8]) -> [UInt8] {
        var out = plain
        var prev = u32(plain, 0)
        for i in stride(from: 4, to: plain.count - 3, by: 4) {
            let stored = u32(plain, i) ^ prev
            put32(&out, i, stored)
            prev = stored
        }
        return out
    }

    // MARK: unwrapping

    /// Writes `source` without its stub to `dest`: the entry point is the
    /// game's own again, and the `.bind` section is dropped when it is the
    /// file's last and nothing else points into it (else it stays, unused).
    @discardableResult
    public static func unwrap(_ source: URL, to dest: URL) throws -> Info {
        guard let info = inspect(source) else { throw SteamError.unsupported("\(source.lastPathComponent) has no SteamStub") }
        if let why = info.unsupported { throw SteamError.unsupported(why) }
        let h = try FileHandle(forReadingFrom: source)
        let pe = try PEImage.read(h)
        try? h.close()
        guard let bind = pe.section(containingRVA: pe.entryPoint),
              pe.section(containingRVA: info.originalEntryPoint)?.executable == true else {
            throw SteamError.unsupported("the original entry point is not in an executable section")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)   // a clone on APFS
        let out = try FileHandle(forUpdating: dest)
        defer { try? out.close() }
        try write32(out, pe.optionalHeader + 16, info.originalEntryPoint)
        try write32(out, pe.optionalHeader + 64, 0)   // CheckSum: not checked for an executable
        let size = try out.seekToEnd()
        let bindEnd = UInt64(bind.rawPointer) + UInt64(bind.rawSize)
        let last = pe.sections.last == bind
        let referenced = pe.dataDirectories.contains { $0.rva != 0 && $0.rva >= bind.virtualAddress
            && $0.rva < bind.virtualAddress + max(bind.virtualSize, bind.rawSize) }
        if last, bindEnd == size, !referenced, bind.rawPointer > 0 {
            // Drop the section: its header, the count, SizeOfImage and its bytes.
            try write16(out, pe.coffHeader + 2, UInt16(pe.sections.count - 1))
            try out.seek(toOffset: UInt64(pe.sectionTable + 40 * (pe.sections.count - 1)))
            try out.write(contentsOf: Data(count: 40))
            let prev = pe.sections[pe.sections.count - 2]
            let end = prev.virtualAddress + max(prev.virtualSize, prev.rawSize)
            let align = max(pe.sectionAlignment, 1)
            try write32(out, pe.optionalHeader + 56, (end + align - 1) / align * align)
            try out.truncate(atOffset: UInt64(bind.rawPointer))
        }
        return info
    }

    // MARK: in a game's folder

    /// A wrapped executable under a game's folder.
    public struct Site: Sendable, Equatable {
        public var path: String
        public var info: Info
        /// The game's executable is kept as `<path>.orig` and the unwrapped copy is in its place.
        public var removed: Bool
    }

    /// Every executable under `root` that carries (or, kept as `.orig`, carried) SteamStub.
    public static func sites(in root: URL) -> [Site] {
        let files = TitleInstaller.regularFiles(under: root)
        let present = Set(files)
        return files.compactMap { path in
            guard path.lowercased().hasSuffix(".exe") else { return nil }
            let removed = present.contains(path + SteamAPISwap.originalSuffix)
            let url = root.appendingPathComponent(removed ? path + SteamAPISwap.originalSuffix : path)
            return inspect(url).map { Site(path: path, info: $0, removed: removed) }
        }
    }

    /// Takes the stub off every wrapped executable Playport can unwrap (the
    /// game's kept as `.orig`). Returns every site, removed or not.
    @discardableResult
    public static func remove(in root: URL) throws -> [Site] {
        var out: [Site] = []
        for var site in sites(in: root) {
            if !site.removed, site.info.unsupported == nil {
                let exe = try InstallFS.resolveInside(root, site.path, createParents: false)
                let tmp = exe.deletingLastPathComponent().appendingPathComponent(".\(exe.lastPathComponent).unwrapped")
                try unwrap(exe, to: tmp)
                guard rename(exe.path, exe.path + SteamAPISwap.originalSuffix) == 0 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw SteamError.transport("cannot keep \(site.path) as .orig (errno \(errno))")
                }
                guard rename(tmp.path, exe.path) == 0 else { throw SteamError.transport("cannot place the unwrapped \(site.path) (errno \(errno))") }
                site.removed = true
            }
            out.append(site)
        }
        return out
    }

    /// Puts every kept executable back. Returns how many.
    @discardableResult
    public static func restore(in root: URL) throws -> Int {
        var n = 0
        for site in sites(in: root) where site.removed {
            let exe = try InstallFS.resolveInside(root, site.path, createParents: false)
            guard rename(exe.path + SteamAPISwap.originalSuffix, exe.path) == 0 else {
                throw SteamError.transport("cannot restore \(site.path) (errno \(errno))")
            }
            n += 1
        }
        return n
    }

    // MARK: bytes

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

    static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
    }

    static func write32(_ h: FileHandle, _ offset: Int, _ v: UInt32) throws {
        var b = [UInt8](repeating: 0, count: 4)
        put32(&b, 0, v)
        try h.seek(toOffset: UInt64(offset))
        try h.write(contentsOf: Data(b))
    }

    static func write16(_ h: FileHandle, _ offset: Int, _ v: UInt16) throws {
        try h.seek(toOffset: UInt64(offset))
        try h.write(contentsOf: Data([UInt8(v & 0xff), UInt8(v >> 8)]))
    }
}

/// The parts of a PE image's headers the unwrapper reads.
struct PEImage {
    struct Section: Equatable {
        var name: String
        var virtualSize: UInt32
        var virtualAddress: UInt32
        var rawSize: UInt32
        var rawPointer: UInt32
        var characteristics: UInt32
        var executable: Bool { characteristics & 0x2000_0000 != 0 }
    }

    struct Directory { var rva: UInt32; var size: UInt32 }

    var coffHeader: Int
    var optionalHeader: Int
    var sectionTable: Int
    var is64: Bool
    var entryPoint: UInt32
    var sectionAlignment: UInt32
    var sections: [Section]
    var dataDirectories: [Directory]

    func section(containingRVA rva: UInt32) -> Section? {
        sections.first { rva >= $0.virtualAddress && rva < $0.virtualAddress + max($0.virtualSize, $0.rawSize) }
    }

    static func read(_ h: FileHandle) throws -> PEImage {
        func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
            try h.seek(toOffset: UInt64(offset))
            guard let d = try h.read(upToCount: count), d.count == count else { throw SteamError.unsupported("truncated PE") }
            return [UInt8](d)
        }
        let dos = try bytes(0, 0x40)
        guard dos[0] == 0x4d, dos[1] == 0x5a else { throw SteamError.unsupported("not a PE file") }
        let pe = Int(SteamStub.u32(dos, 0x3c))
        let coff = try bytes(pe, 24)
        guard coff[0..<4] == [0x50, 0x45, 0, 0] else { throw SteamError.unsupported("not a PE file") }
        let count = Int(UInt16(coff[6]) | UInt16(coff[7]) << 8)
        let optSize = Int(UInt16(coff[20]) | UInt16(coff[21]) << 8)
        let optAt = pe + 24
        let opt = try bytes(optAt, optSize)
        let magic = UInt16(opt[0]) | UInt16(opt[1]) << 8
        guard magic == 0x10b || magic == 0x20b, optSize >= (magic == 0x20b ? 112 : 96) else { throw SteamError.unsupported("unknown optional header") }
        let is64 = magic == 0x20b
        let dirAt = is64 ? 112 : 96
        let dirCount = min(Int(SteamStub.u32(opt, dirAt - 4)), (optSize - dirAt) / 8)
        let dirs = (0..<max(0, dirCount)).map { Directory(rva: SteamStub.u32(opt, dirAt + 8 * $0), size: SteamStub.u32(opt, dirAt + 8 * $0 + 4)) }
        let tableAt = optAt + optSize
        let table = try bytes(tableAt, 40 * count)
        let sections = (0..<count).map { i -> Section in
            let o = 40 * i
            let name = String(decoding: table[o..<o + 8].prefix { $0 != 0 }, as: UTF8.self)
            return Section(name: name, virtualSize: SteamStub.u32(table, o + 8), virtualAddress: SteamStub.u32(table, o + 12),
                           rawSize: SteamStub.u32(table, o + 16), rawPointer: SteamStub.u32(table, o + 20),
                           characteristics: SteamStub.u32(table, o + 36))
        }
        return PEImage(coffHeader: pe + 4, optionalHeader: optAt, sectionTable: tableAt, is64: is64,
                       entryPoint: SteamStub.u32(opt, 16), sectionAlignment: SteamStub.u32(opt, 32),
                       sections: sections, dataDirectories: dirs)
    }
}
