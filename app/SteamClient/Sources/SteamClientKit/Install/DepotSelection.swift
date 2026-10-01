// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which of an app's depots make up a Windows install on this device, and why
/// each other depot is left out. Steam's own rules, narrowed to what the
/// runtime runs: Windows or OS-neutral content, 64-bit or arch-neutral, the
/// default language plus the chosen one, owned DLC only, no low-violence
/// variant, and no `depotfromapp` redistributables (shared VC++/DirectX
/// installs, recorded as not installed).
public struct DepotSelection: Sendable, Equatable {
    public struct Skip: Sendable, Equatable {
        public var depotID: UInt32
        public var reason: String
    }

    public struct Options: Sendable, Equatable {
        public var language: String
        /// DLC app IDs the session's licenses cover; empty for anonymous sessions.
        public var ownedDLC: Set<UInt32>
        /// The depots the session's packages list (Library.ownedDepotIDs), when
        /// known: a depot outside it is left out, as Steam denies its key.
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
                if let from = d.depotFromApp {
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

    static func exclusion(_ d: DepotInfo, _ o: Options) -> String? {
        if let from = d.depotFromApp { return "shared install from app \(from) (redistributable, not installed)" }
        if d.publicManifestGID == nil { return d.encryptedManifestsOnly ? "encrypted manifests only" : "no public manifest" }
        if !d.isWindows { return "os \(d.osList.joined(separator: ","))" }
        if let arch = d.osArch, !arch.isEmpty, arch != "64" { return "osarch \(arch)" }
        if let owned = o.ownedDepots, !owned.contains(d.depotID) {
            return d.dlcAppID.map { "DLC app \($0) not owned" } ?? "not in an owned package"
        }
        if let dlc = d.dlcAppID, !o.ownedDLC.contains(dlc) { return "DLC app \(dlc) not owned" }
        if d.lowViolence { return "low-violence variant" }
        if let lang = d.language, lang != o.language { return "language \(lang)" }
        return nil
    }
}
