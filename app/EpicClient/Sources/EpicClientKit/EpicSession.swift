// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContentKit

/// Epic's endpoints and its launcher's public identity (decision 0058), as the
/// spike measured them (plan 3.1).
public enum EpicAPI {
    public static let clientID = "34a02cf8f4414e29b15921876da36f9a"
    static let clientSecret = Secret("daafbccc737745039dffe53d94fc76cf")
    static let account = "https://account-public-service-prod03.ol.epicgames.com"
    static let ecommerce = "https://ecommerceintegration-public-service-ecomprod02.ol.epicgames.com"
    /// What the launcher sends: Epic's services expect a launcher-shaped agent.
    public static let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"

    /// The page that answers with the code (JSON) once the player is signed in.
    public static var redirectURL: URL {
        var c = URLComponents(string: "https://www.epicgames.com/id/api/redirect")!
        c.queryItems = [.init(name: "clientId", value: clientID), .init(name: "responseType", value: "code")]
        return c.url!
    }

    /// The page the sign-in sheet opens: Epic's login, which goes on to `redirectURL`.
    public static var loginURL: URL {
        var c = URLComponents(string: "https://www.epicgames.com/id/login")!
        c.queryItems = [.init(name: "redirectUrl", value: redirectURL.absoluteString)]
        return c.url!
    }

    /// Whether `url` is the redirect page, whose body `redirectPage` reads.
    public static func isRedirect(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "www.epicgames.com" && url.path == "/id/api/redirect"
    }

    public enum RedirectPage: Sendable, Equatable {
        case code(Secret<String>)
        /// Epic wants the player to do something on its site first (seen: accept the
        /// privacy policy, PRIVACY_POLICY_ACCEPTANCE).
        case correctiveAction(String)
        /// Not signed in yet, or a page of no known shape.
        case none
    }

    /// The redirect page's JSON: `authorizationCode` (or the code in its
    /// `redirectUrl`), or Epic's corrective-action error.
    public static func redirectPage(_ body: [UInt8]) -> RedirectPage {
        guard let o = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { return .none }
        if let code = o["authorizationCode"] as? String, isCode(code) { return .code(Secret(code)) }
        if let r = o["redirectUrl"] as? String, let u = URLComponents(string: r), u.host == "localhost",
           let code = u.queryItems?.first(where: { $0.name == "code" })?.value, isCode(code) {
            return .code(Secret(code))
        }
        if (o["errorCode"] as? String) == "errors.com.epicgames.oauth.corrective_action_required" {
            return .correctiveAction((o["metadata"] as? [String: Any])?["correctiveAction"] as? String ?? "unknown")
        }
        return .none
    }

    static func isCode(_ s: String) -> Bool { s.count == 32 && s.allSatisfy(\.isHexDigit) }
}

extension EpicAPI.RedirectPage {
    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case let (.code(x), .code(y)): x.value == y.value
        case let (.correctiveAction(x), .correctiveAction(y)): x == y
        case (.none, .none): true
        default: false
        }
    }
}

/// What a session keeps in the Keychain (one item, JSON): never logged.
struct EpicTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var refreshExpiresAt: Date
    /// The account's ID and display name, from the token reply (a session kept
    /// before step 1 of the store game sign-in plan has neither until it refreshes
    /// or `account()` asks Epic).
    var accountID: String?
    var displayName: String?
}

/// Who is signed in, for a game's launch arguments (decision 0059): never logged.
public struct EpicAccountIdentity: Sendable {
    public var accountID: Secret<String>
    public var displayName: Secret<String>
}

