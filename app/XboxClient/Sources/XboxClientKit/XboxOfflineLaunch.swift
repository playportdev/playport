// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b assets/xodus-offline-license.patch,
// xodus-offline-license-revocation.patch (license.rs recover_offline and
// offline_identity_mode) and src/main/offline-identity.ts (accountCacheKey,
// offlineIdentityCacheDirectory); translated to Swift by the Playport authors,
// 2026-10-30. Modified: the designation is Microsoft's answer to this session, not
// the key licence's binding (the recorded licences are Machine-bound and carry an
// `isOffline` lease without it); one prefix; typed reasons.
import Foundation
import ContentKit

/// Why a copy can't start while Microsoft's licensing can't be reached. Each case's
/// text says that a connection is needed and why.
public enum XboxOfflineRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    /// This phone isn't the account's offline device (the setting is off).
    case notOfflineDevice
    /// No licence from an online play since this phone became the offline device.
    case notPlayedOnline
    /// Microsoft's licence for the copy came with no offline lease.
    case noOfflineLease
    /// The offline lease ended at this time.
    case leaseEnded(Date)

    public var description: String {
        switch self {
        case .notOfflineDevice:
            "Playing without a connection needs this phone to be your Xbox offline device, and it isn't. Connect to the internet "
                + "to play, or turn on Offline device under Settings › Accounts › Xbox while online and play the game once."
        case .notPlayedOnline:
            "This game hasn't been played online on this phone since it became your offline device, so it has no offline "
                + "licence here yet. Connect to the internet and play it once."
        case .noOfflineLease:
            "Microsoft gave this game no offline licence on this phone. Connect to the internet to play it."
        case .leaseEnded(let end):
            "This game's offline licence ended on \(Self.day(end)). Connect to the internet so Microsoft can renew it."
        }
    }
    /// A log label: no dates, no identifiers.
    var label: String {
        switch self {
        case .notOfflineDevice: "not the offline device"
        case .notPlayedOnline: "not played online since the designation"
        case .noOfflineLease: "no offline lease"
        case .leaseEnded: "offline lease ended"
        }
    }
    static func day(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }
}

/// The offline launch rule: while licensing can't be reached, a copy starts on its
/// stored keys only on the offline device, from a licence Microsoft issued at or after
/// the designation (an online play), while that licence's offline lease lasts.
enum XboxOfflineLaunch {
    static func check(_ stored: XboxStoredLicence?, designation: XboxOfflineDesignation?, now: Date) -> Result<XboxStoredLicence, XboxOfflineRefusal> {
        guard let designation, designation.designated else { return .failure(.notOfflineDevice) }
        guard let stored, let storedAt = stored.storedAt, storedAt >= designation.since else { return .failure(.notPlayedOnline) }
        guard let lease = stored.offlineLease else { return .failure(.noOfflineLease) }
        guard lease.expiresAt > now else { return .failure(.leaseEnded(lease.expiresAt)) }
        return .success(stored)
    }
}

/// The runtime's offline identity (xgameruntime `OfflineIdentity.h`, feature
/// `xuser-offline-identity-v2`): the last signed-in Xbox identity, kept per account in
/// the prefix so a game signs in while Microsoft is unreachable. The launcher decides
/// per play, after the licence, through the game's environment.
public enum XboxOfflineIdentity {
    /// The game's environment for a play on `licence`:
    /// - stored keys (an offline start): `use` the cached identity, and fail the network
    ///   sign-in at once (`XODUS_FORCE_OFFLINE`);
    /// - Microsoft's licence with an offline lease on the offline device: `store` it;
    /// - otherwise neither, and the runtime deletes the cached identity at its next sign-in.
    /// `XODUS_ACCOUNT_HASH` names the account's cache; nil when signed out.
    public static func environment(licence: XboxLicence, offlineDevice: Bool, account: String?) -> [String: Secret<String>] {
        guard let account else { return [:] }
        var env = ["XODUS_ACCOUNT_HASH": Secret(account)]
        if licence.source == .cache {
            env["XODUS_OFFLINE_IDENTITY"] = Secret("use"); env["XODUS_FORCE_OFFLINE"] = Secret("1")
        } else if offlineDevice, licence.offlineLease != nil {
            env["XODUS_OFFLINE_IDENTITY"] = Secret("store")
        }
        return env
    }

    /// Nexus's `accountCacheKey`: an opaque, stable name for the signed-in account (the
    /// first 32 hex digits of SHA-256 of its trimmed, lower-cased sign-in name).
    static func account(_ username: String) -> String {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Array(SHA256Stream.hash(Array(name.utf8)).prefix(16)).hex
    }

    /// Deletes every account's cached identity in the prefix (each Wine user's
    /// `AppData/Local/Xodus Nexus/offline-identity`): at sign-out, device reset and
    /// every designation change, and when this device is no longer the offline device.
    /// Never follows a link out of the prefix. Returns how many caches it deleted.
    @discardableResult
    public static func remove(prefix: URL) throws -> Int {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        guard isDirectory(users) else { return 0 }
        var removed = 0
        for user in try fm.contentsOfDirectory(atPath: users.path) {
            var current = users
            var safe = true
            for part in [user, "AppData", "Local", "Xodus Nexus", "offline-identity"] {
                current.appendPathComponent(part, isDirectory: true)
                guard isDirectory(current) else { safe = false; break }
            }
            guard safe else { continue }
            try fm.removeItem(at: current)
            removed += 1
        }
        return removed
    }
    /// A real directory, not a link to one.
    private static func isDirectory(_ url: URL) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }
}

extension XboxSession {
    /// The opaque name of the signed-in account's offline identity cache; nil when signed out.
    public var offlineIdentityAccount: String? {
        struct Name: Decodable { let username: String }
        return ((try? read(Name.self, "session")) ?? nil).map { XboxOfflineIdentity.account($0.username) }
    }
}
