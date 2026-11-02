// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// A manifest tag: a name, a type (1 platform, 2 architecture, 3 locale, 4 region, 5 category,
/// 0x4000 alternate) and a bitmask over the manifest's entries, most significant bit first.
public struct TACTTag: Sendable, Equatable {
    public let name: String
    public let type: UInt16
    let mask: [UInt8]

    public func has(_ entry: Int) -> Bool { mask[entry >> 3] & (0x80 >> UInt8(entry & 7)) != 0 }

    static func read(_ r: inout ByteReader, count: Int, entries: Int) throws -> [TACTTag] {
        let bytes = (entries + 7) / 8
        return try (0..<count).map { _ in
            let name = try r.cString()
            let type = UInt16(try r.be(2))
            return TACTTag(name: name, type: type, mask: Array(try r.take(bytes)))
        }
    }
}

/// Which entries of a manifest to take: the named tags are ORed within their type and ANDed across
/// types, then the `excluded` tags are taken away. A type no named tag has is not constrained.
public struct TagQuery: Sendable, Equatable {
    public var tags: [String]
    public var excluded: [String]

    public init(tags: [String], excluded: [String] = []) {
        self.tags = tags
        self.excluded = excluded
    }

    /// The Windows x64 client (decision 0177) in one locale for the given regions: platform and
    /// x64 tags from the product config, both content categories, and not the Alternate
    /// (censored) data. Nothing of the ARM64 client: its tags are not asked for.
    public static func client(_ product: ProductConfig, locale: String, regions: [StoreRegion]) -> TagQuery {
        TagQuery(tags: product.platformTags + product.x64Tags + [locale] + regions.map(\.tag) + ["speech", "text"],
                 excluded: ["Alternate"])
    }

    /// The selected entries as a bitmask (same layout as a tag's). A named tag the manifest does
    /// not have is an error, so a wrong locale never selects everything or nothing silently.
    func select(_ tags: [TACTTag], entries: Int, what: String) throws -> [UInt8] {
        let bytes = (entries + 7) / 8
        var byType = [UInt16: [UInt8]]()
        for name in self.tags {
            guard let t = tags.first(where: { $0.name == name }) else {
                throw BattleNetError.unsupported("\(what) has no tag '\(name)'")
            }
            byType[t.type] = zip(byType[t.type] ?? [UInt8](repeating: 0, count: bytes), t.mask).map { $0 | $1 }
        }
        var selected = [UInt8](repeating: 0xFF, count: bytes)
        for mask in byType.values { selected = zip(selected, mask).map { $0 & $1 } }
        for name in excluded {
            guard let t = tags.first(where: { $0.name == name }) else { continue }
            selected = zip(selected, t.mask).map { $0 & ~$1 }
        }
        if entries & 7 != 0 { selected[bytes - 1] &= ~(0xFF >> UInt8(entries & 7)) }
        return selected
    }
}

/// The install manifest ("IN"): the files that go in the product folder as plain files (the
/// executables, their DLLs), each with its CKey, decoded size and tags.
public struct InstallManifest: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public let name: String
        public let ckey: TACTHash
        public let size: UInt64
    }

    public let tags: [TACTTag]
    public let files: [File]

    public init(_ bytes: [UInt8]) throws {
        var r = ByteReader(bytes, what: "install manifest")
        guard try r.take(2).elementsEqual("IN".utf8) else { throw BattleNetError.damaged("install manifest: no IN magic") }
        let version = try r.u8()
        guard version == 1 else { throw BattleNetError.unsupported("install manifest version \(version)") }
        let hashSize = Int(try r.u8())
        guard hashSize == 16 else { throw BattleNetError.damaged("install manifest: hash size \(hashSize)") }
        let tagCount = Int(try r.be(2)), count = Int(try r.be(4))
        // Each entry takes at least a NUL, a key and a size: a count past that is damage.
        try r.need(count * (1 + 16 + 4))
        tags = try TACTTag.read(&r, count: tagCount, entries: count)
        var files = [File]()
        files.reserveCapacity(count)
        for _ in 0..<count {
            let name = try r.cString()
            let ckey = TACTHash(bytes: Array(try r.take(16)))
            files.append(File(name: name, ckey: ckey, size: try r.be(4)))
        }
        guard r.remaining == 0 else { throw BattleNetError.damaged("install manifest: \(r.remaining) bytes after the last file") }
        self.files = files
    }

    /// Whether the file at `index` carries every tag in `names`.
    public func file(_ index: Int, has names: [String]) -> Bool {
        names.allSatisfy { n in tags.contains { $0.name == n && $0.has(index) } }
    }

    public func select(_ query: TagQuery) throws -> [File] { try selectIndexes(query).map { files[$0] } }

    /// The indexes of the files `query` selects, in manifest order.
    public func selectIndexes(_ query: TagQuery) throws -> [Int] {
        let mask = try query.select(tags, entries: files.count, what: "install manifest")
        return files.indices.filter { mask[$0 >> 3] & (0x80 >> UInt8($0 & 7)) != 0 }
    }
}

