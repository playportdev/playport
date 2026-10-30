// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

extension XboxFixtureHTTP {
    func reply(_ operation: String, body: [UInt8]) { replies[operation, default: []].append(XboxHTTPResponse(status: 200, body: body)) }
}

/// Xbox Live's user.auth, XSTS and packagespc answer from queues (synthetic bodies in
/// the recorded shapes of PLA-487 captures 12, 15 and 22); the broker is XboxFixtureHTTP.
actor XboxPackagesHTTP: XboxHTTP {
    let tickets = XboxFixtureHTTP()
    var replies: [String: [XboxHTTPResponse]] = [:]
    var requests: [XboxHTTPRequest] = []
    func answer(_ host: String, status: Int = 200, _ body: String) { replies[host, default: []].append(XboxHTTPResponse(status: status, body: Array(body.utf8))) }
    func send(_ request: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        guard let host = request.url.host, host.hasSuffix("xboxlive.com") else { return try await tickets.send(request) }
        requests.append(request)
        guard var queue = replies[host], !queue.isEmpty else { throw ClientError.transport("no fixture") }
        let r = queue.removeFirst(); replies[host] = queue
        return r
    }
}

final class XboxPackageLocationTests: XCTestCase, @unchecked Sendable {
    let date = Date(timeIntervalSince1970: 1_793_318_400)
    static let content = "31f3afa5-02a7-4cd9-ac6e-4f4be4604ab8"
    // A made-up user hash shorter than a real one, so the secret scan never matches it.
    static let user = #"{"IssueInstant":"2026-10-30T11:40:24Z","NotAfter":"2026-11-03T11:40:24Z","Token":"synthetic-user-jwt","DisplayClaims":{"xui":[{"uhs":"uhs4321"}]}}"#
    static let xsts = #"{"IssueInstant":"2026-10-30T11:40:24Z","NotAfter":"2026-10-31T03:40:24Z","Token":"synthetic-xsts-jwt","DisplayClaims":{"xui":[{"uhs":"uhs4321"}]}}"#
    static func packages(found: Bool = true, file: String = "TeamCherry.15373CD61C66B_1.5.12620.0_x64__y4jvztpgccj42.msixvc") -> String {
        """
        {"PackageFound":\(found),"ContentId":"\(content)","VersionId":"1.5.12620.0.0a1b2c3d-0000-4000-8000-000000000001","PackageFiles":[
         {"ContentId":"\(content)","FileName":"update-1.5.12396.0.0a1b2c3d-0000-4000-8000-000000000002.xsp","FileSize":83648,"FileHash":"",
          "CdnRootPaths":["http://assets1.xboxlive.com/12/0a1b2c3d-0000-4000-8000-000000000003/"],"RelativeUrl":"\(content)/x.xsp"},
         {"ContentId":"\(content)","FileName":"\(file)","FileSize":5281849344,"FileHash":"",
          "CdnRootPaths":["http://assets1.xboxlive.com/12/0a1b2c3d-0000-4000-8000-000000000003/","http://assets2.xboxlive.com/12/0a1b2c3d-0000-4000-8000-000000000003/","http://evil.example.com/"],
          "RelativeUrl":"\(content)/1.5.12620.0.0a1b2c3d-0000-4000-8000-000000000001/\(file)"}]}
        """
    }

    func signedIn() async throws -> (XboxSession, XboxPackagesHTTP, XboxLines) {
        let http = XboxPackagesHTTP(), lines = XboxLines()
        let session = XboxSession(store: MemorySecretStore(), http: http, log: lines.logger, now: { [date] in date })
        _ = try await session.prepareSignIn()
        _ = try await session.signIn(xboxSignInToken())
        let ticket = String(decoding: try xboxFixture("store-ticket.xml"), as: UTF8.self)
            .replacingOccurrences(of: "www.microsoft.com", with: "user.auth.xboxlive.com")
        await http.tickets.reply("renew", body: Array(ticket.utf8))
        return (session, http, lines)
    }

