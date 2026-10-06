// SPDX-License-Identifier: GPL-3.0-or-later
// The Steam screens' state: one SteamService for the app's lifetime (the
// Keychain store), the
// Pair screen's PairingModel, the owned-games list, the art cache, the
// downloads (SteamInstalls) and what each game's Steam API emulator is told
// (SteamGameProfile).

import Combine
import Foundation
import SteamClientKit
import UIKit

@MainActor
final class SteamAccountModel: ObservableObject {
    let service: SteamService
    /// The download queue, every store's (Downloads.swift), and Steam's driver of it.
    let installs: Downloads
    let steamInstalls: SteamInstalls
    private let art: ArtworkCache

    @Published private(set) var state: SteamService.AccountState = .unknown
    @Published private(set) var pairing = PairingModel()
    /// The sign-in card "On this phone": account name, password, then approval or a code.
    @Published private(set) var credentials = CredentialSignInModel()
    /// The owned games; a change looks for updates to queue (SteamInstalls.checkUpdates).
    @Published private(set) var games: [SteamGame] = [] {
        didSet { steamInstalls.checkUpdates(games: games, titles: LibraryModel.shared.catalog.titles) }
    }
    @Published private(set) var gamesFetchedAt: Date?
    @Published private(set) var gamesLoading = false
    @Published private(set) var gamesError: String?
    /// The games are listed (cached or fetched), or there is no account to list them for:
    /// what the opening animation waits for from Steam (UI/AppOpening.swift).
    @Published private(set) var listedOnce = false
    @Published private(set) var lastRenewal: SteamService.Renewal?
    @Published private(set) var signingOut = false
    /// The emulator's profile per app, as kept by the service (loadGameProfile).
    @Published private(set) var gameProfiles: [UInt32: SteamGameProfile] = [:]
    @Published private(set) var gameProfileLoading: Set<UInt32> = []
    @Published private(set) var gameProfileErrors: [UInt32: String] = [:]
    /// Each game's stats and achievements as the last sync left them (syncStats).
    @Published private(set) var userStats: [UInt32: SteamService.StatsSync] = [:]
    @Published private(set) var statsSyncing: Set<UInt32> = []
    @Published private(set) var statsErrors: [UInt32: String] = [:]
    /// Each game's last Steam Cloud sync (syncCloud).
    @Published private(set) var cloud: [UInt32: SteamService.CloudSync] = [:]
    @Published private(set) var cloudSyncing: Set<UInt32> = []
    @Published private(set) var cloudErrors: [UInt32: String] = [:]
    /// Set when a title launch suspends the session (suspendForLaunch): from
    /// then on this process does no Steam work, so a page's sync is skipped
    /// rather than shown as "Not synced"; the next start of the app syncs
    /// every played game (syncPlayedStats).
    @Published private(set) var suspendedForLaunch = false

    /// Settings' switch for every game's Steam Cloud sync.
    static let cloudKey = "steamCloud"
    static var cloudOn: Bool { UserDefaults.standard.object(forKey: cloudKey) as? Bool ?? true }

    private var pairTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var guardCodes: GuardCodeInbox?
    private var catalogWatch: AnyCancellable?
    private var started = false
    private var images: [String: UIImage] = [:]

    /// A background refresh after a restore happens at most this often.
    static let refreshAge: TimeInterval = 15 * 60

    /// The model the UI created, if any: a title launch suspends its session
    /// (TitleLaunch.begin) even after the tab view is gone.
    static private(set) weak var current: SteamAccountModel?

