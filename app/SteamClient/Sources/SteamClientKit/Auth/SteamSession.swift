// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the QR flow reports to whoever displays the code. The challenge URL is
/// the QR payload: it goes to the presenter, never to a log.
public enum QREvent: Sendable {
    case challenge(Secret<String>, expiresIn: TimeInterval)
    /// Steam rotated the challenge; the old code no longer works.
    case replaced(Secret<String>)
    /// The phone scanned the code and is showing the confirmation prompt.
    case scanned
    case approved(accountTag: String)
}

/// What a credential sign-in reports to its screen. Nothing here is secret
/// but an e-mail code's domain, which `AuthConfirmation.message` carries for
/// the screen only.
public enum CredentialEvent: Sendable, Equatable {
    /// Steam took the account name and password; how it wants the sign-in confirmed.
    case confirm([AuthConfirmation])
    case codeAccepted
    /// Steam refused the Steam Guard code; the session goes on, another may be sent.
    case codeRejected
    case approved(accountTag: String)
}

/// Where the screen hands Steam Guard codes to a running credential sign-in
/// (`SteamSession.loginWithCredentials`), which takes them between polls.
public final class GuardCodeInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Secret<String>] = []

    public init() {}

    /// A code as typed: spaces and dashes go, letters are upper-cased (Steam's codes are five characters).
    public func submit(_ code: String) {
        let clean = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard !clean.isEmpty else { return }
        lock.withLock { pending.append(Secret(clean)) }
    }

    func take() -> Secret<String>? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }

    /// The next code, as soon as one comes within `seconds`; nil when none did.
    func next(within seconds: TimeInterval) async throws -> Secret<String>? {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if let c = take() { return c }
            let left = end.timeIntervalSinceNow
            if left <= 0 { return nil }
            try await Task.sleep(nanoseconds: UInt64(min(left, 0.1) * 1_000_000_000))
        }
    }
}

public struct AccountSummary: Sendable {
    public var accountTag: String   // non-reversible tag of the account name
    public var steamIDTag: String   // non-reversible tag of the SteamID
    public var anonymous: Bool
    public var cellID: UInt32
    public var heartbeatSeconds: Int
}

public struct LogoutReport: Sendable {
    public var revoked: Bool
    public var revokeResult: String
    public var loggedOff: Bool
    public var credentialsDeleted: Bool
}

