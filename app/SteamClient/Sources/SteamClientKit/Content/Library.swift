// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct OwnedApp: Sendable, Codable, Equatable {
    public var appID: UInt32
    public var name: String
    public var type: String
    public var viaPackage: UInt32
}

public struct DepotInfo: Sendable, Codable, Equatable {
    public var depotID: UInt32
    public var name: String?
    public var osList: [String]
    public var osArch: String?
    public var publicManifestGID: UInt64?
    public var publicManifestSize: UInt64?
    public var publicManifestDownload: UInt64?
    public var depotFromApp: UInt32?
    public var sharedInstall: Bool
    public var dlcAppID: UInt32?
    public var encryptedManifestsOnly: Bool
    /// `config/language`: empty for the default depot, else the language a
    /// split-language depot carries.
    public var language: String? = nil
    /// `config/lowviolence`: a censored variant Steam installs only on request.
    public var lowViolence: Bool = false
    /// Manifests on the other branches Steam lists in the clear, by branch
    /// name; a password branch's are encrypted and not here.
    public var branchManifests: [String: BranchManifest]? = nil
    /// A `depotfromapp` depot whose source app installs into this app's folder
    /// (Half-Life's engine and base content for Counter-Strike): the game's own
    /// content, with the source app's manifests filled in by `resolvingSharedInstalls`.
    /// Nil for every other depot, a redistributable included.
    public var sharesInstallDir: Bool? = nil

    /// A `depotfromapp` depot Steam installs into this app's own folder: one whose source app shares
    /// the folder (`sharesInstallDir`), or one Steam does not list as a `sharedinstall` (Red Dead
    /// Redemption 2's depot 1899671 of Rockstar's installers, from the config app 1899670, whose
    /// manifest the game's own record lists). A `sharedinstall` depot goes into its source app's
    /// folder (Steamworks Common Redistributables'), and is not this app's content.
    public var isContentFromAnotherApp: Bool { depotFromApp != nil && (sharesInstallDir == true || !sharedInstall) }

    /// Windows content: explicitly "windows", or no OS restriction.
    public var isWindows: Bool { osList.isEmpty || osList.contains("windows") }
}

public struct BranchManifest: Sendable, Codable, Equatable {
    public var gid: UInt64
    public var size: UInt64?
    public var download: UInt64?
}

/// One of `depots/branches`: `public`, or a beta such as The Witcher 3's `classic`.
public struct Branch: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    public var buildID: UInt32?
    public var description: String?
    public var passwordRequired: Bool
    /// `timeupdated`, Unix seconds.
    public var updated: UInt64?
    public var id: String { name }
    public var isPublic: Bool { name == Branch.publicName }

    public static let publicName = "public"
}

public struct AppDepots: Sendable, Codable, Equatable {
    public var appID: UInt32
    public var name: String
    /// The public branch's build; in a `onBranch` view, that branch's.
    public var publicBuildID: UInt32?
    public var changeNumber: UInt32?
    public var depots: [DepotInfo]
    /// `config/installdir`: the directory name Steam installs the title under.
    public var installDir: String? = nil
    /// `depots/branches`, public included; nil in a record cached before branches were read.
    public var branches: [Branch]? = nil
    /// The Windows `config/launch` executable, relative to the install folder
    /// as Steam gives it (`Bin/Win64/KingdomCome.exe`); nil when there is none.
    public var launchExecutable: String? = nil
    /// That launch entry's `arguments` (`-steam -game cstrike`), nil when it has none.
    public var launchArguments: String? = nil
    public var windowsDepots: [DepotInfo] {
        depots.filter { $0.isWindows && $0.publicManifestGID != nil && $0.depotFromApp == nil && $0.dlcAppID == nil }
    }

    public func branch(_ name: String) -> Branch? { branches?.first { $0.name == name } }

    /// The app a depot's key and manifest request code are asked for: the source
    /// app of another app's depot installed in this app's folder (`isContentFromAnotherApp`),
    /// as Steam's own client does; this app for every other depot.
    public func keyAppID(depot: UInt32) -> UInt32 {
        guard let d = depots.first(where: { $0.depotID == depot }), d.isContentFromAnotherApp, let from = d.depotFromApp
        else { return appID }
        return from
    }

