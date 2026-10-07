// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The QR code the Pair screen shows. The payload is the secret challenge URL;
/// the fingerprint is a short, non-reversible label of it that the screen and
/// the redacted log both show, so a scan can be matched to the code shown.
public struct QRCode: Sendable, Equatable {
    public var payload: Secret<String>
    public var fingerprint: String
    /// When the pairing attempt gives up locally (the countdown's end).
    public var expiresAt: Date
    /// 1 for the first challenge, +1 each time Steam replaces it.
    public var generation: Int

    public init(payload: Secret<String>, expiresAt: Date, generation: Int) {
        self.payload = payload
        self.fingerprint = Self.fingerprint(of: payload)
        self.expiresAt = expiresAt
        self.generation = generation
    }

    /// Four Crockford base-32 characters (no I, L, O or U), taken from 20
    /// bits of the payload's SHA-1.
    public static func fingerprint(of payload: Secret<String>) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let h = SHA1.hash(Array(payload.value.utf8))
        let bits = UInt32(h[0]) << 12 | UInt32(h[1]) << 4 | UInt32(h[2]) >> 4
        return String((0..<4).map { alphabet[Int((bits >> (15 - 5 * $0)) & 0x1f)] })
    }
}

public enum SignInMethod: Sendable {
    /// Another device signed in to the account scans a QR code and approves.
    case qr(deadline: TimeInterval = 300)
    /// The account name and password typed on this phone, then an approval in
    /// the Steam Mobile app or a Steam Guard code (`CredentialLogin.codes`).
    case credentials(CredentialLogin)
}

/// A sign-in by account name and password. The password lives only in this
/// value, which the sign-in drops once Steam has it (encrypted); it is never
/// stored or logged.
public struct CredentialLogin: Sendable {
    public var accountName: String
    public var password: Secret<String>
    /// Where the screen sends a Steam Guard code while the sign-in runs.
    public var codes: GuardCodeInbox
    public var deadline: TimeInterval

    public init(accountName: String, password: Secret<String>, codes: GuardCodeInbox, deadline: TimeInterval = 300) {
        self.accountName = accountName
        self.password = password
        self.codes = codes
        self.deadline = deadline
    }
}

public enum SignInEvent: Sendable, Equatable {
    /// A code to show: the first challenge, or Steam's replacement for it.
    case code(QRCode)
    case scanned
    case approved(accountTag: String)
    /// A credential sign-in: Steam took the password and wants one of these to confirm it.
    case confirm([AuthConfirmation])
    /// A credential sign-in: Steam took the Steam Guard code, or refused it (another may follow).
    case codeAccepted
    case codeRejected
    /// Logged on with the new session; the last event of a successful sign-in.
    case signedIn(SteamService.Account)
}

/// How a sign-in attempt ended without a session. Each maps to one Pair-screen state.
public enum SignInFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// Steam ended the session unscanned, or the local deadline passed.
    case expired
    /// Steam ended the session after the code was scanned: declined on the
    /// other device (Steam reports a denial and a timeout the same way).
    case denied
    /// The attempt was abandoned here (the app left the foreground, or the user cancelled).
    case cancelled
    /// Another sign-in, restore or sign-out is running.
    case busy
    /// Steam refused the account name and password.
    case wrongPassword
    /// Steam refuses sign-ins from here for a while (too many attempts).
    case throttled
    case network(String)
    case failed(String)

    public var description: String {
        switch self {
        case .expired: return "expired"
        case .denied: return "denied"
        case .cancelled: return "cancelled"
        case .busy: return "busy"
        case .wrongPassword: return "wrong password"
        case .throttled: return "throttled"
        case let .network(s): return "network: \(s)"
        case let .failed(s): return "failed: \(s)"
        }
    }

    static func from(_ error: Error, scanned: Bool) -> SignInFailure {
        if let f = error as? SignInFailure { return f }
        if error is CancellationError { return .cancelled }
        guard let e = error as? SteamError else { return .failed("\(type(of: error))") }
        switch e {
        case .cancelled: return .cancelled
        case .qrExpired: return .expired
        case let .qrSessionEnded(r): return r == .accessDenied || scanned ? .denied : .expired
        case let .credentialsRefused(r):
            switch r {
            case .invalidPassword: return .wrongPassword
            case .rateLimitExceeded, .accountLoginDeniedThrottle: return .throttled
            case .invalidState: return .busy
            default: return .failed("Steam refused the sign-in (\(r.name))")
            }
        case let .authSessionEnded(r):
            switch r {
            case .accessDenied: return .denied
            case .rateLimitExceeded, .accountLoginDeniedThrottle: return .throttled
            default: return .expired
            }
        case .eresult(.invalidState, _): return .busy
        case .transport, .timeout, .retriesExhausted: return .network(e.description)
        default: return .failed(e.description)
        }
    }
}