/// The Epic sign-in: the redirect page's code traded for `eg1` tokens, refreshed
/// before they expire, kept only in the store (the Keychain on the phone, under
/// its own service name; decision 0058). Sign-out kills the session at Epic, then
/// deletes the item.
public actor EpicSession {
    public static let keychainService = "dev.playport.app.epic"
    static let key = "session"

    public enum State: Sendable, Equatable { case signedOut, signedIn }

    let store: any SecretStore
    let http: HTTPClient
    let log: Logger
    private var tokens: EpicTokens?
    private var loaded = false
    /// The clock; tests move it.
    var now: @Sendable () -> Date = { Date() }

    public init(store: any SecretStore, log: Logger) {
        self.store = store
        self.log = log
        http = HTTPClient(log: log, userAgent: EpicAPI.userAgent)
    }

    public var state: State {
        loadIfNeeded()
        return tokens == nil ? .signedOut : .signedIn
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let raw = try? store.read(Self.key), let t = try? JSONDecoder.epic.decode(EpicTokens.self, from: Data(raw.value)) {
            tokens = t.refreshExpiresAt > now() ? t : nil
        }
    }

    /// Trades the redirect page's code for tokens and keeps them.
    public func signIn(code: Secret<String>) async throws {
        try keep(try await fetch(["grant_type": "authorization_code", "code": code.value], label: "Epic sign-in"))
        log.info("epic", "signed in")
    }

    /// A valid access token, refreshed first when it has under five minutes left.
    public func accessToken() async throws -> Secret<String> {
        loadIfNeeded()
        guard var t = tokens else { throw ClientError.notLoggedOn }
        if t.expiresAt.timeIntervalSince(now()) < 300 {
            do {
                let old = t
                t = try await fetch(["grant_type": "refresh_token", "refresh_token": t.refreshToken], label: "Epic token refresh")
                t.accountID = t.accountID ?? old.accountID
                t.displayName = t.displayName ?? old.displayName
            } catch let ClientError.eresult(.accessDenied, context) {
                log.warn("epic", "refresh refused (\(context)): signed out")
                forget()
                throw ClientError.notLoggedOn
            }
            try keep(t)
            log.info("epic", "token refreshed")
        }
        return Secret(t.accessToken)
    }

    // MARK: a game's sign-in (decision 0059)

    /// The account's ID and display name: from the kept tokens, else Epic's verify call (then kept).
    public func account() async throws -> EpicAccountIdentity {
        let token = try await accessToken()
        guard var t = tokens else { throw ClientError.notLoggedOn }
        if t.accountID == nil || t.displayName == nil {
            let url = URL(string: EpicAPI.account + "/account/api/oauth/verify")!
            let body = try await launchHTTP.get(url, headers: ["Authorization": Secret("bearer " + token.value)],
                                                maxBytes: 1 << 16, label: "Epic account")
            let who = try Self.parseVerify(body)
            t.accountID = who.accountID.value
            t.displayName = who.displayName.value
            try keep(t)
        }
        return EpicAccountIdentity(accountID: Secret(t.accountID ?? ""), displayName: Secret(t.displayName ?? ""))
    }

    static func parseVerify(_ reply: [UInt8]) throws -> EpicAccountIdentity {
        struct Reply: Decodable { var account_id: String; var displayName: String? }
        guard let r = try? JSONDecoder().decode(Reply.self, from: Data(reply)), isCode(r.account_id) else {
            throw ClientError.protocolChanged("Epic account: unexpected reply")
        }
        return EpicAccountIdentity(accountID: Secret(r.account_id), displayName: Secret(r.displayName ?? ""))
    }

    /// A one-time exchange code for a game's launch (`-AUTH_PASSWORD=`): any Epic client can
    /// trade it for a session on the account within its five minutes, so it is fetched right
    /// after Play and given only to the game's command line.
    public func exchangeCode() async throws -> Secret<String> {
        let token = try await accessToken()
        let url = URL(string: EpicAPI.account + "/account/api/oauth/exchange")!
        let body = try await launchHTTP.get(url, headers: ["Authorization": Secret("bearer " + token.value)],
                                            maxBytes: 1 << 16, label: "Epic exchange code")
        return try Self.parseExchange(body)
    }

    static func parseExchange(_ reply: [UInt8]) throws -> Secret<String> {
        struct Reply: Decodable { var code: String }
        guard let r = try? JSONDecoder().decode(Reply.self, from: Data(reply)), isCode(r.code) else {
            throw ClientError.protocolChanged("Epic exchange code: unexpected reply")
        }
        return Secret(r.code)
    }

    /// The ownership token of one catalogue item, for a game whose catalogue sets
    /// `OwnershipToken` (`-epicovt=` names a file holding it).
    public func ownershipToken(namespace: String, catalogItem: String) async throws -> Secret<String> {
        let who = try await account()
        let token = try await accessToken()
        guard Self.isCode(who.accountID.value), Self.isName(namespace), Self.isName(catalogItem),
              let url = URL(string: EpicAPI.ecommerce + "/ecommerceintegration/api/public/platforms/EPIC/identities/"
                            + who.accountID.value + "/ownershipToken") else {
            throw ClientError.protocolChanged("Epic ownership token: an unexpected account, namespace or item")
        }
        let form = "nsCatalogItemId=" + Self.formEscape(namespace + ":" + catalogItem)
        let body = try await launchHTTP.send(url, method: "POST",
                                             headers: ["Authorization": Secret("bearer " + token.value),
                                                       "Content-Type": Secret("application/x-www-form-urlencoded")],
                                             body: Secret(Array(form.utf8)), maxBytes: 1 << 16, label: "Epic ownership token")
        return try Self.parseOwnershipToken(body)
    }

    static func parseOwnershipToken(_ reply: [UInt8]) throws -> Secret<String> {
        struct Reply: Decodable { var token: String }
        guard let r = try? JSONDecoder().decode(Reply.self, from: Data(reply)), !r.token.isEmpty, r.token.utf8.count <= 1 << 14,
              r.token.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw ClientError.protocolChanged("Epic ownership token: unexpected reply")
        }
        return Secret(r.token)
    }

    static func isCode(_ s: String) -> Bool { EpicAPI.isCode(s) }
    static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A Play waits for these calls: a short timeout and one retry, not the installer's patience.
    private var launchHTTP: HTTPClient {
        var h = http
        h.timeout = 10
        h.maxAttempts = 2
        return h
    }

    /// Ends the session at Epic (best effort: offline, the item still goes), then deletes it.
    public func signOut() async {
        loadIfNeeded()
        if let t = tokens, t.expiresAt > now(), let url = URL(string: EpicAPI.account + "/account/api/oauth/sessions/kill/" + t.accessToken) {
            do {
                _ = try await http.send(url, method: "DELETE", headers: ["Authorization": Secret("bearer " + t.accessToken)],
                                        maxBytes: 1 << 16, label: "Epic sign-out")
                log.info("epic", "session ended at Epic")
            } catch {
                log.warn("epic", "Epic did not end the session (\(error)); the kept token is deleted anyway")
            }
        }
        forget()
    }

    private func forget() {
        try? store.delete(Self.key)
        tokens = nil
        loaded = true
    }

    private func fetch(_ form: [String: String], label: String) async throws -> EpicTokens {
        let url = URL(string: EpicAPI.account + "/account/api/oauth/token")!
        let body = (form.merging(["token_type": "eg1"]) { a, _ in a }).sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.formEscape($0.value))" }.joined(separator: "&")
        let basic = Data("\(EpicAPI.clientID):\(EpicAPI.clientSecret.value)".utf8).base64EncodedString()
        let reply = try await http.send(url, method: "POST",
                                        headers: ["Authorization": Secret("basic " + basic),
                                                  "Content-Type": Secret("application/x-www-form-urlencoded")],
                                        body: Secret(Array(body.utf8)), maxBytes: 1 << 16, label: label)
        return try Self.parseTokens(reply, now: now())
    }

    static func parseTokens(_ reply: [UInt8], now: Date) throws -> EpicTokens {
        struct Reply: Decodable {
            var access_token: String
            var refresh_token: String
            var expires_in: Double?
            var refresh_expires: Double?
            var account_id: String?
            var displayName: String?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: Data(reply)) else {
            throw ClientError.protocolChanged("Epic token: unexpected reply")
        }
        return EpicTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                          expiresAt: now.addingTimeInterval(r.expires_in ?? 7200),
                          refreshExpiresAt: now.addingTimeInterval(r.refresh_expires ?? 86_400 * 30),
                          accountID: r.account_id, displayName: r.displayName)
    }

    static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func keep(_ t: EpicTokens) throws {
        try store.write(Self.key, Secret([UInt8](try JSONEncoder.epic.encode(t))))
        tokens = t
        loaded = true
    }

    /// A GET with the session's token.
    func authorized(_ url: URL, maxBytes: Int, label: String) async throws -> [UInt8] {
        let token = try await accessToken()
        return try await http.get(url, headers: ["Authorization": Secret("bearer " + token.value)], maxBytes: maxBytes, label: label)
    }

    /// A GET without the token (the CDN).
    func plain(_ url: URL, maxBytes: Int, label: String) async throws -> [UInt8] {
        try await http.get(url, maxBytes: maxBytes, label: label)
    }
}

extension JSONDecoder {
    static let epic: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let epic: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