    /// This app with each `depotfromapp` depot whose source app (in `sources`)
    /// installs into the same folder taking that app's manifests for the depot.
    /// A source with another folder (Steamworks Common Redistributables'
    /// `Steamworks Shared`) or not in `sources` leaves the depot a redistributable.
    public func resolvingSharedInstalls(_ sources: [UInt32: AppDepots]) -> AppDepots {
        guard let dir = installDir?.lowercased() else { return self }
        var out = self
        out.depots = depots.map { d in
            guard let from = d.depotFromApp, from != appID, let src = sources[from], src.installDir?.lowercased() == dir,
                  let own = src.depots.first(where: { $0.depotID == d.depotID && $0.depotFromApp == nil })
            else { return d }
            var d = d
            d.publicManifestGID = own.publicManifestGID
            d.publicManifestSize = own.publicManifestSize
            d.publicManifestDownload = own.publicManifestDownload
            d.encryptedManifestsOnly = own.encryptedManifestsOnly
            d.branchManifests = own.branchManifests
            d.sharesInstallDir = true
            return d
        }
        return out
    }

    public func buildID(branch name: String) -> UInt32? {
        name == Branch.publicName ? publicBuildID : branch(name)?.buildID
    }

    /// Branches a download can use: public first, then the betas Steam lists
    /// in the clear that carry at least one manifest, newest first.
    public var installableBranches: [Branch] {
        let betas = (branches ?? []).filter { b in
            !b.isPublic && !b.passwordRequired && depots.contains { $0.branchManifests?[b.name] != nil }
        }.sorted { ($0.updated ?? 0) > ($1.updated ?? 0) }
        return [branch(Branch.publicName) ?? Branch(name: Branch.publicName, buildID: publicBuildID, description: nil,
                                                     passwordRequired: false, updated: nil)] + betas
    }

    /// The app as it is on `name`: every depot's public manifest fields hold
    /// that branch's manifest (none when the depot has none there, so it is
    /// not installed), and the build is the branch's.
    public func onBranch(_ name: String) throws -> AppDepots {
        if name == Branch.publicName { return self }
        guard let b = branch(name) else { throw SteamError.notFound("app \(appID) has no branch \(name)") }
        guard !b.passwordRequired else { throw SteamError.unsupported("branch \(name) of app \(appID) needs a password") }
        var out = self
        out.publicBuildID = b.buildID
        out.depots = depots.map { d in
            var d = d
            let m = d.branchManifests?[name]
            d.publicManifestGID = m?.gid
            d.publicManifestSize = m?.size
            d.publicManifestDownload = m?.download
            d.encryptedManifestsOnly = false
            return d
        }
        return out
    }
}

/// PICS: licenses -> packages -> apps -> depots (SteamApps.picsGetProductInfo,
/// SteamService's PICS refresh), with access tokens where Steam grants them.
public struct Library: Sendable {
    let session: SteamSession
    let log: Logger

    public init(session: SteamSession) async {
        self.session = session
        self.log = await session.log
    }

    private func cm() async throws -> CMConnection {
        guard let c = await session.cm else { throw SteamError.transport("not connected") }
        return c
    }

    public func accessTokens(apps: [UInt32] = [], packages: [UInt32] = []) async throws -> CMsgClientPICSAccessTokenResponse {
        let cm = try await cm()
        let p = try await cm.call(.clientPICSAccessTokenRequest,
                                  CMsgClientPICSAccessTokenRequest(packageIDs: packages, appIDs: apps))
        guard p.knownEMsg == .clientPICSAccessTokenResponse else { throw SteamError.protocolChanged("PICS token reply EMsg \(p.emsg)") }
        return try CMsgClientPICSAccessTokenResponse.decode(p.body)
    }