    init() {
        let log = SteamUILog.logger
        service = SteamService(backend: SteamSession(store: KeychainSecretStore(), log: log), log: log,
                               stateDirectory: SteamPaths.state)
        art = ArtworkCache(directory: SteamPaths.art, log: log)
        installs = Downloads()
        steamInstalls = SteamInstalls(service: service, downloads: installs)
        installs.register(steamInstalls, for: .steam)
        GameImports.shared.attach(installs)
        Self.current = self
        // A game installed or updated (the catalogue's builds) may leave an update to queue, or none.
        catalogWatch = LibraryModel.shared.$catalog.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] catalog in
            MainActor.assumeIsolated {
                guard let self, !self.games.isEmpty else { return }
                self.steamInstalls.checkUpdates(games: self.games, titles: catalog.titles)
            }
        }
    }

    /// Before the runtime starts (decision 0004): cancel pairing, close the
    /// CM session, and keep Steam work out of this process from here on.
    /// The caller holds the model until the suspension has run.
    func suspendForLaunch() async {
        suspendedForLaunch = true
        installs.holdForLaunch()
        pairTask?.cancel()
        pairTask = nil
        credentialTask?.cancel()
        credentialTask = nil
        await service.suspendForLaunch()
    }

    /// A kept profile older than this is fetched again when its page opens.
    static let gameProfileAge: TimeInterval = 24 * 3600

    /// Shows the kept profile, then fetches it from Steam when `refresh`, or
    /// when there is none or it is older than a day and the account is signed in.
    func loadGameProfile(_ appID: UInt32, refresh: Bool = false) async {
        if let kept = await service.gameProfile(appID: appID) { gameProfiles[appID] = kept }
        let stale = gameProfiles[appID].map { Date().timeIntervalSince($0.fetchedAt) > Self.gameProfileAge } ?? true
        guard refresh || stale, case .signedIn = state, !suspendedForLaunch, !gameProfileLoading.contains(appID) else { return }
        gameProfileLoading.insert(appID)
        defer { gameProfileLoading.remove(appID) }
        do {
            gameProfiles[appID] = try await service.refreshGameProfile(appID: appID)
            gameProfileErrors[appID] = nil
        } catch {
            gameProfileErrors[appID] = InstallCopy.reason(error)
            SteamUILog.logger.warn("steamapi", "app \(appID): profile not fetched: \(error)")
        }
    }

    /// Brings the game's achievements and stats on Steam and in the
    /// emulator's save together (SteamService.syncUserStats): what a play
    /// earned goes to Steam. Needs the session, so a play's results go at the
    /// next start of the app, where every played game is synced.
    func syncStats(_ appID: UInt32) async {
        guard case .signedIn = state, !suspendedForLaunch, !statsSyncing.contains(appID) else { return }
        statsSyncing.insert(appID)
        defer { statsSyncing.remove(appID) }
        do {
            userStats[appID] = try await service.syncUserStats(appID: appID, saves: LibraryModel.emulatorSaves)
            statsErrors[appID] = nil
        } catch SteamError.notFound(_) {
            statsErrors[appID] = nil   // the game has no stats
        } catch {
            statsErrors[appID] = InstallCopy.reason(error)
            SteamUILog.logger.warn("stats", "app \(appID): not synced: \(error)")
        }
    }

    /// Every game the emulator has saved progress for, and every played game's cloud saves.
    func syncPlayedStats() async {
        let saves = LibraryModel.emulatorSaves
        let played = ((try? FileManager.default.contentsOfDirectory(atPath: saves.path)) ?? []).compactMap(UInt32.init)
        for app in played.sorted() { await syncStats(app) }
        for t in LibraryModel.shared.catalog.titles where t.lastPlayed != nil {
            if let app = t.appID { await syncCloud(app) }
        }
    }

    /// Brings the game's Steam Cloud saves and the phone's together
    /// (SteamService.syncCloud), with the player's choices for conflicts.
    /// Nothing when Steam Cloud is off in Settings or on the game's page.
    func syncCloud(_ appID: UInt32, resolve: [String: SteamService.CloudChoice] = [:]) async {
        guard Self.cloudOn, case .signedIn = state, !suspendedForLaunch, !cloudSyncing.contains(appID),
              let t = LibraryModel.shared.catalog.titles.first(where: { $0.appID == appID }),
              LaunchSettingsStore.shared.binding(for: t.id).wrappedValue.cloudSync ?? true else { return }
        cloudSyncing.insert(appID)
        defer { cloudSyncing.remove(appID) }
        do {
            cloud[appID] = try await service.syncCloud(appID: appID, roots: LibraryModel.cloudRoots(appID: appID, installDir: t.installDir),
                                                       backups: LibraryModel.cloudBackups, resolve: resolve)
            cloudErrors[appID] = nil
        } catch {
            cloudErrors[appID] = InstallCopy.reason(error)
            SteamUILog.logger.warn("cloud", "app \(appID): not synced: \(error)")
        }
    }

    #if !PLAYPORT_RELEASE
    /// A dev build's Game options: forget the game's last sync, then sync as a first one.
    func forgetCloud(_ appID: UInt32) async {
        await service.forgetCloud(appID: appID)
        cloud[appID] = nil
        SteamUILog.logger.info("cloud", "app \(appID): the last sync forgotten (a dev build's Game options)")
        await syncCloud(appID)
    }
    #endif

    /// The game's cloud conflicts still open, for Play (LibraryModel.play):
    /// after a sync already running for it (at most 30 s), from this process's
    /// last sync; a game not synced yet in this process is synced first when
    /// Steam is signed in, so Steam's newer saves come down before it starts;
    /// else the service's kept state. None when Steam Cloud is off in Settings
    /// or for the game.
    func openCloudConflicts(_ appID: UInt32, titleID: String) async -> [SteamService.CloudConflict] {
        guard Self.cloudOn, LaunchSettingsStore.shared.settings(for: titleID).cloudSync ?? true else { return [] }
        for _ in 0..<120 where cloudSyncing.contains(appID) { try? await Task.sleep(for: .milliseconds(250)) }
        if cloud[appID] == nil, case .signedIn = state { await syncCloud(appID) }
        if let c = cloud[appID] { return c.conflicts }
        return await service.keptCloud(appID: appID)?.conflicts ?? []
    }

    /// Follows the service's state for the model's lifetime. Called once.
    func start() {
        guard !started else { return }
        started = true
        Task {
            for await s in await service.observe() {
                let wasSignedIn = state.account != nil
                state = s
                // The download queue runs while Steam is signed in (SteamInstalls): at every
                // start of the app that is once the stored session is restored.
                switch s {
                case .signedIn: steamInstalls.signedIn(true)
                case .signedOut, .expired, .offline: steamInstalls.signedIn(false)
                case .unknown, .restoring, .pairing: break
                }
                if s.account == nil, wasSignedIn { games = []; gamesFetchedAt = nil }
            }
        }
    }

    // MARK: foreground

    /// Every return to the foreground (and the first): a silent restore, then
    /// the cached games at once and a background refresh when they are old.
    func sceneBecameActive() {
        start()
        Task {
            let s = await service.restoreIfPossible()
            lastRenewal = await service.lastRenewal
            guard s.account != nil else { listedOnce = true; return }
            // What the last play earned goes to Steam (the play itself ran with Steam closed).
            if case .signedIn = s { Task { await self.syncPlayedStats() } }
            await showCachedGames()
            if !games.isEmpty { listedOnce = true }
            if case .signedIn = s, gamesFetchedAt.map({ Date().timeIntervalSince($0) > Self.refreshAge }) ?? true {
                await loadGames(refresh: true)
            }
            listedOnce = true
        }
    }

    /// Leaving the foreground cancels a pairing attempt: iOS suspends the
    /// poll, and Steam then expires the session anyway. A credential sign-in
    /// goes on: its approval is in the Steam Mobile app, often on this phone,
    /// and its poll picks the same session up again on the way back.
    func sceneLeftActive() {
        guard pairing.isInFlight else { return }
        pairing.sceneBecameInactive()
        pairTask?.cancel()
        pairTask = nil
        updateIdleTimer()
    }

    // MARK: pairing

    func startPairing() {
        cancelCredentialSignIn()
        pairTask?.cancel()
        pairing = PairingModel()
        pairing.start()
        updateIdleTimer()
        let stream = service.signIn(method: .qr())
        pairTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    self.pairing.apply(event)
                    self.updateIdleTimer()
                    if case .signedIn = event {
                        await self.loadGames(refresh: true)
                    }
                }
            } catch {
                guard let self else { return }
                self.pairing.apply(error as? SignInFailure ?? .failed("\(error)"))
            }
            self?.updateIdleTimer()
        }
    }

    func cancelPairing() {
        pairTask?.cancel()
        pairTask = nil
        pairing = PairingModel()
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = pairing.keepsScreenAwake || credentials.keepsScreenAwake
    }

    // MARK: sign-in by account name (UI/SignInView.swift)

    /// The name keyboard closed; true when the password comes next.
    func credentialName(_ name: String) -> Bool {
        credentials.setAccountName(name)
        return credentials.phase == .password
    }

    /// The password keyboard closed. The password goes straight into the
    /// sign-in, which encrypts it for Steam and drops it; nothing here keeps it.
    func credentialPassword(_ password: String) {
        credentials.passwordEntered(empty: password.isEmpty)
        guard !password.isEmpty else { return }
        pairTask?.cancel()
        pairTask = nil
        if pairing.isInFlight { pairing = PairingModel() }
        credentialTask?.cancel()
        let codes = GuardCodeInbox()
        guardCodes = codes
        updateIdleTimer()
        let stream = service.signIn(method: .credentials(CredentialLogin(accountName: credentials.accountName,
                                                                        password: Secret(password), codes: codes)))
        credentialTask = Task { [weak self] in
            do {
                for try await event in stream {
                    // A cancelled attempt (Cancel, or a new one) no longer owns the card.
                    guard let self, !Task.isCancelled else { return }
                    self.credentials.apply(event)
                    self.updateIdleTimer()
                    if case .signedIn = event { await self.loadGames(refresh: true) }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.credentials.apply(error as? SignInFailure ?? .failed("\(error)"))
            }
            self?.updateIdleTimer()
        }
    }

    /// A Steam Guard code typed on the card.
    func submitGuardCode(_ code: String) {
        guard credentials.takesCode, let guardCodes, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guardCodes.submit(code)
        credentials.codeSubmitted()
    }

    /// Cancel (B) or a new attempt: the running sign-in stops, the name stays.
    func cancelCredentialSignIn() {
        credentialTask?.cancel()
        credentialTask = nil
        guardCodes = nil
        credentials.reset()
        updateIdleTimer()
    }

    // MARK: account

    func signOut() async {
        steamInstalls.holdForSignOut()
        signingOut = true
        defer { signingOut = false }
        do {
            let r = try await service.signOut()
            SteamUILog.logger.info("ui", "signed out: revoked=\(r.revoked) (\(r.revokeResult)) credentialsDeleted=\(r.credentialsDeleted)")
        } catch {
            SteamUILog.logger.warn("ui", "sign-out failed: \(error)")
        }
        // Which apps have art cached says what the account owned (decision 0004).
        try? await art.clear()
        images = [:]
        games = []
        gamesFetchedAt = nil
        lastRenewal = nil
        pairing = PairingModel()
        credentials = CredentialSignInModel()
    }

    // MARK: games

    func showCachedGames() async {
        guard games.isEmpty, let cached = await service.cachedGames() else { return }
        games = cached.games
        gamesFetchedAt = cached.fetchedAt
    }

    func loadGames(refresh: Bool) async {
        guard !gamesLoading else { return }
        gamesLoading = true
        defer { gamesLoading = false }
        do {
            games = try await service.ownedGames(refresh: refresh)
            gamesFetchedAt = Date()
            gamesError = nil
        } catch {
            gamesError = "Couldn't refresh your library (\(error))."
        }
    }

    func appInfo(_ appID: UInt32) async throws -> SteamAppInfo {
        try await service.appInfo(appID)
    }

    // MARK: art

    /// Art already loaded, without waiting: a view drawn again shows it at once.
    func cachedImage(_ app: SteamAppInfo, _ kind: ArtworkCache.Kind) -> UIImage? {
        images["\(app.appID)/\(kind.rawValue)"]
    }

    func image(_ app: SteamAppInfo, _ kind: ArtworkCache.Kind) async -> UIImage? {
        let key = "\(app.appID)/\(kind.rawValue)"
        if let hit = images[key] { return hit }
        guard let url = try? await art.image(app, kind), let img = UIImage(contentsOfFile: url.path) else { return nil }
        images[key] = img
        return img
    }
}
