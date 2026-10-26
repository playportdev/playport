// SPDX-License-Identifier: GPL-3.0-or-later
// The library the product UI shows: PlayportKit's catalogue, re-adopted from
// the prefix's C:\Games each time the app comes to the front, with the bundled
// cohort (Titles/ at the app root) and the install engine's receipts. Every
// path is fixed at launch: wine_host_init points HOME at the prefix later.
// Verification, uninstall and adoption run off the main thread; their results
// are logged to the app log (AppLog) as `library:` lines. None needs Steam:
// a Steam install is verified against its retained manifests.

import EpicClientKit
import GOGClientKit
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
    /// What a Play does before the game starts, by title id, for its Play button (a Steam game's
    /// redistributables download).
    @Published private(set) var preparing: [String: String] = [:]
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
        removeSteamTickets("at app start")
        removeEpicOwnershipFiles("at app start")
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

    /// The latest removal of encrypted app tickets (removeSteamTickets); Play waits for it.
    private var ticketSweep: Task<Void, Never>?

    /// Takes the encrypted app ticket out of every installed Steam game's
    /// emulator settings (decision 0017): at app start, for one a crash, a kill
    /// or the restart after a game left behind, and at sign-out. Off the main
    /// thread; a Play waits for it before it writes its own.
    @discardableResult
    func removeSteamTickets(_ when: String) -> Task<Void, Never> {
        let roots = catalog.titles.filter { $0.appID != nil }
            .map { Self.paths.games.appendingPathComponent($0.installDir, isDirectory: true) }
        let previous = ticketSweep
        let task = Task.detached(priority: .utility) {
            await previous?.value
            var removed = 0
            for root in roots {
                do { removed += try SteamAPISwap.removeTickets(in: root) } catch {
                    LibraryModel.log("ticket: not removed from \(root.lastPathComponent) \(when): \(error)")
                }
            }
            LibraryModel.log("ticket: \(removed) removed \(when) (\(roots.count) Steam game(s) checked)")
        }
        ticketSweep = task
        return task
    }

    /// The latest removal of Epic ownership token files; an Epic Play waits for it.
    private var ownershipSweep: Task<Void, Never>?

    /// Takes the ownership token file out of every installed Epic game's folder
    /// (decision 0059): at app start, for one a crash, a kill or the restart after a
    /// game left behind, and at sign-out. Off the main thread.
    @discardableResult
    func removeEpicOwnershipFiles(_ when: String) -> Task<Void, Never> {
        let roots = catalog.titles.filter { $0.store == .epic }
            .map { Self.paths.games.appendingPathComponent($0.installDir, isDirectory: true) }
        let previous = ownershipSweep
        let task = Task.detached(priority: .utility) {
            await previous?.value
            var removed = 0
            for root in roots {
                do { removed += try EpicOwnershipFile.remove(in: root) } catch {
                    LibraryModel.log("epic: ownership token file not removed from \(root.lastPathComponent) \(when): \(error)")
                }
            }
            LibraryModel.log("epic: \(removed) ownership token file(s) removed \(when) (\(roots.count) Epic game(s) checked)")
        }
        ownershipSweep = task
        return task
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
    /// An Epic game starts signed in (decision 0059): a fresh exchange code and, when its catalogue
    /// asks, an ownership token. When they cannot be had it does not start; the player gets Try again,
    /// and for a game that may run offline Play offline (`epicOffline`), which starts it as before
    /// step 1 of the store game sign-in plan, with no sign-in arguments.
    /// `continuing`: the Play goes on after Playport's restart that followed its prerequisites
    /// (AppRestart.continuePlay, decision 0084): no cloud save check (the Play passed it a few
    /// seconds ago) and no prerequisites, so it cannot restart again.
    @discardableResult
    func play(_ id: String, epicOffline: Bool = false, continuing: Bool = false) async throws -> Bool {
        guard catalog.title(id: id)?.canPlay == true, !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return false }
        // A game whose saves changed on the phone and on Steam asks which to keep first; the
        // choice starts it, Decide later does not (UI/CloudConflictView.swift).
        if !continuing, let t = catalog.title(id: id), let app = t.appID, let steam = SteamAccountModel.current {
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
        var plan = try t.launchPlan(cohort: Self.cohort)
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
        settings.graphicsEnvironment = [:]
        #else
        let settings = LaunchSettingsStore.shared.effective(for: t)
        #endif
        // A Steam app's steam_api: the emulator told about the paired account, or the game's own.
        let service = SteamAccountModel.current?.service
        // The emulator's encrypted app ticket, on by default (decision 0017): asked for now, while the
        // session is up (TitleLaunch.start closes it), after the start's sweep of old ones.
        var ticket: Secret<[UInt8]>?
        // The game's auth session and web API tickets, on by default (decision 0062): armed now, and
        // the CM session stays logged on for them alone through the play.
        var tickets: SteamTicketBroker?
        if let app = t.appID, settings.steamAPI == .emulated, let service {
            await ticketSweep?.value
            ticket = await service.encryptedAppTicket(appID: app)
            tickets = await service.prepareTicketSession(appID: app, playLog: SteamTicketHost.log)
        }
        let steamAPI = t.appID.map { app in
            LaunchCoordinator.SteamAPI(appID: app, root: Self.paths.games.appendingPathComponent(t.installDir, isDirectory: true),
                                       mode: settings.steamAPI,
                                       settings: { await service?.emulatorSettings(appID: app) ?? .init(appID: app) },
                                       ticket: ticket, tickets: tickets)
        }
        let endTickets = { if tickets != nil { Task { await service?.endPlay() } } }
        // An Epic game's sign-in (decision 0059), fetched now: the code lives five minutes.
        var epicArgs: [String] = []
        var epic: LaunchCoordinator.Epic?
        if t.store == .epic {
            await ownershipSweep?.value
            let root = Self.paths.games.appendingPathComponent(t.installDir, isDirectory: true)
            epic = LaunchCoordinator.Epic(root: root)
            if epicOffline {
                Self.log("epic: \(t.name) plays offline, not signed in (the player's choice)")
            } else {
                let started = Date()
                do {
                    let signIn = try await EpicAccount.shared.launchSignIn(t.key.id, installDir: t.installDir)
                    epicArgs = EpicInstaller.authArguments(signIn.auth)
                    epic?.ownershipToken = signIn.ownershipToken
                    Self.log("epic: \(t.name) signed in for the launch: exchange code fetched"
                             + (signIn.ownershipToken != nil ? ", with an ownership token" : "")
                             + String(format: " in %.2f s", Date().timeIntervalSince(started)))
                } catch {
                    Self.log("epic: \(t.name) could not be signed in: \(error)")
                    askEpicSignIn(t, error)
                    endTickets()
                    return false
                }
            }
        }
        // A page's sidecar check can finish while adoption or sign-in is in flight. Use the
        // kept record for this one public ID, with no extra Play-time request (PLA-61).
        if t.store == .epic, let rec = EpicAccount.shared.installer.loadRecord(t.key.id) {
            plan.args = EpicInstaller.withDeployment(plan.args, deploymentID: rec.deploymentID)
        }
        // The game's own prerequisite installers, run before it when they have not run in the
        // prefix (decision 0079): the files the game ships (and, for a Steam game, the Steam
        // redistributables it lists, decision 0081). The Epic build's,
        // and Unreal Engine's, which a UE game's bootstrap would run itself without the prefix
        // seed's VC++ runtime key.
        var storePrerequisites: [Prerequisite] = []
        if continuing {
            Self.log("play \(t.name) (\(t.id)): continued after its prerequisites ran before the restart; none run now")
        } else if t.store == .epic, let p = EpicAccount.shared.installer.prerequisite(t.key.id) {
            do {
                if let pre = try Prerequisite.make(ids: p.ids, name: p.name, installDir: t.installDir, path: p.path, arguments: p.args) {
                    storePrerequisites.append(pre)
                }
            } catch {
                Self.log("epic: \(t.name)'s prerequisite is not a file in its folder (\(error)); not run")
            }
        }
        let installDir = t.installDir
        var unrealEngine: Prerequisite?
        if !continuing {
            unrealEngine = await Task.detached(priority: .userInitiated) {
                Prerequisite.unrealEngine(installDir: installDir, games: Self.paths.games)
            }.value
        }
        // A Steam game's install scripts (decision 0081): its own, and those of the Steamworks Common
        // Redistributables depots it lists, downloaded first when Playport does not hold them yet.
        if !continuing, let app = t.appID, t.store == .steam {
            storePrerequisites += await steamInstallScripts(t, appID: app)
        }
        // A GOG game's redistributables (decision 0090): those its build names, from GOG's
        // dependency repository, placed in its folder first when absent.
        if !continuing, t.store == .gog {
            storePrerequisites += await gogDependencies(t)
            storePrerequisites += await gogSupportSetups(t)
            gogInstallScripts(t)
        }
        let prerequisites = Prerequisite.merge(store: storePrerequisites, unrealEngine: unrealEngine)
        // A GOG game's Galaxy service (decision 0063), on by default: listening from now to the game's exit
        // when its build names a Galaxy client and GOG is signed in; otherwise the game runs without it.
        let galaxy = t.store == .gog ? await GOGAccount.shared.galaxyListener(t.key.id, name: t.name) : nil
        // FEX's disk cache stays under its budget (decision 0056): cleared before this launch when over it.
        await Task.detached(priority: .userInitiated) { EmulatorCache.keepWithinBudget { Self.log($0) } }.value
        // The on-screen controller under the game, on a foldable only (VirtualGamepad.swift).
        VirtualGamepad.shared.prepare(settings.virtualPad && Panel.isFoldable, layout: settings.virtualPadLayout, titleID: t.id)
        let fex = FEXProfile.launch(appID: t.appID, exe: plan.exe, ordering: settings.ordering, maxInst: settings.maxInst,
                                    x87Reduced: settings.x87Reduced, diskCache: settings.diskCache)
        guard TitleLaunch.shared.start(title: t.name, titleID: t.id, exe: plan.exe, args: plan.args + settings.arguments + epicArgs,
                                       config: settings.config(over: plan.config),
                                       screen: settings.guestScreen, frameLimit: settings.frameLimit,
                                       graphics: settings.graphics, graphicsEnvironment: settings.graphicsEnvironment,
                                       steamAppID: t.appID, fex: fex, steamAPI: steamAPI,
                                       memory: MemoryNeed.of(t, cohort: Self.cohort), epic: epic, galaxy: galaxy,
                                       prerequisites: prerequisites, epicOffline: epicOffline) else {
            endTickets()
            galaxy?.stop()
            return false
        }
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

    /// A Steam game's install-script prerequisites (decision 0081), its `Registry` values written
    /// for the runtime's start. The app 228980 depots it lists that Playport lacks are downloaded
    /// into Games/Steamworks Shared first, on the paired session; without them (no session, a
    /// failed download) their entries are left out and the game starts all the same.
    private func steamInstallScripts(_ t: InstalledTitle, appID: UInt32) async -> [Prerequisite] {
        let layout = Self.paths.layout, games = Self.paths.games, prefix = WineHostRuntime.shared.prefixURL
        let local = TitleInstaller(layout: layout, session: nil, log: SteamUILog.logger)
        let shared = local.loadReceipt(appID)?.commonRedistributableDepots ?? []
        // DirectX June 2010's depot holds only DXSETUP, which is skipped: not downloaded for it.
        let fetch = CommonRedistributables.depotsToDownload(shared)
        let directXAbsent = shared.contains(CommonRedistributables.directXJun2010Depot)
            && !local.missingCommonRedistributables([CommonRedistributables.directXJun2010Depot]).isEmpty
        if directXAbsent {
            Self.log("steam: \(t.name) lists DirectX June 2010 (depot \(CommonRedistributables.directXJun2010Depot)); "
                     + "not downloaded: its one entry, DXSETUP, is skipped")
        }
        let missing = local.missingCommonRedistributables(fetch)
        if !missing.isEmpty {
            Self.log("steam: \(t.name) lists Steamworks Common Redistributables depots \(shared); downloading \(missing)")
            preparing[t.id] = "Downloading Steam redistributables…"
            let started = Date()
            do {
                guard let service = SteamAccountModel.current?.service else { throw SteamError.notLoggedOn }
                let installer = try await service.titleInstaller(layout: layout)
                let r = try await installer.installCommonRedistributables(fetch, say: { line in
                    if !line.hasPrefix("progress:") { SteamUILog.logger.info("redist", line) }
                })
                Self.log("steam: Steamworks Common Redistributables \(r?.receipt.depots.map(\.depotID) ?? []) in Games/"
                         + "\(CommonRedistributables.installDir), \(r?.stage?.downloadedBytes ?? 0) bytes downloaded"
                         + String(format: " in %.1f s", Date().timeIntervalSince(started)))
            } catch {
                Self.log("steam: Steamworks Common Redistributables \(missing) not downloaded (\(error)); \(t.name) starts without them")
            }
            preparing[t.id] = nil
        }
        let installDir = t.installDir, name = t.name
        let s = await Task.detached(priority: .userInitiated) { () -> SteamPrerequisites in
            let hive = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
            var s = SteamPrerequisites()
            func add(_ dir: String, _ script: String) {
                let url = games.appendingPathComponent(dir, isDirectory: true).appendingPathComponent(script)
                do {
                    s.add(try SteamInstallScript.parse(try Data(contentsOf: url)), appID: appID, installDir: dir, script: script,
                          games: games, hive: hive)
                } catch {
                    s.notes.append("\(dir)/\(script): not read (\(error)); left out")
                }
            }
            // Steam's order: the shared redistributables, then the game's own scripts.
            let wanted = Set(shared)
            for (depot, script) in local.installScripts(appID: CommonRedistributables.appID) where wanted.contains(depot) {
                add(CommonRedistributables.installDir, script)
            }
            if directXAbsent {
                s.add(.directXJun2010, appID: appID, installDir: CommonRedistributables.installDir,
                      script: SteamInstallScript.directXJun2010Script, games: games, hive: hive)
            }
            var own = local.installScripts(appID: appID).map(\.path)
            if own.isEmpty, local.loadReceipt(appID) == nil {
                own = SteamPrerequisites.scriptFiles(in: games.appendingPathComponent(installDir, isDirectory: true))
            }
            for script in own { add(installDir, script) }
            return s
        }.value
        for note in s.notes { Self.log("steam: \(name) install script: \(note)") }
        // A skipped entry (DXSETUP) is recorded as skipped, and its HasRunKey written as after a
        // success, before the runtime starts, so the game sees it installed in this Play.
        if !s.skipped.isEmpty {
            let store = PrerequisiteStore(prefix: prefix)
            var record = store.load()
            for k in s.skipped {
                Self.log(k.line)
                record.recordSkipped(ids: k.ids, name: k.name, reason: k.reason, title: name, build: Manifest.build)
            }
            do { try store.save(record) } catch { Self.log("steam: \(name) skipped prerequisites not recorded: \(error)") }
        }
        let registry = s.registry + s.skipped.flatMap(\.registry)
        if !registry.isEmpty {
            do {
                try PrefixRegistryFile(prefix: prefix).add(registry)
                Self.log("steam: \(name) install script registry: \(registry.map { "\($0.key) \"\($0.name)\"" }.joined(separator: ", "))")
            } catch {
                Self.log("steam: \(name) install script registry not written: \(error)")
            }
        }
        if !s.prerequisites.isEmpty {
            Self.log("steam: \(name) install scripts: \(s.prerequisites.count) prerequisite(s): \(s.prerequisites.map(\.name).joined(separator: ", "))")
        }
        return s.prerequisites
    }

    /// A GOG game's redistributables (decision 0090), as GOG Galaxy and Heroic install them: the ids
    /// its build names, looked up in GOG's dependency repository; DirectX and the .NET Framework are
    /// recorded as skipped (Playport's builtins and Wine Mono cover them); each other installer is
    /// placed in the game's folder when absent and runs once per prefix. Without GOG (signed out,
    /// offline, a failed download) the ones it cannot place are left out and the game starts.
    private func gogDependencies(_ t: InstalledTitle) async -> [Prerequisite] {
        let installer = GOGAccount.shared.installer, prefix = WineHostRuntime.shared.prefixURL
        let pid = t.key.id, name = t.name, installDir = t.installDir
        let ids = await installer.dependencyIDs(productID: pid)
        guard !ids.isEmpty else { return [] }
        let repository: [GOGDependency]
        do {
            repository = try await installer.dependencyRepository(for: ids)
        } catch {
            Self.log("gog: \(name) names redistributables [\(ids.joined(separator: ", "))]; GOG's repository not read (\(error)); it starts without them")
            return []
        }
        let s = GOGDependencies.select(ids, from: repository)
        for note in s.notes { Self.log("gog: \(name) redistributable \(note)") }
        if !s.skipped.isEmpty {
            let store = PrerequisiteStore(prefix: prefix)
            var record = store.load()
            for k in s.skipped {
                let id = GOGDependencies.prerequisiteID(k.dependency.id)
                Self.log("prerequisite: GOG \(k.dependency.name) (\(id)) skipped: \(k.reason)")
                record.recordSkipped(ids: [id], name: k.dependency.name, reason: k.reason, title: name, build: Manifest.build)
            }
            do { try store.save(record) } catch { Self.log("gog: \(name) skipped prerequisites not recorded: \(error)") }
        }
        // Only those not yet run (or a failure from another build) are fetched.
        let record = PrerequisiteStore(prefix: prefix).load()
        func prerequisite(_ d: GOGDependency) -> Prerequisite? {
            let ids = [GOGDependencies.prerequisiteID(d.id)]
            // An .msi through Wine's msiexec (decision 0103), an .exe itself with GOG's command-line
            // string as it is, as GOG Galaxy passes it (decision 0090, PLA-251).
            return d.isWindowsInstallerPackage
                ? try? Prerequisite.windowsInstallerPackage(ids: ids, name: d.name, installDir: installDir, path: d.executable, arguments: d.arguments)
                : try? Prerequisite.verbatim(ids: ids, name: d.name, installDir: installDir, path: d.executable, arguments: d.arguments)
        }
        let pending = s.run.filter { d in prerequisite(d).map { !record.pending($0, build: Manifest.build).isEmpty } ?? false }
        let missing = installer.missingDependencies(pending, installDir: installDir)
        var absent = Set<String>()
        if !missing.isEmpty {
            Self.log("gog: \(name) redistributables to download: \(missing.map(\.id).joined(separator: ", "))")
            preparing[t.id] = "Downloading GOG redistributables…"
            let started = Date()
            do {
                let bytes = try await installer.placeDependencies(missing, productID: pid, installDir: installDir)
                Self.log("gog: \(name) redistributables in its folder, \(bytes) bytes downloaded"
                         + String(format: " in %.1f s", Date().timeIntervalSince(started)))
            } catch {
                Self.log("gog: \(name) redistributables not downloaded (\(error)); it starts without them")
                absent = Set(installer.missingDependencies(missing, installDir: installDir).map(\.id))
            }
            preparing[t.id] = nil
        }
        let out = s.run.filter { !absent.contains($0.id) }.compactMap(prerequisite)
        if !out.isEmpty {
            Self.log("gog: \(name) redistributables: \(out.count) prerequisite(s): \(out.map(\.name).joined(separator: ", "))")
        }
        return out
    }

    /// A GOG game's support setups (decision 0099), as GOG Galaxy and Heroic run them after an install:
    /// each installed product's `temp_executable`, from the game's folder, with Heroic's command line,
    /// once per prefix and build, after its redistributables. A setup not in the folder is left out.
    private func gogSupportSetups(_ t: InstalledTitle) async -> [Prerequisite] {
        let installer = GOGAccount.shared.installer
        let pid = t.key.id, name = t.name, installDir = t.installDir
        guard let rec = installer.loadRecord(pid) else { return [] }
        let commands = await installer.supportCommands(productID: pid)
        let folder = installer.layout.gamesRoot.appendingPathComponent(installDir, isDirectory: true)
        return commands.compactMap { c in
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(c.executable).path) else {
                Self.log("gog: \(name) support setup \(c.executable) is not in its folder; left out")
                return nil
            }
            do {
                guard var p = try Prerequisite.make(ids: [GOGSupportCommand.prerequisiteID(productID: c.productID, buildID: rec.buildID)],
                                                    name: "GOG setup (\(c.executable))", installDir: installDir, path: c.executable,
                                                    arguments: "") else { return nil }
                p.args = GOGSupportCommand.arguments(folder: "C:\\Games\\" + installDir.replacingOccurrences(of: "/", with: "\\"),
                                                     productID: c.productID, buildID: rec.buildID, version: rec.version)
                Self.log("gog: \(name) support setup: \(p.exe)")
                return p
            } catch {
                Self.log("gog: \(name) support setup \(c.executable) is not a file in its folder (\(error)); not run")
                return nil
            }
        }
    }

    /// A GOG game's install scripts (decision 0103): the setRegistry values of each
    /// `goggame-<product>.script` its install holds, written for the runtime's start (a value the
    /// prefix holds is kept); the scripts' other actions are left out and logged.
    private func gogInstallScripts(_ t: InstalledTitle) {
        let installer = GOGAccount.shared.installer, prefix = WineHostRuntime.shared.prefixURL
        guard let rec = installer.loadRecord(t.key.id) else { return }
        let folder = installer.layout.gamesRoot.appendingPathComponent(rec.installDir, isDirectory: true)
        let windows = "C:\\Games\\" + rec.installDir.replacingOccurrences(of: "/", with: "\\")
        var registry: [PrefixRegistryValue] = []
        for file in GOGInstallScript.scriptFiles(rec.files.map(\.path)) {
            do {
                let plan = try GOGInstallScript.parse(try Data(contentsOf: folder.appendingPathComponent(file))).plan(folder: windows)
                for note in plan.notes { Self.log("gog: \(t.name) install script \(file): \(note)") }
                registry += plan.registry
            } catch {
                Self.log("gog: \(t.name) install script \(file) not read (\(error)); left out")
            }
        }
        guard !registry.isEmpty else { return }
        do {
            try PrefixRegistryFile(prefix: prefix).add(registry)
            Self.log("gog: \(t.name) install script registry: \(registry.map { "\($0.hive.rawValue) \($0.key) \"\($0.name)\"" }.joined(separator: ", "))")
        } catch {
            Self.log("gog: \(t.name) install script registry not written: \(error)")
        }
    }

    /// Epic could not sign the game in: Try again, Play offline for a game that may run
    /// offline (its catalogue allows it and asks for no ownership token), or Cancel.
    func askEpicSignIn(_ t: InstalledTitle, _ error: Error) {
        let offline = EpicAccount.shared.game(t.key.id)?.mayPlayOffline ?? false
        let why: String
        if case ClientError.notLoggedOn? = error as? ClientError {
            why = "You are not signed in to Epic Games. Sign in under Settings › Accounts."
        } else {
            why = InstallCopy.detailed("Epic Games can't be reached.", error)
        }
        let note = why + (offline ? " This game can also play offline, without its online features." : "")
        var options = [PadOption(id: "retry", label: "Try again")]
        if offline { options.append(PadOption(id: "offline", label: "Play offline")) }
        options.append(PadOption(id: "cancel", label: "Cancel"))
        PadModal.shared.picker(title: "Epic could not sign the game in", context: t.name, note: note, options: options,
                               selected: nil) { choice in
            switch choice {
            case "retry": Task { try? await LibraryModel.shared.play(t.id) }
            case "offline": Task { try? await LibraryModel.shared.play(t.id, epicOffline: true) }
            default: break
            }
        }
    }

    /// The Cloud save conflict screen for the game's open conflicts; `thenPlay` starts it once settled.
    func askCloud(_ t: InstalledTitle, _ app: UInt32, _ conflicts: [SteamService.CloudConflict], thenPlay: Bool) {
        PadModal.shared.cloudConflict(CloudConflictSession(titleID: t.id, appID: app, name: t.name, conflicts: conflicts,
                                                           thenPlay: thenPlay, playSeconds: t.playSeconds))
    }

    /// A cohort title has a committed checksum list; a Steam install has its retained manifests.
    func canVerify(_ t: InstalledTitle) -> Bool {
        t.checksums != nil || (t.source == .installed && t.appID != nil)
            || (t.store == .gog && GOGAccount.shared.installer.loadRecord(t.key.id) != nil)
            || (t.store == .epic && EpicAccount.shared.installer.loadRecord(t.key.id) != nil)
    }

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
                if t.store == .gog, t.checksums == nil {
                    let r = try await GOGAccount.shared.installer.verify(productID: t.key.id)
                    let v = InstalledTitle.Verification(date: Date(), files: r.files, bad: r.bad.count, unlisted: 0)
                    LibraryModel.log("verify \(t.name): \(r.files - r.bad.count)/\(r.files) OK against GOG's manifest"
                                     + (r.bad.isEmpty ? "" : "; bad: " + r.bad.prefix(20).joined(separator: ", ")))
                    await LibraryModel.shared.verified(id, v, error: nil)
                    return
                }
                if t.store == .epic, t.checksums == nil {
                    let r = try await EpicAccount.shared.installer.verify(t.key.id)
                    let v = InstalledTitle.Verification(date: Date(), files: r.files, bad: r.bad.count, unlisted: 0)
                    LibraryModel.log("verify \(t.name): \(r.files - r.bad.count)/\(r.files) OK against Epic's manifest, "
                                     + String(format: "%.1f s", Date().timeIntervalSince(started))
                                     + (r.bad.isEmpty ? "" : "; bad: " + r.bad.prefix(20).joined(separator: ", ")))
                    await LibraryModel.shared.verified(id, v, error: nil)
                    return
                }
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

    /// A store's repair finished (GOG, Epic): its verification as it stands now.
    func recordVerification(_ id: String, files: Int, bad: [String]) {
        Self.log("repair \(id): \(files - bad.count)/\(files) OK after")
        catalog.update(id) { $0.lastVerification = .init(date: Date(), files: files, bad: bad.count, unlisted: 0) }
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
    /// record, manifests and any paused download); in a folder another Steam
    /// app shares, only the files that app does not list (TitleInstaller.uninstallShared).
    /// Saves kept in the prefix's user profile stay. Not while the title is
    /// running or being checked.
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
                if t.store == .gog { await GOGAccount.shared.installer.forget(productID: t.key.id) }
                if t.store == .epic { await EpicAccount.shared.installer.forget(t.key.id) }
            } catch {
                LibraryModel.log("uninstall \(t.name) failed: \(error)")
                failure = "\(error)"
            }
            await LibraryModel.shared.removed(id, error: failure)
        }
    }

    /// Steam's shared redistributables in Games/Steamworks Shared (decision 0081), which the
    /// library does not list: their size from their install record, nil when none is installed.
    nonisolated func steamworksSharedBytes() async -> UInt64? {
        await Task.detached(priority: .utility) {
            TitleInstaller(layout: LibraryModel.paths.layout, session: nil, log: SteamUILog.logger)
                .loadReceipt(CommonRedistributables.appID)?.bytes
        }.value
    }

    /// Settings › Storage's Remove on Steamworks Shared: its folder, record and manifests go, as
    /// a title's uninstall removes them; the next Play of a game that lists them downloads them
    /// again (steamInstallScripts). Not while a game runs or a Play is preparing. The size left
    /// (nil when removed).
    func removeSteamworksShared() async -> UInt64? {
        guard !TitleLaunch.shared.running, preparing.isEmpty else { return await steamworksSharedBytes() }
        Self.log("steam: removing Games/\(CommonRedistributables.installDir) (Steamworks Common Redistributables)")
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try TitleInstaller(layout: LibraryModel.paths.layout, session: nil, log: SteamUILog.logger)
                    .uninstall(installDir: CommonRedistributables.installDir, appID: CommonRedistributables.appID)
                return nil
            } catch {
                return "\(error)"
            }
        }.value
        Self.log("steam: Games/\(CommonRedistributables.installDir) \(error.map { "not removed: \($0)" } ?? "removed")")
        return await steamworksSharedBytes()
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
