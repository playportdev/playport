// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// A scripted Steam session: every pairing state, restore outcome and
/// library answer the service can meet, with no network and no account.
actor FakeBackend: SteamBackend {
    enum QRScript {
        /// Emit the events, then end the login with the result.
        case events([QREvent], Result<AccountSummary, Error>)
        /// Emit the events, then poll until cancelled.
        case hang([QREvent])
    }

    var stored: StoredSession?
    var qr: QRScript = .hang([])
    var restoreResult: Result<AccountSummary, Error> = .success(FakeBackend.summary)
    var restoreDelay: UInt64 = 0
    var restoreInFlight = false
    var renewResult: Result<Bool, Error> = .success(false)
    var renewedToken: String?
    var loggedOn: (loggedOn: Bool, anonymous: Bool, connected: Bool) = (false, false, false)
    var licenses: [CMsgClientLicenseList.License] = [.init(packageID: 1, timeCreated: nil, licenseType: nil, flags: nil, accessToken: 0)]
    var ownedIDs: [UInt32] = []
    var records: [UInt32: KeyValue] = [:]
    var persona: Result<String?, Error> = .success("Knight Player")

    var calls: [String] = []
    var qrCancelled = false

    static let summary = AccountSummary(accountTag: Redactor.tag("acct", "someone"), steamIDTag: Redactor.tag("sid", "7"),
                                        anonymous: false, cellID: 1, heartbeatSeconds: 9)
    static func session(exp: TimeInterval) -> StoredSession {
        StoredSession(accountName: "someone", steamID: 7, refreshToken: SessionTests.jwt(sub: "7", exp: exp), guardData: nil, savedAt: Date())
    }

    func set(stored s: StoredSession?) { stored = s }
    func set(qr s: QRScript) { qr = s }
    func set(restore r: Result<AccountSummary, Error>) { restoreResult = r }
    func set(restoreDelay ns: UInt64) { restoreDelay = ns }
    func set(renew r: Result<Bool, Error>, token: String? = nil) { renewResult = r; renewedToken = token }
    func set(library ids: [UInt32], _ recs: [UInt32: KeyValue]) { ownedIDs = ids; records = recs }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    func storedSession() async throws -> StoredSession? { stored }
    func isLoggedOn() async -> (loggedOn: Bool, anonymous: Bool, connected: Bool) { loggedOn }
    func connect(maxEndpoints: Int) async throws { calls.append("connect"); loggedOn.connected = true }
    func disconnect() async { calls.append("disconnect"); loggedOn = (false, false, false) }

    func loginWithQR(deadline: TimeInterval, onEvent: @escaping @Sendable (QREvent) -> Void) async throws -> AccountSummary {
        calls.append("qr")
        switch qr {
        case let .events(events, result):
            for e in events { onEvent(e) }
            let s = try result.get()
            stored = Self.session(exp: 2_000_000_000)
            loggedOn = (true, false, true)
            return s
        case let .hang(events):
            for e in events { onEvent(e) }
            do {
                while true { try await Task.sleep(nanoseconds: 10_000_000) }
            } catch {
                qrCancelled = true
                throw error
            }
        }
    }

    /// A credential sign-in: emit `before`, then wait for a code when `codeRejects`
    /// is not nil (refusing the first `codeRejects` codes), then end with the result.
    var credentials: (before: [CredentialEvent], codeRejects: Int?, result: Result<AccountSummary, Error>) = ([], nil, .success(FakeBackend.summary))
    var credentialNames: [String] = []
    var passwordsSeen: [String] = []
    var codesSeen: [String] = []
    func set(credentials before: [CredentialEvent], codeRejects: Int? = nil, _ result: Result<AccountSummary, Error>) {
        credentials = (before, codeRejects, result)
    }

    func loginWithCredentials(accountName: String, password: Secret<String>, codes: GuardCodeInbox, deadline: TimeInterval,
                              onEvent: @escaping @Sendable (CredentialEvent) -> Void) async throws -> AccountSummary {
        calls.append("credentials")
        credentialNames.append(accountName)
        passwordsSeen.append(password.value)
        for e in credentials.before { onEvent(e) }
        if var rejects = credentials.codeRejects {
            while true {
                guard let c = try await codes.next(within: 5) else { throw SteamError.authSessionEnded(.expired) }
                codesSeen.append(c.value)
                if rejects > 0 { rejects -= 1; onEvent(.codeRejected); continue }
                onEvent(.codeAccepted)
                break
            }
        }
        let s = try credentials.result.get()
        onEvent(.approved(accountTag: s.accountTag))
        stored = Self.session(exp: 2_000_000_000)
        loggedOn = (true, false, true)
        return s
    }

    /// Like SteamSession, a second logon while one is in progress is refused.
    func restore() async throws -> AccountSummary {
        calls.append("restore")
        if restoreInFlight { throw SteamError.eresult(.invalidState, context: "restore while restore is in progress") }
        restoreInFlight = true
        defer { restoreInFlight = false }
        if restoreDelay > 0 { try await Task.sleep(nanoseconds: restoreDelay) }
        let s = try restoreResult.get()
        loggedOn = (true, false, true)
        return s
    }

    func logOnAnonymous() async throws -> AccountSummary {
        calls.append("anonymous")
        loggedOn = (true, true, true)
        return AccountSummary(accountTag: "anonymous", steamIDTag: "sid#0000", anonymous: true, cellID: 1, heartbeatSeconds: 9)
    }

    func renewTokens() async throws -> Bool {
        calls.append("renew")
        let r = try renewResult.get()
        if r, let t = renewedToken { stored?.refreshToken = t }
        return r
    }

    func awaitLicenses(timeout: Double) async throws -> [CMsgClientLicenseList.License] { calls.append("licenses"); return licenses }
    func ownedAppIDs(licenses: [CMsgClientLicenseList.License]) async throws -> [UInt32] { calls.append("owned"); return ownedIDs }
    func appRecords(_ appIDs: [UInt32]) async throws -> [UInt32: KeyValue] {
        calls.append("records")
        return records.filter { appIDs.contains($0.key) }
    }

    var statsSnapshot: UserStatsSnapshot?
    var storedStats: [[UInt32: UInt32]] = []
    var refuse: [UInt32: UInt32] = [:]
    /// Steam's state from now on: earlier stores are forgotten.
    func set(stats s: UserStatsSnapshot?, refuse r: [UInt32: UInt32] = [:]) { statsSnapshot = s; refuse = r; storedStats = [] }
    func userStats(appID: UInt32) async throws -> UserStatsSnapshot {
        calls.append("userstats")
        guard var s = statsSnapshot else { throw SteamError.notFound("no stats") }
        for (i, v) in storedValues { s.values[i] = v }
        return s
    }
    var storedValues: [UInt32: UInt32] {
        storedStats.reduce(into: [:]) { acc, d in for (k, v) in d where refuse[k] == nil { acc[k] = v } }
    }
    func storeUserStats(appID: UInt32, crc: UInt32, values: [UInt32: UInt32]) async throws -> CMsgClientStoreUserStatsResponse {
        calls.append("storestats")
        storedStats.append(values)
        var w = ProtoWriter()
        w.int32(2, 1)
        w.uint32(3, crc + 1)
        for (id, v) in refuse where values[id] != nil {
            var m = ProtoWriter(); m.uint32(1, id); m.uint32(2, v); w.bytes(4, m.bytes)
        }
        return try CMsgClientStoreUserStatsResponse.decode(w.bytes)
    }

    /// Steam Cloud: files by full name, and a change number that moves on every upload.
    var cloud: [String: (data: [UInt8], time: UInt64)] = [:]
    var cloudChange: UInt64 = 1
    func cloudFile(_ name: String) -> [UInt8]? { cloud[name]?.data }
    func set(cloud c: [String: [UInt8]]) { cloud = c.mapValues { ($0, 1_700_000_000) }; cloudChange += 1 }
    func cloudChangelist(appID: UInt32) async throws -> CCloudGetAppFileChangelistResponse {
        calls.append("changelist")
        var w = ProtoWriter()
        w.uint64(1, cloudChange)
        for (name, f) in cloud.sorted(by: { $0.key < $1.key }) {
            var m = ProtoWriter()
            m.string(1, name); m.bytes(2, SHA1.hash(f.data)); m.uint64(3, f.time); m.uint32(4, UInt32(f.data.count))
            w.bytes(2, m.bytes)
        }
        return try CCloudGetAppFileChangelistResponse.decode(w.bytes)
    }
    func cloudDownload(appID: UInt32, name: String) async throws -> [UInt8] {
        calls.append("download \(name)")
        guard let f = cloud[name] else { throw SteamError.notFound(name) }
        return f.data
    }
    /// As Steam: a name that differs from a stored one only in case is refused (DuplicateRequest).
    func cloudUpload(appID: UInt32, files: [(name: String, data: [UInt8], time: UInt64)]) async throws -> [String] {
        var committed: [String] = []
        for f in files {
            calls.append("upload \(f.name)")
            guard !cloud.keys.contains(where: { $0 != f.name && $0.lowercased() == f.name.lowercased() }) else { continue }
            cloud[f.name] = (f.data, f.time)
            committed.append(f.name)
        }
        cloudChange += 1
        return committed
    }

    func set(persona p: Result<String?, Error>) { persona = p }
    func personaName() async throws -> String? { calls.append("persona"); return try persona.get() }

    var ticket: Result<[UInt8], Error> = .success(Array("a made-up encrypted app ticket".utf8))
    var ticketDelay: UInt64 = 0
    func set(ticket t: Result<[UInt8], Error>, delay ns: UInt64 = 0) { ticket = t; ticketDelay = ns }
    func encryptedAppTicket(appID: UInt32, timeout: Double) async throws -> Secret<[UInt8]> {
        calls.append("ticket \(appID)")
        if ticketDelay > 0 { try await Task.sleep(nanoseconds: ticketDelay) }
        return Secret(try ticket.get())
    }

    // A live play's tickets (decision 0062).
    nonisolated let connectTokens = GameConnectTokens()
    nonisolated let ticketPushes = TicketPushRoute()
    nonisolated let traffic = CMTraffic()
    var ownership: Result<[UInt8], Error> = .success(Array("an ownership ticket".utf8))
    var authLists: [CMsgClientAuthList] = []
    var gamesPlayed: [[UInt32]] = []
    func set(ownership o: Result<[UInt8], Error>) { ownership = o }
    func appOwnershipTicket(appID: UInt32, timeout: Double) async throws -> Secret<[UInt8]> {
        calls.append("ownership \(appID)")
        return Secret(try ownership.get())
    }
    func sendAuthList(_ list: CMsgClientAuthList) async throws { authLists.append(list) }
    func setGamesPlayed(_ appIDs: [UInt32]) async throws { gamesPlayed.append(appIDs) }

    func logout(revoke: Bool) async throws -> LogoutReport {
        calls.append(revoke ? "logout-revoke" : "logout")
        let had = stored != nil
        stored = nil
        loggedOn = (false, false, false)
        return LogoutReport(revoked: revoke && had, revokeResult: revoke ? "OK" : "not attempted", loggedOff: true, credentialsDeleted: had)
    }
}

