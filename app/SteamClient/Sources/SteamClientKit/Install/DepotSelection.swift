// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which of an app's depots make up a Windows install on this device, and why
/// each other depot is left out. Steam's own rules, narrowed to what the
/// runtime runs: Windows or OS-neutral content, 64-bit or arch-neutral, the
/// default language plus the chosen one, owned DLC only, no low-violence
/// variant, and no `sharedinstall` depot of another app (shared VC++/DirectX
/// installs, recorded as not installed). Another app's depot Steam installs
/// into this app's folder (`DepotInfo.isContentFromAnotherApp`) is content
/// and follows the other rules.
public struct DepotSelection: Sendable, Equatable {
    public struct Skip: Sendable, Equatable {
        public var depotID: UInt32
        public var reason: String
    }

    /// What an account's packages grant (Library.ownership): the depots they list and the apps
    /// they list. A package can list a DLC app without its depots: The Witcher 3's lists its 16
    /// free DLC and both expansions as apps, and Steam installs their depots for it (PLA-850).
    public struct Ownership: Sendable, Equatable {
        public var depots: Set<UInt32>
        public var apps: Set<UInt32>

        public init(depots: Set<UInt32>, apps: Set<UInt32>) {
            self.depots = depots
            self.apps = apps
        }

        /// From PICS package records (`depotids`, `appids`).
        public init(packages: [KeyValue]) {
            func ids(_ key: String) -> Set<UInt32> {
                Set(packages.flatMap { $0[key]?.children ?? [] }.compactMap(\.uint32))
            }
            self.init(depots: ids("depotids"), apps: ids("appids"))
        }
    }

    public struct Options: Sendable, Equatable {
        public var language: String
        /// DLC app IDs the session's packages list; empty for anonymous sessions. A DLC depot is
        /// installed only when its DLC app is here, and then even when no package lists the
        /// depot itself.
        public var ownedDLC: Set<UInt32>
        /// The depots the session's packages list (Ownership.depots), when known: a depot
        /// outside it and not an owned DLC's is left out, as Steam denies its key.
        public var ownedDepots: Set<UInt32>?
        /// An explicit depot list (`--depot`): exactly these, in PICS order.
        public var explicit: [UInt32]?

        public init(language: String = "english", ownedDLC: Set<UInt32> = [], ownedDepots: Set<UInt32>? = nil,
                    explicit: [UInt32]? = nil) {
            self.language = language.lowercased()
            self.ownedDLC = ownedDLC
            self.ownedDepots = ownedDepots
            self.explicit = explicit
        }

        /// Automatic selection for an account whose packages grant `owned`.
        public init(language: String = "english", owned: Ownership) {
            self.init(language: language, ownedDLC: owned.apps, ownedDepots: owned.depots)
        }
    }

    /// In install order: a later depot overrides an earlier one by path.
    public var depots: [DepotInfo]
    public var skipped: [Skip]

    public static func select(_ app: AppDepots, _ o: Options = Options()) throws -> DepotSelection {
        var chosen: [DepotInfo] = [], skipped: [Skip] = []
        if let explicit = o.explicit {
            let known = Set(app.depots.map(\.depotID))
            if let missing = explicit.first(where: { !known.contains($0) }) {
                throw SteamError.notFound("depot \(missing) is not listed for app \(app.appID)")
            }
            for d in app.depots {
                guard explicit.contains(d.depotID) else {
                    skipped.append(Skip(depotID: d.depotID, reason: "not requested"))
                    continue
                }
                if let from = d.depotFromApp, !d.isContentFromAnotherApp {
                    throw SteamError.unsupported("depot \(d.depotID) is a shared install from app \(from) (redistributable)")
                }
                guard d.publicManifestGID != nil else {
                    throw SteamError.unsupported("depot \(d.depotID) has no manifest on this branch (encrypted or on another branch only)")
                }
                chosen.append(d)
            }
            return DepotSelection(depots: chosen, skipped: skipped)
        }
        for d in app.depots {
            if let reason = exclusion(d, o) {
                skipped.append(Skip(depotID: d.depotID, reason: reason))
            } else {
                chosen.append(d)
            }
        }
        guard !chosen.isEmpty else { throw SteamError.notFound("no installable Windows depot for app \(app.appID)") }
        return DepotSelection(depots: chosen, skipped: skipped)
    }

    /// The reason a receipt keeps for a redistributable depot (`skippedDepots`, "<depot>: <reason>").
    static func sharedInstallReason(_ app: UInt32) -> String { "shared install from app \(app) (redistributable, not installed)" }

    /// The reason for another `sharedinstall` app's depot: Steam installs it into that app's own
    /// folder, which Playport does not. Not `sharedInstallReason`, which a record written before
    /// Playport installed `isContentFromAnotherApp` depots gave every source app's depot
    /// (`InstallReceipt.depotsToRecheck`).
    static func sharedInstallElsewhereReason(_ app: UInt32) -> String { "shared install in app \(app)'s own folder (not installed)" }

    /// The depot and source app of a receipt's `skippedDepots` entry for a redistributable; nil for any other.
    public static func sharedInstall(skipped entry: String) -> (depotID: UInt32, appID: UInt32)? {
        let parts = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let depot = UInt32(parts[0]), parts[1].hasPrefix("shared install from app ") else { return nil }
        let rest = parts[1].dropFirst("shared install from app ".count)
        guard let app = UInt32(rest.prefix { $0.isNumber }), parts[1] == sharedInstallReason(app) else { return nil }
        return (depot, app)
    }

    /// The reason a DLC's depot is left out for: the account does not own its DLC app, or its
    /// ownership was unknown (an anonymous session, licenses not fetched).
    static func unownedDLCReason(_ app: UInt32) -> String { "DLC app \(app) not owned" }

    /// The depot of a receipt's `skippedDepots` entry for an unowned DLC's depot; nil for any other.
    public static func unownedDLC(skipped entry: String) -> UInt32? {
        let parts = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let depot = UInt32(parts[0]), parts[1].hasPrefix("DLC app ") else { return nil }
        guard let app = UInt32(parts[1].dropFirst("DLC app ".count).prefix { $0.isNumber }),
              parts[1] == unownedDLCReason(app) else { return nil }
        return depot
    }

    /// The depot a receipt's `skippedDepots` entry ("<depot>: <reason>") names.
    static func skippedDepotID(_ entry: String) -> UInt32? {
        UInt32(entry.prefix { $0 != ":" }.trimmingCharacters(in: .whitespaces))
    }

    static func exclusion(_ d: DepotInfo, _ o: Options) -> String? {
        if let from = d.depotFromApp, !d.isContentFromAnotherApp {
            return from == CommonRedistributables.appID ? sharedInstallReason(from) : sharedInstallElsewhereReason(from)
        }
        if d.publicManifestGID == nil { return d.encryptedManifestsOnly ? "encrypted manifests only" : "no public manifest" }
        if !d.isWindows { return "os \(d.osList.joined(separator: ","))" }
        if let arch = d.osArch, !arch.isEmpty, arch != "64" { return "osarch \(arch)" }
        let dlcOwned = d.dlcAppID.map(o.ownedDLC.contains)
        if let owned = o.ownedDepots, !owned.contains(d.depotID), dlcOwned != true {
            return d.dlcAppID.map(unownedDLCReason) ?? "not in an owned package"
        }
        if let dlc = d.dlcAppID, dlcOwned == false { return unownedDLCReason(dlc) }
        if d.lowViolence { return "low-violence variant" }
        if let lang = d.language, lang != o.language { return "language \(lang)" }
        return nil
    }
}