    /// Xodus's chain: an RPS ticket for user.auth, an XSTS token for update.xboxlive.com,
    /// then GetBasePackage; the first .msixvc's xboxlive.com CDN URLs.
    func testThePackageIsFoundThroughXboxLiveForTheAccount() async throws {
        let (session, http, lines) = try await signedIn()
        await http.answer("user.auth.xboxlive.com", Self.user)
        await http.answer("xsts.auth.xboxlive.com", Self.xsts)
        await http.answer("packagespc.xboxlive.com", Self.packages())
        let location = try await session.packageLocation(contentID: Self.content.uppercased())
        XCTAssertEqual(location.size, 5_281_849_344)
        XCTAssertEqual(location.version, "1.5.12620.0")
        XCTAssertEqual(location.fileName, "TeamCherry.15373CD61C66B_1.5.12620.0_x64__y4jvztpgccj42.msixvc")
        XCTAssertEqual(location.urls.map(\.host), ["assets1.xboxlive.com", "assets2.xboxlive.com"], "no host outside xboxlive.com")
        XCTAssertTrue(location.urls[0].absoluteString.hasSuffix("/12/0a1b2c3d-0000-4000-8000-000000000003/\(Self.content)/1.5.12620.0.0a1b2c3d-0000-4000-8000-000000000001/\(location.fileName)"))

        let sent = await http.requests
        XCTAssertEqual(sent.map { $0.url.absoluteString }, ["https://user.auth.xboxlive.com/user/authenticate", "https://xsts.auth.xboxlive.com/xsts/authorize",
                                                         "https://packagespc.xboxlive.com/GetBasePackage/\(Self.content)"])
        let auth = try JSONSerialization.jsonObject(with: Data(sent[0].body.value)) as! [String: Any]
        XCTAssertEqual((auth["Properties"] as! [String: String])["RpsTicket"], "t=synthetic-store-ticket&p=")
        let xsts = try JSONSerialization.jsonObject(with: Data(sent[1].body.value)) as! [String: Any]
        XCTAssertEqual(xsts["RelyingParty"] as? String, "http://update.xboxlive.com")
        XCTAssertEqual((xsts["Properties"] as! [String: Any])["UserTokens"] as? [String], ["synthetic-user-jwt"])
        XCTAssertEqual(sent[2].headers["Authorization"]?.value, "XBL3.0 x=uhs4321;synthetic-xsts-jwt")
        XCTAssertEqual(sent[2].headers["x-xbl-contract-version"]?.value, "3")
        let broker = await http.tickets.request("renew")
        XCTAssertTrue(String(decoding: broker!.body.value, as: UTF8.self).contains(">user.auth.xboxlive.com<"))
        for secret in ["synthetic-user-jwt", "synthetic-xsts-jwt", "synthetic-store-ticket", "uhs4321"] { XCTAssertFalse(lines.text.contains(secret), secret) }
        XCTAssertFalse(lines.text.contains("assets1"))
    }

    func testNoPackageForTheAccountIsTheMissingEntitlementError() async throws {
        for (status, body) in [(200, Self.packages(found: false)), (403, "{}"), (404, "")] {
            let (session, http, _) = try await signedIn()
            await http.answer("user.auth.xboxlive.com", Self.user)
            await http.answer("xsts.auth.xboxlive.com", Self.xsts)
            await http.answer("packagespc.xboxlive.com", status: status, body)
            do { _ = try await session.packageLocation(contentID: Self.content); XCTFail("found") } catch let error as XboxInstallRefusal {
                XCTAssertEqual(error, .notEntitled, "HTTP \(status)")
            }
        }
    }

    /// With no .msixvc file the first .msixvc2 is the package (PLA-503).
    func testAnMSIXVC2PackageIsFoundAndXboxLiveRefusalAsksForSignIn() async throws {
        let (session, http, _) = try await signedIn()
        await http.answer("user.auth.xboxlive.com", Self.user)
        await http.answer("xsts.auth.xboxlive.com", Self.xsts)
        await http.answer("packagespc.xboxlive.com", Self.packages(file: "Game_1.0.0.0_x64__abc.msixvc2"))
        let location = try await session.packageLocation(contentID: Self.content)
        XCTAssertEqual(location.fileName, "Game_1.0.0.0_x64__abc.msixvc2")
        XCTAssertTrue(location.isMSIXVC2)
        XCTAssertTrue(location.urls[0].absoluteString.hasSuffix("/Game_1.0.0.0_x64__abc.msixvc2"))
        let (other, http2, _) = try await signedIn()
        await http2.answer("user.auth.xboxlive.com", Self.user)
        await http2.answer("xsts.auth.xboxlive.com", status: 401, #"{"XErr":2148916233}"#)
        do { _ = try await other.packageLocation(contentID: Self.content); XCTFail("refused") } catch XboxSessionError.signInRequired {}
    }
}
