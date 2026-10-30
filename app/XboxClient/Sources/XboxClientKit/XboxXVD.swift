// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/msixvc/src/{xvd.rs,
// layout.rs, math.rs, models/xvd/{structs,layout,constants,flags}.rs}; translated
// to Swift by the Playport authors, 2026-10-30. Modified: every read bounds-checked
// and every count capped (a damaged package throws, never traps); the hash tree's
// levels are verified from the header's top hash down; only fixed, integrity-
// protected, non-resilient XVDs are accepted.
import Foundation
import ContentKit

/// An MSIXVC's XVD header (the first three pages; the package's own signature is
/// the first 0x200 bytes, checked by `XboxXVDSignature`).
struct XboxXVDHeader: Equatable {
    static let size = 3 * XboxXVD.page
    static let readOnly: UInt32 = 1 << 0
    static let encryptionDisabled: UInt32 = 1 << 1
    static let integrityDisabled: UInt32 = 1 << 2
    static let resiliency: UInt32 = 1 << 4
    static let regionIDInXTS: UInt32 = 1 << 6

    var volumeFlags: UInt32
    var formatVersion: UInt32
    var driveSize: UInt64
    var vduid: UUID
    var topHash: [UInt8]
    var xvdType: UInt32
    var contentType: UInt32
    var embeddedLength: UInt32
    var userDataLength: UInt32
    var xvcDataLength: UInt32
    var dynamicHeaderLength: UInt32
    var mutablePages: UInt32
    /// major.minor.build.revision, as the package's file name carries it.
    var version: String

    static func parse(_ b: [UInt8]) throws -> XboxXVDHeader {
        guard b.count >= size else { throw XboxXVD.damaged("its header is cut short") }
        guard Array(b[0x200..<0x208]) == Array("msft-xvd".utf8) else {
            if b.count >= 4, Array(b[0..<4]) == [0x50, 0x4B, 0x03, 0x04] {
                throw ClientError.protocolChanged("Xbox package is an MSIXVC2 ZIP, but Microsoft named it as an MSIXVC")
            }
            throw XboxXVD.damaged("it is not an XVD")
        }
        let r = XboxBytes(b)
        let v = (0..<4).map { r.u16(0x3BC + 2 * $0) }
        let h = XboxXVDHeader(
            volumeFlags: r.u32(0x208), formatVersion: r.u32(0x20C), driveSize: r.u64(0x218), vduid: r.guid(0x220),
            topHash: Array(b[0x240..<0x260]), xvdType: r.u32(0x280), contentType: r.u32(0x284),
            embeddedLength: r.u32(0x288), userDataLength: r.u32(0x28C), xvcDataLength: r.u32(0x290),
            dynamicHeaderLength: r.u32(0x294), mutablePages: UInt32(b[0x470]),
            version: "\(v[3]).\(v[2]).\(v[1]).\(v[0])")
        guard h.xvdType == 0 else { throw ClientError.unsupported("Xbox package is a dynamic XVD") }
        guard h.volumeFlags & integrityDisabled == 0 else { throw ClientError.unsupported("Xbox package has no hash tree to verify it by") }
        guard h.volumeFlags & resiliency == 0 else { throw ClientError.unsupported("Xbox package has a resilient hash tree") }
        guard h.driveSize <= XboxXVD.maxHashedPages * UInt64(XboxXVD.page) else { throw XboxXVD.damaged("its drive is too large") }
        guard h.hashedPages >= 1, h.hashedPages <= XboxXVD.maxHashedPages else { throw XboxXVD.damaged("it hashes \(h.hashedPages) pages") }
        return h
    }

    var hashedPages: UInt64 {
        XboxXVD.pages(UInt64(userDataLength)) + XboxXVD.pages(UInt64(xvcDataLength))
            + XboxXVD.pages(UInt64(dynamicHeaderLength)) + XboxXVD.pages(driveSize)
    }
}

/// Where each part of the XVD starts, in pages, as Xodus's `XvdHeader::layout`.
struct XboxXVDLayout: Equatable {
    var hashTree: XboxHashTreeLayout
    var hashTreeStart: UInt64
    var userData: UInt64
    var xvcInfo: UInt64
    var dynamicHeader: UInt64
    var drive: UInt64
    var end: UInt64

    init(_ h: XboxXVDHeader) {
        hashTree = XboxHashTreeLayout(hashedPages: h.hashedPages)
        var page: UInt64 = 3
        page += XboxXVD.pages(UInt64(h.embeddedLength))
        page += UInt64(h.mutablePages)
        hashTreeStart = page
        page += hashTree.pages
        userData = page; page += XboxXVD.pages(UInt64(h.userDataLength))
        xvcInfo = page; page += XboxXVD.pages(UInt64(h.xvcDataLength))
        dynamicHeader = page; page += XboxXVD.pages(UInt64(h.dynamicHeaderLength))
        drive = page; page += XboxXVD.pages(h.driveSize)
        end = page
    }
}

