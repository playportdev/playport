// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// Licensing's transport: licensing.mp answers from a queue, the device registers
/// with a licence that carries an EncryptedDeviceKey, the rest is XboxFixtureHTTP.
/// `offline` fails every request as a dropped connection would.
actor XboxLicensingHTTP: XboxHTTP {
    let tickets = XboxFixtureHTTP()
    var licensing: [XboxHTTPResponse] = []
    var requests: [XboxHTTPRequest] = []
    var offline = false
    var device = "device-add-licensing.xml"
    func answer(_ name: String, status: Int = 200, leases: [String]? = nil) throws {
        licensing.append(XboxHTTPResponse(status: status, body: try xboxLicensingFixture(name, leases: leases)))
    }
    func answer(body: [UInt8], status: Int = 200) { licensing.append(XboxHTTPResponse(status: status, body: body)) }
    func setOffline(_ value: Bool) { offline = value }
    func registerWith(_ name: String) { device = name }
    func send(_ request: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        if offline { throw ClientError.transport("Xbox request failed; check your connection") }
        if request.url.host == "licensing.mp.microsoft.com" {
            requests.append(request)
            guard !licensing.isEmpty else { throw ClientError.transport("no fixture") }
            return licensing.removeFirst()
        }
        if request.url.path.contains("deviceaddcredential") { return XboxHTTPResponse(status: 200, body: try xboxFixture(device)) }
        return try await tickets.send(request)
    }
}

/// A licensing response fixture with each `@file` value replaced by that file's
/// base64, as Microsoft sends the licence XML. `leases` replaces the lease list.
func xboxLicensingFixture(_ name: String, leases: [String]? = nil) throws -> [UInt8] {
    var json = try JSONSerialization.jsonObject(with: Data(try xboxFixture(name)))
    func resolve(_ value: Any) throws -> Any {
        if let text = value as? String, text.hasPrefix("@") { return Data(try xboxFixture(String(text.dropFirst()))).base64EncodedString() }
        if let list = value as? [Any] { return try list.map(resolve) }
        if let object = value as? [String: Any] { return try object.mapValues(resolve) }
        return value
    }
    if let leases, var object = json as? [String: Any], var licence = object["license"] as? [String: Any] {
        licence["leases"] = leases.map { ["value": "@" + $0] }; object["license"] = licence; json = object
    }
    return Array(try JSONSerialization.data(withJSONObject: try resolve(json)))
}

final class XboxLicensingTests: XCTestCase, @unchecked Sendable {
    // The fixtures' licence: issued 2026-10-30T11:41:58Z, expiring as issued; its
    // offline lease runs 30 days and asks for a check after 2.
    static let issued = Date(timeIntervalSince1970: 1_793_360_518)
    static let leaseEnds = Date(timeIntervalSince1970: 1_795_952_518)
    static let content = "4F1D6B2E-8C3A-4E5F-9A7B-0C1D2E3F4A5B"
    let clock: XboxClock = { let clock = XboxClock(); clock.now = issued.addingTimeInterval(600); return clock }()

    func signedIn(_ http: XboxLicensingHTTP, _ store: MemorySecretStore = MemorySecretStore(), log: Logger = .silent) async throws -> XboxSession {
        let session = XboxSession(store: store, http: http, log: log, now: { [clock] in clock.now })
        _ = try await session.prepareSignIn()
        guard case .signedIn = try await session.signIn(xboxSignInToken()) else { throw ClientError.noCredentials }
        try await http.tickets.reply("renew", "store-ticket.xml")
        return session
    }
    func granted(_ result: XboxLicenceResult, file: StaticString = #filePath, line: UInt = #line) throws -> XboxLicence {
        guard case .licensed(let licence) = result else { XCTFail("not licensed: \(result)", file: file, line: line); throw ClientError.noCredentials }
        return licence
    }

    func testTheLicenceUnwrapsItsContentKeyWithTheSyntheticDevicesKey() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await http.answer("licence-content.json")
        let licence = try granted(await session.licence(contentID: Self.content))
        XCTAssertEqual(licence.source, .microsoft)
        XCTAssertEqual(licence.contentID, Self.content.lowercased())
        XCTAssertEqual(licence.keys.count, 1)
        XCTAssertEqual(licence.keys[0].id, UUID(uuidString: "1c2d3e4f-5a6b-4c7d-8e9f-a0b1c2d3e4f5"))
        XCTAssertEqual(licence.keys[0].key.value, Array(0x40...0x5f), "the test content key the fixture wraps")
        XCTAssertEqual(licence.expiresAt, Self.issued)
        XCTAssertEqual(licence.offlineLease, XboxLicenceLease(expiresAt: Self.leaseEnds, pollAt: Date(timeIntervalSince1970: 1_793_533_318)))

