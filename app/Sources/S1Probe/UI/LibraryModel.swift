// SPDX-License-Identifier: GPL-3.0-or-later
// The library the product UI shows: PlayportKit's catalogue, re-adopted from
// the prefix's C:\Games each time the app comes to the front, with the bundled
// cohort (Titles/ at the app root) and the install engine's receipts. Every
// path is fixed at launch: wine_host_init points HOME at the prefix later.
// Verification, uninstall and adoption run off the main thread; their results
// are logged to the app log (AppLog) as `library:` lines. None needs Steam:
// a Steam install is verified against its retained manifests.

import Foundation
import PlayportKit
import SteamClientKit
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    /// The app container, the parent of Documents.
    nonisolated static let home = WineHostRuntime.documents.deletingLastPathComponent()
    nonisolated static let paths = PlayportPaths.container(home: home)
    /// Where the Steam API emulator saves each game's achievements and stats
    /// (`%APPDATA%\GSE Saves\<appid>` in the prefix; EmulatorStats).
    nonisolated static let emulatorSaves = WineHostRuntime.documents
        .appendingPathComponent("prefix/drive_c/users/playport/AppData/Roaming/GSE Saves", isDirectory: true)
    /// Where Steam Cloud's roots are (Cloud.Roots) for a game in `installDir`.
    nonisolated static func cloudRoots(appID: UInt32, installDir: String) -> Cloud.Roots {
        Cloud.Roots(user: WineHostRuntime.documents.appendingPathComponent("prefix/drive_c/users/playport", isDirectory: true),
                    gameInstall: paths.games.appendingPathComponent(installDir, isDirectory: true),
                    remote: EmulatorStats.folder(emulatorSaves, appID: appID).appendingPathComponent("remote", isDirectory: true))
    }
    /// The copies a cloud sync replaced, one folder per game and sync (in Files).
    nonisolated static let cloudBackups = WineHostRuntime.documents.appendingPathComponent("Cloud Backups", isDirectory: true)
    nonisolated static let cohort: Cohort = {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Titles", isDirectory: true)
        do {
            return try Cohort.load(directory: dir)
        } catch {
            log("no cohort list at \(dir.lastPathComponent)/titles.json: \(error)")
            return Cohort(titles: [])
        }
    }()

    @Published private(set) var catalog: Catalog
    @Published private(set) var scanning = false
    /// A scan has finished since launch (a dev build's UIDriver waits for it).
    @Published private(set) var scannedOnce = false
    @Published private(set) var verifying: Set<String> = []
    /// The last verification's failure to run, by title.
    @Published private(set) var verifyErrors: [String: String] = [:]
    @Published private(set) var removing: Set<String> = []
    @Published private(set) var removeErrors: [String: String] = [:]
    /// A refresh asked for while a scan ran: its scan may predate the change.
    private var rescan = false
    private let store = CatalogStore(url: LibraryModel.paths.catalog)

    private init() {
        _ = (Self.home, Self.paths, Self.cohort)
        catalog = store.load()
        // A game's session that its process did not live to count (the restart after it, a
        // crash, the app ended from outside): added up to its last beat (UI/PlayClock.swift).
        let clock = PlayClock.shared.store
        if let left = clock.load() {
            if catalog.addPlayTime(left) { save() }
            clock.clear()
            Self.log("play time: \(left.titleID) +\(Int(left.seconds)) s from the session the last process left"
                     + " (total \(Int(catalog.title(id: left.titleID)?.playSeconds ?? 0)) s)")
        }
        // Cloud saves a sync replaced are kept 30 days (Cloud.Backups): once per process, which
        // after decision 0029 is once per game played.
        Task.detached(priority: .utility) {
            let removed = Cloud.Backups.prune(LibraryModel.cloudBackups)
            if !removed.isEmpty {
                LibraryModel.log("cloud backups: removed \(removed.count) older than 30 days: "
                                 + removed.map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" }.joined(separator: ", "))
            }
        }
    }

    /// The game ended in this process: its session counts when the runtime ran it
    /// (`counted`), not for a launch refused before that.
    func sessionEnded(counted: Bool) {
        guard let s = PlayClock.shared.end(), counted else { return }
        catalog.addPlayTime(s)
        save()
        Self.log("play time: \(s.titleID) +\(Int(s.seconds)) s (total \(Int(catalog.title(id: s.titleID)?.playSeconds ?? 0)) s)")
    }

    nonisolated static func log(_ line: String) { WineHostRuntime.appendLog("library: " + line) }

    /// Re-adopts what is on disk. Not while a title runs: the catalogue is the
    /// launcher's, not the game's.
    func refresh() {
        guard !TitleLaunch.shared.running else { return }
        guard !scanning else { rescan = true; return }
        scanning = true
        let previous = catalog
        Task.detached(priority: .userInitiated) {
            let paths = LibraryModel.paths
            let scanned = Adoption.scan(games: paths.games, cohort: LibraryModel.cohort,
                                        receipts: Adoption.receipts(in: paths.layout.installsDir),
                                        storeReceipts: paths.layout.storeReceipts(), previous: previous)
            await LibraryModel.shared.adopted(scanned)
        }
    }

    private func adopted(_ scanned: Catalog) {
        scanning = false
        scannedOnce = true
        // Edits made while the scan ran win over the scan's copy of them.
        var merged = scanned
        for i in merged.titles.indices {
            guard let now = catalog.title(id: merged.titles[i].id) else { continue }
            merged.titles[i].lastPlayed = now.lastPlayed
            merged.titles[i].playSeconds = now.playSeconds
            if now.buildID == merged.titles[i].buildID { merged.titles[i].lastVerification = now.lastVerification }
        }
        if merged.titles.map(\.id) != catalog.titles.map(\.id) {
            Self.log("adopted \(merged.titles.count) title(s): "
                     + merged.titles.map { "\($0.name) [\($0.badge.rawValue)]" }.joined(separator: ", "))
        }
        // A title removed while the scan ran stays removed.
        merged.titles.removeAll { removing.contains($0.id) }
        catalog = merged
        save()
        if rescan {
            rescan = false
            refresh()
        }
    }

    func title(_ id: String) -> InstalledTitle? { catalog.title(id: id) }

    /// Runs the setup checks (SetupState.beforePlay), awaits on-device setup when needed, then starts TitleLaunch; false on
    /// cancellation or a title that can no longer play.
    /// Its screen, frame rate limit, Direct3D backend, environment and steam_api come from LaunchSettingsStore;
    /// its memory need (MemoryNeed) from the cohort; a Steam app runs with its app ID as Steam's game id (SteamGameID);
    /// FEX's memory ordering and block size from the game's profile with its page's choices over it (FEXProfile).
    /// Throws for a title whose executable is not a path inside C:\Games, or whose
    /// cohort entry has a bad madeira.cfg key or screen (LaunchPlanError).
    @discardableResult
    func play(_ id: String) async throws -> Bool {
        guard catalog.title(id: id)?.canPlay == true, !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return false }
        // A game whose saves changed on the phone and on Steam asks which to keep first; the
        // choice starts it, Decide later does not (UI/CloudConflictView.swift).
        if let t = catalog.title(id: id), let app = t.appID, let steam = SteamAccountModel.current {
            let conflicts = await steam.openCloudConflicts(app, titleID: id)
            if !conflicts.isEmpty {
                Self.log("play \(t.name) (\(id)): \(conflicts.count) cloud save conflict(s); asking which saves to keep")
                askCloud(t, app, conflicts, thenPlay: true)
                return false
            }
        }
        // The first-run checks, by themselves: a missing pairing file (iOS 26) opens the checklist
        // with the fix; a missing pairing (iOS 27) or LocalDevVPN down JitSetup fixes (UI/SetupView.swift).
        guard SetupState.shared.beforePlay(steamGame: catalog.title(id: id)?.appID != nil) else { return false }
        guard await JitSetup.shared.ensureReady() else { return false }
        // Setup may outlive navigation or a catalogue refresh: validate again
        // and build the launch from current settings only after sheet dismissal.
        guard let t = catalog.title(id: id), t.canPlay, !verifying.contains(id), !removing.contains(id),
              !TitleLaunch.shared.running, !TitleLaunch.shared.spent,
              SteamAccountModel.current?.installs.jobs[t.key] == nil else { return false }
        let plan = try t.launchPlan(cohort: Self.cohort)
        // The player's settings over 720p, 60 fps, Vulkan for DX12 and DXMT otherwise.
        #if PLAYPORT_RELEASE
        var settings = LaunchSettingsStore.shared.effective(for: t)
        // Memory ordering, block size, x87 precision, the disk cache, the Steam API choice and runtime keys are a dev build's
        // (decision 0034): the player's app runs the game's profile and the emulator, whatever a dev build left stored.
        settings.ordering = MemoryOrdering()
        settings.maxInst = nil
        settings.x87Reduced = nil
        settings.diskCache = nil
        settings.steamAPI = .emulated
        settings.runtime = [:]
        #else
        let settings = LaunchSettingsStore.shared.effective(for: t)
        #endif
        // A Steam app's steam_api: the emulator told about the paired account, or the game's own.
        let service = SteamAccountModel.current?.service
        let steamAPI = t.appID.map { app in
            LaunchCoordinator.SteamAPI(appID: app, root: Self.paths.games.appendingPathComponent(t.installDir, isDirectory: true),
                                       mode: settings.steamAPI,
                                       settings: { await service?.emulatorSettings(appID: app) ?? .init(appID: app) })
        }
        // FEX's disk cache stays under its budget (decision 0056): cleared before this launch when over it.
        await Task.detached(priority: .userInitiated) { EmulatorCache.keepWithinBudget { Self.log($0) } }.value
        let fex = FEXProfile.launch(appID: t.appID, exe: plan.exe, ordering: settings.ordering, maxInst: settings.maxInst,
                                    x87Reduced: settings.x87Reduced, diskCache: settings.diskCache)
        guard TitleLaunch.shared.start(title: t.name, titleID: t.id, exe: plan.exe, args: plan.args + settings.arguments,
                                       config: settings.config(over: plan.config),
                                       screen: settings.screen, frameLimit: settings.frameLimit,
                                       graphics: settings.graphics,
                                       steamAppID: t.appID, fex: fex, steamAPI: steamAPI,
                                       memory: MemoryNeed.of(t, cohort: Self.cohort)) else { return false }
        catalog.update(id) { $0.lastPlayed = Date() }
        save()
        PlayClock.shared.begin(id)
        if let detection = t.direct3D {
            Self.log("Direct3D evidence for \(t.id): \(detection.summary), modules=\(detection.modulesScanned) limited=\(detection.limited)")
            for evidence in detection.evidence {
                Self.log("Direct3D \(evidence.api.rawValue): \(evidence.module) \(evidence.kind.rawValue) \(evidence.name)")
            }
        }
        Self.log("play \(t.name) (\(t.id)) on \(settings.graphics.rawValue): \(plan.exe) \((plan.args + settings.arguments).joined(separator: " "))")
        return true
    }

    /// The Cloud save conflict screen for the game's open conflicts; `thenPlay` starts it once settled.
    func askCloud(_ t: InstalledTitle, _ app: UInt32, _ conflicts: [SteamService.CloudConflict], thenPlay: Bool) {
        PadModal.shared.cloudConflict(CloudConflictSession(titleID: t.id, appID: app, name: t.name, conflicts: conflicts,
                                                           thenPlay: thenPlay, playSeconds: t.playSeconds))
    }

    /// A cohort title has a committed checksum list; a Steam install has its retained manifests.
    func canVerify(_ t: InstalledTitle) -> Bool { t.checksums != nil || (t.source == .installed && t.appID != nil) }

    /// Hashes every file against the title's checksum list or, for a Steam
    /// install, the manifests it was installed from.
    func verify(_ id: String) {
        guard let t = catalog.title(id: id), canVerify(t), !verifying.contains(id), !removing.contains(id) else { return }
        verifying.insert(id)
        verifyErrors[id] = nil
        UIApplication.shared.isIdleTimerDisabled = true
        Self.log("verify \(t.name) against \(t.checksums ?? "its Steam manifests")")
        Task.detached(priority: .userInitiated) {
            let started = Date()
            do {
                let (v, report): (InstalledTitle.Verification, TitleInstaller.VerifyReport)
                if t.checksums == nil, let app = t.appID {
                    let r = try await TitleInstaller(layout: LibraryModel.paths.layout, session: nil, log: SteamUILog.logger).verify(appID: app)
                    (v, report) = (InstalledTitle.Verification(date: Date(), files: r.files, bad: r.bad.count, unlisted: r.unlisted.count), r)
                } else {
                    (v, report) = try await TitleVerifier.verify(t, games: LibraryModel.paths.games, cohort: LibraryModel.cohort)
                }
                LibraryModel.log("verify \(t.name): \(v.files - v.bad)/\(v.files) OK, \(v.bad) bad, \(v.unlisted) unlisted, "
                                 + String(format: "%.1f s", Date().timeIntervalSince(started))
                                 + (report.bad.isEmpty ? "" : "; bad: " + report.bad.prefix(20).joined(separator: ", ")))
                await LibraryModel.shared.verified(id, v, error: nil)
            } catch {
                LibraryModel.log("verify \(t.name) failed: \(error)")
                await LibraryModel.shared.verified(id, nil, error: "\(error)")
            }
        }
    }

    /// A Steam repair's final report: every file now matches.
    func recordVerification(appID: UInt32, report r: TitleInstaller.VerifyReport) {
        let id = "app-\(appID)"
        Self.log("repair \(id): \(r.repaired ?? 0) file(s) replaced, \(r.files) OK")
        catalog.update(id) { $0.lastVerification = .init(date: Date(), files: r.files, bad: r.bad.count, unlisted: r.unlisted.count) }
        verifyErrors[id] = nil
        save()
    }

    private func verified(_ id: String, _ v: InstalledTitle.Verification?, error: String?) {
        verifying.remove(id)
        UIApplication.shared.isIdleTimerDisabled = !verifying.isEmpty || SteamAccountModel.current?.installs.isBusy == true
        if let v { catalog.update(id) { $0.lastVerification = v } }
        verifyErrors[id] = error
        save()
    }

    /// Deletes the title's folder from C:\Games (and, for a Steam install, its
    /// record, manifests and any paused download). Saves kept in the prefix's
    /// user profile stay. Not while the title is running or being checked.
    func uninstall(_ id: String) {
        guard let t = catalog.title(id: id), !removing.contains(id), !verifying.contains(id), !TitleLaunch.shared.running
        else { return }
        removing.insert(id)
        removeErrors[id] = nil
        // A paused update or repair of it goes too (the uninstall deletes its stage).
        if let installs = SteamAccountModel.current?.installs, installs.jobs[t.key] != nil {
            installs.discard(t.key)
        }
        Self.log("uninstall \(t.name) (\(t.id)): C:\\Games\\\(t.installDir)")
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try TitleInstaller(layout: LibraryModel.paths.layout, session: nil, log: SteamUILog.logger)
                    .uninstall(installDir: t.installDir, appID: t.appID)
                // Another store's or an import's receipt (decision 0057).
                if t.store != .steam { LibraryModel.paths.layout.removeReceipt(t.key) }
            } catch {
                LibraryModel.log("uninstall \(t.name) failed: \(error)")
                failure = "\(error)"
            }
            await LibraryModel.shared.removed(id, error: failure)
        }
    }

    /// The game page's Executable: the player's pick (nil: adoption's own), then a
    /// re-adoption so its machine and Direct3D evidence follow it.
    func setExecutable(_ id: String, _ path: String?) {
        guard !TitleLaunch.shared.running else { return }
        catalog.update(id) { $0.chosenExecutable = path }
        save()
        Self.log("executable of \(id): \(path ?? "adoption's pick")")
        refresh()
    }

    /// The game page's Name: display only (the title's ID does not change); empty puts the folder's back.
    func rename(_ id: String, _ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        catalog.update(id) {
            $0.displayName = trimmed?.isEmpty == false ? trimmed : nil
            if let n = $0.displayName { $0.name = n }
        }
        save()
        refresh()
    }

    private func removed(_ id: String, error: String?) {
        if let error {
            removeErrors[id] = error
        } else {
            catalog.titles.removeAll { $0.id == id }
            save()
        }
        removing.remove(id)
        refresh()
    }

    private func save() {
        do {
            try store.save(catalog)
        } catch {
            Self.log("catalog not saved: \(error)")
        }
    }

    /// Free space for new installs, as the system counts it for important use.
    var freeBytes: UInt64? {
        let v = try? Self.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    /// The phone's storage in all (Downloads' storage bar).
    var totalBytes: UInt64? {
        let v = try? Self.home.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return v?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
    }
}
