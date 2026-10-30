// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f tokens/{device,manager}.rs,
// api/live/mod.rs and xodus-cli/commands/login.rs; translated to Swift by the
// Playport authors, 2026-10-30. Modified: injected HTTP and SecretStore, silent
// renewal, sign-out fencing and handlers, bounded replacement on a device-authentication fault.
import Foundation
import ContentKit

public enum XboxSessionState: Sendable { case signedOut, signedIn }
public enum XboxSignInResult: Sendable { case signedIn, continueAt(XboxLoginPage) }
public struct XboxTicket: Sendable {
    public let token: Secret<String>
    public let expiresAt: Date
}

public enum XboxSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case signInRequired
    case deviceRejected
    public var description: String {
        switch self {
        case .signInRequired: "Microsoft couldn't renew your Xbox sign-in. Sign in again in Settings › Accounts › Xbox."
        case .deviceRejected: "Microsoft rejected the Xbox device. Try signing in again."
        }
    }
}

/// The session and the synthetic device are separate Keychain items. The device's
/// membername, password, SPLicenseBlock (private RSA key) and hardware survive
/// sign-out. Every issued ticket/proof and every account identifier is deleted.
public actor XboxSession {
    public static let keychainService = "dev.playport.app.xbox"
    private let store: any SecretStore
    // Internal, not private: XboxLicensing.swift extends the session.
    let http: any XboxHTTP
    let log: Logger
    let now: @Sendable () -> Date
    private(set) var generation: UInt64 = 0
    private var deviceFlight: Task<XboxToken, Error>?
    private var signOutHandlers: [UInt64: @Sendable () -> Void] = [:]
    private var lastSignOutHandler: UInt64 = 0

    public init(store: any SecretStore, http: any XboxHTTP = XboxURLSessionHTTP(), log: Logger = .silent,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.http = http; self.log = log; self.now = now
    }
    public var state: XboxSessionState { (try? read(XboxStoredSession.self, "session")) == nil ? .signedOut : .signedIn }
    /// Synthetic identity, not a phone identifier. Secret-wrapped even in tests;
    /// never expose the registration's Microsoft/account identifiers in logs.
    public var deviceIdentity: Secret<String>? { (try? read(XboxDevice.self, "device"))?.identity.mapSecret }
    /// The account's PUID: licensing's `localTicketReference`. Never logged.
    var ticketReference: String? { get throws { try read(XboxStoredSession.self, "session")?.puid } }

    public func prepareSignIn(market: String = "en-US") async throws -> XboxLoginPage {
        _ = try await deviceToken()
        return XboxSignIn.page(market: market)
    }
    public func signIn(_ token: XboxSignInToken) async throws -> XboxSignInResult {
        let epoch = generation
        let prop: XboxDAProperty
        do { prop = try JSONDecoder().decode(XboxDAProperty.self, from: Data(token.data.value)) }
        catch { throw ClientError.protocolChanged("Microsoft sign-in returned invalid data") }
        guard !prop.sSigninName.isEmpty, !prop.sDAToken.isEmpty, !prop.sSTSInlineFlowToken.isEmpty else { throw XboxXML.invalid() }
        let user = XboxToken(legacy: true, value: prop.sDAToken, proof: nil, scope: XboxSOAP.sts, expires: try XboxSOAP.date(prop.sDAExpires))
        let device = try await deviceToken()
        try check(epoch)
        let body = try XboxSOAP.request(now: now(), device: device, user: user, username: prop.sSigninName,
            app: XboxSignIn.clientID, scopes: [(XboxSOAP.userScope, "TOKEN_BROKER"), (XboxSOAP.tb, nil)], inline: prop.sSTSInlineFlowToken)
        let reply = try XboxSOAP.reply(await send(XboxSOAP.endpoint, body: body, epoch: epoch), device: device)
        if reply.fault {
            if let url = reply.inlineURL { return .continueAt(try XboxSignIn.continuation(url)) }
            throw XboxSessionError.signInRequired
        }
        guard reply.tokens.filter({ $0.legacy && $0.scope == XboxSOAP.sts }).count == 1,
              reply.tokens.contains(where: { !$0.legacy && $0.scope == XboxSOAP.userScope }) else { throw XboxXML.invalid() }
        try write(XboxStoredSession(username: prop.sSigninName, puid: prop.K, tokens: reply.tokens), "session")
        log.info("xbox", "signed in")
        return .signedIn
    }
    /// Force a silent exchange. Only a definitive authentication refusal deletes
    /// the session. Network/service/schema errors leave it available for a retry.
    @discardableResult public func renew() async throws -> XboxTicket {
        try await userTicket(scope: XboxSOAP.userScope, clientID: XboxSignIn.clientID, force: true)
    }
    public func userTicket(scope: String = "scope=service::user.auth.xboxlive.com::MBI_SSL&api-version=2.0",
                           clientID: String = XboxSignIn.clientID) async throws -> XboxTicket {
        try await userTicket(scope: scope, clientID: clientID, force: false)
    }
    /// The Microsoft Store's own ticket (`www.microsoft.com`, MBI_SSL, the Store
    /// app's client ID), exchanged silently as Xodus Nexus's `store_session` does.
    /// PCGAFD entitlements take it as the raw `Authorization` value. A refusal asks
    /// for sign-in but keeps the session: it is not the platform ticket's verdict.
    public func storeTicket() async throws -> XboxTicket {
        let epoch = generation
        guard let session = try read(XboxStoredSession.self, "session"),
              let user = session.tokens.first(where: { $0.legacy && $0.scope == XboxSOAP.sts }) else { throw XboxSessionError.signInRequired }
        if let cached = session.tokens.first(where: { !$0.legacy && $0.scope == Self.storeScope && $0.expires > now().addingTimeInterval(60) }) {
            return XboxTicket(token: Secret(cached.value), expiresAt: cached.expires)
        }
        let device = try await deviceToken()
        try check(epoch)
        let request = try XboxSOAP.request(now: now(), device: device, user: user, username: session.username,
            app: Self.storeApp, scopes: [(Self.storeScope, "mbi_ssl")], silent: true)
        let reply = try XboxSOAP.reply(await send(XboxSOAP.endpoint, body: request, epoch: epoch), device: device)
        guard !reply.fault else { throw XboxSessionError.signInRequired }
        let tickets = reply.tokens.filter { !$0.legacy && $0.scope == Self.storeScope }
        guard tickets.count == 1, tickets[0].value.hasPrefix("t="), tickets[0].value.contains("&p=") else { throw XboxXML.invalid() }
        guard var current = try read(XboxStoredSession.self, "session") else { throw XboxSessionError.signInRequired }
        current.tokens.removeAll { !$0.legacy && $0.scope == Self.storeScope }; current.tokens.append(tickets[0])
        try write(current, "session")
        return XboxTicket(token: Secret(tickets[0].value), expiresAt: tickets[0].expires)
    }
    static let storeScope = "www.microsoft.com"
    static let storeApp = "{d6d5a677-0872-4ab0-9442-bb792fce85c5}"
    private func userTicket(scope: String, clientID: String, force: Bool) async throws -> XboxTicket {
        let epoch = generation
        guard var session = try read(XboxStoredSession.self, "session"),
              let user = session.tokens.first(where: { $0.legacy && $0.scope == XboxSOAP.sts }) else { throw XboxSessionError.signInRequired }
        // Per-client tickets are not reused for another game's client ID.
        if !force, clientID == XboxSignIn.clientID, let cached = session.tokens.first(where: { !$0.legacy && $0.scope == scope && $0.expires > now().addingTimeInterval(60) }) {
            return XboxTicket(token: Secret(cached.value), expiresAt: cached.expires)
        }
        let device = try await deviceToken()
        try check(epoch)
        let request = try XboxSOAP.request(now: now(), device: device, user: user, username: session.username,
            app: clientID, scopes: [(scope, "TOKEN_BROKER"), (XboxSOAP.tb, nil)], silent: true)
        let reply = try XboxSOAP.reply(await send(XboxSOAP.endpoint, body: request, epoch: epoch), device: device)
        if reply.fault {
            try clearSession()
            log.info("xbox", "sign-in required")
            throw XboxSessionError.signInRequired
        }
        guard let ticket = reply.tokens.first(where: { !$0.legacy && $0.scope == scope }),
              reply.tokens.filter({ !$0.legacy && $0.scope == scope }).count == 1 else { throw XboxXML.invalid() }
        if let refreshed = reply.tokens.first(where: { $0.legacy && $0.scope == XboxSOAP.sts }) {
            session.tokens.removeAll { $0.legacy && $0.scope == XboxSOAP.sts }; session.tokens.append(refreshed)
        }
        if clientID == XboxSignIn.clientID {
            session.tokens.removeAll { !$0.legacy && $0.scope == scope }; session.tokens.append(ticket)
        }
        try write(session, "session")
        log.info("xbox", "session renewed silently")
        return XboxTicket(token: Secret(ticket.value), expiresAt: ticket.expires)
    }
    /// `policy` is the RST PolicyReference: content licensing asks for `www.microsoft.com`
    /// under the Store app with `mbi_ssl`, as Xodus's exchange_device_token does.
    public func deviceTicket(scope: String = "scope=service::user.auth.xboxlive.com::MBI_SSL&api-version=2.0",
                             clientID: String = "{28C08266-F973-4AE6-FFE4-409B249F138F}",
                             policy: String = "TOKEN_BROKER") async throws -> XboxTicket {
        guard state == .signedIn else { throw XboxSessionError.signInRequired }
        let epoch = generation, device = try await deviceToken()
        let request = try XboxSOAP.request(now: now(), device: device, username: "", app: clientID, scopes: [(scope, policy)])
        let reply = try XboxSOAP.reply(await send(XboxSOAP.endpoint, body: request, epoch: epoch), device: device)
        guard !reply.fault else { throw XboxSessionError.deviceRejected }
        guard reply.tokens.count == 1, let token = reply.tokens.first, !token.legacy else { throw XboxXML.invalid() }
        return XboxTicket(token: Secret(token.value), expiresAt: token.expires)
    }
    public func signOut() throws {
        generation &+= 1; deviceFlight?.cancel(); deviceFlight = nil
        for action in signOutHandlers.values { action() }
        try clearSession()
        log.info("xbox", "signed out; session secrets deleted, synthetic device kept")
    }
    /// Runs `action` at each sign-out (and device reset), before the session's
    /// secrets are deleted: a play's bridge closes its channel with it (0167).
    public func onSignOut(_ action: @escaping @Sendable () -> Void) -> UInt64 {
        lastSignOutHandler &+= 1
        signOutHandlers[lastSignOutHandler] = action
        return lastSignOutHandler
    }
    public func removeSignOutHandler(_ id: UInt64) { signOutHandlers[id] = nil }
    /// Dev UI only. Reset does not unlink the old device at Microsoft; it counts
    /// toward the Store's limit until the player removes it there.
    public func resetDevice() throws {
        try signOut()
        try store.delete("device")
        try write(XboxDevice.make(), "device")
        log.info("xbox", "synthetic device reset")
    }
    private func clearSession() throws {
        // All issued/user secrets live in these items: tickets, account information and
        // licences' content keys. Never the persistent device item.
        var failure: Error?
        for key in ["session", "device-token", "licences"] { do { try store.delete(key) } catch { failure = error } }
        if failure != nil { throw ClientError.credentialStore("Xbox session could not be deleted") }
    }
    private func deviceToken() async throws -> XboxToken {
        if let token = try read(XboxToken.self, "device-token"), token.expires > now().addingTimeInterval(60) { return token }
        if let task = deviceFlight { return try await task.value }
        let epoch = generation
        let task = Task { try await self.authenticateDevice(epoch: epoch) }
        deviceFlight = task
        defer { if generation == epoch { deviceFlight = nil } }
        return try await task.value
    }
    private func authenticateDevice(epoch: UInt64) async throws -> XboxToken {
        var device = try read(XboxDevice.self, "device") ?? XboxDevice.make()
        try write(device, "device")
        // One rejection-driven replacement, never for an HTTP/service/parse error.
        for attempt in 0..<2 {
            if device.registration == nil {
                let body = try await send(URL(string: "https://login.live.com/ppsecure/deviceaddcredential.srf")!, body: device.request(), epoch: epoch)
                device.registration = try XboxDeviceRegistration(body)
                try write(device, "device")
                log.info("xbox", "synthetic device registered")
            }
            let privateKey = try XboxRSA(XboxCrypto.privateKey(device.registration!.license))
            let body = try XboxSOAP.request(now: now(), username: device.username, scopes: [(XboxSOAP.tb, nil)], privateKey: privateKey)
            let reply = try XboxSOAP.reply(await send(XboxSOAP.endpoint, body: body, epoch: epoch))
            if reply.fault {
                guard attempt == 0 else { throw XboxSessionError.deviceRejected }
                device = XboxDevice.make(); try write(device, "device")
                log.info("xbox", "Microsoft rejected the synthetic device; replacing it")
                continue
            }
            guard reply.tokens.count == 1, let token = reply.tokens.first, token.legacy, token.scope == XboxSOAP.sts,
                  let proof = token.proof else { throw XboxXML.invalid() }
            _ = try XboxCrypto.clep(XboxCrypto.decode(proof), keyBytes: 48)
            try write(token, "device-token")
            return token
        }
        throw XboxSessionError.deviceRejected
    }
    private func send(_ url: URL, body: [UInt8], epoch: UInt64) async throws -> [UInt8] {
        try check(epoch)
        let response: XboxHTTPResponse
        do { response = try await http.send(XboxHTTPRequest(url: url,
            headers: ["User-Agent": Secret(XboxSOAP.userAgent), "Content-Type": Secret("application/soap+xml")], body: Secret(body))) }
        catch is CancellationError { throw ClientError.cancelled }
        catch { throw ClientError.transport("Xbox request failed; check your connection") }
        try check(epoch)
        guard response.body.value.count <= 1024 * 1024 else { throw XboxXML.invalid() }
        // SOAP faults use HTTP 500 as well as 200; classify a real Envelope, not
        // arbitrary provider error text. Service 5xx must not replace the device.
        if response.status == 500, let xml = try? XboxXML.parse(response.body.value), xml.child("Body")?.child("Fault") != nil {
            return response.body.value
        }
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox service returned HTTP \(response.status)") }
        return response.body.value
    }
    func check(_ epoch: UInt64) throws { if generation != epoch || Task.isCancelled { throw ClientError.cancelled } }
    func read<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        do {
            guard let bytes = try store.read(key) else { return nil }
            return try JSONDecoder().decode(type, from: Data(bytes.value))
        } catch { throw ClientError.credentialStore("Xbox credentials could not be read") }
    }
    func write<T: Encodable>(_ value: T, _ key: String) throws {
        do { try store.write(key, Secret(Array(JSONEncoder().encode(value)))) }
        catch { throw ClientError.credentialStore("Xbox credentials could not be saved") }
    }
}

private struct XboxStoredSession: Codable {
    let username: String
    let puid: String
    var tokens: [XboxToken]
}
private extension String { var mapSecret: Secret<String> { Secret(self) } }