/// The hash tree: levels 3 to 0 back to back, 170 entries of 24 bytes a page. Level 0
/// hashes every page from the user data on; each higher level hashes the pages of the
/// one below; the top level's single page is hashed in the header (full SHA-256).
struct XboxHashTreeLayout: Equatable {
    /// Per level 0...3: first page (relative to the tree), pages, entries.
    var start: [UInt64]
    var pages: UInt64
    var entries: [UInt64]
    var top: Int

    init(hashedPages n: UInt64) {
        func stored(_ x: UInt64) -> UInt64 { x == 1 ? 0 : x }
        func levelPages(_ x: UInt64) -> UInt64 { (stored(x) + 169) / 170 }
        let l0 = max(levelPages(n), 1), l1 = levelPages(l0), l2 = levelPages(l1), l3 = levelPages(l2)
        entries = [n, stored(l0), stored(l1), stored(l2)]
        start = [l3 + l2 + l1, l3 + l2, l3, 0]
        pages = l0 + l1 + l2 + l3
        let counts = [l0, l1, l2, l3], held = [n, stored(l0), stored(l1), stored(l2)]
        top = (0..<4).first { held[$0] > 0 && held[$0] <= 170 && counts[$0] == 1 } ?? 0
    }

    /// Byte offset in the package of entry `i` of `level`, given the tree's first page.
    func entryOffset(level: Int, _ i: UInt64, treeStart: UInt64) -> UInt64 {
        (treeStart + start[level] + i / 170) * UInt64(XboxXVD.page) + (i % 170) * 24
    }
    func pageOffset(level: Int, _ p: UInt64, treeStart: UInt64) -> UInt64 { (treeStart + start[level] + p) * UInt64(XboxXVD.page) }
    func levelPages(_ level: Int) -> UInt64 { (entries[level] + 169) / 170 }
}

/// An XVC region (XvcRegionHeader): pages `[start, start + count)` of the package,
/// encrypted with the XVC key at `keyIndex` unless that is nil.
struct XboxXVCRegion: Equatable {
    var id: UInt32
    var keyIndex: Int?
    var flags: UInt32
    var firstSegment: UInt32
    var start: UInt64
    var count: UInt64
    var end: UInt64 { start + count }
}

struct XboxXVCInfo: Equatable {
    var contentID: UUID
    /// The XVC's key GUIDs by index (nil GUIDs dropped).
    var keys: [Int: UUID]
    var regions: [XboxXVCRegion]

    static func parse(_ b: [UInt8], packagePages: UInt64) throws -> XboxXVCInfo {
        let headerSize = 3496, regionSize = 128
        guard b.count >= headerSize else { throw XboxXVD.damaged("its XVC information is cut short") }
        let r = XboxBytes(b)
        var keys: [Int: UUID] = [:]
        for i in 0..<0xC0 {
            let off = 16 + 16 * i
            if b[off..<off + 16].contains(where: { $0 != 0 }) { keys[i] = r.guid(off) }
        }
        let version = r.u32(16 + 16 * 0xC0 + 0x100), count = r.u32(16 + 16 * 0xC0 + 0x104)
        guard version >= 1 else { throw ClientError.unsupported("Xbox package's XVC information is version \(version)") }
        guard count <= 4096, headerSize + Int(count) * regionSize <= b.count else { throw XboxXVD.damaged("it lists \(count) regions") }
        var regions: [XboxXVCRegion] = []
        for n in 0..<Int(count) {
            let o = headerSize + n * regionSize
            let key = r.u16(o + 4), offset = r.u64(o + 80), length = r.u64(o + 88)
            guard offset % UInt64(XboxXVD.page) == 0, length % UInt64(XboxXVD.page) == 0 else { throw XboxXVD.damaged("a region is not page-aligned") }
            let start = offset / UInt64(XboxXVD.page), pages = length / UInt64(XboxXVD.page)
            guard start <= packagePages, pages <= packagePages - start else { throw XboxXVD.damaged("a region runs past the package") }
            let index: Int? = key < 0xC0 ? Int(key) : nil
            if let index, keys[index] == nil { throw XboxXVD.damaged("a region names a key the package doesn't list") }
            regions.append(XboxXVCRegion(id: r.u32(o), keyIndex: index, flags: r.u32(o + 8), firstSegment: r.u32(o + 12),
                                         start: start, count: pages))
        }
        return XboxXVCInfo(contentID: r.guid(0), keys: keys, regions: regions)
    }
}

