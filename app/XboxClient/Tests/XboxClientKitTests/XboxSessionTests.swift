// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
import XboxClientKit

func xboxFixture(_ name: String) throws -> [UInt8] {
    let bytes = Array(try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!))
    return name.hasSuffix(".xml") ? try XboxSignedFixture.sign(bytes) : bytes
}
func xboxSignInToken() throws -> XboxSignInToken {
    let message = Secret(String(decoding: try xboxFixture("signin.json"), as: UTF8.self))
    guard case let .token(token) = try XboxSignIn.receive(message, from: URL(string: "https://login.live.com/ppsecure/post.srf")!) else { throw ClientError.noCredentials }
    return token
}

actor XboxFixtureHTTP: XboxHTTP {
    var replies: [String: [XboxHTTPResponse]] = [:]
    var calls: [(String, XboxHTTPRequest)] = []
    func reply(_ operation: String, _ name: String, status: Int = 200) throws {
        replies[operation, default: []].append(XboxHTTPResponse(status: status, body: try xboxFixture(name)))
    }
    func send(_ request: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        let xml = String(decoding: request.body.value, as: UTF8.self)
        let operation = request.url.path.contains("deviceaddcredential") ? "register" : xml.contains("rsa-sha256") ? "authenticate"
            : xml.contains("UsernameHint") ? (xml.contains(">Silent<") ? "renew" : "signin") : "device-ticket"
        calls.append((operation, request))
        if var queue = replies[operation], !queue.isEmpty { let response = queue.removeFirst(); replies[operation] = queue; return response }
        let name = ["register": "device-add.xml", "authenticate": "device-auth.xml", "signin": "user-issued.xml", "renew": "user-renewed.xml", "device-ticket": "device-ticket.xml"][operation]!
        return XboxHTTPResponse(status: 200, body: try xboxFixture(name))
    }
    func count(_ operation: String) -> Int { calls.filter { $0.0 == operation }.count }
    func request(_ operation: String) -> XboxHTTPRequest? { calls.last { $0.0 == operation }?.1 }
}
final class XboxLines: @unchecked Sendable {
    let lock = NSLock()
    private var lines: [String] = []
    var logger: Logger { Logger(verbose: true) { [self] line in lock.withLock { lines.append(line) } } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

final class XboxSessionTests: XCTestCase, @unchecked Sendable {
    let date = Date(timeIntervalSince1970: 1_793_318_400)
    func session(_ store: MemorySecretStore, _ http: XboxFixtureHTTP, log: Logger = .silent) -> XboxSession {
        XboxSession(store: store, http: http, log: log, now: { [date] in date })
    }
    func signIn(_ session: XboxSession) async throws {
        _ = try await session.prepareSignIn()
        guard case .signedIn = try await session.signIn(xboxSignInToken()) else { return XCTFail("sign-in not finished") }
    }
    func testSignInExchangesTicketsAndRestoresAcrossRelaunchThenRenewsSilently() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), lines = XboxLines()
        let first = session(store, http, log: lines.logger)
        try await signIn(first)
        let ticket = try await first.userTicket()
        XCTAssertEqual(ticket.token.value, "synthetic-compact-user")
        let device = try await first.deviceTicket()
        XCTAssertEqual(device.token.value, "synthetic-compact-device")
        let relaunched = session(store, http, log: lines.logger)
        let restored = await relaunched.state
        XCTAssertEqual(restored, .signedIn)
        let renewed = try await relaunched.renew()
        XCTAssertEqual(renewed.token.value, "synthetic-renewed-user")
        let request = await http.request("renew")
        XCTAssertTrue(String(decoding: request!.body.value, as: UTF8.self).contains(">Silent<"))
        XCTAssertFalse(lines.text.contains("synthetic-"))
        XCTAssertFalse(lines.text.contains("example.invalid"))
        XCTAssertFalse(lines.text.contains("CipherValue"))
    }
    func testSignOutDeletesAllIssuedSecretsButSignInReusesTheSameSyntheticDevice() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        try await signIn(s)
        let before = await s.deviceIdentity
        let kept = try store.read("device")
        try await s.signOut()
        let signedOut = await s.state
        XCTAssertEqual(signedOut, .signedOut)
        XCTAssertNil(try store.read("session")); XCTAssertNil(try store.read("device-token"))
        XCTAssertEqual(try store.read("device"), kept)
        try await signIn(s)
        let after = await s.deviceIdentity, registrations = await http.count("register")
        XCTAssertEqual(before, after); XCTAssertEqual(registrations, 1)
    }
    func testARefusedRenewalAsksForSignInAgainButKeepsTheDevice() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        try await signIn(s)
        let before = await s.deviceIdentity
        // A play's bridge and the app's account both hear of it, as at a sign-out.
        let heard = XboxCounter()
        _ = await s.onSignOut { heard.add() }
        try await http.reply("renew", "renewal-refused.xml", status: 500)
        do { _ = try await s.renew(); XCTFail("refusal accepted") }
        catch { XCTAssertEqual(error as? XboxSessionError, .signInRequired); XCTAssertTrue(String(describing: error).contains("Sign in again")) }
        let state = await s.state, after = await s.deviceIdentity
        XCTAssertEqual(state, .signedOut); XCTAssertEqual(before, after)
        XCTAssertNil(try store.read("session")); XCTAssertNil(try store.read("device-token"))
        XCTAssertEqual(heard.value, 1, "the sign-out handlers ran")
    }
    func testOnlyMicrosoftsDeviceAuthenticationRefusalReplacesARegisteredDevice() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        try await signIn(s)
        let before = await s.deviceIdentity
        try await s.signOut()
        try await http.reply("authenticate", "device-rejected.xml", status: 500)
        try await signIn(s)
        let after = await s.deviceIdentity, registrations = await http.count("register")
        XCTAssertNotEqual(before, after); XCTAssertEqual(registrations, 2)
    }
    func testAServiceFailureDoesNotBurnAnotherStoreDeviceAndResetIsExplicit() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        try await signIn(s)
        let before = await s.deviceIdentity
        try await s.signOut()
        try await http.reply("authenticate", "device-rejected.xml", status: 503)
        do { _ = try await s.prepareSignIn(); XCTFail("service failure accepted") } catch {}
        let unchanged = await s.deviceIdentity, count = await http.count("register")
        XCTAssertEqual(before, unchanged); XCTAssertEqual(count, 1)
        try await s.resetDevice()
        let reset = await s.deviceIdentity
        XCTAssertNotEqual(reset, before)
        try await signIn(s)
        let registrations = await http.count("register")
        XCTAssertEqual(registrations, 2)
    }
    func testMicrosoftCanAskForASecondHostedApprovalStep() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        try await http.reply("signin", "inline-approval.xml", status: 500)
        _ = try await s.prepareSignIn()
        guard case let .continueAt(page) = try await s.signIn(xboxSignInToken()) else { return XCTFail("approval not presented") }
        XCTAssertEqual(page.url.host, "login.live.com")
        XCTAssertEqual(page.headers["hostApp"], "CloudExperienceHost")
        let pending = await s.state
        XCTAssertEqual(pending, .signedOut)
        guard case .signedIn = try await s.signIn(xboxSignInToken()) else { return XCTFail("second step failed") }
    }
    /// Microsoft's real first leg (phone, 2026-11-02): no fault, a collection whose Xbox Live
    /// answer carries only its status and the approval page, beside an issued STS ticket.
    func testAnXboxLiveAnswerThatAsksForApprovalContinuesAtItsPage() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        await http.set("signin", XboxHTTPResponse(status: 200, body: try XboxSignedFixture.sign(xboxFixture("user-inline-consent.xml"), force: true)))
        _ = try await s.prepareSignIn()
        guard case let .continueAt(page) = try await s.signIn(xboxSignInToken()) else { return XCTFail("approval not presented") }
        XCTAssertEqual(page.url.absoluteString, "https://login.live.com/ppsecure/InlineConnect.srf?synthetic=consent")
        let pending = await s.state
        XCTAssertEqual(pending, .signedOut)
        guard case .signedIn = try await s.signIn(xboxSignInToken()) else { return XCTFail("second step failed") }
    }
    /// A game's own client ID (a GUID MSAAppId, say) that Microsoft wants approved refuses
    /// that game's ticket only; the same answer for Playport's client ends the session.
    func testAnApprovalPageForAGamesClientRefusesItsTicketButKeepsTheSession() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        try await signIn(s)
        let consent = try XboxSignedFixture.sign(xboxFixture("user-inline-consent.xml"), force: true)
        await http.set("renew", XboxHTTPResponse(status: 200, body: consent))
        let game = "6c7e2b74-6f3a-4f31-9e4b-2d0a9c1f5e01"
        do { _ = try await s.userTicket(scope: "scope=xboxlive.signin&api-version=2.0&clientid=\(game)", clientID: game); XCTFail("ticket issued") }
        catch { XCTAssertEqual(error as? XboxSessionError, .titleApprovalRequired) }
        let kept = await s.state
        XCTAssertEqual(kept, .signedIn); XCTAssertNotNil(try store.read("session"))
        await http.set("renew", XboxHTTPResponse(status: 200, body: consent))
        do { _ = try await s.renew(); XCTFail("renewal accepted") }
        catch { XCTAssertEqual(error as? XboxSessionError, .signInRequired) }
        let ended = await s.state
        XCTAssertEqual(ended, .signedOut)
    }
    func testStoreReason501NamesTenDevicesAndWhereToUnlinkButHTTP501IsNotThatError() throws {
        let bytes = try xboxFixture("device-limit.json")
        XCTAssertThrowsError(try XboxLicenceFailure.check(XboxHTTPResponse(status: 200, body: bytes))) {
            XCTAssertEqual($0 as? XboxLicenceFailure, .deviceLimit)
            let message = String(describing: $0)
            XCTAssertTrue(message.contains("10")); XCTAssertTrue(message.contains("account.microsoft.com/devices"))
            XCTAssertFalse(message.contains("synthetic-private")); XCTAssertFalse(message.contains("untrusted.invalid"))
        }
        XCTAssertThrowsError(try XboxLicenceFailure.check(XboxHTTPResponse(status: 501, body: bytes))) {
            XCTAssertNil($0 as? XboxLicenceFailure)
        }
    }
    func testACorruptOrTamperedResponseNeverCreatesASession() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        let original = String(decoding: try xboxFixture("user-issued.xml"), as: UTF8.self)
        // Tamper a signed digest, independently of any encrypted payload/key.
        let damaged = original.replacingOccurrences(of: "<DigestValue>", with: "<DigestValue>A")
        await http.set("signin", XboxHTTPResponse(status: 200, body: Array(damaged.utf8)))
        _ = try await s.prepareSignIn()
        do { _ = try await s.signIn(xboxSignInToken()); XCTFail("tampered response accepted") } catch {}
        let state = await s.state
        XCTAssertEqual(state, .signedOut)
    }
    /// A reply to a device-keyed request must carry Microsoft's signature: one with it
    /// stripped is refused, though its encrypted body would still decrypt.
    func testAnUnsignedResponseNeverCreatesASession() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        let original = String(decoding: try xboxFixture("user-issued.xml"), as: UTF8.self)
        let start = try XCTUnwrap(original.range(of: "<Signature")), end = try XCTUnwrap(original.range(of: "</Signature>"))
        let unsigned = original.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
        await http.set("signin", XboxHTTPResponse(status: 200, body: Array(unsigned.utf8)))
        _ = try await s.prepareSignIn()
        do { _ = try await s.signIn(xboxSignInToken()); XCTFail("unsigned response accepted") } catch {
            XCTAssertTrue("\(error)".contains("signature"), "\(error)")
        }
        let state = await s.state
        XCTAssertEqual(state, .signedOut)
    }
    func testAnExpiredTicketRenewsWithoutOpeningTheSignInPage() async throws {
        let http = XboxFixtureHTTP(), clock = XboxClock(), store = MemorySecretStore()
        let session = XboxSession(store: store, http: http, now: { clock.now })
        try await http.reply("signin", "user-expiring.xml")
        try await signIn(session)
        clock.now = ISO8601DateFormatter().date(from: "2041-01-01T00:00:00Z")!
        let ticket = try await session.userTicket()
        XCTAssertEqual(ticket.token.value, "synthetic-renewed-user")
        let count = await http.count("signin")
        XCTAssertEqual(count, 1)
    }
    func testASOAPServiceFaultDoesNotReplaceTheSyntheticDevice() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), s = session(store, http)
        try await signIn(s)
        let before = await s.deviceIdentity
        try await s.signOut()
        let body = String(decoding: try xboxFixture("device-rejected.xml"), as: UTF8.self)
            .replacingOccurrences(of: "s:Sender", with: "s:Receiver")
            .replacingOccurrences(of: "wst:FailedAuthentication", with: "s:InternalServerError")
        await http.set("authenticate", XboxHTTPResponse(status: 500, body: Array(body.utf8)))
        do { _ = try await s.prepareSignIn(); XCTFail("service fault accepted") } catch {}
        let after = await s.deviceIdentity, count = await http.count("register")
        XCTAssertEqual(before, after); XCTAssertEqual(count, 1)
    }
    func testASignOutWhileRenewingCannotPutTheSessionSecretsBack() async throws {
        let store = MemorySecretStore(), http = XboxHeldHTTP()
        let s = XboxSession(store: store, http: http)
        try await signIn(s)
        await http.hold()
        let renewal = Task { try await s.renew() }
        await http.waitUntilHeld()
        try await s.signOut()
        await http.release()
        do { _ = try await renewal.value; XCTFail("signed-out renewal returned a ticket") } catch {}
        let state = await s.state
        XCTAssertEqual(state, .signedOut)
        XCTAssertNil(try store.read("session")); XCTAssertNil(try store.read("device-token"))
        XCTAssertNotNil(try store.read("device"))
    }
}
extension XboxFixtureHTTP {
    func set(_ operation: String, _ response: XboxHTTPResponse) { replies[operation, default: []].append(response) }
}

final class XboxClock: @unchecked Sendable {
    let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_793_318_400)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

actor XboxHeldHTTP: XboxHTTP {
    let fixtures = XboxFixtureHTTP()
    var shouldHold = false
    var held = false
    var waiter: CheckedContinuation<Void, Never>?
    var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() { shouldHold = true }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func send(_ request: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        if shouldHold {
            held = true; waiter?.resume(); waiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
            shouldHold = false
        }
        return try await fixtures.send(request)
    }
}

/// A count a `@Sendable` closure bumps.
final class XboxCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
