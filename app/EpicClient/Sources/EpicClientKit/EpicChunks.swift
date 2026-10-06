// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

/// Epic's chunk files from the CDN folders the asset names, no token needed
/// (measured on all three CDNs). Bases in the asset's order; one that fails
/// four times in a row is passed over while another still works. Each chunk is
/// checked: the file's GUID, then the inflated size and SHA-1 from the manifest.
public actor EpicChunkSource: ContentChunkSource {
    let session: EpicSession
    let bases: [URL]
    let log: Logger
    private var failures: [URL: Int] = [:]
    public var attempts = 4

    public init(session: EpicSession, bases: [URL], log: Logger) {
        self.session = session
        self.bases = bases
        self.log = log
    }

    public func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        guard let path = c.locator, Self.safe(path), c.key.count == 16, case let .sha1(sha) = c.check else {
            throw ClientError.unsafeContent("Epic chunk without a name")
        }
        let want = EpicManifest.Chunk(guid: c.key, hash: 0, sha1: sha, group: UInt8(clamping: c.group), window: c.size,
                                      fileSize: UInt64(c.compressedSize))
        var last: Error = ClientError.notFound("chunk")
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let usable = bases.filter { (failures[$0] ?? 0) < 4 }
            let pool = usable.isEmpty ? bases : usable
            guard !pool.isEmpty else { throw ClientError.notFound("Epic gave no CDN") }
            let base = pool[attempt % pool.count]
            let url = base.appendingPathComponent(path)
            do {
                let body = try await session.plain(url, maxBytes: Int(c.compressedSize) + 4096, label: "Epic chunk")
                let plain = try EpicChunkFile.decode(body, expect: want)
                failures[base] = 0
                return plain
            } catch ClientError.cancelled {
                throw ClientError.cancelled
            } catch {
                failures[base, default: 0] += 1
                log.warn("epic", "chunk \(want.guidHex.prefix(8)) from \(base.host ?? "?") failed: \(error)")
                last = error
            }
        }
        throw last
    }

    /// `ChunksV4/GG/HASH_GUID.chunk`, nothing else.
    static func safe(_ p: String) -> Bool {
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].hasPrefix("Chunks") && parts[1].count == 2 && parts[1].allSatisfy(\.isNumber)
            && parts[2].hasSuffix(".chunk") && parts[2].allSatisfy { $0.isHexDigit || $0 == "_" || $0 == "." || $0.isLetter }
            && parts.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
}
