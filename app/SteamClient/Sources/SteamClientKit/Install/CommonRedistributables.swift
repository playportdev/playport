// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Steamworks Common Redistributables (app 228980): the shared depots of DirectX, VC++, .NET,
/// OpenAL and PhysX installers that a game lists as `depotfromapp` 228980 and Steam installs once
/// into `Steamworks Shared`, each depot with its own `installscript.vdf`. Playport downloads the
/// ones a game lists into the same one folder, shared by every game, as Steam does (decision 0081).
public enum CommonRedistributables {
    public static let appID: UInt32 = 228980
    /// The folder under games, as Steam names it (`config/installdir`).
    public static let installDir = "Steamworks Shared"
    /// DirectX June 2010's depot: its install script's one entry is DXSETUP, which Playport skips
    /// (its built-in DirectX libraries cover it), so it is never downloaded.
    public static let directXJun2010Depot: UInt32 = 228990

    /// Of the depots a game lists, those to download: all but DirectX June 2010's.
    public static func depotsToDownload(_ listed: [UInt32]) -> [UInt32] {
        listed.filter { $0 != directXJun2010Depot }
    }
}

extension InstallReceipt {
    /// The depots of app 228980 the title lists, from its record's skipped depots.
    public var commonRedistributableDepots: [UInt32] {
        skippedDepots.compactMap { DepotSelection.sharedInstall(skipped: $0) }
            .filter { $0.appID == CommonRedistributables.appID }.map(\.depotID)
    }

    /// The depots this record left out that Steam's depot list decides again at a repair:
    /// - other apps' depots (any source app but 228980) left out as shared installs: a record
    ///   written before Playport installed another app's depots into a game's folder
    ///   (`DepotInfo.isContentFromAnotherApp`; PLA-365) gave them all that reason. A record written
    ///   since names a true shared install otherwise (`DepotSelection.sharedInstallElsewhereReason`);
    /// - DLC depots left out as not owned, unless the record says that was decided with the
    ///   account's ownership (`dlcOwnershipChecked`): a record written before PLA-850's fix left
    ///   every owned DLC whose depot no package lists out so.
    public var depotsToRecheck: [UInt32] {
        skippedDepots.compactMap { e in
            if let shared = DepotSelection.sharedInstall(skipped: e) {
                return shared.appID == CommonRedistributables.appID ? nil : shared.depotID
            }
            return dlcOwnershipChecked == true ? nil : DepotSelection.unownedDLC(skipped: e)
        }
    }

    /// This record after a repair's check of its `depotsToRecheck` against `selection`, Steam's
    /// depot list now (with the account's ownership when `ownershipKnown`): `joining`, the rechecked
    /// depots the selection installs that the record lacks; the record with the others' entries
    /// as the selection gives them now and every other entry kept. Its DLC entries count as
    /// decided only when the ownership was known; until then they stay as they were.
    public func rechecked(by selection: DepotSelection, ownershipKnown: Bool)
        -> (receipt: InstallReceipt, joining: [DepotInfo]) {
        let recheck = Set(depotsToRecheck.filter { d in
            ownershipKnown || !skippedDepots.contains { DepotSelection.unownedDLC(skipped: $0) == d }
        })
        let have = Set(depots.map(\.depotID))
        var updated = self
        updated.skippedDepots = skippedDepots.filter { e in DepotSelection.skippedDepotID(e).map { !recheck.contains($0) } ?? true }
            + selection.skipped.filter { recheck.contains($0.depotID) }.map { "\($0.depotID): \($0.reason)" }
        if ownershipKnown { updated.dlcOwnershipChecked = true }
        return (updated, selection.depots.filter { !have.contains($0.depotID) && recheck.contains($0.depotID) })
    }
}

extension TitleInstaller {
    /// The install-script files of an install, by depot: the files its retained manifests flag
    /// (DepotFileFlag.installScript), as Steam lists them in its app manifest's InstallScripts.
    /// Paths are relative to the install folder, `/`-separated. Empty with no record or manifests.
    public func installScripts(appID: UInt32) -> [(depotID: UInt32, path: String)] {
        guard let receipt = loadReceipt(appID) else { return [] }
        var out: [(depotID: UInt32, path: String)] = []
        for ref in receipt.depots {
            guard let m = try? RetainedManifest.load(layout.manifestFile(ref)) else { continue }
            for f in m.files where f.isInstallScript { out.append((ref.depotID, f.path)) }
        }
        return out
    }

    /// Of `depots` (app 228980's), those Playport's install of it does not hold.
    public func missingCommonRedistributables(_ depots: [UInt32]) -> [UInt32] {
        let have = Set(loadReceipt(CommonRedistributables.appID)?.depots.map(\.depotID) ?? [])
        return depots.filter { !have.contains($0) }
    }

    /// Adds `depots` of app 228980 to `Games/Steamworks Shared`: an install of exactly the depots it
    /// held plus these, so a depot another game needed stays. Already there, nothing is fetched.
    public func installCommonRedistributables(_ depots: [UInt32], engine: InstallEngine.Options = .init(),
                                              say: @escaping @Sendable (String) -> Void) async throws -> Outcome? {
        guard !missingCommonRedistributables(depots).isEmpty else { return nil }
        let have = loadReceipt(CommonRedistributables.appID)?.depots.map(\.depotID) ?? []
        let wanted = Array(Set(have + depots)).sorted()
        return try await install(.init(appID: CommonRedistributables.appID, selection: .init(explicit: wanted),
                                       destName: CommonRedistributables.installDir, branch: Branch.publicName, engine: engine),
                                 say: say)
    }
}
