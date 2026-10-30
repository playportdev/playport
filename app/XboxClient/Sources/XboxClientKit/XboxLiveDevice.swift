// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f crates/xodus/src/auth.rs (do_sisu,
// get_xsts_token) and Xodus Nexus e0668a12f1da931aed13537ef04295599011317b
// assets/xodus-offline-license.patch (commands/offline_pc.rs: the device, title
// and user claims for `http://mp.microsoft.com/`); translated to Swift by the
// Playport authors, 2026-10-30. The request signature is the format OpenXbox's
// xal-rs signs (Xodus's auth.rs calls it), written from the recorded requests'
// shape (PLA-487: a 76-byte header, policy version 1, a FILETIME, ES256); no xal
// code taken. Modified: injected HTTP and signer; Apple signs with CryptoKit; one
// fresh proof key per chain, as each Xodus CLI run makes one.
import Foundation
import ContentKit
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The ES256 proof key Xbox Live binds a device token to. Every request that
/// presents the token is signed with it.
protocol XboxLiveSigner: Sendable {
    /// The public point's x and y, 32 bytes each.
    var publicKey: (x: [UInt8], y: [UInt8]) { get }
    /// An ECDSA P-256 signature over SHA-256 of `message`: r and s, 32 bytes each.
    func sign(_ message: [UInt8]) throws -> [UInt8]
}

/// A P-256 key that lives for one chain of Xbox Live requests and is never stored.
struct XboxProofKey: XboxLiveSigner {
    #if canImport(CryptoKit)
    private let key = P256.Signing.PrivateKey()
    var publicKey: (x: [UInt8], y: [UInt8]) {
        let raw = Array(key.publicKey.rawRepresentation)
        return (Array(raw[0..<32]), Array(raw[32..<64]))
    }
    func sign(_ message: [UInt8]) throws -> [UInt8] { Array(try key.signature(for: Data(message)).rawRepresentation) }
    init() throws {}
    #else
    // The test host has no P-256; tests sign with a fixed XboxLiveSigner.
    var publicKey: (x: [UInt8], y: [UInt8]) { ([], []) }
    func sign(_ message: [UInt8]) throws -> [UInt8] { [] }
    init() throws { throw ClientError.unsupported("Xbox Live request signing needs CryptoKit") }
    #endif
}

/// Xbox Live's `Signature` header: the signing policy's version (1), the request's
/// time as a Windows FILETIME and the ES256 signature, big-endian, base64. The signed
/// message is the version, the time, the method, the path and query, the
/// Authorization header and the body's first 8 KiB, each followed by a NUL byte.
enum XboxLiveSignature {
    static let version: UInt32 = 1
    static let maxBody = 8192

    static func fileTime(_ date: Date) -> UInt64 {
        UInt64((date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
    }
    static func message(method: String, url: URL, authorization: String, body: [UInt8], time: UInt64) -> [UInt8] {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }
        var out = bigEndian(version) + [0] + bigEndian(time) + [0]
        for part in [Array(method.uppercased().utf8), Array(path.utf8), Array(authorization.utf8), Array(body.prefix(maxBody))] {
            out += part + [0]
        }
        return out
    }
    static func header(_ signer: any XboxLiveSigner, method: String, url: URL, authorization: String = "", body: [UInt8], at date: Date) throws -> String {
        let time = fileTime(date)
        let signature = try signer.sign(message(method: method, url: url, authorization: authorization, body: body, time: time))
        guard signature.count == 64 else { throw ClientError.verificationFailed("Xbox Live request signature has the wrong size") }
        return XboxCrypto.base64(bigEndian(version) + bigEndian(time) + signature)
    }
    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}

/// The device, title and user tokens Xbox Live issues this app's synthetic device and
/// the signed-in account through SISU (Xodus's `do_sisu`), and their XSTS token for one
/// relying party. Each chain uses a fresh proof key.
enum XboxLiveDevice {
    static let deviceAuth = URL(string: "https://device.auth.xboxlive.com/device/authenticate")!
    static let sisu = URL(string: "https://sisu.xboxlive.com/authorize")!
    /// The Xbox app's title (Xodus's `do_sisu` callers pass 704208617 with this client).
    static let userScope = "scope=xboxlive.signin&api-version=2.0&clientid=\(XboxSignIn.clientID)"
    static let clientVersion = "10.0.22621"

