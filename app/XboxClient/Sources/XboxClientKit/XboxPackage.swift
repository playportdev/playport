// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/msixvc/src/{xvd.rs
// (parse, parse_user_package_files, parse_segment_metadata,
// parse_ntfs_segment_metadata), hash_tree.rs} and crates/xodus-cli/src/commands/
// streaming.rs (the metadata prefix, then file by file); translated to Swift by the
// Playport authors, 2026-10-30. Modified: every page is checked against the hash tree
// before it is used or written; the file list is the NTFS drive's, with
// SegmentMetadata.bin's keep-encrypted flags when the package has it.
import Foundation
import ContentKit

/// A file the package installs. Its bytes are `size` from `offset`; a kept-encrypted
/// file is written as its whole encrypted pages.
public struct XboxPackageFile: Codable, Sendable, Equatable {
    /// `/`-separated, relative to the game's folder.
    public let path: String
    public let size: UInt64
    /// Absolute in the package, page-aligned; nil for an empty file.
    public let offset: UInt64?
    public let keepEncrypted: Bool
    /// The XVC region its pages are in, and the key that region is encrypted with
    /// (nil: an unencrypted region).
    public let region: UInt32?
    public let keyID: UUID?

    public var pages: UInt64 { XboxXVD.pages(size) }
    /// What lands on disk: the plaintext, or the kept file's whole pages.
    public var installedSize: UInt64 { keepEncrypted ? pages * UInt64(XboxXVD.page) : size }
}

/// A package's metadata, checked against its hash tree: header, regions, keys and
/// the files to install. Built from the metadata prefix (every byte before the first
/// encrypted region: header, hash tree, user data, XVC information, the drive's GPT
/// and NTFS metadata), which the install keeps beside its stage.
public struct XboxPackage: Sendable {
    /// The XVD's VDUID: the content ID Microsoft licenses and lists packages by.
    public let contentID: UUID
    public let version: String
    /// The package's full name (TeamCherry.15373CD61C66B_1.5.12620.0_x64__y4jvztpgccj42).
    public let packageName: String
    public let size: UInt64
    public let files: [XboxPackageFile]
    /// Whether SegmentMetadata.bin chose the kept-encrypted files (else: every `.exe`).
    public let segmentMetadata: Bool
    /// MicrosoftGame.config from the user data, when the package carries it.
    public let gameConfig: [UInt8]?
    /// Bytes the metadata prefix covers.
    public let prefixBytes: UInt64
    /// The XVC's key GUIDs the files' regions use (a licence must carry each).
    public var keyIDs: Set<UUID> { Set(files.compactMap(\.keyID)) }

    let header: XboxXVDHeader
    let layout: XboxXVDLayout
    let regions: [XboxXVCRegion]
    let tree: XboxPackageTree

    /// Reads and checks the metadata in `prefix` (the package's first `prefixBytes`):
    /// the header signed by one of `trust`'s keys, then the hash tree from its top hash down.
    public static func load(prefix: URL, trust: XboxXVDTrust = .retail) throws -> XboxPackage {
        let file = try XboxLocalFile(prefix)
        return try load(read: { try file.read($0, $1) }, available: file.size, file: file, trust: trust)
    }

