// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/msixvc/src/xvd.rs
// (download_file_http: a file's pages by HTTP range, decrypted unless kept
// encrypted, the last page cut to the file's size); translated to Swift by the
// Playport authors, 2026-10-30. Modified: a file's pages are split into ContentKit
// chunks of up to 1 MiB, each page is checked against its level-0 hash entry before
// it is decrypted, and a page that fails is fetched once more before the install stops.
import Foundation
import ContentKit

/// One chunk: up to 256 pages of one file from `offset`, and what to do with them.
struct XboxChunk: Equatable {
    enum Mode: UInt8 { case plain = 0, decrypt = 1, keep = 2 }
    static let maxPages = 256
    var offset: UInt64
    var pages: Int
    var mode: Mode
    var key: [UInt8] {
        var k = [UInt8](); k.appendLE(offset); k.appendLE(UInt32(pages)); k.append(mode.rawValue)
        return k
    }
    init(offset: UInt64, pages: Int, mode: Mode) { self.offset = offset; self.pages = pages; self.mode = mode }
    init(_ key: [UInt8]) throws {
        guard key.count == 13, let mode = Mode(rawValue: key[12]) else { throw ClientError.protocolChanged("not an Xbox chunk") }
        offset = key.readLE64(at: 0); pages = Int(key.readLE32(at: 8)); self.mode = mode
        guard pages >= 1, pages <= Self.maxPages, offset % UInt64(XboxXVD.page) == 0 else { throw ClientError.protocolChanged("not an Xbox chunk") }
    }
}

extension XboxPackage {
    /// Every file as ContentKit parts, in path order: a kept-encrypted file's whole
    /// pages, a plain file's bytes. Chunks are unique by package offset.
    public func plan() -> ContentPlan {
        var files: [ContentFile] = [], chunks: [ContentChunk] = [], directories = Set<String>()
        let page = UInt64(XboxXVD.page)
        for f in self.files.sorted(by: { $0.path < $1.path }) {
            var dir = f.path.split(separator: "/").dropLast()
            while !dir.isEmpty { directories.insert(dir.joined(separator: "/")); dir.removeLast() }
            var parts: [ContentPart] = []
            if let offset = f.offset, f.size > 0 {
                let mode: XboxChunk.Mode = f.keepEncrypted ? .keep : (f.region != nil ? .decrypt : .plain)
                var done: UInt64 = 0
                while done < f.pages {
                    let n = Int(min(f.pages - done, UInt64(XboxChunk.maxPages)))
                    let chunk = XboxChunk(offset: offset + done * page, pages: n, mode: mode)
                    let length = UInt32(min(UInt64(n) * page, f.installedSize - done * page))
                    parts.append(ContentPart(chunk: chunks.count, length: length, fileOffset: done * page))
                    chunks.append(ContentChunk(key: chunk.key, size: length, compressedSize: UInt32(n) * UInt32(page), check: .none))
                    done += UInt64(n)
                }
            }
            files.append(ContentFile(path: f.path, size: f.installedSize, hash: .none, parts: parts))
        }
        var id = Array("xbox-msixvc/1".utf8)
        id += Array(contentID.uuidString.lowercased().utf8) + Array(version.utf8) + header.topHash
        return ContentPlan(files: files, directories: directories.sorted(), chunks: chunks, identity: SHA1.hash(id))
    }

    /// The kept-encrypted files' tweaks, from the hash tree (PLA-499 decrypts by them).
    func encryptedLayout(_ source: XboxPackageSource) throws -> [XboxEncryptedFile] {
        try files.filter(\.keepEncrypted).map { f in
            guard let offset = f.offset, let region = f.region, let keyID = f.keyID else { throw XboxXVD.damaged("\(f.path) has no region") }
            let entries = try source.entries(offset / UInt64(XboxXVD.page), Int(f.pages))
            return XboxEncryptedFile(path: f.path, size: f.size, region: region, keyID: keyID, units: entries.map { $0.readLE32(at: 20) })
        }
    }
}

/// Chunks from the package: from the metadata prefix when they lie in it, else the CDN.
/// Every page is checked against the hash tree; decrypted pages are cut to the chunk.
final class XboxPackageSource: ContentChunkSource, @unchecked Sendable {
    let package: XboxPackage
    let prefix: XboxLocalFile
    let remote: any XboxPackageBytes
    let log: Logger
    private let ciphers: [UInt32: XboxXTS]

    init(package: XboxPackage, prefix: URL, remote: any XboxPackageBytes, keys: [UUID: [UInt8]], log: Logger) throws {
        self.package = package; self.prefix = try XboxLocalFile(prefix); self.remote = remote; self.log = log
        var ciphers: [UInt32: XboxXTS] = [:]
        for f in package.files where f.region != nil && f.keyID != nil {
            guard ciphers[f.region!] == nil else { continue }
            guard let key = keys[f.keyID!] else { throw ClientError.verificationFailed("Xbox licence has no key for this package") }
            ciphers[f.region!] = try XboxXTS(key: key, region: f.region!, vduid: package.contentID)
        }
        self.ciphers = ciphers
    }

    func entries(_ first: UInt64, _ count: Int) throws -> [[UInt8]] {
        try package.entries(first, count) { try self.prefix.read($0, $1) }
    }

    func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        let x = try XboxChunk(c.key)
        let page = XboxXVD.page, first = x.offset / UInt64(page)
        let entries = try self.entries(first, x.pages)
        let length = x.pages * page
        var bytes: [UInt8] = []
        for attempt in 0..<2 {
            bytes = x.offset + UInt64(length) <= package.prefixBytes ? try prefix.read(x.offset, length) : try await remote.read(x.offset, length)
            let bad = bytes.withUnsafeBytes { b in
                (0..<x.pages).first { !package.tree.matches(UnsafeRawBufferPointer(rebasing: b[($0 * page)..<(($0 + 1) * page)]), number: first + UInt64($0), entry: entries[$0]) }
            }
            guard let bad else { break }
            if attempt == 0 { log.warn("xbox", "package page \(first + UInt64(bad)) failed its hash; fetching it again"); continue }
            throw ClientError.verificationFailed("Xbox package page \(first + UInt64(bad)) does not match the package's hash tree")
        }
        if x.mode == .decrypt {
            guard let region = package.regions.first(where: { $0.keyIndex != nil && first >= $0.start && first < $0.end })?.id,
                  let cipher = ciphers[region] else { throw ClientError.verificationFailed("Xbox package page \(first) has no key") }
            cipher.decrypt(&bytes, units: entries.map { $0.readLE32(at: 20) }[...])
        }
        guard Int(c.size) <= bytes.count else { throw ClientError.verificationFailed("Xbox chunk is shorter than its part") }
        if Int(c.size) < bytes.count { bytes.removeLast(bytes.count - Int(c.size)) }
        return bytes
    }
}