/// A settable clock for the renewal interval.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

final class PairingTests: XCTestCase {
    let url1 = Secret("https://s.team/q/1/1111111111111111111")
    let url2 = Secret("https://s.team/q/1/2222222222222222222")

    func service(_ b: FakeBackend, dir: URL? = nil, clock: TestClock = TestClock()) -> SteamService {
        SteamService(backend: b, log: .silent, stateDirectory: dir, now: { clock.now })
    }

    /// Runs one pairing attempt to its end, feeding every event to a PairingModel.
    func pair(_ s: SteamService) async -> (events: [SignInEvent], failure: SignInFailure?, model: PairingModel, phases: [PairingModel.Phase]) {
        var model = PairingModel()
        model.start()
        var phases = [model.phase]
        var events: [SignInEvent] = []
        do {
            for try await e in s.signIn(method: .qr(deadline: 120)) {
                events.append(e)
                model.apply(e)
                phases.append(model.phase)
            }
            return (events, nil, model, phases)
        } catch {
            let f = error as? SignInFailure
            if let f { model.apply(f); phases.append(model.phase) }
            return (events, f, model, phases)
        }
    }

    func testApprovedPairingWalksEveryStateAndSignsIn() async throws {
        let b = FakeBackend()
        await b.set(qr: .events([.challenge(url1, expiresIn: 120), .replaced(url2), .scanned, .approved(accountTag: FakeBackend.summary.accountTag)],
                                .success(FakeBackend.summary)))
        let s = service(b)
        let states = await s.observe()
        let r = await pair(s)
        XCTAssertNil(r.failure)
        XCTAssertEqual(r.events.count, 5)
        guard case let .code(c1) = r.events[0], case let .code(c2) = r.events[1] else { return XCTFail("\(r.events)") }
        XCTAssertEqual([c1.generation, c2.generation], [1, 2])
        XCTAssertNotEqual(c1.fingerprint, c2.fingerprint, "a replaced code shows a new fingerprint")
        XCTAssertEqual(c1.payload, url1)
        XCTAssertEqual(r.events[2], .scanned)
        XCTAssertEqual(r.events[3], .approved(accountTag: FakeBackend.summary.accountTag))
        guard case let .signedIn(account) = r.events[4] else { return XCTFail() }
        XCTAssertEqual(account.pairedUntil, Date(timeIntervalSince1970: 2_000_000_000), "Paired until comes from the token's exp")

        // The Pair screen's walk: requesting -> code -> code -> scanned -> approved -> paired.
        XCTAssertEqual(r.phases.count, 6)
        XCTAssertEqual(r.phases[0], .requesting)
        XCTAssertEqual(r.phases[2], .showingCode(c2))
        XCTAssertEqual(r.phases[3], .scanned)
        XCTAssertEqual(r.phases[4], .approved(accountTag: account.accountTag))
        XCTAssertEqual(r.model.phase, .paired(account))
        var copy = PairingModel(); copy.apply(.scanned)
        XCTAssertEqual(copy.message, "Approve on your other device…")
        copy.apply(.approved(accountTag: "acct#0000"))
        XCTAssertEqual(copy.message, "Paired. Loading your library…")

        let st = await s.state
        XCTAssertEqual(st, .signedIn(account))
        var seen: [SteamService.AccountState] = []
        for await x in states { seen.append(x); if seen.count == 3 { break } }
        XCTAssertEqual(seen, [.unknown, .pairing, .signedIn(account)])
        let renewal = await s.lastRenewal
        XCTAssertEqual(renewal?.result, "paired", "a fresh pairing counts as a renewal")
    }

