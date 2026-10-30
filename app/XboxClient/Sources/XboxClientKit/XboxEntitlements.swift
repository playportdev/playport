// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b
// assets/xodus-subscription-login.patch (xodus-cli commands/library.rs and
// subscription.rs) and src/main/account-library.ts; translated to Swift by the
// Playport authors, 2026-10-30. Modified: one strict parser over the response
// (no CLI hop), the account's copies only (no pages, no "other" access).
import Foundation
import ContentKit

/// How the account licenses a copy: bought (or through a bought bundle), or
/// through PC Game Pass, whose licence lapses with the membership (0166).
public enum XboxAccess: String, Codable, Sendable { case owned, gamePass }

struct XboxEntitlement: Equatable {
    let status: String
    let trial: Bool
    let sharing: String
    let ends: Date
    let parent: String?
    /// A licence with a provenance flag Nexus does not trust (`isPositron` not false).
    let special: Bool
}

/// The Store's entitlements (PCGAFD): every product the account can license,
/// each satisfied by itself or by a parent (a bundle or a Game Pass plan).
enum XboxEntitlements {
    /// PC Game Pass, Game Pass Ultimate and their variants (account-library.ts `plans`).
    static let plans: Set<String> = ["CFQ7TTC0KGQ8", "CFQ7TTC0KHS0", "CFQ7TTC0P85B", "CFQ7TTC0K5DJ", "CFQ7TTC0K6L8", "CFQ7TTC10QFD"]
    static let maximum = 10_000

    static func url(market: String) -> URL {
        URL(string: "https://beige.xboxservices.com/PCGAFD/entitlements?market=\(market)&language=en-US&appVersion=0.2.3")!
    }

    static func isProductID(_ value: String) -> Bool { StoreGameKey.isProductID(value) }

    /// One response page. A row that is not a well-formed licence is left out, with
    /// every product it satisfies: a bad parent never grants its child access.
    static func parse(_ bytes: [UInt8]) throws -> [String: XboxEntitlement] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let rows = root["entitlements"] as? [String: Any], rows.count <= maximum else {
            throw ClientError.protocolChanged("Xbox entitlements have an unexpected shape")
        }
        var entries: [String: XboxEntitlement] = [:], blocked = Set<String>()
        for (id, value) in rows {
            guard isProductID(id) else { continue }
            guard let row = value as? [String: Any], let entry = entry(row) else { blocked.insert(id); continue }
            entries[id] = entry
        }
        var queue = Array(blocked)
        while let id = queue.popLast() {
            for (child, entry) in entries where entry.parent == id { entries[child] = nil; queue.append(child) }
        }
        return entries
    }

    private static func entry(_ row: [String: Any]) -> XboxEntitlement? {
        guard let status = row["status"] as? String, status.count < 40,
              let trial = row["isTrial"] as? Bool,
              let sharing = row["sharingSource"] as? String, sharing.count < 40,
              let end = row["endDate"] as? String, end.count < 50, let ends = date(end) else { return nil }
        let parent: String?
        switch row["satisfiedByProductId"] {
        case nil, is NSNull: parent = nil
        case let id as String where isProductID(id): parent = id
        default: return nil
        }
        let special = row["isPositron"].map { ($0 as? Bool) != false } ?? false
        return XboxEntitlement(status: status, trial: trial, sharing: sharing, ends: ends, parent: parent, special: special)
    }

    static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: value) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: value)
    }

    /// The copy's access, following its parents: owned when the chain ends in a
    /// licence of its own, Game Pass when it passes through a plan. Inactive, trial,
    /// shared, expired, flagged, cyclic or unresolved chains give no access, and
    /// a plan is not a copy.
    static func access(_ id: String, in entries: [String: XboxEntitlement], now: Date) -> XboxAccess? {
        var current = id, subscription = false, visited = Set<String>()
        for depth in 0..<16 {
            guard visited.insert(current).inserted else { return nil }
            subscription = subscription || plans.contains(current)
            guard let item = entries[current] else { return depth > 0 && subscription ? .gamePass : nil }
            guard !item.special, item.status == "Active", !item.trial, item.sharing == "None", item.ends > now else { return nil }
            guard let parent = item.parent else {
                if current == id && plans.contains(current) { return nil }
                return subscription ? .gamePass : .owned
            }
            current = parent
        }
        return nil
    }
}