        // The request Xodus's get_license_content sends, with the Store tickets.
        let sent = await http.requests.last
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.url.absoluteString, "https://licensing.mp.microsoft.com/v7.0/licenses/content")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["from"]?.value, "XboxLicenseManager")
        XCTAssertEqual(request.headers["Authorization"]?.value, "synthetic-compact-device")
        XCTAssertEqual(request.headers["user-agent"]?.value, "XboxLm-PC/Microsoft.GamingServices_32.107.4002.0_x64__8wekyb3d8bbwe")
        XCTAssertNotNil(request.headers["MS-CV"]?.value.wholeMatch(of: /[A-Za-z0-9+\/]{22}\.0/))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.body.value)) as? [String: Any])
        XCTAssertEqual(body["contentId"] as? String, Self.content.lowercased())
        XCTAssertEqual(body["market"] as? String, "US")
        XCTAssertEqual(body["licenseVersion"] as? Int, 4)
        XCTAssertEqual(body["concurrencyMode"] as? String, "Rude")
        XCTAssertEqual(body["needKey"] as? Bool, true); XCTAssertEqual(body["keyOnly"] as? Bool, true)
        XCTAssertEqual(body["deviceContext"] as? [String: String], ["hardwareManufacturer": "Public", "hardwareType": "Public", "mobileOperator": "Public"])
        let challenge = String(decoding: Data(base64Encoded: try XCTUnwrap(body["clientChallenge"] as? String))!, as: UTF8.self)
        XCTAssertTrue(challenge.contains("<LicenseProtocolVersion>5</LicenseProtocolVersion>"))
        let users = try XCTUnwrap(body["users"] as? [String: [[String: String]]])
        XCTAssertEqual(users, ["S-1-5-21-0000000000-0000000000-0000000000-1001": [
            ["identityType": "Msa", "identityValue": "t=synthetic-store-ticket&p=", "localTicketReference": "synthetic-puid"]]])
        // The device's ticket is the Store app's www.microsoft.com ticket under mbi_ssl.
        let ticketRequest = await http.tickets.request("device-ticket")
        let exchange = String(decoding: try XCTUnwrap(ticketRequest).body.value, as: UTF8.self)
        XCTAssertTrue(exchange.contains(">www.microsoft.com<") && exchange.contains("URI=\"mbi_ssl\""))
        XCTAssertTrue(exchange.contains(">{d6d5a677-0872-4ab0-9442-bb792fce85c5}<"))
    }

    func testCachedKeysServeWhileMicrosoftIsUnreachableOnlyWithinTheOfflineLease() async throws {
        let http = XboxLicensingHTTP(), store = MemorySecretStore(), session = try await signedIn(http, store)
        try await http.answer("licence-content.json")
        _ = try granted(await session.licence(contentID: Self.content))
        XCTAssertNotNil(try store.read("licences"), "the keys are in the Keychain")

        await http.setOffline(true)
        clock.now = Self.leaseEnds.addingTimeInterval(-60)
        let cached = try granted(await session.licence(contentID: Self.content))
        XCTAssertEqual(cached.source, .cache)
        XCTAssertEqual(cached.keys.map(\.key.value), [Array(0x40...0x5f)])
        XCTAssertEqual(cached.keys.map(\.id), [UUID(uuidString: "1c2d3e4f-5a6b-4c7d-8e9f-a0b1c2d3e4f5")!])
        XCTAssertEqual(cached.expiresAt, Self.issued); XCTAssertEqual(cached.offlineLease?.expiresAt, Self.leaseEnds)

        clock.now = Self.leaseEnds
        guard case .unavailable(.network) = try await session.licence(contentID: Self.content) else { return XCTFail("lease ended") }
        let other = "00000000-0000-4000-8000-0000000000aa"
        guard case .unavailable(.network) = try await session.licence(contentID: other) else { return XCTFail("another copy has no keys") }
    }

    func testWithoutAnOfflineLeaseTheKeysLastOnlyAsLongAsTheLicence() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await http.answer("licence-content.json", leases: ["licence-lease-online.xml", "licence-key.xml"])
        let licence = try granted(await session.licence(contentID: Self.content))
        XCTAssertNil(licence.offlineLease, "an online lease, or a lease without a policy, grants no offline time")
        XCTAssertEqual(licence.usableUntil, Self.issued)
        await http.setOffline(true)
        guard case .unavailable(.network) = try await session.licence(contentID: Self.content) else { return XCTFail("expired as issued") }
    }

    func testServiceErrorsUseTheLeaseButNeitherIsARefusalAndHTTPRejectionsDoNot() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await http.answer("licence-content.json")
        _ = try granted(await session.licence(contentID: Self.content))
        for status in [408, 429, 500, 501, 503] {
            try await http.answer("device-limit.json", status: status)
            let cached = try granted(await session.licence(contentID: Self.content))
            XCTAssertEqual(cached.source, .cache, "HTTP \(status) is a service error, not reason 501")
        }
        for status in [400, 401, 403, 404] {
            try await http.answer("licence-refused.json", status: status)
            guard case .unavailable(.rejected(status)) = try await session.licence(contentID: Self.content) else { return XCTFail("HTTP \(status)") }
        }
        // None of those deleted the keys.
        await http.setOffline(true)
        let last = try granted(await session.licence(contentID: Self.content))
        XCTAssertEqual(last.source, .cache)
    }

    func testOnlyMicrosoftsSatisfactionFailureIsADefinitiveRefusal() async throws {
        let http = XboxLicensingHTTP(), store = MemorySecretStore(), session = try await signedIn(http, store)
        let other = "00000000-0000-4000-8000-0000000000aa"
        try await http.answer("licence-content.json")
        _ = try granted(await session.licence(contentID: Self.content))

        // Malformed or ambiguous answers and keys that don't unwrap are no verdict.
        var ambiguous = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try xboxLicensingFixture("licence-content.json"))) as? [String: Any])
        ambiguous["satisfactionFailure"] = ["code": 1, "description": "synthetic"]
        for body in [Array("not json".utf8), Array("{}".utf8), Array(try JSONSerialization.data(withJSONObject: ambiguous)),
                     Array(#"{"satisfactionFailure":{"code":"1","description":"synthetic"}}"#.utf8),
                     Array(#"{"license":{"keys":[],"leases":[]}}"#.utf8)] {
            await http.answer(body: body)
            guard case .unavailable(.invalidResponse) = try await session.licence(contentID: Self.content) else { return XCTFail(String(decoding: body, as: UTF8.self)) }
        }
        try await http.answer("licence-refused.json")
        guard case .refused(.refused) = try await session.licence(contentID: Self.content) else { return XCTFail("reason 1") }
        await http.setOffline(true)
        guard case .unavailable(.network) = try await session.licence(contentID: Self.content) else { return XCTFail("a refusal deletes the copy's keys") }
        await http.setOffline(false)

        // Reason 501 refuses the device, not the copy: asked for another copy, it
        // still drops every copy's keys.
        try await http.answer("licence-content.json"); _ = try granted(await session.licence(contentID: Self.content))
        try await http.answer("device-limit.json")
        guard case .refused(.deviceLimit) = try await session.licence(contentID: other) else { return XCTFail("reason 501") }
        await http.setOffline(true)
        guard case .unavailable(.network) = try await session.licence(contentID: Self.content) else { return XCTFail("device refused") }
    }

    func testANetworkFailureIsNotARefusalAndAnotherDevicesLicenceIsInvalid() async throws {
        let http = XboxLicensingHTTP()
        await http.registerWith("device-add.xml")  // a device licence without an EncryptedDeviceKey
        let session = try await signedIn(http)
        try await http.answer("licence-content.json")
        guard case .unavailable(.invalidResponse) = try await session.licence(contentID: Self.content) else { return XCTFail("no device key") }
        guard case .unavailable(.network) = try await session.licence(contentID: Self.content) else { return XCTFail("dropped") }
        do { _ = try await session.licence(contentID: "not-a-guid"); XCTFail("content IDs are GUIDs") } catch ClientError.unsupported {}
    }

    func testNoLicenceKeyOrTicketReachesTheLogAndSignOutDeletesTheKeys() async throws {
        let http = XboxLicensingHTTP(), store = MemorySecretStore(), lines = XboxLines()
        let session = try await signedIn(http, store, log: lines.logger)
        try await http.answer("licence-content.json")
        let licence = try granted(await session.licence(contentID: Self.content))
        try await http.answer("licence-refused.json")
        _ = try await session.licence(contentID: Self.content)
        try await http.answer("device-limit.json")
        _ = try await session.licence(contentID: Self.content)
        await http.setOffline(true)
        _ = try await session.licence(contentID: Self.content)

        let key = licence.keys[0].key.value
        let response = String(decoding: try xboxLicensingFixture("licence-content.json"), as: UTF8.self)
        let text = lines.text
        XCTAssertTrue(text.contains("licence granted") && text.contains("licence refused"))
        for secret in [Data(key).base64EncodedString(), key.map { String(format: "%02x", $0) }.joined(), String(response.dropFirst(300).prefix(40)),
                       "synthetic-compact-device", "synthetic-store-ticket", "synthetic-puid", "synthetic-private-provider-text", "untrusted.invalid",
                       Self.content.lowercased(), "1c2d3e4f"] {
            XCTAssertFalse(text.contains(secret), "log holds \(secret)")
        }
        XCTAssertFalse(String(describing: licence).contains(Data(key).base64EncodedString()))
        XCTAssertFalse(String(describing: licence.keys).contains("64, 65"), "keys print redacted")
        try await session.signOut()
        XCTAssertNil(try store.read("licences"))
        XCTAssertNotNil(try store.read("device"))
    }

    func testRFC3394KeyUnwrapAndAWrongKey() throws {
        func hex(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { UInt8(Array(s)[$0...$0 + 1].map(String.init).joined(), radix: 16)! } }
        let kek = Array(0...15) as [UInt8]
        // RFC 3394 section 4.1: 128 bits of key data under a 128-bit KEK.
        XCTAssertEqual(try XboxLicensing.unwrap(hex("1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5"), key: kek),
                       hex("00112233445566778899aabbccddeeff"))
        XCTAssertThrowsError(try XboxLicensing.unwrap(hex("1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5"), key: Array(1...16)))
        XCTAssertEqual(XboxLicensing.date("2026-11-29T11:41:58.4221143+00:00"), Self.leaseEnds)
        XCTAssertNil(XboxLicensing.date("2026-11-29T11:41:58.4221143"), "no offset, no instant")
    }
}