    static func load(read: @escaping @Sendable (UInt64, Int) throws -> [UInt8], available: UInt64, file: XboxLocalFile?,
                     trust: XboxXVDTrust) throws -> XboxPackage {
        let page = UInt64(XboxXVD.page)
        guard available >= UInt64(XboxXVDHeader.size) else { throw XboxXVD.damaged("its header is cut short") }
        let headerBytes = try read(0, XboxXVDHeader.size)
        let header = try XboxXVDHeader.parse(headerBytes)
        try XboxXVDSignature.verify(headerBytes, trust: trust)
        let layout = XboxXVDLayout(header)
        guard available >= layout.drive * page else { throw XboxXVD.damaged("its metadata is cut short") }
        let tree = try XboxPackageTree(header: header, layout: layout, read: read)
        let verified = XboxVerifiedReader(tree: tree, read: read, available: available)
        let info = try XboxXVCInfo.parse(verified.read(layout.xvcInfo * page, Int(header.xvcDataLength)), packagePages: layout.end)
        tree.encrypted = info.regions.filter { $0.keyIndex != nil }.map { ($0.start, $0.end) }
        let prefixPages = Self.prefixPages(info, layout)
        guard available >= prefixPages * page else { throw XboxXVD.damaged("its metadata is cut short") }
        let user = try XboxUserData.files(verified.read(layout.userData * page, Int(header.userDataLength)))
        let sector = header.volumeFlags & (1 << 3) != 0 ? 512 : 4096
        let ntfs = try XboxNTFS.files(read: { try verified.read($0, $1) }, drive: layout.drive * page, driveSize: header.driveSize, sector: sector)

        // SegmentMetadata.bin names the kept-encrypted files; without it every .exe is (Xodus).
        var keep: [String: XboxSegment]?
        if let raw = user.files.first(where: { $0.key.lowercased() == "segmentmetadata.bin" })?.value {
            var byPath: [String: XboxSegment] = [:]
            for s in try XboxSegmentMetadata.parse(raw) { byPath[s.path.replacingOccurrences(of: "\\", with: "/").lowercased()] = s }
            keep = byPath
        }
        var files: [XboxPackageFile] = [], seen = Set<String>()
        for f in ntfs {
            try WindowsName.check(path: f.path.split(separator: "/").map(String.init), seen: &seen)
            var region: XboxXVCRegion?
            if let offset = f.offset {
                guard offset % page == 0 else { throw ClientError.unsupported("Xbox package file \(f.path) is not page-aligned") }
                let first = offset / page, count = max(XboxXVD.pages(f.size), 1)
                guard first >= layout.userData, first + count <= layout.end else { throw XboxXVD.damaged("\(f.path) lies outside the drive") }
                region = info.regions.first { first >= $0.start && first < $0.end && $0.keyIndex != nil }
                if let r = region, first + count > r.end { throw XboxXVD.damaged("\(f.path) runs out of its region") }
                if region == nil, info.regions.contains(where: { $0.keyIndex != nil && $0.start < first + count && $0.end > first }) {
                    throw XboxXVD.damaged("\(f.path) runs into an encrypted region")
                }
            }
            let segment = keep?[f.path.lowercased()]
            if let segment, segment.size != f.size { throw XboxXVD.damaged("\(f.path) has two sizes") }
            let flagged = keep == nil ? f.path.lowercased().hasSuffix(".exe") : (segment?.flags ?? 0) & XboxSegment.keepEncryptedOnDisk != 0
            files.append(XboxPackageFile(path: f.path, size: f.size, offset: f.offset, keepEncrypted: region != nil && flagged && f.size > 0,
                                         region: region?.id, keyID: region.flatMap { r in r.keyIndex.flatMap { info.keys[$0] } }))
        }
        guard !files.isEmpty else { throw XboxXVD.damaged("its drive has no files") }
        let config = user.files.first { $0.key.lowercased() == "microsoftgame.config" }?.value
        return XboxPackage(contentID: header.vduid, version: header.version, packageName: user.packageName, size: layout.end * page,
                           files: files, segmentMetadata: keep != nil, gameConfig: config, prefixBytes: prefixPages * page,
                           header: header, layout: layout, regions: info.regions, tree: tree)
    }

    /// Everything before the first encrypted region (where the drive's NTFS metadata is).
    static func prefixPages(_ info: XboxXVCInfo, _ layout: XboxXVDLayout) -> UInt64 {
        let firstEncrypted = info.regions.filter { $0.keyIndex != nil && $0.count > 0 }.map(\.start).min() ?? layout.end
        return max(min(firstEncrypted, layout.end), layout.drive)
    }

    /// The level-0 entries (hash, and data unit for an encrypted page) of `count`
    /// pages from package page `first`, each level-0 page checked first.
    func entries(_ first: UInt64, _ count: Int, read: (UInt64, Int) throws -> [UInt8]) throws -> [[UInt8]] {
        try tree.entries(first, count, read: read)
    }
}

/// The hash tree, checked from the header's top hash down: the top page at load, every
/// lower page (levels 2, 1, 0) the first time a lookup needs it. Verified pages above
/// level 0 stay in memory (level 1 is 0.6% of the hash tree); level-0 pages are read again.
final class XboxPackageTree: @unchecked Sendable {
    let header: XboxXVDHeader
    let layout: XboxXVDLayout
    /// Encrypted regions' page ranges: their entries hash 20 bytes and carry a data unit.
    var encrypted: [(UInt64, UInt64)] = []
    private let lock = NSLock()
    private var upper: [Int: [UInt64: [UInt8]]] = [:]

    init(header: XboxXVDHeader, layout: XboxXVDLayout, read: (UInt64, Int) throws -> [UInt8]) throws {
        self.header = header; self.layout = layout
        _ = try page(level: layout.hashTree.top, 0, read: read)
    }

    func isEncrypted(_ page: UInt64) -> Bool { encrypted.contains { page >= $0.0 && page < $0.1 } }

    /// Page `p` of hash-tree `level`, checked against its entry one level up (the top page against the header).
    func page(level: Int, _ p: UInt64, read: (UInt64, Int) throws -> [UInt8]) throws -> [UInt8] {
        let t = layout.hashTree
        guard level <= t.top, p < t.levelPages(level) else { throw XboxXVD.damaged("a page is outside its hash tree") }
        if level > 0, let cached = lock.withLock({ upper[level]?[p] }) { return cached }
        let bytes = try read(t.pageOffset(level: level, p, treeStart: layout.hashTreeStart), XboxXVD.page)
        if level == t.top {
            guard p == 0, SHA256Stream.hash(bytes) == header.topHash else { throw XboxXVD.damaged("its hash tree doesn't match its header") }
        } else {
            let parent = try page(level: level + 1, p / 170, read: read)
            let o = Int(p % 170) * 24
            guard bytes.withUnsafeBytes({ XboxXVD.pageHash($0) }).elementsEqual(parent[o..<(o + 24)]) else {
                throw XboxXVD.damaged("its hash tree level \(level) page \(p) is wrong")
            }
        }
        if level > 0 { lock.withLock { upper[level, default: [:]][p] = bytes } }
        return bytes
    }

