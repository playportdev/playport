// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// A 16-byte key (EKey or CKey) packed into two integers, most significant byte first, so that
/// the millions of keys an install plans take no heap allocation each and sort as their bytes do.
public struct PackedKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hi: UInt64
    public let lo: UInt64

    public init(_ bytes: some Collection<UInt8>) {
        precondition(bytes.count == 16)
        var hi: UInt64 = 0, lo: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            if i < 8 { hi = hi << 8 | UInt64(b) } else { lo = lo << 8 | UInt64(b) }
        }
        self.hi = hi
        self.lo = lo
    }

    public init(_ hash: TACTHash) { self.init(hash.bytes) }

    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: hi >> (56 - 8 * UInt64($0))) }
            + (0..<8).map { UInt8(truncatingIfNeeded: lo >> (56 - 8 * UInt64($0))) }
    }

    public var hash: TACTHash { TACTHash(bytes: bytes) }
    public var description: String { bytes.hex }

    /// The first 9 bytes, which the local store's `.idx` journals key by.
    var key9: (UInt64, UInt8) { (hi, UInt8(truncatingIfNeeded: lo >> 56)) }

    public static func < (a: PackedKey, b: PackedKey) -> Bool { (a.hi, a.lo) < (b.hi, b.lo) }
}

/// A CDN index (`{archive}.index`, the file index and the archive group): blocks of entries
/// `key | size | offset` sorted by key, a table of each block's last key and MD5, and a footer
/// whose MD5 is the index's name. Every hash is checked on load.
public struct ArchiveIndex: Sendable {
    /// Where an object is: the archive it is in (its place in the CDN config's list; nil for an
    /// object the file index lists, which is fetched whole) and its range there.
    public struct Entry: Sendable, Equatable {
        public let key: PackedKey
        public let size: UInt32
        public let archive: Int?
        public let offset: UInt32
    }

    static let footerSize = 28
    static let blockSize = 4096

    /// 4 for an archive's index, 0 for the file index (loose objects), 6 for the archive group
    /// (a 2-byte archive number, then the offset).
    public let offsetBytes: Int
    public let count: Int
    let bytes: [UInt8]
    let blocks: Int

    public init(_ bytes: [UInt8], name: TACTHash?) throws {
        let what = "archive index \(name?.hex ?? "")"
        guard bytes.count >= Self.footerSize else { throw BattleNetError.damaged("\(what): \(bytes.count) bytes") }
        let footer = Array(bytes[(bytes.count - Self.footerSize)...])
        if let name, MD5.hash(footer) != name.bytes { throw BattleNetError.damaged("\(what): footer does not hash to its name") }
        guard Array(MD5.hash(Array(footer[8..<20]) + [UInt8](repeating: 0, count: 8)).prefix(8)) == Array(footer[20..<28]) else {
            throw BattleNetError.damaged("\(what): footer hash")
        }
        guard footer[8] == 1, footer[11] == 4, footer[13] == 4, footer[14] == 16, footer[15] == 8 else {
            throw BattleNetError.unsupported("\(what): format \(footer[8..<16].map { String($0) }.joined(separator: ","))")
        }
        offsetBytes = Int(footer[12])
        guard [0, 4, 5, 6].contains(offsetBytes) else { throw BattleNetError.unsupported("\(what): \(offsetBytes)-byte offsets") }
        count = Int(footer.readLE32(at: 16))
        let body = bytes.count - Self.footerSize
        guard body % (Self.blockSize + 24) == 0 else { throw BattleNetError.damaged("\(what): \(body) bytes before the footer") }
        blocks = body / (Self.blockSize + 24)
        let entrySize = 20 + offsetBytes
        guard count <= blocks * (Self.blockSize / entrySize) else { throw BattleNetError.damaged("\(what): \(count) entries in \(blocks) blocks") }
        let toc = Array(bytes[(blocks * Self.blockSize)..<body])
        guard Array(MD5.hash(toc).prefix(8)) == Array(footer[0..<8]) else { throw BattleNetError.damaged("\(what): table of contents hash") }
        for b in 0..<blocks {
            let block = Array(bytes[(b * Self.blockSize)..<((b + 1) * Self.blockSize)])
            let at = blocks * 16 + b * 8
            guard Array(MD5.hash(block).prefix(8)) == Array(toc[at..<(at + 8)]) else {
                throw BattleNetError.damaged("\(what): block \(b) does not match its hash")
            }
        }
        self.bytes = bytes
        var seen = 0
        try walk { _, _, field in
            // An archive's offset is 32 bits; a 5-byte field past that would be cut short.
            guard offsetBytes != 5 || field <= UInt64(UInt32.max) else { throw BattleNetError.damaged("\(what): offset \(field) past 32 bits") }
            seen += 1
        }
        guard seen == count else { throw BattleNetError.damaged("\(what): \(seen) entries, the footer says \(count)") }
    }

