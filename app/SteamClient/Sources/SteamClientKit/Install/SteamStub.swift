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
/// variant 3 header decrypts to the signature 0xC0DEC0DF. Variant 3.1 has one
/// 0xF0-byte header layout for x86 and x64 (`Header31`): it names the
/// original entry point, the app ID, the flags and, when the stub also
/// encrypts the game's code, the code section and its AES-256 key, IV and
/// the 16 bytes taken from its start. Variant 3.1 is unwrapped, x86 and x64,
/// with or without encrypted code; 3.0 is recognised and reported, and left
/// alone. Only 3.1 x64 without encrypted code has been checked against a
/// real executable (En Garde!: docs/evidence/2026-09-27-gbe-steam-api-build.md,
/// docs/plans/finished.md#en-garde); x86 and encrypted code follow the same
/// header (docs/evidence/2026-10-12-steamstub-x86.md).
///
/// Variant 2.0 (x86 only) marks its entry with the dword 0xC0DEC0DE just
/// before it; the stub's first instructions load the header's address and
/// its size in dwords (`mov esi, imm32; mov ecx, imm32`). The header is
/// XOR-chained the same way, 856, 884 or 952 bytes (`Header20`), and names
/// the original entry point as an address, the app ID, and, with flag 0x04,
/// the code section's range and the key its dwords are XOR-chained from.
/// Checked against Assassin's Creed's launcher (952 bytes, encoded code:
/// docs/evidence/2026-10-14-assassins-creed.md).
///
/// Like SteamAPISwap, the game's executable is kept as `<name>.orig` and a
/// copy without the stub takes its place (an APFS clone plus a few header
/// bytes, and the code section when it was encrypted), and `restore` puts the
/// game's back; verify and repair see the kept original.
public enum SteamStub {
    public static let signature: UInt32 = 0xC0DE_C0DF
    /// The dword just before a variant 2.0 stub's entry.
    static let marker20: UInt32 = 0xC0DE_C0DE
    /// A variant 2.0 stub's first instructions, before `mov esi, <header address>`.
    static let prologue20: [UInt8] = [0x53, 0x51, 0x52, 0x56, 0x57, 0x55, 0x8B, 0xEC, 0x81, 0xEC, 0x00, 0x10, 0x00, 0x00, 0xBE]
    /// The variant 2.0 header flag for a code section XOR-chained by the stub.
    static let encodedCodeFlag20: UInt32 = 0x04
    static let supported: Set<String> = ["3.1", "2.0"]
    /// The header flag for a stub that left the game's code as it was.
    static let noEncryptionFlag: UInt32 = 0x02

    public struct Info: Sendable, Equatable {
        /// "3.1", "3.0" (from the header's size) or "2.0".
        public var variant: String
        /// "x64" or "x86".
        public var arch: String
        public var appID: UInt32
        /// The game's own entry point (an RVA).
        public var originalEntryPoint: UInt32
        /// The stub also encrypts the game's code section.
        public var encrypted: Bool
        public var flags: UInt32
        /// Why a 3.1 or 2.0 header cannot be unwrapped as it reads (an entry point or
        /// encrypted code outside the image); nil when it can.
        public var defect: String? = nil

        /// What Playport can take off; nil when it can, else why not.
        public var unsupported: String? {
            if !SteamStub.supported.contains(variant) { return "SteamStub \(variant) \(arch) is not supported yet" }
            return defect.map { "\(label): \($0)" }
        }

        public var label: String { "SteamStub \(variant) \(arch)" + (encrypted ? " with encrypted code" : "") }
    }

    /// A decoded variant 3.1 header, the same 0xF0-byte layout for x86 and x64.
    struct Header31 {
        var bytes: [UInt8]
        var imageBase: UInt64 { u64(bytes, 0x08) }
        var originalEntryPoint: UInt64 { u64(bytes, 0x20) }
        var appID: UInt32 { u32(bytes, 0x38) }
        var flags: UInt32 { u32(bytes, 0x3C) }
        var codeSectionRVA: UInt64 { u64(bytes, 0x48) }
        var codeSectionSize: UInt64 { u64(bytes, 0x50) }
        var aesKey: [UInt8] { Array(bytes[0x58..<0x78]) }
        /// The CBC IV, itself encrypted with the key (one ECB block).
        var aesIV: [UInt8] { Array(bytes[0x78..<0x88]) }
        /// The code section's first ciphertext block; the section in the file starts with the second.
        var stolenBlock: [UInt8] { Array(bytes[0x88..<0x98]) }
        /// A code section named and the no-encryption flag clear.
        var encrypted: Bool { (codeSectionRVA != 0 || codeSectionSize != 0) && flags & noEncryptionFlag == 0 }
    }

