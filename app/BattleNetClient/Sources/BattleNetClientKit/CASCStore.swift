// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// The game's local store (`Data/data`): `data.NNN` files of 30-byte local headers each followed
/// by an object exactly as the CDN serves it (BLTE, encrypted blocks too), and sixteen `.idx`
/// journals mapping the first 9 bytes of each EKey to its file, offset and size.
public enum CASC {
    /// A local header: the EKey byte-reversed, the size of header and object (LE), two flag
    /// bytes, then two checksums.
    public static let headerSize = 30
    /// Each data file starts with sixteen header-only entries, one per journal.
    public static let segmentHeaderSize = 16 * headerSize
    /// A data file's offsets are 30 bits.
    public static let maxDataFileSize: UInt64 = 1 << 30
    public static let buckets = 16

    /// The journal a key is in (seed 0); the data files' own headers use seed 1.
    public static func bucket(_ key: PackedKey, seed: Int = 0) -> Int {
        var x: UInt8 = 0
        for i in 0..<8 { x ^= UInt8(truncatingIfNeeded: key.hi >> (8 * UInt64(i))) }
        x ^= UInt8(truncatingIfNeeded: key.lo >> 56)
        return (Int((x & 0xF) ^ (x >> 4)) + seed) & 0xF
    }

    static let checksumTable: [UInt32] = [
        0x0493_96B8, 0x72A8_2A9B, 0xEE62_6CCA, 0x9917_754F, 0x15DE_40B1, 0xF5A8_A9B6, 0x421E_AC7E, 0xA9D5_5C9A,
        0x317F_D40C, 0x04FA_F80D, 0x3D6B_E971, 0x5293_3CFD, 0x27F6_4B7D, 0xC6F5_C11B, 0xD575_7E3A, 0x6C38_8745,
    ]

    /// The local header of an object of `size` bytes at `offset` in `data.{dataFile}`.
    public static func header(_ key: PackedKey, size: Int, dataFile: Int, offset: UInt32, flags: UInt16 = 0) -> [UInt8] {
        var h = Array(key.bytes.reversed())
        h.appendLE(UInt32(headerSize + size))
        h += [UInt8(truncatingIfNeeded: flags), UInt8(truncatingIfNeeded: flags >> 8)]
        h.appendLE(Lookup3.hashlittle(h[0..<0x16], 0x3D6B_E971))
        h += checksumB(h, dataFile: dataFile, offset: offset)
        return h
    }

    /// The second checksum: the header's first 0x1A bytes folded into four by their position in
    /// the data files, mixed with a table entry chosen by that position.
    static func checksumB(_ h: [UInt8], dataFile: Int, offset: UInt32) -> [UInt8] {
        let position = (offset & 0x3FFF_FFFF) | UInt32(dataFile & 3) << 30
        let mixed = checksumTable[Int((position &+ 0x1E) & 0xF)] ^ (position &+ 0x1E)
        let m = (0..<4).map { UInt8(truncatingIfNeeded: mixed >> (8 * UInt32($0))) }
        var folded: [UInt8] = [0, 0, 0, 0]
        let shift = Int(position & 3)
        for i in 0..<0x1A { folded[(i + shift) & 3] ^= h[i] }
        return (0..<4).map { j in
            let i = (j + 0x1A + shift) & 3
            return folded[i] ^ m[i]
        }
    }

    /// The EKey and object size a header at `offset` in `data.{dataFile}` names, or nil when it
    /// is damaged (either checksum).
    public static func readHeader(_ h: ArraySlice<UInt8>, dataFile: Int, offset: UInt32) -> (key: PackedKey, size: Int)? {
        guard h.count >= headerSize else { return nil }
        let b = Array(h.prefix(headerSize))
        guard b.readLE32(at: 0x16) == Lookup3.hashlittle(b[0..<0x16], 0x3D6B_E971),
              Array(b[0x1A..<0x1E]) == checksumB(b, dataFile: dataFile, offset: offset) else { return nil }
        let total = Int(b.readLE32(at: 0x10))
        guard total >= headerSize else { return nil }
        return (PackedKey(b[0..<16].reversed()), total - headerSize)
    }

    /// The keys of a data file's sixteen header-only entries: key `i` falls in journal `i` by the
    /// headers' seed, carries the data file's number in its second byte, and is otherwise fixed.
    public static func segmentKeys(dataFile: Int) -> [PackedKey] {
        let base = MD5.hash(Array("data/data".utf8))
        return (0..<buckets).map { slot in
            for first in 0...255 {
                let key = PackedKey([UInt8(first), UInt8(truncatingIfNeeded: dataFile)] + base[2..<9] + [UInt8](repeating: 0, count: 7))
                if bucket(key, seed: 1) == slot { return key }
            }
            preconditionFailure("every journal is reachable through the first byte")
        }
    }

