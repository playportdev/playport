// SPDX-License-Identifier: GPL-3.0-or-later
// A Battle.net product's art on the phone (PLA-607): fetched once from Blizzard's image host
// (BattleNetClientKit.BattleNetArt) and kept under Caches beside the GOG and Epic art, so the
// library, Home and the launch screen draw it with no network after that.

import BattleNetClientKit
import Foundation
import SteamClientKit

public struct BattleNetArtCache: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `battlenet-wow_classic_era_hero.jpg`.
    public func file(_ p: BattleNetProduct, _ size: BattleNetArt.Size) -> URL {
        directory.appendingPathComponent("\(BattleNet.key(p).fileStem)_\(size.rawValue).jpg")
    }

    /// The art already on disk.
    public func cached(_ p: BattleNetProduct, _ size: BattleNetArt.Size) -> Data? {
        try? Data(contentsOf: file(p, size))
    }

    /// The art on disk, else what `fetch` brings, kept for next time; nil when the fetch fails
    /// (nothing is kept, so the next load asks again).
    public func load(_ p: BattleNetProduct, _ size: BattleNetArt.Size,
                     fetch: @Sendable () async throws -> [UInt8]) async -> Data? {
        if let data = cached(p, size) { return data }
        guard let bytes = try? await fetch() else { return nil }
        let data = Data(bytes)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(p, size), options: .atomic)
        return data
    }
}