    /// `device` is the synthetic device's TOKEN_BROKER ticket for Xbox Live's user.auth
    /// scope; `user` the account's `xboxlive.signin` ticket for the Xbox app's client.
    static func xsts(_ http: any XboxHTTP, signer: any XboxLiveSigner, device: XboxTicket, user: XboxTicket,
                     relyingParty: String, now: Date) async throws -> XboxLive.Token {
        let key = signer.publicKey
        let proof: [String: Any] = ["alg": "ES256", "crv": "P-256", "kty": "EC", "use": "sig",
                                    "x": base64URL(key.x), "y": base64URL(key.y)]
        let deviceBody = try XboxLive.json(["RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT", "Properties": [
            "AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": rps(device.token.value),
            "Version": clientVersion, "ProofKey": proof]])
        let deviceToken = try token(try await signed(http, signer, deviceAuth, deviceBody, contract: true, now: now))
        let sisuBody = try XboxLive.json(["AccessToken": rps(user.token.value), "AppId": XboxSignIn.clientID,
                                          "DeviceToken": deviceToken, "Sandbox": "RETAIL", "SiteName": "user.auth.xboxlive.com",
                                          "ProofKey": proof])
        let (title, userToken) = try titleAndUser(try await signed(http, signer, sisu, sisuBody, contract: false, now: now))
        let xstsBody = try XboxLive.json(["RelyingParty": relyingParty, "TokenType": "JWT", "Properties": [
            "SandboxId": "RETAIL", "DeviceToken": deviceToken, "TitleToken": title, "UserTokens": [userToken]]])
        let response = try await signed(http, signer, XboxLive.xsts, xstsBody, contract: true, now: now)
        guard let reply = try? JSONDecoder().decode(XSTSReply.self, from: Data(response.body.value)),
              let uhs = reply.DisplayClaims.xui.first?.uhs, plain(uhs), plain(reply.Token, dots: true) else { throw unexpected }
        return XboxLive.Token(token: Secret(reply.Token), userHash: Secret(uhs))
    }

    private static func signed(_ http: any XboxHTTP, _ signer: any XboxLiveSigner, _ url: URL, _ body: [UInt8],
                               contract: Bool, now: Date) async throws -> XboxHTTPResponse {
        var headers = ["Content-Type": Secret("application/json"), "Accept": Secret("application/json"),
                       "MS-CV": Secret(XboxCrypto.correlationVector()),
                       "Signature": Secret(try XboxLiveSignature.header(signer, method: "POST", url: url, body: body, at: now))]
        if contract { headers["x-xbl-contract-version"] = Secret("1") }
        let response = try await XboxLive.send(http, XboxHTTPRequest(url: url, headers: headers, body: Secret(body)))
        // 401/403: Xbox Live's verdict on the account or its tickets, as XboxLive.token reads it.
        if response.status == 401 || response.status == 403 { throw XboxSessionError.signInRequired }
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox Live sign-in returned HTTP \(response.status)") }
        return response
    }

    private struct TokenReply: Decodable { let Token: String }
    private struct XSTSReply: Decodable {
        struct Claims: Decodable { struct User: Decodable { let uhs: String }; let xui: [User] }
        let Token: String
        let DisplayClaims: Claims
    }
    private struct SISUReply: Decodable {
        let TitleToken: TokenReply
        let UserToken: TokenReply
    }
    private static func token(_ response: XboxHTTPResponse) throws -> String {
        guard let reply = try? JSONDecoder().decode(TokenReply.self, from: Data(response.body.value)), plain(reply.Token, dots: true) else { throw unexpected }
        return reply.Token
    }
    private static func titleAndUser(_ response: XboxHTTPResponse) throws -> (String, String) {
        guard let reply = try? JSONDecoder().decode(SISUReply.self, from: Data(response.body.value)),
              plain(reply.TitleToken.Token, dots: true), plain(reply.UserToken.Token, dots: true) else { throw unexpected }
        return (reply.TitleToken.Token, reply.UserToken.Token)
    }
    /// A JWT (base64url and dots) or a user hash: nothing that could split a header.
    private static func plain(_ value: String, dots: Bool = false) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || (dots && $0 == UInt8(ascii: "."))
        }
    }
    private static var unexpected: ClientError { .protocolChanged("Xbox Live sign-in returned an unexpected answer") }
    /// Xbox Live takes RPS tickets as `t=<ticket>`, as the recorded requests send them.
    static func rps(_ ticket: String) -> String { ticket.hasPrefix("t=") ? ticket : "t=" + ticket }
    static func base64URL(_ bytes: [UInt8]) -> String {
        String(XboxCrypto.base64(bytes).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").prefix { $0 != "=" })
    }
}