/// The size manifest ("DS"): every stored object's encoded size with the download manifest's
/// tags, so the download for a tag query is a sum over a bitmask. Kept as bytes, not per-entry
/// values (retail lists about 1.5 million objects).
public struct SizeManifest: Sendable {
    public let tags: [TACTTag]
    public let count: Int
    public let totalSize: UInt64
    let keySize: Int
    let entries: [UInt8]

    public init(_ bytes: [UInt8]) throws {
        var r = ByteReader(bytes, what: "size manifest")
        guard try r.take(2).elementsEqual("DS".utf8) else { throw BattleNetError.damaged("size manifest: no DS magic") }
        let version = try r.u8()
        guard version == 1 else { throw BattleNetError.unsupported("size manifest version \(version)") }
        keySize = Int(try r.u8())
        guard (1...16).contains(keySize) else { throw BattleNetError.damaged("size manifest: key size \(keySize)") }
        count = Int(try r.be(4))
        let tagCount = Int(try r.be(2))
        totalSize = try r.be(5)
        try r.need(count * (keySize + 4))
        tags = try TACTTag.read(&r, count: tagCount, entries: count)
        guard r.remaining == count * (keySize + 4) else {
            throw BattleNetError.damaged("size manifest: \(r.remaining) bytes for \(count) entries")
        }
        entries = Array(bytes[r.pos...])
    }

    /// The encoded size of entry `i`.
    public func encodedSize(_ i: Int) -> UInt64 {
        let at = i * (keySize + 4) + keySize
        return ByteReader.be(entries, at: at, 4)
    }

    /// The bytes to download for `query`, and how many objects.
    public func total(_ query: TagQuery) throws -> (bytes: UInt64, objects: Int) {
        let mask = try query.select(tags, entries: count, what: "size manifest")
        var bytes: UInt64 = 0, objects = 0
        for (b, m) in mask.enumerated() where m != 0 {
            for bit in 0..<8 where m & (0x80 >> UInt8(bit)) != 0 {
                bytes += encodedSize(b * 8 + bit)
                objects += 1
            }
        }
        return (bytes, objects)
    }
}

/// The encoding table ("EN"): CKey → decoded size and EKeys, and EKey → encoding spec and encoded
/// size. Kept as its pages' bytes; lookups binary-search the page index, then scan one page.
public struct EncodingTable: Sendable {
    public struct Content: Sendable, Equatable {
        public let decodedSize: UInt64
        public let ekeys: [TACTHash]
    }

    public struct Encoded: Sendable, Equatable {
        public let spec: String
        public let encodedSize: UInt64
    }

    let bytes: [UInt8]
    let ckeySize: Int, ekeySize: Int
    public let specs: [String]
    let cePageSize: Int, esPageSize: Int
    /// (first key, page offset) per page.
    let cePages: [([UInt8], Int)]
    let esPages: [([UInt8], Int)]