    /// Approved, but the logon on that socket failed: the stored token is
    /// used by a restore instead of asking for a second approval.
    func testFailedFirstLogonAfterApprovalRestores() async {
        let b = FakeBackend()
        await b.set(qr: .events([.challenge(url1, expiresIn: 120), .scanned, .approved(accountTag: "acct#0000")],
                                .failure(SteamError.timeout("waiting for emsg(751)"))))
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = service(b)
        let r = await pair(s)
        XCTAssertNil(r.failure)
        guard case .paired = r.model.phase else { return XCTFail("\(r.model.phase)") }
        let restores = await b.count("restore"), renews = await b.count("renew")
        XCTAssertEqual([restores, renews], [1, 0])
    }

    func testUnscannedSessionEndIsExpired() async {
        let b = FakeBackend()
        await b.set(qr: .events([.challenge(url1, expiresIn: 120)], .failure(SteamError.qrSessionEnded(.fileNotFound))))
        let s = service(b)
        let r = await pair(s)
        XCTAssertEqual(r.failure, .expired)
        XCTAssertEqual(r.model.phase, .expired)
        XCTAssertEqual(r.model.message, "Code expired; show a new one")
        XCTAssertEqual(r.model.actionTitle, "Show a new code")
        XCTAssertNil(r.model.code)
        let st = await s.state
        XCTAssertEqual(st, .signedOut)
        let disconnects = await b.count("disconnect")
        XCTAssertGreaterThan(disconnects, 0, "a failed attempt closes its socket")
    }

    func testSteamExpiredResultIsExpired() async {
        let b = FakeBackend()
        await b.set(qr: .events([.challenge(url1, expiresIn: 120)], .failure(SteamError.qrSessionEnded(.expired))))
        let r = await pair(service(b))
        XCTAssertEqual(r.failure, .expired)
    }

