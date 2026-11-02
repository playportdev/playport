// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The fixed product list (decision 0174): World of Warcraft retail and its Classic products, by
/// their TACT product code. Other Battle.net products are never asked for.
public enum BattleNetProduct: String, CaseIterable, Sendable, Codable {
    case wow
    case wowClassic = "wow_classic"
    case wowClassicEra = "wow_classic_era"
    case wowAnniversary = "wow_anniversary"

    /// The TACT product code (`wow_classic_era`), also the store game ID.
    public var code: String { rawValue }

    public var name: String {
        switch self {
        case .wow: return "World of Warcraft"
        case .wowClassic: return "World of Warcraft Classic"
        case .wowClassicEra: return "World of Warcraft Classic Era"
        case .wowAnniversary: return "World of Warcraft Classic Anniversary"
        }
    }

    /// The x64 client's machine tag, every WoW product config's Windows `tags_64bit` (the
    /// recorded configs of all four products say so). An install's `.build.info` tags name it
    /// once the install holds the x64 client Play starts (decision 0177); an install from before
    /// it names `arm64` instead, and its update brings the x64 client (BattleNetUpdateCheck).
    public static let x64ClientTag = "x86_64"
}

/// A store region (GLOSSARY.md): the Battle.net region an install belongs to. The version and CDN
/// endpoints have a row per region; the manifests tag region-specific data with `tag`.
public enum StoreRegion: String, CaseIterable, Sendable, Codable {
    case us, eu, kr, tw

    /// The region's tag in the install, download and size manifests.
    public var tag: String { rawValue.uppercased() }
}