    public init(_ bytes: [UInt8]) throws {
        let what = "encoding table"
        var r = ByteReader(bytes, what: what)
        guard try r.take(2).elementsEqual("EN".utf8) else { throw BattleNetError.damaged("\(what): no EN magic") }
        let version = try r.u8()
        guard version == 1 else { throw BattleNetError.unsupported("\(what) version \(version)") }
        ckeySize = Int(try r.u8())
        ekeySize = Int(try r.u8())
        guard ckeySize == 16, ekeySize == 16 else { throw BattleNetError.damaged("\(what): key sizes \(ckeySize)/\(ekeySize)") }
        cePageSize = Int(try r.be(2)) * 1024
        esPageSize = Int(try r.be(2)) * 1024
        let ceCount = Int(try r.be(4)), esCount = Int(try r.be(4))
        guard cePageSize > 0, esPageSize > 0 else { throw BattleNetError.damaged("\(what): zero page size") }
        guard try r.u8() == 0 else { throw BattleNetError.damaged("\(what): flags") }
        let specSize = Int(try r.be(4))
        let specBytes = try r.take(specSize)
        specs = try specBytes.split(separator: 0, omittingEmptySubsequences: true).map {
            guard let s = String(validating: $0, as: UTF8.self) else { throw BattleNetError.damaged("\(what): spec is not UTF-8") }
            return s
        }
        func pages(_ count: Int, size: Int, keySize: Int, kind: String) throws -> [([UInt8], Int)] {
            try r.need(count * (keySize + 16))
            var index = [([UInt8], [UInt8])]()
            index.reserveCapacity(count)
            for _ in 0..<count { index.append((Array(try r.take(keySize)), Array(try r.take(16)))) }
            try r.need(count * size)
            let found = try index.enumerated().map { i, entry in
                let at = r.pos + i * size
                guard MD5.hash(Array(bytes[at..<(at + size)])) == entry.1 else {
                    throw BattleNetError.damaged("\(what): \(kind) page \(i) does not match its MD5")
                }
                return (entry.0, at)
            }
            r.pos += count * size
            return found
        }
        cePages = try pages(ceCount, size: cePageSize, keySize: ckeySize, kind: "content")
        esPages = try pages(esCount, size: esPageSize, keySize: ekeySize, kind: "encoded")
        self.bytes = bytes
    }

    /// The page whose first key is the last one not above `key`.
    static func page(_ pages: [([UInt8], Int)], for key: [UInt8]) -> Int? {
        var lo = 0, hi = pages.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key.lexicographicallyPrecedes(pages[mid].0) { hi = mid } else { lo = mid + 1 }
        }
        return lo == 0 ? nil : pages[lo - 1].1
    }

    public func content(_ ckey: TACTHash) -> Content? {
        guard let start = Self.page(cePages, for: ckey.bytes) else { return nil }
        var at = start
        let end = start + cePageSize
        while at + 6 + ckeySize <= end {
            let keys = Int(bytes[at])
            if keys == 0 { break }
            let next = at + 6 + ckeySize + keys * ekeySize
            guard next <= end else { break }
            if bytes[(at + 6)..<(at + 6 + ckeySize)].elementsEqual(ckey.bytes) {
                let size = ByteReader.be(bytes, at: at + 1, 5)
                let ekeys = (0..<keys).map { k in
                    TACTHash(bytes: Array(bytes[(at + 6 + ckeySize + k * ekeySize)..<(at + 6 + ckeySize + (k + 1) * ekeySize)]))
                }
                return Content(decodedSize: size, ekeys: ekeys)
            }
            at = next
        }
        return nil
    }

    public func encoded(_ ekey: TACTHash) -> Encoded? {
        guard let start = Self.page(esPages, for: ekey.bytes) else { return nil }
        let entry = ekeySize + 4 + 5
        var at = start
        while at + entry <= start + esPageSize {
            let key = bytes[at..<(at + ekeySize)]
            if key.allSatisfy({ $0 == 0 }) { break }
            if key.elementsEqual(ekey.bytes) {
                let spec = Int(ByteReader.be(bytes, at: at + ekeySize, 4))
                let size = ByteReader.be(bytes, at: at + ekeySize + 4, 5)
                guard spec < specs.count else { return nil }
                return Encoded(spec: specs[spec], encodedSize: size)
            }
            at += entry
        }
        return nil
    }
}