    func testLocalDeadlineIsExpired() async {
        let b = FakeBackend()
        await b.set(qr: .events([.challenge(url1, expiresIn: 120)], .failure(SteamError.qrExpired)))
        let r = await pair(service(b))
        XCTAssertEqual(r.failure, .expired)
        XCTAssertEqual(r.model.phase, .expired)
    }

    func testSessionEndAfterScanIsDenied() async {
        let b = FakeBackend()
        await b.set(qr: .events([.challenge(url1, expiresIn: 120), .scanned], .failure(SteamError.qrSessionEnded(.fileNotFound))))
        let r = await pair(service(b))
        XCTAssertEqual(r.failure, .denied)
        XCTAssertEqual(r.model.phase, .denied)
        XCTAssertEqual(r.model.message, "Sign-in was declined")
        XCTAssertEqual(r.model.actionTitle, "Show a new code")
    }

    func testAccessDeniedIsDeniedEvenUnscanned() async {
        let b = FakeBackend()
        await b.set(qr: .events([.challenge(url1, expiresIn: 120)], .failure(SteamError.qrSessionEnded(.accessDenied))))
        let r = await pair(service(b))
        XCTAssertEqual(r.failure, .denied)
    }

    func testNetworkAndOtherFailures() async {
        let b = FakeBackend()
        await b.set(qr: .events([], .failure(SteamError.retriesExhausted("no CM"))))
        var r = await pair(service(b))
        guard case .network = r.failure else { return XCTFail("\(String(describing: r.failure))") }
        guard case .failed = r.model.phase else { return XCTFail() }
        XCTAssertEqual(r.model.actionTitle, "Show a new code")
        await b.set(qr: .events([], .failure(SteamError.protocolChanged("x"))))
        r = await pair(service(b))
        guard case .failed = r.failure else { return XCTFail() }
    }

    /// Leaving the foreground cancels the attempt: the poll stops, the screen
    /// says so and offers a new code, and a late `cancelled` does not hide that.
    func testBackgroundingCancelsTheAttempt() async throws {
        let b = FakeBackend()
        await b.set(qr: .hang([.challenge(url1, expiresIn: 120)]))
        let s = service(b)
        var model = PairingModel()
        model.start()
        var iterator = s.signIn().makeAsyncIterator()
        let first = try await iterator.next()
        guard case let .code(c)? = first else { return XCTFail() }
        model.apply(.code(c))
        XCTAssertTrue(model.keepsScreenAwake)
        XCTAssertEqual(model.code, c)

        model.sceneBecameInactive()
        XCTAssertEqual(model.phase, .interrupted)
        XCTAssertFalse(model.keepsScreenAwake)
        XCTAssertEqual(model.actionTitle, "Show a new code")
        let consumer = Task { () -> Error? in
            do { _ = try await iterator.next(); return nil } catch { return error }
        }
        consumer.cancel()
        _ = await consumer.value
        model.apply(.cancelled)
        XCTAssertEqual(model.phase, .interrupted)
        try await waitUntil { await b.qrCancelled }
        try await waitUntil { await s.state == .signedOut }
    }

    func testUserCancelReturnsToIntro() {
        var m = PairingModel()
        m.start()
        m.apply(.cancelled)
        XCTAssertEqual(m.phase, .intro)
    }

    func testSecondAttemptWhilePairingIsBusy() async throws {
        let b = FakeBackend()
        await b.set(qr: .hang([.challenge(url1, expiresIn: 120)]))
        let s = service(b)
        var first = s.signIn().makeAsyncIterator()
        _ = try await first.next()
        let r = await pair(s)
        XCTAssertEqual(r.failure, .busy)
        guard case .failed = r.model.phase else { return XCTFail() }
        let st = await s.state
        XCTAssertEqual(st, .pairing, "the first attempt is untouched")
    }

    func testIntroCopyAndCountdown() {
        var m = PairingModel()
        XCTAssertEqual(m.phase, .intro)
        XCTAssertEqual(m.message, "Open the Steam app on another phone or tablet signed in to your account, and scan this code. Keep Playport open until it confirms.")
        XCTAssertEqual(PairingModel.Copy.warning, "Don't switch to Steam on this phone; the sign-in will expire.")
        XCTAssertTrue(m.showsWarning)
        XCTAssertEqual(m.actionTitle, "Show code")
        XCTAssertFalse(m.keepsScreenAwake)
        let start = Date(timeIntervalSince1970: 1000)
        let code = QRCode(payload: url1, expiresAt: start.addingTimeInterval(125), generation: 1)
        m.apply(.code(code))
        XCTAssertEqual(m.message, PairingModel.Copy.intro, "the code keeps the instructions")
        XCTAssertTrue(m.showsWarning)
        XCTAssertNil(m.actionTitle)
        XCTAssertEqual(m.countdown(at: start), "2:05")
        XCTAssertEqual(m.countdown(at: start.addingTimeInterval(124.5)), "0:01")
        XCTAssertEqual(m.countdown(at: start.addingTimeInterval(500)), "0:00")
    }