/// The user data's package files (XvdUserDataPackageFileEntry): name → bytes.
enum XboxUserData {
    static func files(_ b: [UInt8]) throws -> (packageName: String, files: [String: [UInt8]]) {
        let r = XboxBytes(b)
        guard b.count >= 16 else { throw XboxXVD.damaged("its user data is cut short") }
        let length = Int(r.u32(0)), type = r.u32(8)
        guard type == 0 else { return ("", [:]) }
        guard length >= 16, length <= b.count - 528 else { throw XboxXVD.damaged("its user data header is out of range") }
        let name = r.utf16(length + 4, max: 260), count = Int(r.u32(length + 524))
        guard count <= 1024, length + 528 + count * 528 <= b.count else { throw XboxXVD.damaged("its user data lists \(count) files") }
        var files: [String: [UInt8]] = [:]
        for n in 0..<count {
            let o = length + 528 + n * 528
            let path = r.utf16(o, max: 260), size = Int(r.u32(o + 520)), offset = Int(r.u32(o + 524))
            guard offset <= b.count - 16, size <= b.count - 16 - offset else { throw XboxXVD.damaged("user data file \(path) is out of range") }
            files[path] = Array(b[(16 + offset)..<(16 + offset + size)])
        }
        return (name, files)
    }
}

/// SegmentMetadata.bin: each packaged file's path, size and flags, in package order.
struct XboxSegment: Equatable {
    static let keepEncryptedOnDisk: UInt16 = 1
    var path: String
    var size: UInt64
    var flags: UInt16
}

enum XboxSegmentMetadata {
    static func parse(_ b: [UInt8]) throws -> [XboxSegment] {
        let r = XboxBytes(b)
        guard b.count >= 100, Array(b[0..<4]) == Array(" PFX".utf8) else { throw XboxXVD.damaged("its segment metadata has no header") }
        let headerLength = Int(r.u32(12)), count = Int(r.u32(16))
        guard headerLength >= 100, count <= 1 << 22, headerLength <= b.count, count * 16 <= b.count - headerLength else {
            throw XboxXVD.damaged("its segment metadata lists \(count) segments")
        }
        let paths = headerLength + count * 16
        var out: [XboxSegment] = []
        out.reserveCapacity(count)
        for n in 0..<count {
            let o = headerLength + n * 16
            let flags = r.u16(o), chars = Int(r.u16(o + 2)), offset = Int(r.u32(o + 4))
            guard offset <= b.count - paths, chars * 2 <= b.count - paths - offset else { throw XboxXVD.damaged("a segment's path is out of range") }
            out.append(XboxSegment(path: r.utf16(paths + offset, max: chars), size: r.u64(o + 8), flags: flags))
        }
        return out
    }
}

enum XboxXVD {
    static let page = 4096
    static let maxHashedPages: UInt64 = 170 * 170 * 170 * 170
    static func pages(_ bytes: UInt64) -> UInt64 { (bytes + UInt64(page) - 1) / UInt64(page) }
    static func damaged(_ why: String) -> ClientError { .verificationFailed("Xbox package is damaged: \(why)") }

    /// The first 24 bytes of the page's SHA-256: a hash tree entry, or the first 20
    /// of it for a page in an encrypted region (the last four are its data unit).
    static func pageHash(_ page: UnsafeRawBufferPointer) -> [UInt8] {
        var s = SHA256Stream()
        s.update(page)
        return Array(s.finalize()[0..<24])
    }
}

/// Bounds are the caller's: every offset here has been range-checked against `b`.
struct XboxBytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }
    func u16(_ o: Int) -> UInt16 { b.readLE16(at: o) }
    func u32(_ o: Int) -> UInt32 { b.readLE32(at: o) }
    func u64(_ o: Int) -> UInt64 { b.readLE64(at: o) }
    /// A Windows GUID: three little-endian fields, then eight bytes as they are.
    func guid(_ o: Int) -> UUID {
        UUID(uuid: (b[o + 3], b[o + 2], b[o + 1], b[o], b[o + 5], b[o + 4], b[o + 7], b[o + 6],
                    b[o + 8], b[o + 9], b[o + 10], b[o + 11], b[o + 12], b[o + 13], b[o + 14], b[o + 15]))
    }
    /// Up to `max` UTF-16LE code units, stopping at a NUL.
    func utf16(_ o: Int, max: Int) -> String {
        var units: [UInt16] = []
        var i = 0
        while i < max, o + 2 * i + 1 < b.count {
            let u = u16(o + 2 * i)
            if u == 0 { break }
            units.append(u); i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }
}
