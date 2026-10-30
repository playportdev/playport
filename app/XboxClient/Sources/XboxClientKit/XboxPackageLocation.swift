// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/xodus/src/api/xbox/{mod,auth}.rs
// (user.auth, XSTS) and crates/xodus-cli/src/{package.rs,commands/streaming.rs}
// (GetBasePackage, the first .msixvc file); translated to Swift by the Playport
// authors, 2026-10-30. Modified: injected transport; Microsoft's "no package for
// this account" is its own typed error; only xboxlive.com CDN roots are used; with
// no .msixvc file, the first .msixvc2 (Xodus pull request #219, e8194a8).
import Foundation
import ContentKit

/// Where a copy's package is: its CDN URLs and size, as `packagespc.xboxlive.com`
/// names them for the signed-in account.
public struct XboxPackageLocation: Sendable, Equatable {
    /// The package's content ID (MSIXVC: the XVD's VDUID; licensing asks for the same GUID).
    public let contentID: String
    public let version: String
    public let fileName: String
    public let size: UInt64
    /// Every CDN root's URL for the file, in Microsoft's order.
    public let urls: [URL]
    /// An MSIXVC2 package (a ZIP), not an MSIXVC (an XVD).
    public var isMSIXVC2: Bool { fileName.lowercased().hasSuffix(".msixvc2") }
}

/// Why an install stopped before any download: Microsoft has no package for the
/// account (no entitlement), or refused the licence. Each has its own message.
public enum XboxInstallRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    case notEntitled
    case licence(XboxLicenceFailure)
    case noPackage
    public var description: String {
        switch self {
        case .notEntitled:
            "Microsoft didn't give this account a download for this game. Check that you own it or that your PC Game Pass is active, then try again."
        case .licence(let failure): failure.description
        case .noPackage: "Microsoft lists no Windows package for this game that Playport can install."
        }
    }
}

/// The calls an install makes to Microsoft for a signed-in account (XboxSession).
public protocol XboxInstallServices: Sendable {
    func packageLocation(contentID: String) async throws -> XboxPackageLocation
    func licence(contentID: String, market: String) async throws -> XboxLicenceResult
}

extension XboxSession: XboxInstallServices {
    /// GetBasePackage for the content ID, with an XSTS token for `http://update.xboxlive.com`
    /// from the account's RPS ticket (Xodus's `api::xbox::run`). Throws
    /// `XboxInstallRefusal.notEntitled` when Microsoft has no package for the account.
    public func packageLocation(contentID: String) async throws -> XboxPackageLocation {
        guard let id = UUID(uuidString: contentID) else { throw ClientError.unsupported("Xbox content ID is not a GUID") }
        let content = id.uuidString.lowercased()
        let epoch = generation
        let rps = try await storeTicket(scope: "user.auth.xboxlive.com")
        try check(epoch)
        let user = try await XboxLive.token(http, url: XboxLive.userAuth, body: XboxLive.userBody(rps.token.value))
        try check(epoch)
        let xsts = try await XboxLive.token(http, url: XboxLive.xsts, body: XboxLive.xstsBody(user.token.value, party: "http://update.xboxlive.com"))
        try check(epoch)
        let request = XboxHTTPRequest(url: URL(string: "https://packagespc.xboxlive.com/GetBasePackage/\(content)")!, method: "GET",
                                      headers: ["x-xbl-contract-version": Secret("3"), "Accept": Secret("application/json"),
                                                "Authorization": Secret("XBL3.0 x=\(xsts.userHash.value);\(xsts.token.value)")],
                                      body: Secret([]))
        let response = try await XboxLive.send(http, request)
        try check(epoch)
        let location = try XboxLive.location(response, content: content)
        log.info("xbox", "package found: \(location.size) bytes on \(location.urls.count) CDN roots")
        return location
    }
}

enum XboxLive {
    static let userAuth = URL(string: "https://user.auth.xboxlive.com/user/authenticate")!
    static let xsts = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!

    struct Token { let token: Secret<String>; let userHash: Secret<String> }