/// The app's one Steam session and everything the UI does with it: pairing, silent restore, token renewal, the owned
/// library, title metadata and sign-out (docs/ARCHITECTURE.md, Native Steam client).
///
/// Nothing here holds a secret beyond the call that needs it: the refresh
/// token stays in the backend's credential store, the QR payload goes to the
/// presenter only, and the files this actor writes (`stateDirectory`) are
/// non-secret: the renewal record, the owned-games cache and the Steam API
/// emulator's profiles (persona name, SteamID64, owned DLC).
public actor SteamService {
    public struct Account: Sendable, Equatable, Codable {
        public var accountTag: String
        public var steamIDTag: String
        /// The refresh token's `exp`: how long the pairing lasts without renewal.
        public var pairedUntil: Date?

        public init(accountTag: String, steamIDTag: String, pairedUntil: Date?) {
            self.accountTag = accountTag
            self.steamIDTag = steamIDTag
            self.pairedUntil = pairedUntil
        }

        init(stored s: StoredSession) {
            accountTag = Redactor.tag("acct", s.accountName)
            steamIDTag = Redactor.tag("sid", String(s.steamID))
            pairedUntil = (try? JWTClaims(token: Secret(s.refreshToken)))?.expiry
        }
    }

    public enum AccountState: Sendable, Equatable {
        /// Before the first `restoreIfPossible()`.
        case unknown
        case signedOut
        case restoring(Account?)
        case pairing
        case signedIn(Account)
        /// Paired, but Steam could not be reached; cached data still shows.
        case offline(Account, reason: String)
        /// Steam refused the stored session, or it expired: pair again.
        case expired

        public var account: Account? {
            switch self {
            case let .signedIn(a), let .offline(a, _): return a
            case let .restoring(a): return a
            default: return nil
            }
        }
    }

    /// The last automatic renewal attempt, kept (non-secret) across launches.
    public struct Renewal: Sendable, Codable, Equatable {
        public var at: Date
        /// "renewed", "not-due" (Steam kept the current token) or "failed: ...".
        public var result: String
        public var pairedUntil: Date?
    }

    struct Record: Codable, Equatable {
        var lastRenewal: Renewal?
        var sessionEnded = false
    }

    public let backend: SteamBackend
    public let log: Logger
    public let renewInterval: TimeInterval
    public let autoRenew: Bool
    private let stateDirectory: URL?
    private let now: @Sendable () -> Date

    public private(set) var state: AccountState = .unknown
    private var record = Record()
    private var appInfoCache: [UInt32: SteamAppInfo] = [:]
    private var observers: [UUID: AsyncStream<AccountState>.Continuation] = [:]
    private var signInTask: Task<Void, Never>?
    private var restoreTask: Task<AccountState, Never>?
    private var signingOut = false
    private var suspended = false

    /// - Parameters:
    ///   - stateDirectory: where the renewal record and games cache live
    ///     (the app: `Library/Application Support/Playport/steam`); nil keeps them in memory.
    ///   - renewInterval: the least time between automatic renewal attempts.
    ///   - autoRenew: renew after a restore when due; off, only an explicit `renewIfDue()` renews.
    public init(backend: SteamBackend, log: Logger, stateDirectory: URL?, renewInterval: TimeInterval = 86_400,
                autoRenew: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.log = log
        self.stateDirectory = stateDirectory
        self.renewInterval = renewInterval
        self.autoRenew = autoRenew
        self.now = now
        if let url = stateDirectory?.appendingPathComponent(Self.recordFile),
           let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Record.self, from: data) {
            record = r
        }
    }

    static let recordFile = "service.json"
    static let gamesFile = "steam-games.json"
    static let profilesFile = "steam-game-profiles.json"
    static let statsDirectory = "steam-stats"
    static let cloudDirectory = "steam-cloud"

    // MARK: state

    /// The current state, then every change, until the stream is dropped.
    public func observe() -> AsyncStream<AccountState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AccountState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation.yield(state)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropObserver(id) } }
        return stream
    }

    private func dropObserver(_ id: UUID) { observers[id] = nil }

    private func set(_ s: AccountState) {
        guard s != state else { return }
        state = s
        for c in observers.values { c.yield(s) }
    }

    public var lastRenewal: Renewal? { record.lastRenewal }

    private func saveRecord() {
        guard let dir = stateDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: dir.appendingPathComponent(Self.recordFile), options: .atomic)
        } catch {
            log.warn("service", "cannot save the service record: \(error)")
        }
    }

    private func checkNotSuspended() throws {
        if suspended { throw SteamError.unsupported("Steam is suspended for a title launch") }
    }

    /// A socket left from an anonymous logon, or one that died in suspension,
    /// must go before a new account logon runs on it.
    private func dropStaleConnection() async {
        let s = await backend.isLoggedOn()
        if s.anonymous || (s.loggedOn && !s.connected) || (!s.loggedOn && s.connected) { await backend.disconnect() }
    }

    // MARK: sign-in

    /// Starts pairing. The stream yields the code (again on every
    /// replacement), the scan, the approval and finally `signedIn`; it throws
    /// a `SignInFailure` otherwise. Dropping or cancelling the stream's
    /// consumer cancels the attempt.
    public nonisolated func signIn(method: SignInMethod = .qr()) -> AsyncThrowingStream<SignInEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<SignInEvent, Error>.makeStream()
        let task = Task { await self.runSignIn(method, continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private final class ScanFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var scanned = false
        private var approved = false
        private var generation = 0
        func markScanned() { lock.withLock { scanned = true } }
        func markApproved() { lock.withLock { approved = true } }
        var wasScanned: Bool { lock.withLock { scanned } }
        var wasApproved: Bool { lock.withLock { approved } }
        func nextGeneration() -> Int { lock.withLock { generation += 1; return generation } }
    }

    private func runSignIn(_ method: SignInMethod, _ out: AsyncThrowingStream<SignInEvent, Error>.Continuation) async {
        // Held so sign-out and a title launch can cancel it too.
        let inner = Task { await self.pair(method, out) }
        signInTask = inner
        await withTaskCancellationHandler { await inner.value } onCancel: { inner.cancel() }
    }

    private func pair(_ method: SignInMethod, _ out: AsyncThrowingStream<SignInEvent, Error>.Continuation) async {
        let deadline: TimeInterval
        switch method {
        case let .qr(d): deadline = d
        case let .credentials(c): deadline = c.deadline
        }
        if suspended { out.finish(throwing: SignInFailure.failed("suspended for a title launch")); return }
        if state == .pairing { out.finish(throwing: SignInFailure.busy); return }
        if case .signedIn = state { out.finish(throwing: SignInFailure.failed("already signed in; sign out first")); return }
        let before = state
        set(.pairing)
        await dropStaleConnection()
        let flag = ScanFlag()
        let started = now()
        let expiresAt = started.addingTimeInterval(deadline)
        let log = self.log
        do {
            let summary: AccountSummary
            switch method {
            case .qr:
                summary = try await backend.loginWithQR(deadline: deadline) { event in
                    switch event {
                    case let .challenge(url, _), let .replaced(url):
                        let code = QRCode(payload: url, expiresAt: expiresAt, generation: flag.nextGeneration())
                        log.info("pair", "code \(code.generation) shown: fingerprint \(code.fingerprint) (payload redacted)")
                        out.yield(.code(code))
                    case .scanned:
                        flag.markScanned()
                        out.yield(.scanned)
                    case let .approved(tag):
                        flag.markApproved()
                        out.yield(.approved(accountTag: tag))
                    }
                }
            case let .credentials(c):
                log.info("pair", "sign-in with \(Redactor.tag("acct", c.accountName)) and a password")
                summary = try await backend.loginWithCredentials(accountName: c.accountName, password: c.password,
                                                                 codes: c.codes, deadline: deadline) { event in
                    switch event {
                    case let .confirm(kinds):
                        // Past the password: a later end is a denial or an expiry, not a wrong password.
                        flag.markScanned()
                        out.yield(.confirm(kinds))
                    case .codeAccepted: out.yield(.codeAccepted)
                    case .codeRejected: out.yield(.codeRejected)
                    case let .approved(tag):
                        flag.markApproved()
                        out.yield(.approved(accountTag: tag))
                    }
                }
            }
            var account = Account(accountTag: summary.accountTag, steamIDTag: summary.steamIDTag, pairedUntil: nil)
            if let s = try? await backend.storedSession() { account.pairedUntil = Account(stored: s).pairedUntil }
            // A fresh token needs no renewal for a full interval.
            record.lastRenewal = Renewal(at: now(), result: "paired", pairedUntil: account.pairedUntil)
            record.sessionEnded = false
            saveRecord()
            log.info("pair", "paired \(account.accountTag); token valid until \(Self.stamp(account.pairedUntil))")
            set(.signedIn(account))
            out.yield(.signedIn(account))
            out.finish()
        } catch {
            let failure = SignInFailure.from(error, scanned: flag.wasScanned)
            log.info("pair", "pairing ended: \(failure) after \(Int(now().timeIntervalSince(started)))s")
            await backend.disconnect()
            // Approved means the token is already stored: a failed first logon
            // is recovered by a restore, not a second approval.
            if flag.wasApproved, !Task.isCancelled, (try? await backend.storedSession()) != nil {
                set(.signedOut)
                // A fresh token: no renewal due for a full interval.
                record.lastRenewal = Renewal(at: now(), result: "paired", pairedUntil: nil)
                let st = await restoreIfPossible()
                if case let .signedIn(account) = st {
                    record.lastRenewal?.pairedUntil = account.pairedUntil
                    saveRecord()
                    log.info("pair", "approved session restored after the first logon failed")
                    out.yield(.signedIn(account))
                    out.finish()
                    return
                }
                out.finish(throwing: failure)
                return
            }
            set(before == .expired ? .expired : .signedOut)
            out.finish(throwing: failure)
        }
    }

    // MARK: restore and renewal

    /// Logs on silently with the stored session, when there is one: at launch,
    /// on every return to the foreground and before any account call. Never
    /// shows UI and never throws; the outcome is the returned state. After a
    /// successful restore it renews the token when the last attempt is older
    /// than `renewInterval`. Concurrent callers share one in-flight restore;
    /// during a sign-out it returns the current state without logging on.
    @discardableResult
    public func restoreIfPossible() async -> AccountState {
        if signingOut { return state }
        if let restoreTask { return await restoreTask.value }
        let task = Task { await restoreOnce() }
        restoreTask = task
        let st = await task.value
        restoreTask = nil
        return st
    }

    private func restoreOnce() async -> AccountState {
        if suspended { return state }
        switch state {
        case .pairing: return state
        case .signedIn:
            let s = await backend.isLoggedOn()
            if s.loggedOn && !s.anonymous && s.connected {
                if autoRenew { await renewIfDue() }
                return state
            }
        default: break
        }
        let stored: StoredSession?
        do { stored = try await backend.storedSession() } catch {
            log.warn("service", "credential store unreadable: \(error)")
            set(.signedOut)
            return state
        }
        guard let stored else {
            set(record.sessionEnded ? .expired : .signedOut)
            return state
        }
        let account = Account(stored: stored)
        if let exp = account.pairedUntil, exp.timeIntervalSince(now()) < 60 {
            log.info("service", "stored session for \(account.accountTag) expired at \(Self.stamp(exp)); pair again")
            endSession()
            return state
        }
        set(.restoring(account))
        await dropStaleConnection()
        do {
            let summary = try await backend.restore()
            var a = account
            a.accountTag = summary.accountTag
            a.steamIDTag = summary.steamIDTag
            record.sessionEnded = false
            set(.signedIn(a))
            if autoRenew { await renewIfDue() }
        } catch let SteamError.eresult(r, context) where Self.deadSession.contains(r) {
            log.info("service", "Steam refused the stored session (\(r.name), \(context)); pair again")
            endSession()
        } catch SteamError.noCredentials {
            set(.signedOut)
        } catch {
            log.warn("service", "restore failed, keeping the pairing: \(error)")
            await backend.disconnect()
            set(.offline(account, reason: Self.reason(error)))
        }
        return state
    }

    /// EResults for which the stored token is dead (SteamSession.logOn deletes it).
    static let deadSession: Set<EResult> = [.invalidPassword, .accessDenied, .expired, .revoked, .invalidSignature, .accountDisabled]

    private func endSession() {
        record.sessionEnded = true
        saveRecord()
        clearGamesCache()
        appInfoCache = [:]
        set(.expired)
    }

    /// Renews the refresh token when the last attempt (or the pairing) is
    /// older than `renewInterval`. The outcome is logged and kept in
    /// `lastRenewal`; a failure leaves the session as it is.
    public func renewIfDue() async {
        guard case let .signedIn(account) = state else { return }
        if let last = record.lastRenewal, now().timeIntervalSince(last.at) < renewInterval { return }
        let result: String
        do {
            result = try await backend.renewTokens() ? "renewed" : "not-due"
        } catch {
            result = "failed: \(error)"
        }
        var a = account
        if let s = try? await backend.storedSession() { a.pairedUntil = Account(stored: s).pairedUntil }
        record.lastRenewal = Renewal(at: now(), result: result, pairedUntil: a.pairedUntil)
        saveRecord()
        log.info("service", "token renewal: \(result); paired until \(Self.stamp(a.pairedUntil))")
        if case .signedIn = state { set(.signedIn(a)) }
    }

    // MARK: library

    /// The owned-games list as last cached for the current account, for an
    /// instant first paint; nil when there is none, or when it was cached
    /// before branches were read (so the version picker has them).
    public func cachedGames() -> (games: [SteamGame], fetchedAt: Date)? {
        guard let tag = state.account?.accountTag, let snap = loadGamesCache(), snap.accountTag == tag,
              !snap.games.contains(where: { $0.info.depots.branches == nil }) else { return nil }
        return (snap.games, snap.fetchedAt)
    }

    /// The account's games with their badges: licenses, then the apps they
    /// grant, then each app's PICS record, then only games. Unless `refresh`,
    /// a cached list for this account is returned without a network call.
    public func ownedGames(refresh: Bool) async throws -> [SteamGame] {
        try checkNotSuspended()
        if !refresh, let cached = cachedGames() { return cached.games }
        if case .signedIn = state {} else { await restoreIfPossible() }
        guard case let .signedIn(account) = state else { throw SteamError.notLoggedOn }
        let licenses = try await backend.awaitLicenses(timeout: 20)
        let ids = try await backend.ownedAppIDs(licenses: licenses)
        let records = try await backend.appRecords(ids)
        var infos: [SteamAppInfo] = []
        for id in ids {
            guard let kv = records[id] else { continue }
            do {
                let info = try SteamAppInfo.parse(appID: id, kv)
                infos.append(info)
                appInfoCache[id] = info
            } catch {
                log.warn("library", "app \(id): unreadable PICS record: \(error)")
            }
        }
        let games = SteamGame.games(from: infos)
        log.info("library", "\(licenses.count) licenses, \(ids.count) apps, \(games.count) games")
        saveGamesCache(GamesSnapshot(accountTag: account.accountTag, fetchedAt: now(), games: games))
        return games
    }

    /// One app's title metadata from PICS. It uses the paired session when
    /// there is one, and an anonymous session otherwise (public metadata only).
    public func appInfo(_ appID: UInt32) async throws -> SteamAppInfo {
        try checkNotSuspended()
        if let hit = appInfoCache[appID] { return hit }
        let s = await backend.isLoggedOn()
        if !(s.loggedOn && s.connected) {
            switch await restoreIfPossible() {
            case .signedIn: break
            default:
                await backend.disconnect()
                _ = try await backend.logOnAnonymous()
            }
        }
        guard let kv = try await backend.appRecords([appID])[appID] else { throw SteamError.notFound("PICS app \(appID)") }
        let info = try SteamAppInfo.parse(appID: appID, kv)
        appInfoCache[appID] = info
        return info
    }

    /// An installer on the paired account's session, logged on (restored
    /// when it dropped), for install, update and repair. Refused once the
    /// process is suspended for a title launch (decision 0004).
    public func titleInstaller(layout: InstallLayout) async throws -> TitleInstaller {
        try checkNotSuspended()
        guard let session = backend as? SteamSession else { throw SteamError.unsupported("installs need a real Steam session") }
        let s = await backend.isLoggedOn()
        if !(s.loggedOn && !s.anonymous && s.connected) { await restoreIfPossible() }
        guard case .signedIn = state else { throw SteamError.notLoggedOn }
        return TitleInstaller(layout: layout, session: session, log: log)
    }

    // MARK: the Steam API emulator's profile

    /// What the game's Steam API emulator is told (SteamAPISwap): the persona
    /// name, the SteamID64 and the DLC the account owns among the app's. It is
    /// fetched now, on the paired session, and kept for launches, which run
    /// with the session closed (decision 0004); `gameProfile` reads it back.
    public func refreshGameProfile(appID: UInt32) async throws -> SteamGameProfile {
        try checkNotSuspended()
        if case .signedIn = state {} else { await restoreIfPossible() }
        guard case .signedIn = state, let stored = try await backend.storedSession() else { throw SteamError.notLoggedOn }
        let account = Account(stored: stored)
        let persona: String?
        do {
            persona = try await backend.personaName()
        } catch {
            log.warn("steamapi", "persona name unavailable (\(error)); the emulator reports none")
            persona = nil
        }
        let owned = Set(try await backend.ownedAppIDs(licenses: try await backend.awaitLicenses(timeout: 20)))
        guard let app = try await backend.appRecords([appID])[appID] else { throw SteamError.notFound("PICS app \(appID)") }
        let ids = SteamGameProfile.ownedDLC(app: app, owned: owned)
        let names = ids.isEmpty ? [:] : try await backend.appRecords(ids)
        let dlc = ids.map { SteamGameProfile.DLC(appID: $0, name: names[$0]?.path("common", "name")?.value ?? "DLC \($0)") }
        let profile = SteamGameProfile(appID: appID, personaName: persona, steamID: stored.steamID, dlc: dlc, fetchedAt: now())
        var snap = loadProfiles()
        if snap?.accountTag != account.accountTag { snap = ProfilesSnapshot(accountTag: account.accountTag, profiles: [:]) }
        snap?.profiles[String(appID)] = profile
        if let snap { saveProfiles(snap) }
        log.info("steamapi", "app \(appID): profile for the emulator: persona \(persona == nil ? "none" : "known"), \(dlc.count) owned DLC")
        return profile
    }

    /// The profile last fetched for this app on the paired account, also while
    /// suspended for a launch; nil when there is none or the account is gone.
    public func gameProfile(appID: UInt32) async -> SteamGameProfile? {
        guard let snap = await pairedProfiles() else { return nil }
        return snap.profiles[String(appID)]
    }

    /// What the emulator is told at a launch, with no network (the session is
    /// closed by then): the SteamID64 of the paired account, always the same
    /// for it, so a game's per-user saves stay where they are; the persona name
    /// and owned DLC from the last `refreshGameProfile` (the persona of another
    /// game's when this one has none). Signed out, only the app ID.
    public func emulatorSettings(appID: UInt32) async -> SteamAPISwap.Settings {
        var s = SteamAPISwap.Settings(appID: appID)
        guard let stored = try? await backend.storedSession() else { return s }
        s.steamID = stored.steamID
        let snap = await pairedProfiles()
        let own = snap?.profiles[String(appID)]
        s.personaName = own?.personaName ?? snap?.profiles.values.sorted { $0.fetchedAt > $1.fetchedAt }.lazy.compactMap(\.personaName).first
        s.dlc = own?.dlc ?? []
        // The schema from the last sync, so the emulator knows the game's achievements and stats.
        if let kept = await keptUserStats(appID: appID) {
            s.files = EmulatorStats.schemaFiles(kept.schema)
        }
        return s
    }

    /// The kept profiles when they are the paired account's (by its stored session:
    /// valid before the first restore and while suspended).
    private func pairedProfiles() async -> ProfilesSnapshot? {
        guard let stored = try? await backend.storedSession(), let snap = loadProfiles(),
              snap.accountTag == Account(stored: stored).accountTag else { return nil }
        return snap
    }

    struct ProfilesSnapshot: Codable {
        var accountTag: String
        var profiles: [String: SteamGameProfile]
    }

    private var profilesURL: URL? { stateDirectory?.appendingPathComponent(Self.profilesFile) }
    private var memoryProfiles: ProfilesSnapshot?

    private func loadProfiles() -> ProfilesSnapshot? {
        guard let url = profilesURL else { return memoryProfiles }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProfilesSnapshot.self, from: data)
    }

    private func saveProfiles(_ snap: ProfilesSnapshot) {
        guard let url = profilesURL else { memoryProfiles = snap; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snap).write(to: url, options: .atomic)
        } catch {
            log.warn("steamapi", "cannot keep the emulator's profile: \(error)")
        }
    }

    // MARK: stats and achievements

    /// What one sync did.
    public struct StatsSync: Sendable, Equatable {
        public var steam: UserStatsSnapshot
        /// Achievements the game unlocked under the emulator, now on Steam.
        public var sentUnlocks: [String]
        /// Stats stored on Steam (achievement blocks not counted).
        public var sentStats: Int
        /// Unlocks and stats the emulator's save got from Steam.
        public var received: Int
        /// Stats Steam refused, by stat ID, with the value it kept.
        public var refused: [UInt32: UInt32]
    }

    struct StatsRecord: Codable {
        var accountTag: String
        var steam: UserStatsSnapshot
        /// Stat values after the last sync, by lower-cased name.
        var baseline: [String: UInt32]
    }

    /// Brings Steam and the emulator's save for `appID` (under `saves`, its
    /// `GSE Saves` folder) together: what the game earned under the emulator
    /// goes to Steam, what Steam has comes to the save (EmulatorStats.plan).
    /// Needs the paired session; the result is kept for launches.
    public func syncUserStats(appID: UInt32, saves: URL) async throws -> StatsSync {
        try checkNotSuspended()
        if case .signedIn = state {} else { await restoreIfPossible() }
        guard case .signedIn = state, let stored = try await backend.storedSession() else { throw SteamError.notLoggedOn }
        let account = Account(stored: stored).accountTag
        var steam = try await backend.userStats(appID: appID)
        let folder = EmulatorStats.folder(saves, appID: appID)
        let local = EmulatorStats.read(folder, schema: steam.schema)
        let kept = loadStats(appID)
        let plan = EmulatorStats.plan(steam: steam, local: local, baseline: kept?.accountTag == account ? kept!.baseline : nil)
        var refused: [UInt32: UInt32] = [:]
        if !plan.store.isEmpty {
            let r = try await backend.storeUserStats(appID: appID, crc: steam.crc, values: plan.store)
            refused = r.failed
            for (id, v) in plan.store { steam.values[id] = refused[id] ?? v }
            if let crc = r.crcStats { steam.crc = crc }
            for name in plan.newUnlocks {
                guard let a = steam.schema.achievements.first(where: { $0.name == name }) else { continue }
                var times = steam.unlockTimes[a.statID] ?? []
                while times.count <= Int(a.bit) { times.append(0) }
                times[Int(a.bit)] = local.unlocked.first { $0.key.lowercased() == name.lowercased() }?.value ?? 0
                steam.unlockTimes[a.statID] = times
            }
        }
        var toLocal = plan.local
        for s in steam.schema.stats where refused[s.id] != nil { toLocal.stats[s.name.lowercased()] = refused[s.id] }
        if !toLocal.unlocked.isEmpty || !toLocal.stats.isEmpty { try EmulatorStats.write(toLocal, to: folder) }
        var baseline: [String: UInt32] = [:]
        for s in steam.schema.stats { baseline[s.name.lowercased()] = steam.values[s.id] ?? EmulatorStats.defaultBits(s) }
        steam.fetchedAt = now()
        saveStats(StatsRecord(accountTag: account, steam: steam, baseline: baseline))
        let sent = plan.newUnlocks.filter { n in steam.schema.achievements.first { $0.name == n }.map(steam.unlocked) ?? false }
        let sync = StatsSync(steam: steam, sentUnlocks: sent,
                             sentStats: plan.store.keys.filter { id in steam.schema.stats.contains { $0.id == id } && refused[id] == nil }.count,
                             received: toLocal.unlocked.count + toLocal.stats.count, refused: refused)
        log.info("stats", "app \(appID): \(steam.unlockedCount)/\(steam.schema.achievements.count) achievements on Steam; "
                 + "sent \(sync.sentUnlocks.count) unlock(s) and \(sync.sentStats) stat(s), \(sync.received) to the emulator"
                 + (refused.isEmpty ? "" : ", \(refused.count) refused"))
        return sync
    }

    /// The snapshot the last sync kept for the paired account (also while suspended).
    public func keptUserStats(appID: UInt32) async -> UserStatsSnapshot? {
        guard let stored = try? await backend.storedSession(), let r = loadStats(appID),
              r.accountTag == Account(stored: stored).accountTag else { return nil }
        return r.steam
    }

    private var statsURL: URL? { stateDirectory?.appendingPathComponent(Self.statsDirectory, isDirectory: true) }
    private var memoryStats: [UInt32: StatsRecord] = [:]

    private func loadStats(_ appID: UInt32) -> StatsRecord? {
        guard let dir = statsURL else { return memoryStats[appID] }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(appID).json")) else { return nil }
        return try? JSONDecoder().decode(StatsRecord.self, from: data)
    }

    private func saveStats(_ r: StatsRecord) {
        guard let dir = statsURL else { memoryStats[r.steam.appID] = r; return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(r).write(to: dir.appendingPathComponent("\(r.steam.appID).json"), options: .atomic)
        } catch {
            log.warn("stats", "cannot keep app \(r.steam.appID)'s stats: \(error)")
        }
    }

    // MARK: Steam Cloud

    /// A file both sides changed, or one a game's first sync cannot place.
    public struct CloudConflict: Sendable, Equatable, Codable {
        public var name: String
        /// Bytes on the phone; nil when it has none.
        public var phoneSize: Int?
        public var phoneTime: Date?
        /// Bytes on Steam; nil when Steam has none.
        public var steamSize: UInt32?
        public var steamTime: Date?

        public init(name: String, phoneSize: Int? = nil, phoneTime: Date? = nil, steamSize: UInt32? = nil, steamTime: Date? = nil) {
            self.name = name
            self.phoneSize = phoneSize
            self.phoneTime = phoneTime
            self.steamSize = steamSize
            self.steamTime = steamTime
        }
    }

    /// How the player settles a conflict: the phone's copy goes to Steam, or
    /// Steam's comes to the phone. The copy that loses is backed up first.
    public enum CloudChoice: String, Sendable, Codable { case phone, steam }

    /// One choice for every conflict: a game's saves are settled as one (the
    /// Cloud save conflict screen), in one `syncCloud(resolve:)` call.
    public static func resolveAll(_ conflicts: [CloudConflict], _ choice: CloudChoice) -> [String: CloudChoice] {
        Dictionary(conflicts.map { ($0.name, choice) }, uniquingKeysWith: { a, _ in a })
    }

    public struct CloudSync: Sendable, Equatable {
        public var downloaded: [String]
        public var uploaded: [String]
        /// Left for the player.
        public var conflicts: [CloudConflict]
        /// Files this sync could not move (by name, why).
        public var failed: [String: String]
        public var at: Date
    }

    struct CloudRecord: Codable {
        var accountTag: String
        var baseline: Cloud.Baseline
        var conflicts: [CloudConflict]
        var at: Date
    }

    /// Brings the game's cloud files on Steam and on the phone together
    /// (Cloud.plan), settling conflicts the player chose in `resolve`. What a
    /// download or a choice replaces goes to `backups/<appid>/<time>/` first.
    public func syncCloud(appID: UInt32, roots: Cloud.Roots, backups: URL, resolve: [String: CloudChoice] = [:]) async throws -> CloudSync {
        try checkNotSuspended()
        if case .signedIn = state {} else { await restoreIfPossible() }
        guard case .signedIn = state, let stored = try await backend.storedSession() else { throw SteamError.notLoggedOn }
        let account = Account(stored: stored).accountTag
        let rules = (try await backend.appRecords([appID])[appID]).map(Cloud.rules) ?? []
        let changes = try await backend.cloudChangelist(appID: appID)
        let remote = changes.remote
        let kept = loadCloud(appID)
        let baseline = kept?.accountTag == account ? kept?.baseline : nil
        // Each local file under the name Steam has for it, else the last sync's (Cloud.named).
        var files = Cloud.named(Cloud.localFiles(rules: rules, roots: roots, steamID: stored.steamID),
                                like: remote.keys.sorted() + (baseline?.files.keys.sorted() ?? []))
        for name in remote.keys where files[name] == nil {
            if let url = roots.file(name), FileManager.default.fileExists(atPath: url.path) { files[name] = url }
        }
        var local: [String: String] = [:]
        for (name, url) in files { if let d = try? Data(contentsOf: url) { local[name] = SHA1.hash([UInt8](d)).hex } }
        var plan = Cloud.plan(remote: remote, local: local, baseline: baseline)
        // A game's first sync does not upload a file Steam lacks: the player says.
        if baseline == nil { for name in local.keys where remote[name] == nil { plan[name] = .conflict } }
        // A conflict stays one until the player settles it, even once a baseline exists.
        let open = kept?.accountTag == account ? Set(kept!.conflicts.map(\.name)) : []
        for name in open where plan[name] != nil { plan[name] = .conflict }
        var settled: [String: String] = [:]   // phone-only files kept off Steam by choice
        for (name, choice) in resolve where plan[name] == .conflict {
            if choice == .steam, remote[name] == nil { plan[name] = nil; settled[name] = local[name]; continue }
            plan[name] = choice == .phone ? .upload : .download
        }
        let backupDir = backups.appendingPathComponent("\(appID)/\(Cloud.Backups.folderName(for: now()))", isDirectory: true)
        func backup(_ name: String, _ data: Data) throws {
            let url = backupDir.appendingPathComponent(name.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "/", with: "_"))
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        var downloaded: [String] = [], uploaded: [String] = [], failed: [String: String] = [:]
        for name in plan.filter({ $0.value == .download }).keys.sorted() {
            do {
                guard let url = files[name] ?? roots.file(name) else { throw SteamError.unsupported("no local root for \(name)") }
                let data = try await backend.cloudDownload(appID: appID, name: name)
                if let old = try? Data(contentsOf: url) { try backup(name, old) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(data).write(to: url, options: .atomic)
                if let t = remote[name]?.time {
                    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(t))], ofItemAtPath: url.path)
                }
                local[name] = SHA1.hash(data).hex
                downloaded.append(name)
            } catch {
                failed[name] = "\(error)"
            }
        }
        var uploads: [(name: String, data: [UInt8], time: UInt64)] = []
        for name in plan.filter({ $0.value == .upload }).keys.sorted() {
            guard let url = files[name], let d = try? Data(contentsOf: url) else { failed[name] = "unreadable"; continue }
            if remote[name] != nil, resolve[name] == .phone {
                // Steam's copy loses to the phone's: keep it.
                do { try backup(name, Data(try await backend.cloudDownload(appID: appID, name: name))) }
                catch { failed[name] = "Steam's copy could not be backed up: \(error)"; continue }
            }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now()
            uploads.append((name, [UInt8](d), UInt64(mtime.timeIntervalSince1970)))
        }
        if !uploads.isEmpty {
            let committed = Set(try await backend.cloudUpload(appID: appID, files: uploads))
            for u in uploads { if committed.contains(u.name) { uploaded.append(u.name) } else { failed[u.name] = "not committed" } }
        }
        // The new baseline: every file both sides now agree on.
        var next = baseline?.files ?? [:]
        for name in Set(remote.keys).union(local.keys) {
            let r = remote[name]?.sha, l = local[name]
            if uploaded.contains(name) || downloaded.contains(name) || (r != nil && r == l) { next[name] = l }
        }
        for (name, sha) in settled { next[name] = sha }
        let conflicts = plan.filter { $0.value == .conflict }.keys.sorted().map { name -> CloudConflict in
            let attrs = files[name].flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            return CloudConflict(name: name, phoneSize: (attrs?[.size] as? NSNumber)?.intValue, phoneTime: attrs?[.modificationDate] as? Date,
                                 steamSize: remote[name]?.size,
                                 steamTime: remote[name].map { Date(timeIntervalSince1970: TimeInterval($0.time)) })
        }
        let at = now()
        saveCloud(appID, CloudRecord(accountTag: account, baseline: Cloud.Baseline(changeNumber: changes.currentChangeNumber, files: next),
                                     conflicts: conflicts, at: at))
        log.info("cloud", "app \(appID): \(remote.count) on Steam, \(local.count) on the phone; \(downloaded.count) down, "
                 + "\(uploaded.count) up, \(conflicts.count) conflict(s)" + (failed.isEmpty ? "" : ", \(failed.count) failed"))
        return CloudSync(downloaded: downloaded, uploaded: uploaded, conflicts: conflicts, failed: failed, at: at)
    }

    /// The conflicts and time of the last sync, for the paired account.
    public func keptCloud(appID: UInt32) async -> (conflicts: [CloudConflict], at: Date)? {
        guard let stored = try? await backend.storedSession(), let r = loadCloud(appID),
              r.accountTag == Account(stored: stored).accountTag else { return nil }
        return (r.conflicts, r.at)
    }

    /// Forgets the game's last sync (its baseline and open conflicts): the
    /// next sync is a first one, where a file that differs on the two sides
    /// is a conflict. A dev build's Game options use it to reach the Cloud
    /// save conflict screen on the phone.
    public func forgetCloud(appID: UInt32) {
        memoryCloud[appID] = nil
        if let dir = cloudURL { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(appID).json")) }
    }

    private var cloudURL: URL? { stateDirectory?.appendingPathComponent(Self.cloudDirectory, isDirectory: true) }
    private var memoryCloud: [UInt32: CloudRecord] = [:]

    private func loadCloud(_ appID: UInt32) -> CloudRecord? {
        guard let dir = cloudURL else { return memoryCloud[appID] }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(appID).json")) else { return nil }
        return try? JSONDecoder().decode(CloudRecord.self, from: data)
    }

    private func saveCloud(_ appID: UInt32, _ r: CloudRecord) {
        guard let dir = cloudURL else { memoryCloud[appID] = r; return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(r).write(to: dir.appendingPathComponent("\(appID).json"), options: .atomic)
        } catch {
            log.warn("cloud", "cannot keep app \(appID)'s cloud state: \(error)")
        }
    }

    // MARK: sign-out and launch

    /// Revokes the token with Steam (unless `revoke` is false), logs off,
    /// deletes the stored session and the cached account data. Installed
    /// games and saves are not reachable from here and stay on the phone.
    public func signOut(revoke: Bool = true) async throws -> LogoutReport {
        signInTask?.cancel()
        signingOut = true
        defer { signingOut = false }
        if let restoreTask { _ = await restoreTask.value }
        let s = await backend.isLoggedOn()
        if try await backend.storedSession() != nil, !(s.loggedOn && !s.anonymous && s.connected) {
            await backend.disconnect()
            do { _ = try await backend.restore() } catch {
                log.warn("service", "logon before sign-out failed: \(error); revoking without a session")
                try? await backend.connect(maxEndpoints: 3)
            }
        }
        let report = try await backend.logout(revoke: revoke)
        record = Record()
        saveRecord()
        clearGamesCache()
        appInfoCache = [:]
        set(.signedOut)
        return report
    }

    /// The launched game's encrypted app ticket (decision 0017), asked for after
    /// Play and before `suspendForLaunch`, within `timeout` seconds. Only on a
    /// session already logged on to the account: a restore here could outlive
    /// the timeout and race the suspension that follows. Nil when there is no
    /// such session, when suspended, or when Steam refuses or does not answer
    /// in time; the game then starts without one. The ticket is returned and
    /// never kept: not here, not in the Keychain, not in `stateDirectory`.
    public func encryptedAppTicket(appID: UInt32, timeout: Double = 5) async -> Secret<[UInt8]>? {
        guard !suspended, case .signedIn = state else {
            log.info("ticket", "app \(appID): no encrypted app ticket (\(suspended ? "suspended" : "not signed in"))")
            return nil
        }
        let s = await backend.isLoggedOn()
        guard s.loggedOn, !s.anonymous, s.connected else {
            log.info("ticket", "app \(appID): no encrypted app ticket (the session is not connected)")
            return nil
        }
        let started = Date()
        do {
            // The limit holds for the whole call, a wait behind a stats call included.
            let backend = self.backend
            let ticket = try await withThrowingTaskGroup(of: Secret<[UInt8]>.self) { group in
                group.addTask { try await backend.encryptedAppTicket(appID: appID, timeout: timeout) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw SteamError.timeout("no encrypted app ticket in \(Int(timeout)) s")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw SteamError.cancelled }
                return first
            }
            log.info("ticket", "app \(appID): encrypted app ticket fetched, \(ticket.value.count) bytes in "
                     + String(format: "%.2f", Date().timeIntervalSince(started)) + " s")
            return ticket
        } catch {
            log.warn("ticket", "app \(appID): no encrypted app ticket: \(error)")
            return nil
        }
    }

    /// Before the runtime starts (decision 0004): cancel pairing, close the CM
    /// session and refuse further Steam work in this process. The refresh
    /// token stays in the Keychain for the next launch.
    public func suspendForLaunch() async {
        suspended = true
        signInTask?.cancel()
        await backend.disconnect()
        appInfoCache = [:]
        log.info("service", "suspended for a title launch; CM session closed")
    }

    // MARK: games cache (non-secret, per account, deleted at sign-out)

    struct GamesSnapshot: Codable {
        var accountTag: String
        var fetchedAt: Date
        var games: [SteamGame]
    }

    private var gamesURL: URL? { stateDirectory?.appendingPathComponent(Self.gamesFile) }
    private var memoryGames: GamesSnapshot?

    private func loadGamesCache() -> GamesSnapshot? {
        guard let url = gamesURL else { return memoryGames }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GamesSnapshot.self, from: data)
    }

    private func saveGamesCache(_ snap: GamesSnapshot) {
        guard let url = gamesURL else { memoryGames = snap; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snap).write(to: url, options: .atomic)
        } catch {
            log.warn("library", "cannot cache the games list: \(error)")
        }
    }

    /// The games list, the emulator's profiles and the kept stats: account data a sign-out removes.
    private func clearGamesCache() {
        memoryGames = nil
        memoryProfiles = nil
        memoryStats = [:]
        memoryCloud = [:]
        if let url = gamesURL { try? FileManager.default.removeItem(at: url) }
        if let url = profilesURL { try? FileManager.default.removeItem(at: url) }
        if let url = statsURL { try? FileManager.default.removeItem(at: url) }
        if let url = cloudURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: formatting

    static func stamp(_ d: Date?) -> String { d.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown" }

    static func reason(_ error: Error) -> String {
        if let e = error as? SteamError {
            switch e {
            case .transport, .timeout, .retriesExhausted: return "Steam can't be reached"
            default: return e.description
            }
        }
        return "\(type(of: error))"
    }
}