    func testFingerprintIsShortStableAndNotThePayload() {
        let f = QRCode.fingerprint(of: url1)
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(f, QRCode.fingerprint(of: url1))
        XCTAssertTrue(f.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        XCTAssertFalse(url1.value.contains(f))
        XCTAssertEqual(Redactor.scrub("fingerprint \(f)"), "fingerprint \(f)")
        let code = QRCode(payload: url1, expiresAt: Date(), generation: 1)
        XCTAssertFalse("\(code)".contains("s.team"), "a printed QRCode never shows its payload")
    }

    func testAccountCopy() {
        let a = SteamService.Account(accountTag: "acct#3f2a", steamIDTag: "sid#0001", pairedUntil: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(AccountCopy.status(.signedOut), "Signed out")
        XCTAssertEqual(AccountCopy.status(.pairing), "Pairing")
        XCTAssertEqual(AccountCopy.status(.signedIn(a)), "Signed in as acct#3f2a")
        XCTAssertEqual(AccountCopy.status(.expired), "Session expired (pair again)")
        XCTAssertEqual(AccountCopy.pairedUntil(a) { _ in "1 Jan 1970" }, "Paired until 1 Jan 1970")
        XCTAssertEqual(AccountCopy.signOutNote, "Installed games and saves stay on this phone")
    }
}

func waitUntil(_ timeout: TimeInterval = 2, _ cond: @escaping () async -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("condition not met in \(timeout)s")
}

final class RestoreTests: XCTestCase {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testNoStoredSessionIsSignedOut() async {
        let b = FakeBackend()
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        let st = await s.restoreIfPossible()
        XCTAssertEqual(st, .signedOut)
        let restores = await b.count("restore")
        XCTAssertEqual(restores, 0)
    }

    /// A restore needs no approval; the first one renews, later ones only
    /// once the interval has passed, and the record survives a relaunch.
    func testRestoreRenewsAtMostOncePerInterval() async throws {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 1_900_000_000))
        await b.set(renew: .success(true), token: SessionTests.jwt(sub: "7", exp: 1_950_000_000))
        let dir = tempDir(), clock = TestClock()
        var s = SteamService(backend: b, log: .silent, stateDirectory: dir, now: { clock.now })
        var st = await s.restoreIfPossible()
        guard case let .signedIn(a) = st else { return XCTFail("\(st)") }
        XCTAssertEqual(a.pairedUntil, Date(timeIntervalSince1970: 1_950_000_000), "renewal moves the expiry")
        var renewal = await s.lastRenewal
        XCTAssertEqual(renewal?.result, "renewed")
        var renews = await b.count("renew"), restores = await b.count("restore"), qrs = await b.count("qr")
        XCTAssertEqual([renews, restores, qrs], [1, 1, 0])

        // Foreground again, same session, same day: nothing.
        clock.advance(3600)
        st = await s.restoreIfPossible()
        renews = await b.count("renew"); restores = await b.count("restore")
        XCTAssertEqual([renews, restores], [1, 1])

        // Relaunch (a new service over a new session) the next day: restore and renew once.
        await b.disconnect()
        clock.advance(86_400)
        await b.set(renew: .success(false))
        s = SteamService(backend: b, log: .silent, stateDirectory: dir, now: { clock.now })
        renewal = await s.lastRenewal
        XCTAssertEqual(renewal?.result, "renewed", "the record is read back at launch")
        st = await s.restoreIfPossible()
        renewal = await s.lastRenewal
        XCTAssertEqual(renewal?.result, "not-due")
        renews = await b.count("renew"); restores = await b.count("restore")
        XCTAssertEqual([renews, restores], [2, 2])
    }