    /// The 480 bytes a data file starts with.
    public static func segmentHeader(dataFile: Int) -> [UInt8] {
        segmentKeys(dataFile: dataFile).enumerated().flatMap { slot, key in
            header(key, size: 0, dataFile: dataFile, offset: UInt32(slot * headerSize), flags: 1)
        }
    }

    /// An object's place in the store, as a journal records it.
    public struct Location: Sendable, Equatable {
        public var key: PackedKey
        public var dataFile: Int
        public var offset: UInt32
        /// Header and object.
        public var size: UInt32

        public init(key: PackedKey, dataFile: Int, offset: UInt32, size: UInt32) {
            self.key = key
            self.dataFile = dataFile
            self.offset = offset
            self.size = size
        }
    }

    /// `{bucket}{generation}.idx`, both in hex.
    public static func journalName(bucket: Int, generation: UInt32) -> String {
        String(format: "%02x%08x.idx", bucket, generation)
    }

    /// The sixteen journals of `dataFiles` data files holding `objects`: each data file's own
    /// headers go in the journal their seed names. `existing` (by bucket) are a store's entries
    /// so far, kept (a language change adds to a store).
    public static func journals(objects: [Location], dataFiles: [Int], existing: [[Location]] = []) -> [[UInt8]] {
        var byBucket = existing.count == buckets ? existing : [[Location]](repeating: [], count: buckets)
        for l in objects { byBucket[bucket(l.key)].append(l) }
        for f in dataFiles {
            for (slot, key) in segmentKeys(dataFile: f).enumerated() {
                byBucket[slot].append(Location(key: key, dataFile: f, offset: UInt32(slot * headerSize), size: UInt32(headerSize)))
            }
        }
        return byBucket.enumerated().map { journal(bucket: $0.offset, $0.element) }
    }

    /// One journal (version 7): a hashed 16-byte header, the hashed entries sorted by key
    /// (`key9 | data file and offset, 5 bytes BE | size LE`), then an empty update section.
    public static func journal(bucket: Int, _ locations: [Location]) -> [UInt8] {
        var spec: [UInt8] = [7, 0, UInt8(bucket), 0, 4, 5, 9, 30]
        spec.appendLE(UInt64(0x40_0000_0000))
        var out = [UInt8]()
        out.appendLE(UInt32(16))
        out.appendLE(Lookup3.hashlittle2(spec[...], pc: 0, pb: 0).c)
        out += spec + [UInt8](repeating: 0, count: 8)
        var entries = [UInt8]()
        entries.reserveCapacity(locations.count * 18)
        var last: (UInt64, UInt8)?
        for l in locations.sorted(by: { $0.key.key9 < $1.key.key9 }) {
            if let last, last == l.key.key9 { continue }
            last = l.key.key9
            entries += l.key.bytes.prefix(9)
            let field = UInt64(l.dataFile) << 30 | UInt64(l.offset & 0x3FFF_FFFF)
            entries += (0..<5).map { UInt8(truncatingIfNeeded: field >> (8 * UInt64(4 - $0))) }
            entries.appendLE(l.size)
        }
        var pc: UInt32 = 0, pb: UInt32 = 0
        for at in stride(from: 0, to: entries.count, by: 18) {
            (pc, pb) = Lookup3.hashlittle2(entries[at..<(at + 18)], pc: pc, pb: pb)
        }
        out.appendLE(UInt32(entries.count))
        out.appendLE(pc)
        out += entries
        // The update section the game appends to: zeros, after a 4 KiB boundary, to at least
        // the size a fresh store's journal has.
        let sorted = (out.count + 0xFFF) & ~0xFFF
        out += [UInt8](repeating: 0, count: max(0x30000, sorted + 0x10000) - out.count)
        return out
    }