    func entries(_ first: UInt64, _ count: Int, read: (UInt64, Int) throws -> [UInt8]) throws -> [[UInt8]] {
        guard first >= layout.userData, first + UInt64(count) <= layout.end else { throw XboxXVD.damaged("a page is outside its hash tree") }
        var out: [[UInt8]] = [], cached: (UInt64, [UInt8])?
        out.reserveCapacity(count)
        for n in 0..<UInt64(count) {
            let i = first + n - layout.userData
            let p = i / 170
            if cached?.0 != p { cached = (p, try page(level: 0, p, read: read)) }
            let o = Int(i % 170) * 24
            out.append(Array(cached!.1[o..<(o + 24)]))
        }
        return out
    }

    /// Whether a package page matches its level-0 entry.
    func matches(_ page: UnsafeRawBufferPointer, number: UInt64, entry: [UInt8]) -> Bool {
        let h = XboxXVD.pageHash(page)
        return isEncrypted(number) ? h[0..<20].elementsEqual(entry[0..<20]) : h.elementsEqual(entry)
    }
}

/// Reads of metadata pages, each checked against the hash tree before it is returned.
final class XboxVerifiedReader: @unchecked Sendable {
    let tree: XboxPackageTree
    let raw: (UInt64, Int) throws -> [UInt8]
    let available: UInt64
    private var good = Set<UInt64>()

    init(tree: XboxPackageTree, read: @escaping (UInt64, Int) throws -> [UInt8], available: UInt64) {
        self.tree = tree; self.raw = read; self.available = available
    }

    func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        let page = UInt64(XboxXVD.page)
        guard offset <= available, UInt64(count) <= available - offset else { throw XboxXVD.damaged("its metadata lies past the metadata it lists") }
        let first = offset / page, last = (offset + UInt64(count) - 1) / page
        let span = try raw(first * page, Int(last - first + 1) * Int(page))
        let todo = (first...last).filter { !good.contains($0) }
        if let start = todo.first {
            let entries = try tree.entries(start, Int(todo.last! - start + 1), read: raw)
            for n in todo {
                let o = Int((n - first) * page)
                let ok = span.withUnsafeBytes { tree.matches(UnsafeRawBufferPointer(rebasing: $0[o..<(o + Int(page))]), number: n, entry: entries[Int(n - start)]) }
                guard ok else { throw XboxXVD.damaged("page \(n) doesn't match its hash") }
                good.insert(n)
            }
        }
        let skip = Int(offset - first * page)
        return Array(span[skip..<(skip + count)])
    }
}

extension XboxPackage {
    /// Fetches the metadata prefix into `url` (resuming a partial one), then loads it. The
    /// header comes first and must be signed by one of `trust`'s keys before more is fetched.
    public static func fetch(_ bytes: any XboxPackageBytes, into url: URL, trust: XboxXVDTrust = .retail, log: Logger = .silent,
                             progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> XboxPackage {
        let page = UInt64(XboxXVD.page)
        try InstallFS.makeDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var have = (try handle.seekToEnd()) / page * page
        try handle.truncate(atOffset: have)
        func fill(to end: UInt64, total: UInt64) async throws {
            while have < end {
                try Task.checkCancellation()
                let n = Int(min(end - have, 4 << 20))
                let chunk = try await bytes.read(have, n)
                try handle.seek(toOffset: have)
                try handle.write(contentsOf: Data(chunk))
                have += UInt64(n)
                progress(have, total)
            }
            try handle.synchronize()
        }
        guard bytes.size >= UInt64(XboxXVDHeader.size) else { throw XboxXVD.damaged("it is smaller than its header") }
        try await fill(to: UInt64(XboxXVDHeader.size), total: UInt64(XboxXVDHeader.size))
        let headerBytes = Array(try handle.readFrom(0, XboxXVDHeader.size))
        let header = try XboxXVDHeader.parse(headerBytes)
        try XboxXVDSignature.verify(headerBytes, trust: trust)
        let layout = XboxXVDLayout(header)
        guard layout.end * page == bytes.size else { throw XboxXVD.damaged("its size doesn't match its header") }
        try await fill(to: layout.drive * page, total: layout.drive * page)
        let info = try XboxXVCInfo.parse(Array(try handle.readFrom(layout.xvcInfo * page, Int(header.xvcDataLength))), packagePages: layout.end)
        let end = prefixPages(info, layout) * page
        log.info("xbox", "package metadata: \(end) bytes before its encrypted region")
        try await fill(to: end, total: end)
        return try load(prefix: url, trust: trust)
    }
}

extension FileHandle {
    fileprivate func readFrom(_ offset: UInt64, _ count: Int) throws -> Data {
        try seek(toOffset: offset)
        let data = try read(upToCount: count) ?? Data()
        guard data.count == count else { throw XboxXVD.damaged("its metadata is cut short") }
        return data
    }
}