    static func userBody(_ rps: String) throws -> [UInt8] {
        try json(["RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT",
                  "Properties": ["AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": rps]])
    }
    static func xstsBody(_ user: String, party: String) throws -> [UInt8] {
        try json(["RelyingParty": party, "TokenType": "JWT", "Properties": ["UserTokens": [user], "SandboxId": "RETAIL"]])
    }
    static func json(_ value: [String: Any]) throws -> [UInt8] {
        Array(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }

    static func token(_ http: any XboxHTTP, url: URL, body: [UInt8]) async throws -> Token {
        let response = try await send(http, XboxHTTPRequest(url: url, headers: [
            "Content-Type": Secret("application/json"), "Accept": Secret("application/json"), "x-xbl-contract-version": Secret("1")],
            body: Secret(body)))
        // 401 is Xbox Live's verdict on the account (no Xbox profile, child account, banned); not the device's.
        if response.status == 401 || response.status == 403 { throw XboxSessionError.signInRequired }
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox Live sign-in returned HTTP \(response.status)") }
        struct Reply: Decodable {
            struct Claims: Decodable { struct User: Decodable { let uhs: String }; let xui: [User] }
            let Token: String
            let DisplayClaims: Claims
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(response.body.value)), !reply.Token.isEmpty,
              let uhs = reply.DisplayClaims.xui.first?.uhs, !uhs.isEmpty,
              uhs.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }),
              !reply.Token.contains(where: { $0 == ";" || $0 == "\r" || $0 == "\n" }) else {
            throw ClientError.protocolChanged("Xbox Live sign-in returned an unexpected answer")
        }
        return Token(token: Secret(reply.Token), userHash: Secret(uhs))
    }

    static func send(_ http: any XboxHTTP, _ request: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        do { return try await http.send(request) }
        catch let error as ClientError { throw error }
        catch is CancellationError { throw ClientError.cancelled }
        catch { throw ClientError.transport("Xbox request failed; check your connection") }
    }

    /// The first `.msixvc` file of the base package (Xodus's choice), else its first
    /// `.msixvc2` (Xodus pull request #219), every CDN root's URL for it.
    static func location(_ response: XboxHTTPResponse, content: String) throws -> XboxPackageLocation {
        if response.status == 401 { throw XboxSessionError.signInRequired }
        if response.status == 403 || response.status == 404 { throw XboxInstallRefusal.notEntitled }
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox packages returned HTTP \(response.status)") }
        struct Reply: Decodable {
            struct File: Decodable {
                let FileName: String; let FileSize: UInt64; let RelativeUrl: String; let CdnRootPaths: [String]?; let ContentId: String?
            }
            let PackageFound: Bool
            let ContentId: String?
            let VersionId: String?
            let PackageFiles: [File]?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(response.body.value)) else {
            throw ClientError.protocolChanged("Xbox packages returned an unexpected answer")
        }
        guard reply.PackageFound else { throw XboxInstallRefusal.notEntitled }
        guard reply.ContentId?.lowercased() == content else { throw ClientError.protocolChanged("Xbox packages answered for another content ID") }
        let files = reply.PackageFiles ?? []
        guard let file = files.first(where: { $0.FileName.lowercased().hasSuffix(".msixvc") })
                ?? files.first(where: { $0.FileName.lowercased().hasSuffix(".msixvc2") }) else {
            throw XboxInstallRefusal.noPackage
        }
        let relative = file.RelativeUrl
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains(".."), !relative.contains("?"), !relative.contains("#"),
              !relative.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7E }) else {
            throw ClientError.protocolChanged("Xbox packages returned an unexpected file path")
        }
        let urls = (file.CdnRootPaths ?? []).compactMap { root -> URL? in
            guard let base = URL(string: root), base.scheme == "http" || base.scheme == "https", base.user == nil, base.port == nil,
                  let host = base.host?.lowercased(), host.hasSuffix(".xboxlive.com"), root.hasSuffix("/") else { return nil }
            return URL(string: root + relative)
        }
        guard !urls.isEmpty else { throw ClientError.protocolChanged("Xbox packages named no usable CDN") }
        let version = String((reply.VersionId ?? "").split(separator: ".").prefix(4).joined(separator: "."))
        return XboxPackageLocation(contentID: content, version: version, fileName: file.FileName, size: file.FileSize, urls: urls)
    }
}