    /// One PICS product-info request, collecting every part of a multi-part
    /// reply (response_pending) under the same job.
    public func productInfo(apps: [(id: UInt32, token: UInt64)] = [], packages: [(id: UInt32, token: UInt64)] = [])
        async throws -> (apps: [UInt32: KeyValue], packages: [UInt32: KeyValue], unknownApps: [UInt32]) {
        let cm = try await cm()
        let job = await cm.beginJob()
        var outApps: [UInt32: KeyValue] = [:], outPackages: [UInt32: KeyValue] = [:], unknown: [UInt32] = []
        do {
            var req = CMsgClientPICSProductInfoRequest()
            req.apps = apps
            req.packages = packages
            var h = ProtoHeader()
            h.jobIDSource = job
            try await cm.send(.clientPICSProductInfoRequest, req, header: h)
            for part in 1...64 {
                let p = try await cm.next(.job(job), timeout: 30)
                guard p.knownEMsg == .clientPICSProductInfoResponse else { throw SteamError.protocolChanged("PICS reply EMsg \(p.emsg)") }
                let r = try CMsgClientPICSProductInfoResponse.decode(p.body)
                for a in r.apps {
                    if let buf = a.buffer, !buf.isEmpty {
                        outApps[a.id] = try KeyValue.parseText(buf)
                    } else if a.missingToken {
                        log.info("pics", "app \(a.id): access token required")
                    } else {
                        throw SteamError.unsupported("PICS app \(a.id) delivered out of band (http_host)")
                    }
                }
                for pk in r.packages {
                    guard let buf = pk.buffer, buf.count > 4 else { continue }
                    // Package buffers are u32 package id + binary KeyValues.
                    outPackages[pk.id] = try KeyValue.parseBinary(buf[4...])
                }
                unknown += r.unknownAppIDs
                if !r.responsePending { break }
                if part == 64 { throw SteamError.protocolChanged("PICS reply exceeded 64 parts") }
            }
        } catch {
            await cm.endJob(job)
            throw error
        }
        await cm.endJob(job)
        return (outApps, outPackages, unknown)
    }

    /// Owned apps for the logged-on account, with name and type. `limit`
    /// bounds how many app records are fetched.
    public func ownedApps(licenses: [CMsgClientLicenseList.License], limit: Int = 500) async throws -> [OwnedApp] {
        try await ownedApps(packages: licenses.map { ($0.packageID, $0.accessToken) }, limit: limit)
    }

    /// Steam's anonymous package ("Anonymous Dedicated Server Comp"), which
    /// anonymous sessions may use without a pushed license.
    public static let anonymousPackage: UInt32 = 17906

    public func ownedApps(packages: [(id: UInt32, token: UInt64)], limit: Int = 500) async throws -> [OwnedApp] {
        let appToPackage = try await ownedAppIDs(packages: packages)
        let appIDs = Array(appToPackage.keys.sorted().prefix(limit))
        let records = try await appRecords(appIDs)
        return appIDs.map { id in
            let common = records[id]?["common"]
            return OwnedApp(appID: id, name: common?["name"]?.value ?? "?",
                            type: common?["type"]?.value ?? "?", viaPackage: appToPackage[id] ?? 0)
        }
    }

    /// The apps the given packages grant, each mapped to the first package
    /// (in package-ID order) that lists it.
    public func ownedAppIDs(packages: [(id: UInt32, token: UInt64)]) async throws -> [UInt32: UInt32] {
        var packageTokens: [UInt32: UInt64] = [:]
        for p in packages { packageTokens[p.id] = p.token }
        var appToPackage: [UInt32: UInt32] = [:]
        let packageIDs = Array(packageTokens.keys).sorted()
        for batch in stride(from: 0, to: packageIDs.count, by: 100) {
            let ids = packageIDs[batch..<min(batch + 100, packageIDs.count)]
            let info = try await productInfo(packages: ids.map { ($0, packageTokens[$0] ?? 0) })
            for pid in ids {
                for a in info.packages[pid]?["appids"]?.children ?? [] {
                    if let id = a.uint32, appToPackage[id] == nil { appToPackage[id] = pid }
                }
            }
        }
        return appToPackage
    }

    /// The depots the given packages grant: Steam hands out a depot's key only
    /// to an account one of whose packages lists it (a pre-order or edition
    /// bonus depot is in the app's table for everyone).
    public func ownedDepotIDs(packages: [(id: UInt32, token: UInt64)]) async throws -> Set<UInt32> {
        var packageTokens: [UInt32: UInt64] = [:]
        for p in packages { packageTokens[p.id] = p.token }
        var out: Set<UInt32> = []
        let packageIDs = Array(packageTokens.keys).sorted()
        for batch in stride(from: 0, to: packageIDs.count, by: 100) {
            let ids = packageIDs[batch..<min(batch + 100, packageIDs.count)]
            let info = try await productInfo(packages: ids.map { ($0, packageTokens[$0] ?? 0) })
            for pid in ids {
                for d in info.packages[pid]?["depotids"]?.children ?? [] { if let id = d.uint32 { out.insert(id) } }
            }
        }
        return out
    }