/// The Steam session state machine. Every authentication transition (QR
/// login, restore, token renewal, logout) runs through `transition`, which
/// admits one at a time: a second concurrent attempt fails with
/// `invalidState` instead of interleaving writes to the credential store.
public actor SteamSession {
    public enum State: Sendable, Equatable { case disconnected, connected, loggedOn(anonymous: Bool) }

    public let store: SecretStore
    public let log: Logger
    public let http: HTTPClient
    public var deviceName = "Playport iOS"
    /// EOSType sent at logon (enums.steamd: Windows10 = 16).
    public var osType: UInt32 = 16

    public private(set) var state: State = .disconnected
    public private(set) var cm: CMConnection?
    public private(set) var cellID: UInt32 = 0
    public private(set) var licenses: [CMsgClientLicenseList.License] = []
    private var transitionInFlight: String?
    var statsCall: Task<Void, Never>?
    /// The game connect tokens of the current logon (decision 0062), cleared at disconnect.
    public nonisolated let connectTokens = GameConnectTokens()
    /// Ticket acks and checks, to a play's broker (SteamTicketBroker).
    public nonisolated let ticketPushes = TicketPushRoute()
    /// What the session's connections carried, and whether one is open.
    public nonisolated let traffic = CMTraffic()

    public init(store: SecretStore, log: Logger) {
        self.store = store
        self.log = log
        self.http = HTTPClient(log: log)
    }

    // MARK: serialisation

    private func transition<T: Sendable>(_ name: String, _ body: () async throws -> T) async throws -> T {
        if let other = transitionInFlight {
            throw SteamError.eresult(.invalidState, context: "\(name) while \(other) is in progress")
        }
        transitionInFlight = name
        defer { transitionInFlight = nil }
        log.debug("auth", "transition begin: \(name)")
        return try await body()
    }

    // MARK: connection

    /// Connects to the first reachable CM from the directory, trying at most
    /// `maxEndpoints` of them.
    public func connect(maxEndpoints: Int = 3) async throws {
        if let cm, await cm.isOpen { return }
        let endpoints = try await CMDirectory.websocketEndpoints(http: http)
        var last: Error = SteamError.notFound("CM")
        for ep in endpoints.prefix(maxEndpoints) {
            try Task.checkCancellation()
            let c = CMConnection(endpoint: ep, log: log, traffic: traffic, push: pushHandler())
            do {
                try await c.connect()
                cm = c
                state = .connected
                return
            } catch {
                log.warn("cm", "endpoint \(ep) failed: \(error)")
                await c.close()
                last = error
            }
        }
        throw SteamError.retriesExhausted("no CM endpoint accepted a connection (\(last))")
    }

    func requireCM() throws -> CMConnection {
        guard let cm else { throw SteamError.transport("not connected") }
        return cm
    }

    public func disconnect() async {
        await cm?.close()
        cm = nil
        state = .disconnected
        // The next logon may be another account, or anonymous: its list comes fresh.
        licenses = []
        // Tokens belong to the logon that got them (decision 0062).
        connectTokens.clear()
    }

    // MARK: machine id (a machine secret, kept in the store)

    private func machineID() throws -> Secret<[UInt8]> {
        if let existing = try store.read(SecretKeys.machineID) { return existing }
        var bytes = [UInt8](repeating: 0, count: 20)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = rng.next() }
        let id = Secret(Array(bytes.hex.uppercased().utf8))
        try store.write(SecretKeys.machineID, id)
        return id
    }

    // MARK: QR login

    /// Starts a QR auth session, reports each challenge through `onEvent`, and
    /// polls until Steam approves, denies or expires it, or `deadline` passes.
    /// On approval the refresh token goes straight to the credential store and
    /// the session logs on with it.
    public func loginWithQR(deadline: TimeInterval = 300, onEvent: @escaping @Sendable (QREvent) -> Void) async throws -> AccountSummary {
        try await transition("qr-login") {
            try await connect()
            var cm = try requireCM()
            let begin = try BeginAuthSessionViaQRResponse.decode(
                await cm.serviceCall("Authentication.BeginAuthSessionViaQR#1",
                                     BeginAuthSessionViaQRRequest(deviceFriendlyName: deviceName, platformType: .steamClient),
                                     authed: false))
            log.info("qr", "challenge issued: version=\(begin.version ?? -1) interval=\(begin.interval)s confirmations=\(begin.allowedConfirmations)")
            onEvent(.challenge(begin.challengeURL, expiresIn: deadline))

            var clientID = begin.clientID
            let interval = max(1.0, Double(begin.interval))
            let started = Date()
            var transientFailures = 0
            var scanned = false
            var polls = 0
            while true {
                try Task.checkCancellation()
                if Date().timeIntervalSince(started) > deadline {
                    log.info("qr", "local deadline of \(Int(deadline))s reached after \(polls) polls")
                    throw SteamError.qrExpired
                }
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                polls += 1
                let poll: PollAuthSessionStatusResponse
                do {
                    poll = try PollAuthSessionStatusResponse.decode(
                        await cm.serviceCall("Authentication.PollAuthSessionStatus#1",
                                             PollAuthSessionStatusRequest(clientID: clientID, requestID: begin.requestID),
                                             authed: false))
                    transientFailures = 0
                } catch let SteamError.eresult(result, _) {
                    // Steam drops the session when the user denies it or it expires.
                    log.info("qr", "poll \(polls): session ended by Steam with \(result.name)")
                    throw SteamError.qrSessionEnded(result)
                } catch let e as SteamError {
                    if case .timeout = e { transientFailures += 1 } else if case .transport = e { transientFailures += 1 } else { throw e }
                    log.warn("qr", "poll \(polls) failed (\(transientFailures)/3): \(e)")
                    if transientFailures >= 3 { throw SteamError.retriesExhausted("QR poll: \(e)") }
                    // CMs drop unauthenticated sockets after about a minute; the
                    // auth session lives server-side, so poll it from a new one.
                    if await !cm.isOpen {
                        await disconnect()
                        try await connect()
                        cm = try requireCM()
                        log.info("qr", "reconnected to \(cm.endpoint); polling the same auth session")
                    }
                    continue
                }
                if let newURL = poll.newChallengeURL {
                    if let nc = poll.newClientID { clientID = nc }
                    log.info("qr", "poll \(polls): challenge replaced by Steam")
                    onEvent(.replaced(newURL))
                }
                if poll.hadRemoteInteraction && !scanned {
                    scanned = true
                    log.info("qr", "poll \(polls): code scanned, awaiting confirmation on the phone")
                    onEvent(.scanned)
                }
                if let refresh = poll.refreshToken {
                    guard let account = poll.accountName else { throw SteamError.protocolChanged("approved poll without account_name") }
                    let claims = try JWTClaims(token: refresh)
                    let session = StoredSession(accountName: account, steamID: claims.subject ?? 0,
                                                refreshToken: refresh.value, guardData: poll.newGuardData?.value, savedAt: Date())
                    try save(session)
                    log.info("qr", "poll \(polls): approved; refresh token stored in \(store.backendName)")
                    onEvent(.approved(accountTag: Redactor.tag("acct", account)))
                    return try await logOn(session)
                }
                log.debug("qr", "poll \(polls): pending")
            }
        }
    }

    // MARK: credential login

    /// Signs in with an account name and password (BeginAuthSessionViaCredentials):
    /// the password is encrypted with the account's RSA key
    /// (GetPasswordRSAPublicKey) and goes to Steam once; nothing keeps it.
    /// `onEvent` gets the confirmations Steam allows (approval in the Steam
    /// Mobile app, a Steam Guard code from the app or by e-mail), then the
    /// session polls until Steam approves, denies or expires it, or
    /// `deadline` passes. A code the player types arrives through `codes`
    /// between polls; a refused code is reported and another may follow. On
    /// approval the refresh token is stored and logged on with exactly as the
    /// QR login does.
    public func loginWithCredentials(accountName: String, password: Secret<String>, codes: GuardCodeInbox,
                                     deadline: TimeInterval = 300,
                                     onEvent: @escaping @Sendable (CredentialEvent) -> Void) async throws -> AccountSummary {
        try await transition("credential-login") {
            try await connect()
            var cm = try requireCM()
            let tag = Redactor.tag("acct", accountName)
            let begin: BeginAuthSessionViaCredentialsResponse
            do {
                let key = try GetPasswordRSAPublicKeyResponse.decode(
                    await cm.serviceCall("Authentication.GetPasswordRSAPublicKey#1",
                                         GetPasswordRSAPublicKeyRequest(accountName: accountName), authed: false))
                let rsa = try RSAPublicKey(modulusHex: key.modulusHex, exponentHex: key.exponentHex)
                let encrypted = Secret(Data(try rsa.encryptPKCS1(Array(password.value.utf8))).base64EncodedString())
                log.info("credentials", "password key for \(tag): \(rsa.byteCount * 8) bits")
                begin = try BeginAuthSessionViaCredentialsResponse.decode(
                    await cm.serviceCall("Authentication.BeginAuthSessionViaCredentials#1",
                                         BeginAuthSessionViaCredentialsRequest(
                                            deviceFriendlyName: deviceName, accountName: accountName,
                                            encryptedPassword: encrypted, encryptionTimestamp: key.timestamp,
                                            platformType: .steamClient),
                                         authed: false))
            } catch let SteamError.eresult(result, _) {
                log.info("credentials", "\(tag): refused by Steam with \(result.name)")
                throw SteamError.credentialsRefused(result)
            }
            let kinds = begin.allowedConfirmations.map { "\($0.type)" }.joined(separator: ",")
            log.info("credentials", "\(tag): session started: interval=\(begin.interval)s confirmations=\(kinds)")
            onEvent(.confirm(begin.allowedConfirmations))
            let codeType: AuthGuardType? = begin.allowedConfirmations.map(\.type).contains(.deviceCode) ? .deviceCode
                : begin.allowedConfirmations.map(\.type).contains(.emailCode) ? .emailCode : nil

            var clientID = begin.clientID
            let interval = max(1.0, Double(begin.interval))
            let started = Date()
            var transientFailures = 0
            var polls = 0
            while true {
                try Task.checkCancellation()
                if Date().timeIntervalSince(started) > deadline {
                    log.info("credentials", "local deadline of \(Int(deadline))s reached after \(polls) polls")
                    throw SteamError.authSessionEnded(.expired)
                }
                // Wait out the interval, sending a code as soon as one comes.
                if let code = try await codes.next(within: interval) {
                    guard let codeType else {
                        log.warn("credentials", "a Steam Guard code came, but Steam asked for none; dropped")
                        continue
                    }
                    do {
                        _ = try await cm.serviceCall("Authentication.UpdateAuthSessionWithSteamGuardCode#1",
                                                     UpdateAuthSessionWithSteamGuardCodeRequest(clientID: clientID, steamID: begin.steamID,
                                                                                                code: code, codeType: codeType),
                                                     authed: false)
                        log.info("credentials", "Steam Guard code (\(codeType)) accepted")
                        onEvent(.codeAccepted)
                    } catch let SteamError.eresult(result, _) {
                        switch result {
                        case .expired, .accessDenied, .fileNotFound, .rateLimitExceeded, .accountLoginDeniedThrottle:
                            log.info("credentials", "Steam Guard code: session ended with \(result.name)")
                            throw SteamError.authSessionEnded(result)
                        default:
                            log.info("credentials", "Steam Guard code refused: \(result.name)")
                            onEvent(.codeRejected)
                        }
                    }
                }
                polls += 1
                let poll: PollAuthSessionStatusResponse
                do {
                    poll = try PollAuthSessionStatusResponse.decode(
                        await cm.serviceCall("Authentication.PollAuthSessionStatus#1",
                                             PollAuthSessionStatusRequest(clientID: clientID, requestID: begin.requestID),
                                             authed: false))
                    transientFailures = 0
                } catch let SteamError.eresult(result, _) {
                    log.info("credentials", "poll \(polls): session ended by Steam with \(result.name)")
                    throw SteamError.authSessionEnded(result)
                } catch let e as SteamError {
                    if case .timeout = e { transientFailures += 1 } else if case .transport = e { transientFailures += 1 } else { throw e }
                    log.warn("credentials", "poll \(polls) failed (\(transientFailures)/3): \(e)")
                    if transientFailures >= 3 { throw SteamError.retriesExhausted("credential poll: \(e)") }
                    if await !cm.isOpen {
                        await disconnect()
                        try await connect()
                        cm = try requireCM()
                        log.info("credentials", "reconnected to \(cm.endpoint); polling the same auth session")
                    }
                    continue
                }
                if let nc = poll.newClientID { clientID = nc }
                if let refresh = poll.refreshToken {
                    let account = poll.accountName ?? accountName
                    let claims = try JWTClaims(token: refresh)
                    let session = StoredSession(accountName: account, steamID: claims.subject ?? begin.steamID,
                                                refreshToken: refresh.value, guardData: poll.newGuardData?.value, savedAt: Date())
                    try save(session)
                    log.info("credentials", "poll \(polls): approved; refresh token stored in \(store.backendName)")
                    onEvent(.approved(accountTag: Redactor.tag("acct", account)))
                    return try await logOn(session)
                }
                log.debug("credentials", "poll \(polls): pending")
            }
        }
    }

    // MARK: session persistence

    private func save(_ s: StoredSession) throws {
        let data = try JSONEncoder().encode(s)
        try store.write(SecretKeys.session, Secret([UInt8](data)))
    }

    public func storedSession() throws -> StoredSession? {
        guard let raw = try store.read(SecretKeys.session) else { return nil }
        do { return try JSONDecoder().decode(StoredSession.self, from: Data(raw.value)) } catch {
            throw SteamError.credentialStore("stored session is unreadable")
        }
    }

    // MARK: logon

    /// Restores the stored session: no QR, the refresh token from the store is
    /// the logon credential (SteamService.login(accessToken = refreshToken)).
    public func restore() async throws -> AccountSummary {
        try await transition("restore") {
            guard let s = try storedSession() else { throw SteamError.noCredentials }
            let claims = try JWTClaims(token: Secret(s.refreshToken))
            if claims.isExpired() {
                log.warn("auth", "stored refresh token expired at \(claims.expiry.map { "\($0)" } ?? "?")")
                throw SteamError.eresult(.expired, context: "stored refresh token")
            }
            log.info("auth", "restoring \(Redactor.tag("acct", s.accountName)) from \(store.backendName); token valid until \(claims.expiry.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown")")
            try await connect()
            return try await logOn(s)
        }
    }

    private func logOn(_ s: StoredSession) async throws -> AccountSummary {
        let cm = try requireCM()
        var logon = CMsgClientLogon()
        logon.accountName = s.accountName
        logon.accessToken = Secret(s.refreshToken)
        logon.shouldRememberPassword = true
        logon.clientOSType = osType
        logon.cellID = cellID
        logon.machineName = deviceName
        logon.machineID = try machineID()
        logon.clientPackageVersion = 1771
        logon.supportsRateLimitResponse = true
        var h = ProtoHeader()
        h.steamID = s.steamID != 0 ? s.steamID : SteamIDs.individualPlaceholder
        h.clientSessionID = 0
        try await cm.send(.clientLogon, logon, header: h)
        let reply = try CMsgClientLogonResponse.decode(await cm.next(.emsg(EMsg.clientLogOnResponse.rawValue), timeout: 30).body)
        guard reply.eresult == .ok else {
            log.warn("auth", "logon refused: \(reply.eresult.name)")
            switch reply.eresult {
            case .invalidPassword, .accessDenied, .expired, .revoked, .invalidSignature, .accountDisabled:
                // The stored token is dead; drop it so the next launch asks for QR.
                try? store.delete(SecretKeys.session)
                log.info("auth", "stale credentials deleted from \(store.backendName)")
            default: break
            }
            throw SteamError.eresult(reply.eresult, context: "ClientLogon")
        }
        return await finishLogon(reply, accountName: s.accountName, anonymous: false)
    }

    /// Anonymous logon: the same CM session path with no account, used to
    /// exercise PICS and the CDN on public, anonymous-licensed content.
    public func logOnAnonymous() async throws -> AccountSummary {
        try await transition("anonymous-logon") {
            try await connect()
            let cm = try requireCM()
            var logon = CMsgClientLogon()
            logon.clientOSType = osType
            logon.cellID = cellID
            logon.machineID = try machineID()
            var h = ProtoHeader()
            h.steamID = SteamIDs.anonymousUser
            h.clientSessionID = 0
            try await cm.send(.clientLogon, logon, header: h)
            let reply = try CMsgClientLogonResponse.decode(await cm.next(.emsg(EMsg.clientLogOnResponse.rawValue), timeout: 30).body)
            guard reply.eresult == .ok else { throw SteamError.eresult(reply.eresult, context: "ClientLogon (anonymous)") }
            return await finishLogon(reply, accountName: "anonymous", anonymous: true)
        }
    }

    private func finishLogon(_ reply: CMsgClientLogonResponse, accountName: String, anonymous: Bool) async -> AccountSummary {
        let heartbeat = Int(reply.heartbeatSeconds ?? reply.legacyHeartbeatSeconds ?? 9)
        if let c = reply.cellID { cellID = c }
        await cm?.startHeartbeat(seconds: heartbeat)
        state = .loggedOn(anonymous: anonymous)
        let sid = await cm?.steamID ?? 0
        log.info("auth", "logged on as \(anonymous ? "anonymous user" : Redactor.tag("acct", accountName)) (\(Redactor.tag("sid", String(sid)))), cell \(cellID), heartbeat \(heartbeat)s")
        return AccountSummary(accountTag: anonymous ? "anonymous" : Redactor.tag("acct", accountName),
                              steamIDTag: Redactor.tag("sid", String(sid)), anonymous: anonymous,
                              cellID: cellID, heartbeatSeconds: heartbeat)
    }

    /// Asks Steam to renew the stored refresh token (GenerateAccessTokenForApp
    /// with renewal allowed). A renewed token replaces the stored one in a
    /// single store write; otherwise the store is untouched.
    public func renewTokens() async throws -> Bool {
        try await transition("renew") {
            guard case .loggedOn(false) = state else { throw SteamError.notLoggedOn }
            guard var s = try storedSession() else { throw SteamError.noCredentials }
            let cm = try requireCM()
            let sid = await cm.steamID
            let r = try GenerateAccessTokenForAppResponse.decode(
                await cm.serviceCall("Authentication.GenerateAccessTokenForApp#1",
                                     GenerateAccessTokenForAppRequest(refreshToken: Secret(s.refreshToken), steamID: sid),
                                     authed: true))
            guard r.accessToken != nil else { throw SteamError.protocolChanged("GenerateAccessTokenForApp without access_token") }
            if let renewed = r.refreshToken {
                s.refreshToken = renewed.value
                s.savedAt = Date()
                try save(s)
                log.info("auth", "refresh token renewed and replaced in \(store.backendName)")
                return true
            }
            log.info("auth", "access token issued; refresh token not due for renewal")
            return false
        }
    }

    // MARK: licenses

    /// The license list Steam pushes after logon. Anonymous sessions get none
    /// (observed live); for them this returns an empty list after `timeout`.
    public func awaitLicenses(timeout: Double = 20) async throws -> [CMsgClientLicenseList.License] {
        guard case let .loggedOn(anonymous) = state else { throw SteamError.notLoggedOn }
        if !licenses.isEmpty { return licenses }
        let cm = try requireCM()
        let packet: CMPacket
        do {
            packet = try await cm.next(.emsg(EMsg.clientLicenseList.rawValue), timeout: anonymous ? min(timeout, 5) : timeout)
        } catch SteamError.timeout(_) where anonymous {
            return []
        }
        let list = try CMsgClientLicenseList.decode(packet.body)
        guard list.eresult == .ok else { throw SteamError.eresult(list.eresult, context: "ClientLicenseList") }
        licenses = list.licenses
        return licenses
    }

    // MARK: persona

    /// The logged-on account's persona name (the name Steam shows to friends
    /// and games), asked for with ClientRequestFriendData. Not the account
    /// name, which is half the login and never leaves the host.
    public func personaName(timeout: Double) async throws -> String? {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let cm = try requireCM()
        let me = await cm.steamID
        try await cm.send(.clientRequestFriendData,
                          CMsgClientRequestFriendData(personaStateRequested: CMsgClientRequestFriendData.flagPlayerName, friends: [me]))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw SteamError.timeout("persona state") }
            let packet = try await cm.next(.emsg(EMsg.clientPersonaState.rawValue), timeout: left)
            if let f = try CMsgClientPersonaState.decode(packet.body).friends.first(where: { $0.friendID == me }) {
                return f.playerName.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
    }

    // MARK: logout

    /// Revokes the stored refresh token, logs off and deletes the session
    /// secret. It never touches installation or save directories: those are
    /// not reachable from here by construction.
    public func logout(revoke: Bool = true) async throws -> LogoutReport {
        try await transition("logout") {
            var report = LogoutReport(revoked: false, revokeResult: "not attempted", loggedOff: false, credentialsDeleted: false)
            let stored = try storedSession()
            if revoke, let s = stored, let cm {
                let loggedOn = state == .loggedOn(anonymous: false)
                do {
                    _ = try await cm.serviceCall("Authentication.RevokeToken#1",
                                                 TokenRevokeRequest(token: Secret(s.refreshToken)), authed: loggedOn)
                    report.revoked = true
                    report.revokeResult = "OK"
                } catch let SteamError.eresult(r, _) {
                    report.revokeResult = r.name
                } catch {
                    report.revokeResult = "\(error)"
                }
                log.info("auth", "revoke refresh token: \(report.revokeResult)")
            }
            if case .loggedOn = state, let cm {
                try? await cm.send(.clientLogOff, CMsgClientLogOff())
                if let p = try? await cm.next(.emsg(EMsg.clientLoggedOff.rawValue), timeout: 5) {
                    let r = (try? CMsgClientLoggedOff.decode(p.body).eresult.name) ?? "?"
                    log.info("auth", "ClientLoggedOff: \(r)")
                }
                report.loggedOff = true
            }
            if stored != nil {
                try store.delete(SecretKeys.session)
                report.credentialsDeleted = try store.read(SecretKeys.session) == nil
            }
            await disconnect()
            return report
        }
    }
}

extension StoredSession: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "StoredSession(\(Redactor.tag("acct", accountName)), <redacted>)" }
    public var debugDescription: String { description }
}
