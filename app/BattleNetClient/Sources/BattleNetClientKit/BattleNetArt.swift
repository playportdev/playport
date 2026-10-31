// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Each product's picture for its library tile and page (PLA-607): Blizzard's own art from the
/// World of Warcraft site (worldofwarcraft.blizzard.com), served by its public image host with
/// no session. The products are a fixed list, so each has a fixed image, sized and cropped by
/// the host's image parameters to a 16:9 JPEG. Nothing of it is kept in the repository; the app
/// fetches it and keeps it under Caches.
public enum BattleNetArt {
    /// A tile (800 wide) or a page's backdrop (1600 wide), both 16:9.
    public enum Size: String, CaseIterable, Sendable {
        case tile, hero

        var width: Int { self == .tile ? 800 : 1600 }
    }

    static let base = "https://blz-contentstack-images.akamaized.net/v3/assets/blt9c12f249ac15c7ec/"

    /// The image's asset path on the host, and the crop that frames it 16:9 when it is not.
    static func source(_ p: BattleNetProduct) -> (path: String, crop: String?) {
        switch p {
        // The site's page image: the logo over a gryphon rider, 1600×900.
        case .wow: return ("bltb5a24e5ab1e2cfb0/6a88e3589b942efdb6f74110/wow-thumbnail-homepage.jpg", nil)
        // The Classic page's panels, 2600×1945 with the figure at the left: Mists of Pandaria
        // Classic, the Anniversary realms' Burning Crusade, and Classic Era's Ragnaros.
        case .wowClassic: return ("blta9c3baa4bc31dfd9/6a86c0667ec8fea6920002f9/classic-mop-bg.png", "2000,1125,x0,y300")
        case .wowAnniversary: return ("blt9637c72b4c27eb66/6a86c058c751e17dc40c4de7/classic-bcc-bg.png", "2000,1125,x0,y300")
        case .wowClassicEra: return ("bltd7f3db63b41b3f73/6a86c0659b942ed84ef740cf/classic-bg.png", "2000,1125,x0,y300")
        }
    }

    public static func url(_ p: BattleNetProduct, _ size: Size) -> URL {
        let s = source(p)
        let query = (s.crop.map { ["crop=\($0)"] } ?? []) + ["width=\(size.width)", "format=jpg", "quality=85"]
        return URL(string: base + s.path + "?" + query.joined(separator: "&"))!
    }

    /// Whether the picture shows the game's name (retail's logo), so the tile draws none over it.
    public static func carriesName(_ p: BattleNetProduct) -> Bool { p == .wow }
}

extension BattleNetClient {
    /// The product's picture at `size`, with the client's manners: a JPEG, or `refused` and
    /// `damaged` as for any other answer.
    public func art(_ p: BattleNetProduct, _ size: BattleNetArt.Size) async throws -> [UInt8] {
        let bytes = try await get(BattleNetArt.url(p, size), what: "\(p.code) art")
        guard bytes.starts(with: [0xFF, 0xD8, 0xFF]) else { throw BattleNetError.damaged("\(p.code) art: not a JPEG") }
        return bytes
    }
}