    /// Full PICS app records, fetched in batches of 50 with whatever access
    /// tokens Steam grants. Apps Steam withholds are absent from the result.
    public func appRecords(_ appIDs: [UInt32]) async throws -> [UInt32: KeyValue] {
        var out: [UInt32: KeyValue] = [:]
        for batch in stride(from: 0, to: appIDs.count, by: 50) {
            let ids = Array(appIDs[batch..<min(batch + 50, appIDs.count)])
            let tokens = try await accessTokens(apps: ids)
            let info = try await productInfo(apps: ids.map { ($0, tokens.appTokens[$0] ?? 0) })
            out.merge(info.apps) { $1 }
        }
        return out
    }

    /// Depot table, branches and every clear branch's manifests for one app.
    public func depots(appID: UInt32) async throws -> AppDepots {
        let tokens = try await accessTokens(apps: [appID])
        let info = try await productInfo(apps: [(appID, tokens.appTokens[appID] ?? 0)])
        guard let app = info.apps[appID] else { throw SteamError.notFound("PICS app \(appID)") }
        var depots = try Self.parseDepots(appID: appID, app)
        let launch = (try? SteamAppInfo.parse(appID: appID, app))?.windowsLaunch
        depots.launchExecutable = launch?.executable
        depots.launchArguments = launch?.arguments
        let sourceIDs = Set(depots.depots.compactMap(\.depotFromApp)).subtracting([appID]).sorted()
        if !sourceIDs.isEmpty {
            do {
                let records = try await appRecords(sourceIDs)
                var sources: [UInt32: AppDepots] = [:]
                for (id, record) in records { sources[id] = try? Self.parseDepots(appID: id, record) }
                depots = depots.resolvingSharedInstalls(sources)
            } catch {
                log.warn("pics", "app \(appID): source apps \(sourceIDs) unreadable (\(error)); their depots are left out")
            }
        }
        return depots
    }

    public static func parseDepots(appID: UInt32, _ app: KeyValue) throws -> AppDepots {
        let depotsNode = app["depots"]
        var depots: [DepotInfo] = []
        for d in depotsNode?.children ?? [] {
            guard let id = UInt32(d.name) else { continue } // "branches", "baselanguages", ...
            let config = d["config"]
            let osList = (config?["oslist"]?.value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            var manifests: [String: BranchManifest] = [:]
            for m in d["manifests"]?.children ?? [] {
                if let v = m.uint64 { manifests[m.name] = BranchManifest(gid: v) } // legacy flat form
                else if let v = m["gid"]?.uint64 {
                    manifests[m.name] = BranchManifest(gid: v, size: m["size"]?.uint64, download: m["download"]?.uint64)
                }
            }
            let pub = manifests.removeValue(forKey: Branch.publicName)
            let (gid, size, download) = (pub?.gid, pub?.size, pub?.download)
            depots.append(DepotInfo(
                depotID: id, name: d["name"]?.value, osList: osList, osArch: config?["osarch"]?.value,
                publicManifestGID: gid, publicManifestSize: size, publicManifestDownload: download,
                depotFromApp: d["depotfromapp"]?.uint32, sharedInstall: d["sharedinstall"]?.value == "1",
                dlcAppID: d["dlcappid"]?.uint32,
                encryptedManifestsOnly: gid == nil && d["encryptedmanifests"] != nil,
                language: config?["language"]?.value.flatMap { $0.isEmpty ? nil : $0.lowercased() },
                lowViolence: config?["lowviolence"]?.value == "1",
                branchManifests: manifests.isEmpty ? nil : manifests))
        }
        let branches = (depotsNode?["branches"]?.children ?? []).map { b in
            Branch(name: b.name, buildID: b["buildid"]?.uint32,
                   description: b["description"]?.value.flatMap { $0.isEmpty ? nil : $0 },
                   passwordRequired: b["pwdrequired"]?.value == "1", updated: b["timeupdated"]?.uint64)
        }
        return AppDepots(appID: appID, name: app.path("common", "name")?.value ?? "?",
                         publicBuildID: depotsNode?.path("branches", "public", "buildid")?.uint32,
                         changeNumber: nil, depots: depots,
                         installDir: app.path("config", "installdir")?.value.flatMap { $0.isEmpty ? nil : $0 },
                         branches: branches)
    }
}
