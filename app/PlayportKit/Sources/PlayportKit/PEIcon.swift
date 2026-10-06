// SPDX-License-Identifier: GPL-3.0-or-later
// A local game's tile art (docs/plans/2026-10-06-pc-import-gog-epic.md, 1.6): the
// icon its executable carries. The PE's resource tree gives the group icon
// (RT_GROUP_ICON, the first one, as Explorer shows), its largest image is
// picked (size, then colour depth), and that image is returned as a one-image
// .ico, which ImageIO reads whether it holds a PNG or a bitmap. Reads only the
// headers and the resource section, so a large executable costs little.

import Foundation
import SteamClientKit

public enum PEIcon {
    /// The executable's largest icon as a one-image .ico file, or nil when it has none.
    public static func ico(of url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return try? extract(h)
    }

    /// Caps: a resource tree or an icon past these is not an icon worth reading.
    static let maxEntries = 4096
    static let maxIconBytes = 4 << 20

    struct Section { var va: UInt32; var size: UInt32; var raw: UInt32; var rawSize: UInt32 }

    static func extract(_ h: FileHandle) throws -> Data? {
        func bytes(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try h.seek(toOffset: offset)
            guard let d = try h.read(upToCount: count), d.count == count else { throw CocoaError(.fileReadCorruptFile) }
            return [UInt8](d)
        }
        let dos = try bytes(0, 0x40)
        guard dos[0] == 0x4D, dos[1] == 0x5A else { return nil }
        let pe = UInt64(dos.readLE32(at: 0x3C))
        let coff = try bytes(pe, 24)
        guard coff[0..<4] == [0x50, 0x45, 0, 0] else { return nil }
        let count = Int(coff.readLE16(at: 6))
        let optSize = Int(coff.readLE16(at: 20))
        let opt = try bytes(pe + 24, optSize)
        guard optSize >= 2 else { return nil }
        let is64 = opt.readLE16(at: 0) == 0x20B
        let dirsAt = is64 ? 112 : 96
        // Data directory 2: the resource table.
        guard optSize >= dirsAt + 24 else { return nil }
        let rsrcRVA = opt.readLE32(at: dirsAt + 16)
        guard rsrcRVA != 0 else { return nil }
        let table = try bytes(pe + 24 + UInt64(optSize), 40 * count)
        let sections = (0..<count).map { i in
            Section(va: table.readLE32(at: i * 40 + 12), size: table.readLE32(at: i * 40 + 8),
                    raw: table.readLE32(at: i * 40 + 20), rawSize: table.readLE32(at: i * 40 + 16))
        }
        guard let rs = sections.first(where: { rsrcRVA >= $0.va && rsrcRVA < $0.va + max($0.size, $0.rawSize) }) else { return nil }
        let base = UInt64(rs.raw) + UInt64(rsrcRVA - rs.va)
        let length = Int(min(rs.rawSize - (rsrcRVA - rs.va), 64 << 20))
        let rsrc = try bytes(base, length)
        func fileOffset(_ rva: UInt32) -> UInt64? {
            sections.first { rva >= $0.va && rva < $0.va + max($0.size, $0.rawSize) }.map { UInt64($0.raw) + UInt64(rva - $0.va) }
        }

        /// The entries of the directory at `at` in the section: (id or nil for a name, offset, is a directory).
        func directory(_ at: Int) -> [(id: UInt32?, offset: Int, isDir: Bool)] {
            guard at >= 0, at + 16 <= rsrc.count else { return [] }
            let n = Int(rsrc.readLE16(at: at + 12)) + Int(rsrc.readLE16(at: at + 14))
            guard n <= maxEntries, at + 16 + n * 8 <= rsrc.count else { return [] }
            return (0..<n).map { i in
                let e = at + 16 + i * 8
                let name = rsrc.readLE32(at: e), off = rsrc.readLE32(at: e + 4)
                return (name & 0x8000_0000 == 0 ? name : nil, Int(off & 0x7FFF_FFFF), off & 0x8000_0000 != 0)
            }
        }
        /// The first data entry under a type/name directory (any language): its bytes.
        func data(under entry: (id: UInt32?, offset: Int, isDir: Bool)) throws -> [UInt8]? {
            var e = entry
            while e.isDir {
                guard let first = directory(e.offset).first else { return nil }
                e = first
            }
            guard e.offset + 16 <= rsrc.count else { return nil }
            let rva = rsrc.readLE32(at: e.offset), size = Int(rsrc.readLE32(at: e.offset + 4))
            guard size > 0, size <= maxIconBytes, let at = fileOffset(rva) else { return nil }
            return try bytes(at, size)
        }

        let types = directory(0)
        guard let group = types.first(where: { $0.id == 14 }), group.isDir,
              let firstGroup = directory(group.offset).first,
              let grp = try data(under: firstGroup), grp.count >= 6 else { return nil }
        let n = Int(grp.readLE16(at: 4))
        guard n > 0, 6 + n * 14 <= grp.count else { return nil }
        // The largest image (0 means 256), then the deepest colour.
        let best = (0..<n).map { i -> (side: Int, bits: Int, id: UInt32, entry: Array<UInt8>.SubSequence) in
            let e = 6 + i * 14
            let w = Int(grp[e]) == 0 ? 256 : Int(grp[e])
            return (w, Int(grp.readLE16(at: e + 6)), UInt32(grp.readLE16(at: e + 12)), grp[e..<(e + 14)])
        }.max { a, b in a.side != b.side ? a.side < b.side : a.bits < b.bits }!
        guard let icons = types.first(where: { $0.id == 3 }), icons.isDir,
              let image = directory(icons.offset).first(where: { $0.id == best.id }),
              let pixels = try data(under: image) else { return nil }
        var ico: [UInt8] = [0, 0, 1, 0, 1, 0]
        ico += best.entry.prefix(8)                        // width, height, colours, reserved, planes, bit count
        ico.appendLE(UInt32(pixels.count))
        ico.appendLE(UInt32(22))
        return Data(ico + pixels)
    }
}