    /// Every entry's key, size and offset field (the archive number and offset for 6 bytes), in
    /// key order.
    private func walk(_ body: (PackedKey, UInt32, UInt64) throws -> Void) rethrows {
        let entrySize = 20 + offsetBytes
        for b in 0..<blocks {
            var at = b * Self.blockSize
            let end = at + Self.blockSize - entrySize
            while at <= end {
                if bytes[at..<(at + 16)].allSatisfy({ $0 == 0 }) { break }
                try body(PackedKey(bytes[at..<(at + 16)]), UInt32(ByteReader.be(bytes, at: at + 16, 4)), ByteReader.be(bytes, at: at + 20, offsetBytes))
                at += entrySize
            }
        }
    }

    /// Every entry, in key order. `archive` is the entry's own (archive group) or `archive`.
    public func forEach(archive: Int? = nil, _ body: (Entry) throws -> Void) rethrows {
        try walk { key, size, field in
            switch offsetBytes {
            case 0: try body(Entry(key: key, size: size, archive: nil, offset: 0))
            case 6: try body(Entry(key: key, size: size, archive: Int(field >> 32), offset: UInt32(truncatingIfNeeded: field)))
            default: try body(Entry(key: key, size: size, archive: archive, offset: UInt32(field)))
            }
        }
    }

    /// An index in the CDN's format over `entries` (sorted by key): with 6-byte offsets it is the
    /// archive group the local store keeps beside the archive indexes.
    public static func build(_ entries: [Entry], offsetBytes: Int) -> [UInt8] {
        let entrySize = 20 + offsetBytes
        let perBlock = blockSize / entrySize
        var data = [UInt8](), lastKeys = [UInt8](), hashes = [UInt8]()
        for start in stride(from: 0, to: entries.count, by: perBlock) {
            var block = [UInt8]()
            block.reserveCapacity(blockSize)
            for e in entries[start..<min(entries.count, start + perBlock)] {
                block += e.key.bytes
                block += (0..<4).map { UInt8(truncatingIfNeeded: e.size >> (24 - 8 * UInt32($0))) }
                let field: UInt64 = offsetBytes == 6 ? UInt64(e.archive ?? 0) << 32 | UInt64(e.offset) : UInt64(e.offset)
                block += (0..<offsetBytes).map { UInt8(truncatingIfNeeded: field >> (8 * UInt64(offsetBytes - 1 - $0))) }
            }
            lastKeys += entries[min(entries.count, start + perBlock) - 1].key.bytes
            block += [UInt8](repeating: 0, count: blockSize - block.count)
            hashes += MD5.hash(block).prefix(8)
            data += block
        }
        let toc = lastKeys + hashes
        var footer = Array(MD5.hash(toc).prefix(8)) + [1, 0, 0, 4, UInt8(offsetBytes), 4, 16, 8]
        footer.appendLE(UInt32(entries.count))
        footer += MD5.hash(Array(footer[8..<20]) + [UInt8](repeating: 0, count: 8)).prefix(8)
        return data + toc + footer
    }
}

/// The download manifest ("DL"): every object of the build's store with its EKey, encoded size
/// and priority, then the tags (after the entries). Versions 1 to 3; kept as bytes, as retail
/// lists about 1.9 million objects.
public struct DownloadManifest: Sendable {
    public let tags: [TACTTag]
    public let count: Int
    let entrySize: Int
    let entries: [UInt8]

    public init(_ bytes: [UInt8]) throws {
        let what = "download manifest"
        var r = ByteReader(bytes, what: what)
        guard try r.take(2).elementsEqual("DL".utf8) else { throw BattleNetError.damaged("\(what): no DL magic") }
        let version = try r.u8()
        guard (1...3).contains(version) else { throw BattleNetError.unsupported("\(what) version \(version)") }
        let keySize = Int(try r.u8())
        guard keySize == 16 else { throw BattleNetError.damaged("\(what): key size \(keySize)") }
        let checksum = try r.u8()
        guard checksum <= 1 else { throw BattleNetError.damaged("\(what): checksum flag \(checksum)") }
        count = Int(try r.be(4))
        let tagCount = Int(try r.be(2))
        var flagBytes = 0
        if version >= 2 { flagBytes = Int(try r.u8()) }
        if version >= 3 { try r.skip(4) }
        entrySize = keySize + 5 + 1 + (checksum == 1 ? 4 : 0) + flagBytes
        try r.need(count * entrySize)
        entries = Array(bytes[r.pos..<(r.pos + count * entrySize)])
        r.pos += count * entrySize
        tags = try TACTTag.read(&r, count: tagCount, entries: count)
        guard r.remaining == 0 else { throw BattleNetError.damaged("\(what): \(r.remaining) bytes after the tags") }
    }

    public func ekey(_ i: Int) -> PackedKey { PackedKey(entries[(i * entrySize)..<(i * entrySize + 16)]) }

    public func encodedSize(_ i: Int) -> UInt64 {
        (16..<21).reduce(UInt64(0)) { $0 << 8 | UInt64(entries[i * entrySize + $1]) }
    }

    /// The indexes of the entries `query` selects, in manifest order (priority order).
    public func select(_ query: TagQuery) throws -> [Int] {
        let mask = try query.select(tags, entries: count, what: "download manifest")
        var out = [Int]()
        for (b, m) in mask.enumerated() where m != 0 {
            for bit in 0..<8 where m & (0x80 >> UInt8(bit)) != 0 { out.append(b * 8 + bit) }
        }
        return out
    }
}