    /// A journal's bucket and entries, after its header and entry hashes are checked.
    public static func readJournal(_ bytes: [UInt8]) throws -> (bucket: Int, locations: [Location]) {
        let what = "store journal"
        guard bytes.count >= 0x28, bytes.readLE32(at: 0) == 16 else { throw BattleNetError.damaged("\(what): header") }
        guard Lookup3.hashlittle2(bytes[8..<24], pc: 0, pb: 0).c == bytes.readLE32(at: 4) else {
            throw BattleNetError.damaged("\(what): header hash")
        }
        guard bytes.readLE16(at: 8) == 7, Array(bytes[12..<16]) == [4, 5, 9, 30] else {
            throw BattleNetError.unsupported("\(what): version \(bytes.readLE16(at: 8)) spec \(bytes[12..<16].map { String($0) })")
        }
        let length = Int(bytes.readLE32(at: 0x20))
        guard length % 18 == 0, 0x28 + length <= bytes.count else { throw BattleNetError.damaged("\(what): \(length) entry bytes") }
        var pc: UInt32 = 0, pb: UInt32 = 0
        var locations = [Location]()
        locations.reserveCapacity(length / 18)
        for at in stride(from: 0x28, to: 0x28 + length, by: 18) {
            (pc, pb) = Lookup3.hashlittle2(bytes[at..<(at + 18)], pc: pc, pb: pb)
            let field = (0..<5).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[at + 9 + $1]) }
            locations.append(Location(key: PackedKey(Array(bytes[at..<(at + 9)]) + [UInt8](repeating: 0, count: 7)),
                                      dataFile: Int(field >> 30), offset: UInt32(field & 0x3FFF_FFFF),
                                      size: bytes.readLE32(at: at + 14)))
        }
        guard pc == bytes.readLE32(at: 0x24) else { throw BattleNetError.damaged("\(what): entries hash") }
        return (Int(bytes[10]), locations)
    }
}

/// `.build.info`, which the game reads its build, CDN and tags from: one row per product in the
/// install root, columns in the order Blizzard's installer writes them.
public struct BuildInfo: Sendable, Equatable {
    public static let header = ["Branch!STRING:0", "Active!DEC:1", "Build Key!HEX:16", "CDN Key!HEX:16", "Install Key!HEX:16",
                                "IM Size!DEC:4", "CDN Path!STRING:0", "CDN Hosts!STRING:0", "CDN Servers!STRING:0",
                                "Tags!STRING:0", "Armadillo!STRING:0", "Last Activated!STRING:0", "Version!STRING:0",
                                "Product!STRING:0"]

    public var region: StoreRegion
    public var buildKey: TACTHash
    public var cdnKey: TACTHash
    public var installKey: TACTHash
    public var installSize: UInt64
    public var cdnPath: String
    public var cdnHosts: [String]
    public var cdnServers: [String]
    /// The install's tags, speech and text groups: platform, machines, the region (`US?`), the
    /// locale and the category.
    public var tags: String
    public var version: String
    public var product: String

    public static func tags(platform: [String], machines: [String], region: StoreRegion, locale: String) -> String {
        let common = (platform + machines + ["\(region.tag)?", locale]).joined(separator: " ")
        return "\(common) speech?:\(common) text?"
    }

    public var text: String {
        let row = [region.rawValue, "1", buildKey.hex, cdnKey.hex, installKey.hex, "\(installSize)", cdnPath,
                   cdnHosts.joined(separator: " "), cdnServers.joined(separator: " "), tags, "", "", version, product]
        return Self.header.joined(separator: "|") + "\n" + row.joined(separator: "|") + "\n"
    }

    /// The active row for `product` in a `.build.info`.
    public static func read(_ bytes: [UInt8], product: String) throws -> BuildInfo {
        let what = ".build.info"
        let t = try PSVTable(bytes, what: what)
        func col(_ n: String) throws -> Int { try t.column(n, what: what) }
        let p = try col("Product"), active = try col("Active")
        guard let r = t.rows.first(where: { $0[p] == product && $0[active] == "1" }) else {
            throw BattleNetError.damaged("\(what): no active \(product) row")
        }
        func hash(_ n: String) throws -> TACTHash {
            guard let h = TACTHash(hex: r[try col(n)]) else { throw BattleNetError.damaged("\(what): \(n)") }
            return h
        }
        guard let region = StoreRegion(rawValue: r[try col("Branch")]) else { throw BattleNetError.damaged("\(what): branch") }
        func list(_ n: String) throws -> [String] { r[try col(n)].split(separator: " ").map(String.init) }
        return BuildInfo(region: region, buildKey: try hash("Build Key"), cdnKey: try hash("CDN Key"),
                         installKey: try hash("Install Key"), installSize: UInt64(r[try col("IM Size")]) ?? 0,
                         cdnPath: r[try col("CDN Path")], cdnHosts: try list("CDN Hosts"), cdnServers: try list("CDN Servers"),
                         tags: r[try col("Tags")], version: r[try col("Version")], product: product)
    }
}