    func testRenewalFailureKeepsTheSession() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        await b.set(renew: .failure(SteamError.eresult(.fail, context: "GenerateAccessTokenForApp")))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        let st = await s.restoreIfPossible()
        guard case .signedIn = st else { return XCTFail("\(st)") }
        let r = await s.lastRenewal
        XCTAssertTrue(r?.result.hasPrefix("failed: ") ?? false)
    }

    func testAutoRenewOff() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil, autoRenew: false)
        _ = await s.restoreIfPossible()
        let renews = await b.count("renew")
        XCTAssertEqual(renews, 0)
    }

    func testPairingDefersTheFirstRenewal() async throws {
        let b = FakeBackend()
        await b.set(qr: .events([.approved(accountTag: "acct#0000")], .success(FakeBackend.summary)))
        let clock = TestClock()
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil, now: { clock.now })
        for try await _ in s.signIn() {}
        await b.disconnect()
        clock.advance(3600)
        _ = await s.restoreIfPossible()
        let renews = await b.count("renew"), restores = await b.count("restore")
        XCTAssertEqual([renews, restores], [0, 1])
    }

    func testLocallyExpiredTokenAsksForPairingWithoutNetwork() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: Date().timeIntervalSince1970 - 10))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        let st = await s.restoreIfPossible()
        XCTAssertEqual(st, .expired)
        let calls = await b.calls
        XCTAssertFalse(calls.contains("restore"))
    }

    func testRefusedSessionIsExpiredAndStaysSoAcrossLaunches() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        await b.set(restore: .failure(SteamError.eresult(.revoked, context: "ClientLogon")))
        let dir = tempDir()
        let s = SteamService(backend: b, log: .silent, stateDirectory: dir)
        var st = await s.restoreIfPossible()
        XCTAssertEqual(st, .expired)
        // SteamSession deletes a refused token; the next launch still says why.
        await b.set(stored: nil)
        st = await SteamService(backend: b, log: .silent, stateDirectory: dir).restoreIfPossible()
        XCTAssertEqual(st, .expired)
    }

    func testUnreachableSteamKeepsThePairing() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        await b.set(restore: .failure(SteamError.retriesExhausted("no CM endpoint")))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        let st = await s.restoreIfPossible()
        guard case let .offline(a, reason) = st else { return XCTFail("\(st)") }
        XCTAssertEqual(a.accountTag, FakeBackend.summary.accountTag)
        XCTAssertEqual(reason, "Steam can't be reached")
    }

    /// Sockets die in suspension: a signed-in state with a dead socket restores again.
    func testDeadSocketOnForegroundRestoresAgain() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        _ = await s.restoreIfPossible()
        await b.disconnect()
        let st = await s.restoreIfPossible()
        guard case .signedIn = st else { return XCTFail("\(st)") }
        let restores = await b.count("restore")
        XCTAssertEqual(restores, 2)
    }

    /// Foreground and pull-to-refresh at once: one restore, both signed in.
    func testConcurrentRestoresShareOneLogon() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        await b.set(restoreDelay: 50_000_000)
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        async let first = s.restoreIfPossible()
        async let second = s.restoreIfPossible()
        let (st1, st2) = await (first, second)
        guard case .signedIn = st1, case .signedIn = st2 else { return XCTFail("\(st1) \(st2)") }
        let restores = await b.count("restore"), connected = await b.isLoggedOn().connected
        XCTAssertEqual(restores, 1)
        XCTAssertTrue(connected)
    }

    /// Foreground during a sign-out from offline: no second logon, ends signed out.
    func testRestoreDuringSignOutDoesNotLogOn() async throws {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        await b.set(restore: .failure(SteamError.retriesExhausted("no CM endpoint")))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        let st = await s.restoreIfPossible()
        guard case .offline = st else { return XCTFail("\(st)") }
        await b.set(restore: .success(FakeBackend.summary))
        await b.set(restoreDelay: 50_000_000)
        async let report = s.signOut()
        try await Task.sleep(nanoseconds: 10_000_000)
        let during = await s.restoreIfPossible()
        guard case .offline = during else { return XCTFail("\(during)") }
        let r = try await report
        XCTAssertTrue(r.revoked)
        let end = await s.state, restores = await b.count("restore")
        XCTAssertEqual(end, .signedOut)
        XCTAssertEqual(restores, 2, "the offline restore and sign-out's own logon, nothing more")
    }

    func testRestoreDropsAnAnonymousLogonFirst() async {
        let b = FakeBackend()
        _ = try? await b.logOnAnonymous()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        _ = await s.restoreIfPossible()
        let calls = await b.calls
        XCTAssertEqual(Array(calls.prefix(3)), ["anonymous", "disconnect", "restore"])
    }

    func testSuspendForLaunch() async {
        let b = FakeBackend()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        _ = await s.restoreIfPossible()
        await s.suspendForLaunch()
        let on = await b.loggedOn
        XCTAssertFalse(on.connected)
        do { _ = try await s.ownedGames(refresh: true); XCTFail() } catch {}
        do { for try await _ in s.signIn() {}; XCTFail() } catch {
            guard case .failed = error as? SignInFailure else { return XCTFail("\(error)") }
        }
        let stored = await b.stored
        XCTAssertNotNil(stored, "the pairing stays for the next launch")
    }
}

final class LibraryServiceTests: XCTestCase {
    static func record(_ id: UInt32, name: String, type: String = "Game", oslist: String = "windows", osarch: String = "64",
                       depotOS: String = "windows", depotArch: String = "") -> KeyValue {
        let text = """
        "\(id)"
        {
            "common" { "name" "\(name)" "type" "\(type)" "oslist" "\(oslist)" "osarch" "\(osarch)" "controller_support" "Full"
                "associations" { "0" { "type" "developer" "name" "Dev \(id)" } }
                "library_assets_full" {
                    "library_capsule" { "image" { "english" "aa11/library_capsule.jpg" } "image2x" { "english" "aa11/library_capsule_2x.jpg" } }
                    "library_hero" { "image" { "english" "bb22/library_hero.jpg" } }
                }
                "header_image" { "english" "cc33/header.jpg" }
            }
            "config" { "installdir" "\(name)"
                "launch" {
                    "0" { "executable" "tool.exe" "type" "option1" "config" { "oslist" "windows" } }
                    "1" { "executable" "\(name.lowercased()).exe" "arguments" "-x" "config" { "oslist" "windows" } }
                    "2" { "executable" "\(name).app" "type" "none" "config" { "oslist" "macos" } }
                }
            }
            "depots" {
                "\(id + 1)" { "config" { "oslist" "\(depotOS)" "osarch" "\(depotArch)" } "manifests" { "public" { "gid" "123" "size" "1000" } } }
                "\(id + 2)" { "config" { "oslist" "macos" } "manifests" { "public" { "gid" "456" "size" "9999" } } }
                "branches" { "public" { "buildid" "42" } }
            }
        }
        """
        return try! KeyValue.parseText(Array(text.utf8))
    }

    func testParse() throws {
        let hk = try SteamAppInfo.parse(appID: 367520, Self.record(367520, name: "Knight"))
        XCTAssertEqual(hk.name, "Knight")
        XCTAssertEqual(hk.developer, "Dev 367520")
        XCTAssertEqual(hk.installDir, "Knight")
        XCTAssertEqual(hk.windowsLaunch?.executable, "knight.exe", "the untyped Windows entry wins")
        XCTAssertEqual(hk.windowsLaunch?.arguments, "-x")
        XCTAssertEqual(hk.publicBuildID, 42)
        XCTAssertEqual(hk.windowsContentDepots.map(\.depotID), [367521])
        XCTAssertEqual(hk.installSize, 1000)
        XCTAssertEqual(hk.art, .init(capsule: "aa11/library_capsule.jpg", capsule2x: "aa11/library_capsule_2x.jpg",
                                     hero: "bb22/library_hero.jpg", header: "cc33/header.jpg"))
        XCTAssertEqual(hk.controllerSupport, "full")
        // A record cached before controller support was read decodes without it.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hk)) as! [String: Any]
        old["controllerSupport"] = nil
        let cached = try JSONDecoder().decode(SteamAppInfo.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(cached.controllerSupport)
    }

    func signedIn(_ b: FakeBackend, dir: URL?) async -> SteamService {
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: dir)
        _ = await s.restoreIfPossible()
        return s
    }

