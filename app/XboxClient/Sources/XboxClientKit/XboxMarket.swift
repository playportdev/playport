// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Store market every Xbox request names: the phone's region when it is a two-letter
/// upper-case region code, else US (the catalogue, licensing and add-ons all take one).
public enum XboxMarket {
    public static var current: String { valid(Locale.current.region?.identifier) }

    public static func valid(_ market: String?) -> String {
        guard let market, market.utf8.count == 2, market.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else { return "US" }
        return market
    }
}