    /// A decoded variant 2.0 header (x86). The 856-byte layout lacks one
    /// import slot, so its fields start 4 bytes earlier.
    struct Header20 {
        var bytes: [UInt8]
        static let sizes = [856, 884, 952]
        private var base: Int { bytes.count == 856 ? 0x14 : 0x18 }
        var flags: UInt32 { u32(bytes, base) }
        /// An address in the image base, not an RVA.
        var originalEntryPoint: UInt32 { u32(bytes, base + 0x14) }
        var codeSectionVA: UInt32 { u32(bytes, base + 0x18) }
        var codeSectionSize: UInt32 { u32(bytes, base + 0x1C) }
        var codeKey: UInt32 { u32(bytes, base + 0x20) }
        var appID: UInt32 { u32(bytes, base + 0x24) }
        var encoded: Bool { flags & encodedCodeFlag20 != 0 }
    }

    /// An executable's SteamStub, read from its headers and the stub header
    /// only; nil when it has none.
    public static func inspect(_ url: URL) -> Info? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let pe = try? PEImage.read(h) else { return nil }
        let arch = pe.is64 ? "x64" : "x86"
        if let head = header20(h, pe) { return inspect20(head, pe) }
        guard let (variant, head) = header(h, pe) else { return nil }
        guard variant == "3.1" else {
            // A 3.0 header is recognised but not read further (its fields stay zero).
            return Info(variant: variant, arch: arch, appID: 0, originalEntryPoint: 0, encrypted: false, flags: 0)
        }
        let h31 = Header31(bytes: head)
        let oep = entryRVA(h31, pe)
        return Info(variant: variant, arch: arch, appID: h31.appID,
                    originalEntryPoint: oep ?? UInt32(truncatingIfNeeded: h31.originalEntryPoint),
                    encrypted: h31.encrypted, flags: h31.flags,
                    defect: oep == nil ? "the original entry point is not in an executable section"
                        : h31.encrypted ? codeSection(h31, pe).defect : nil)
    }

    /// The decoded stub header before the entry point, with its variant.
    static func header(_ h: FileHandle, _ pe: PEImage) -> (String, [UInt8])? {
        guard let bind = pe.section(containingRVA: pe.entryPoint), bind.name == ".bind" else { return nil }
        let epOffset = UInt64(bind.rawPointer) + UInt64(pe.entryPoint - bind.virtualAddress)
        for (size, variant) in [(0xF0, "3.1"), (0xD0, "3.0")] where epOffset >= UInt64(size) {
            guard (try? h.seek(toOffset: epOffset - UInt64(size))) != nil,
                  let raw = try? h.read(upToCount: size), raw.count == size else { continue }
            let head = decodeHeader([UInt8](raw))
            if u32(head, 4) == signature { return (variant, head) }
        }
        return nil
    }

    /// A variant 2.0 stub's header, decoded; an empty one when the stub is
    /// found but its header size is not a known one.
    static func header20(_ h: FileHandle, _ pe: PEImage) -> [UInt8]? {
        guard !pe.is64, let bind = pe.section(containingRVA: pe.entryPoint), bind.name == ".bind" else { return nil }
        let epOffset = UInt64(bind.rawPointer) + UInt64(pe.entryPoint - bind.virtualAddress)
        guard epOffset >= 4, (try? h.seek(toOffset: epOffset - 4)) != nil,
              let raw = try? h.read(upToCount: 4 + 0x40), raw.count >= 4 + prologue20.count + 9 else { return nil }
        let code = [UInt8](raw)
        guard u32(code, 0) == marker20 else { return nil }
        let at = (4...(code.count - prologue20.count - 9)).first { Array(code[$0..<$0 + prologue20.count]) == prologue20 }
        guard let at, code[at + prologue20.count + 4] == 0xB9 else { return nil }
        let va = UInt64(u32(code, at + prologue20.count)), size = Int(u32(code, at + prologue20.count + 5)) * 4
        guard Header20.sizes.contains(size) else { return [] }
        guard va > pe.imageBase, va - pe.imageBase <= UInt64(UInt32.max),
              let s = pe.section(containingRVA: UInt32(va - pe.imageBase)) else { return [] }
        let off = UInt64(s.rawPointer) + (va - pe.imageBase - UInt64(s.virtualAddress))
        guard (try? h.seek(toOffset: off)) != nil, let head = try? h.read(upToCount: size), head.count == size else { return [] }
        return decodeHeader([UInt8](head))
    }

    static func inspect20(_ head: [UInt8], _ pe: PEImage) -> Info {
        guard !head.isEmpty else {
            return Info(variant: "2.0", arch: "x86", appID: 0, originalEntryPoint: 0, encrypted: false, flags: 0,
                        defect: "the stub header is not one of the known sizes")
        }
        let h20 = Header20(bytes: head)
        let oep = entryRVA20(h20, pe)
        return Info(variant: "2.0", arch: "x86", appID: h20.appID, originalEntryPoint: oep ?? h20.originalEntryPoint,
                    encrypted: h20.encoded, flags: h20.flags,
                    defect: oep == nil ? "the original entry point is not in an executable section"
                        : h20.encoded ? codeSection20(h20, pe).defect : nil)
    }

    /// A 2.0 header's entry point as an RVA in an executable section.
    static func entryRVA20(_ head: Header20, _ pe: PEImage) -> UInt32? {
        let va = UInt64(head.originalEntryPoint)
        guard va > pe.imageBase, va - pe.imageBase <= UInt64(UInt32.max) else { return nil }
        let rva = UInt32(va - pe.imageBase)
        return pe.section(containingRVA: rva)?.executable == true ? rva : nil
    }

    /// The section a 2.0 stub encoded and how many bytes of it, or why not.
    static func codeSection20(_ head: Header20, _ pe: PEImage) -> (section: PEImage.Section?, size: Int, defect: String?) {
        let va = UInt64(head.codeSectionVA)
        guard va > pe.imageBase, let s = pe.section(containingRVA: UInt32(truncatingIfNeeded: va - pe.imageBase)),
              UInt64(s.virtualAddress) == va - pe.imageBase else {
            return (nil, 0, "the encoded code is not at a section's start")
        }
        let size = Int(head.codeSectionSize) & ~3
        guard size >= 4, size <= Int(s.rawSize) else {
            return (nil, 0, "the encoded code size \(head.codeSectionSize) does not fit its section (\(s.rawSize) bytes)")
        }
        return (s, size, nil)
    }

    /// A 2.0 stub's code decoding: each dword XORed with the one before it
    /// as stored, the first with the header's key.
    static func decodeCode20(_ raw: [UInt8], key: UInt32) -> [UInt8] {
        var out = raw, key = key
        for i in stride(from: 0, to: raw.count - 3, by: 4) {
            let stored = u32(raw, i)
            put32(&out, i, stored ^ key)
            key = stored
        }
        return out
    }

    /// The inverse of decodeCode20, for building test images.
    static func encodeCode20(_ plain: [UInt8], key: UInt32) -> [UInt8] {
        var out = plain, prev = key
        for i in stride(from: 0, to: plain.count - 3, by: 4) {
            let stored = u32(plain, i) ^ prev
            put32(&out, i, stored)
            prev = stored
        }
        return out
    }

    /// The game's entry point as an RVA in an executable section: the
    /// header's value as an RVA, or, failing that, as an address in the
    /// header's image base.
    static func entryRVA(_ head: Header31, _ pe: PEImage) -> UInt32? {
        let oep = head.originalEntryPoint
        var candidates = [oep]
        if head.imageBase != 0, oep > head.imageBase { candidates.append(oep - head.imageBase) }
        for c in candidates where c <= UInt64(UInt32.max) {
            if pe.section(containingRVA: UInt32(c))?.executable == true { return UInt32(c) }
        }
        return nil
    }

    /// The encrypted code section and how many bytes of it are encrypted,
    /// or why they cannot be decrypted.
    static func codeSection(_ head: Header31, _ pe: PEImage) -> (section: PEImage.Section?, size: Int, defect: String?) {
        guard head.codeSectionRVA <= UInt64(UInt32.max), let s = pe.section(containingRVA: UInt32(head.codeSectionRVA)),
              UInt64(s.virtualAddress) == head.codeSectionRVA else {
            return (nil, 0, "the encrypted code is not at a section's start")
        }
        let size = head.codeSectionSize
        guard size >= 16, size % 16 == 0, size <= UInt64(s.rawSize) else {
            return (nil, 0, "the encrypted code size \(size) does not fit its section (\(s.rawSize) bytes)")
        }
        return (s, Int(size), nil)
    }

    /// The game's code decrypted: AES-256-CBC over the stolen first block and
    /// the section's bytes up to the size, the IV being the header's IV
    /// decrypted with the key.
    static func decryptCode(_ head: Header31, section raw: [UInt8], size: Int) throws -> [UInt8] {
        let aes = try AES256Decryptor(key: head.aesKey)
        var chain = head.aesIV
        aes.decryptBlock(&chain)
        var data = head.stolenBlock + raw.prefix(size - 16)
        for off in stride(from: 0, to: data.count, by: 16) {
            let cipher = Array(data[off..<off + 16])
            aes.decryptBlock(&data, at: off)
            for i in 0..<16 { data[off + i] ^= chain[i] }
            chain = cipher
        }
        return data
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
    /// game's own again, its code decrypted when the stub encrypted it, and
    /// on x64 the `.bind` section is dropped when it is the file's last and
    /// nothing else points into it (else it stays, unused). An x86 `.bind`
    /// always stays: its relocations may sit in a section before it.
    @discardableResult
    public static func unwrap(_ source: URL, to dest: URL) throws -> Info {
        guard let info = inspect(source) else { throw SteamError.unsupported("\(source.lastPathComponent) has no SteamStub") }
        if let why = info.unsupported { throw SteamError.unsupported(why) }
        let h = try FileHandle(forReadingFrom: source)
        defer { try? h.close() }
        let pe = try PEImage.read(h)
        guard let bind = pe.section(containingRVA: pe.entryPoint),
              pe.section(containingRVA: info.originalEntryPoint)?.executable == true else {
            throw SteamError.unsupported("the original entry point is not in an executable section")
        }
        var code: (offset: UInt64, bytes: [UInt8])?
        if info.variant == "2.0" {
            guard let head = header20(h, pe), !head.isEmpty else { throw SteamError.unsupported("no SteamStub 2.0 header") }
            let h20 = Header20(bytes: head)
            if info.encrypted {
                let c = codeSection20(h20, pe)
                guard let s = c.section else { throw SteamError.unsupported(c.defect ?? "no code section") }
                try h.seek(toOffset: UInt64(s.rawPointer))
                guard let raw = try h.read(upToCount: c.size), raw.count == c.size else { throw SteamError.unsupported("truncated code section") }
                code = (UInt64(s.rawPointer), decodeCode20([UInt8](raw), key: h20.codeKey))
            }
        } else if info.encrypted {
            guard let (_, head) = header(h, pe) else { throw SteamError.unsupported("no SteamStub header") }
            let h31 = Header31(bytes: head)
            let c = codeSection(h31, pe)
            guard let s = c.section else { throw SteamError.unsupported(c.defect ?? "no code section") }
            try h.seek(toOffset: UInt64(s.rawPointer))
            guard let raw = try h.read(upToCount: c.size), raw.count == c.size else { throw SteamError.unsupported("truncated code section") }
            code = (UInt64(s.rawPointer), try decryptCode(h31, section: [UInt8](raw), size: c.size))
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)   // a clone on APFS
        let out = try FileHandle(forUpdating: dest)
        defer { try? out.close() }
        try write32(out, pe.optionalHeader + 16, info.originalEntryPoint)
        try write32(out, pe.optionalHeader + 64, 0)   // CheckSum: not checked for an executable
        if let code {
            try out.seek(toOffset: code.offset)
            try out.write(contentsOf: Data(code.bytes))
        }
        let size = try out.seekToEnd()
        let bindEnd = UInt64(bind.rawPointer) + UInt64(bind.rawSize)
        let last = pe.sections.last == bind
        let referenced = pe.dataDirectories.contains { $0.rva != 0 && $0.rva >= bind.virtualAddress
            && $0.rva < bind.virtualAddress + max(bind.virtualSize, bind.rawSize) }
        if pe.is64, last, bindEnd == size, !referenced, bind.rawPointer > 0 {
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
    var imageBase: UInt64
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
                       entryPoint: SteamStub.u32(opt, 16),
                       imageBase: is64 ? SteamStub.u64(opt, 24) : UInt64(SteamStub.u32(opt, 28)), sectionAlignment: SteamStub.u32(opt, 32),
                       sections: sections, dataDirectories: dirs)
    }
}