    func testOwnedGamesAndCache() async throws {
        let b = FakeBackend()
        await b.set(library: [367520, 10, 20, 50, 60, 70], [
            367520: Self.record(367520, name: "Knight"),
            10: Self.record(10, name: "Alpha"),
            20: Self.record(20, name: "Old", osarch: "32"),
            50: Self.record(50, name: "Soundtrack", type: "Music"),
            70: Self.record(70, name: "Beta Demo", type: "Demo"),
            // 60: withheld by Steam
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = await signedIn(b, dir: dir)
        let none = await s.cachedGames()
        XCTAssertNil(none)
        let games = try await s.ownedGames(refresh: false)
        XCTAssertEqual(games.map(\.info.name), ["Alpha", "Beta Demo", "Knight", "Old"], "games and demos only, by name")
        XCTAssertEqual(games.map(\.id), [10, 70, 367520, 20], "a game that may not run is listed too")

        // A relaunch paints from disk with no network call.
        let s2 = await signedIn(b, dir: dir)
        let recordsBefore = await b.count("records")
        let cached = await s2.cachedGames()
        XCTAssertEqual(cached?.games, games)
        let again = try await s2.ownedGames(refresh: false)
        XCTAssertEqual(again, games)
        let recordsAfter = await b.count("records")
        XCTAssertEqual(recordsAfter, recordsBefore)

        // Metadata from the same fetch, no second PICS call.
        let info = try await s2.appInfo(367520)
        XCTAssertEqual(info.name, "Knight")

        // Sign-out revokes and deletes the cached account data.
        let report = try await s2.signOut()
        XCTAssertTrue(report.revoked)
        let st = await s2.state
        XCTAssertEqual(st, .signedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("steam-games.json").path))
        let renewal = await s2.lastRenewal
        XCTAssertNil(renewal)
    }

    func testCacheIsPerAccount() async throws {
        let b = FakeBackend()
        await b.set(library: [10], [10: Self.record(10, name: "Alpha")])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = await signedIn(b, dir: dir)
        _ = try await s.ownedGames(refresh: true)
        await b.set(restore: .success(AccountSummary(accountTag: "acct#ffff", steamIDTag: "sid#ffff", anonymous: false, cellID: 1, heartbeatSeconds: 9)))
        let other = await signedIn(b, dir: dir)
        let cached = await other.cachedGames()
        XCTAssertNil(cached, "another account never sees this one's list")
    }

    func testAppInfoSignedOutUsesAnAnonymousSession() async throws {
        let b = FakeBackend()
        await b.set(library: [], [367520: Self.record(367520, name: "Knight")])
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        let info = try await s.appInfo(367520)
        XCTAssertEqual(info.name, "Knight")
        let calls = await b.calls
        XCTAssertTrue(calls.contains("anonymous"))
        do { _ = try await s.appInfo(99); XCTFail() } catch SteamError.notFound(_) {}
    }

    func testGameProfileForTheEmulator() async throws {
        let b = FakeBackend()
        var knight = Self.record(367520, name: "Knight")
        knight.children.append(KeyValue(name: "extended", children: [KeyValue(name: "listofdlc", value: "40,41,42")]))
        // 41 is owned but Steam withholds its record; 42 is not owned.
        await b.set(library: [367520, 40, 41], [367520: knight, 40: Self.record(40, name: "Soundtrack", type: "DLC")])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = await signedIn(b, dir: dir)
        let none = await s.gameProfile(appID: 367520)
        XCTAssertNil(none)
        let p = try await s.refreshGameProfile(appID: 367520)
        XCTAssertEqual(p.personaName, "Knight Player")
        XCTAssertEqual(p.steamID, 7)
        XCTAssertEqual(p.language, "english")
        XCTAssertEqual(p.dlc, [.init(appID: 40, name: "Soundtrack"), .init(appID: 41, name: "DLC 41")])

        // Kept across a relaunch and through the suspension for a launch.
        let s2 = await signedIn(b, dir: dir)
        await s2.suspendForLaunch()
        let kept = await s2.gameProfile(appID: 367520)
        XCTAssertEqual(kept, p)
        do { _ = try await s2.refreshGameProfile(appID: 367520); XCTFail() } catch SteamError.unsupported(_) {}

        // What a launch tells the emulator, from the kept profile and the stored session.
        let settings = await s2.emulatorSettings(appID: 367520)
        XCTAssertEqual(settings, SteamAPISwap.Settings(appID: 367520, personaName: "Knight Player", steamID: 7, dlc: p.dlc))
        let otherGame = await s2.emulatorSettings(appID: 10)
        XCTAssertEqual(otherGame, SteamAPISwap.Settings(appID: 10, personaName: "Knight Player", steamID: 7), "the account's persona, no DLC")

        // Another account never sees it; a sign-out deletes it.
        await b.set(stored: StoredSession(accountName: "other", steamID: 8, refreshToken: SessionTests.jwt(sub: "8", exp: 2_000_000_000),
                                          guardData: nil, savedAt: Date()))
        let other = SteamService(backend: b, log: .silent, stateDirectory: dir)
        let foreign = await other.gameProfile(appID: 367520)
        XCTAssertNil(foreign)
        let foreignSettings = await other.emulatorSettings(appID: 367520)
        XCTAssertEqual(foreignSettings, SteamAPISwap.Settings(appID: 367520, steamID: 8))
        let s3 = await signedIn(b, dir: dir)
        _ = try await s3.signOut()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("steam-game-profiles.json").path))
    }

    func testGameProfileWithoutAPersonaName() async throws {
        let b = FakeBackend()
        await b.set(library: [10], [10: Self.record(10, name: "Alpha")])
        await b.set(persona: .failure(SteamError.timeout("persona state")))
        let s = await signedIn(b, dir: nil)
        let p = try await s.refreshGameProfile(appID: 10)
        XCTAssertNil(p.personaName, "the emulator then reports its default, never the account name")
        XCTAssertEqual(p.dlc, [])
    }

    func testEmulatorSettingsSignedOutAreTheAppIDOnly() async {
        let s = SteamService(backend: FakeBackend(), log: .silent, stateDirectory: nil)
        let settings = await s.emulatorSettings(appID: 10)
        XCTAssertEqual(settings, SteamAPISwap.Settings(appID: 10))
    }

    func testEncryptedAppTicketOnTheSignedInSessionOnly() async throws {
        let b = FakeBackend()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = Counter()
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: Logger { lines.add($0) }, stateDirectory: dir)
        // Before any restore: no session to ask on, and none is started for it.
        let early = await s.encryptedAppTicket(appID: 367520)
        XCTAssertNil(early)
        let restores = await b.count("restore")
        XCTAssertEqual(restores, 0)
        _ = await s.restoreIfPossible()

        let ticket = await s.encryptedAppTicket(appID: 367520)
        XCTAssertEqual(ticket?.value, Array("a made-up encrypted app ticket".utf8))
        let asked = await b.count("ticket 367520")
        XCTAssertEqual(asked, 1)
        // Never kept on the host: no file the service writes holds it, and no log line.
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for f in files { XCTAssertNil((try? Data(contentsOf: f))?.range(of: Data("made-up encrypted".utf8)), f.lastPathComponent) }
        XCTAssertFalse(lines.values.contains { $0.contains("made-up") })
        XCTAssertTrue(lines.values.contains { $0.contains("encrypted app ticket fetched, 30 bytes") })

        // Steam refuses: the game starts without one.
        await b.set(ticket: .failure(SteamError.eresult(.accessDenied, context: "ClientRequestEncryptedAppTicket 367520")))
        let refused = await s.encryptedAppTicket(appID: 367520)
        XCTAssertNil(refused)

        // Steam is slow: the limit holds and the game starts without one.
        await b.set(ticket: .success([1, 2, 3]), delay: 2_000_000_000)
        let t0 = Date()
        let slow = await s.encryptedAppTicket(appID: 367520, timeout: 0.2)
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)

        // The session dropped: no ticket, and no restore to get one.
        await b.set(ticket: .success([1, 2, 3]))
        await b.disconnect()
        let dropped = await s.encryptedAppTicket(appID: 367520)
        XCTAssertNil(dropped)

        // Suspended for the launch: none.
        _ = await s.restoreIfPossible()
        await s.suspendForLaunch()
        let suspended = await s.encryptedAppTicket(appID: 367520)
        XCTAssertNil(suspended)
        let askedInAll = await b.count("ticket 367520")
        XCTAssertEqual(askedInAll, 3)
    }

    func testOwnedGamesNeedsASession() async {
        let s = SteamService(backend: FakeBackend(), log: .silent, stateDirectory: nil)
        do { _ = try await s.ownedGames(refresh: true); XCTFail() } catch SteamError.notLoggedOn {} catch { XCTFail("\(error)") }
    }
}

final class ArtworkTests: XCTestCase {
    let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]

    func app(_ capsule: String?) throws -> SteamAppInfo {
        var a = try SteamAppInfo.parse(appID: 367520, LibraryServiceTests.record(367520, name: "Knight"))
        a.art.capsule = capsule
        return a
    }

    func testFetchOnceByHashedPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fetched = Counter()
        let jpeg = self.jpeg
        let cache = ArtworkCache(directory: dir) { url in
            fetched.add(url.absoluteString)
            try await Task.sleep(nanoseconds: 20_000_000)
            return jpeg
        }
        let a = try app("aa11/library_capsule.jpg")
        async let x = cache.image(a, .capsule)
        async let y = cache.image(a, .capsule)
        let (u1, u2) = try await (x, y)
        XCTAssertEqual(u1, u2)
        XCTAssertEqual(fetched.values, ["https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/367520/aa11/library_capsule.jpg"])
        _ = try await cache.image(a, .capsule)
        XCTAssertEqual(fetched.values.count, 1, "served from disk")
        let cached = await cache.cached(a, .capsule)
        XCTAssertEqual(cached, u1)
        try await cache.clear()
        let gone = await cache.cached(a, .capsule)
        XCTAssertNil(gone)
    }

    func testUnsafeOrMissingPathsFallBackToTheLegacyName() throws {
        XCTAssertEqual(ArtworkCache.assetPath(try app("../../etc/passwd"), .capsule), "library_600x900.jpg")
        XCTAssertEqual(ArtworkCache.assetPath(try app("a/b?c"), .capsule), "library_600x900.jpg")
        XCTAssertEqual(ArtworkCache.assetPath(try app(nil), .capsule), "library_600x900.jpg")
        XCTAssertEqual(ArtworkCache.assetPath(try app("aa11/library_capsule.jpg"), .capsule), "aa11/library_capsule.jpg")
    }

    func testNonImageIsRefused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkCache(directory: dir) { _ in Array("<html>".utf8) }
        do { _ = try await cache.image(try app(nil), .hero); XCTFail() } catch SteamError.unsafeContent(_) {}
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var values: [String] { lock.withLock { v } }
}
