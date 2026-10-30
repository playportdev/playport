// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// A fixed proof key: the public point is 0xAA… and 0xBB…, every signature 0x5C….
/// The host has no P-256; the phone signs with CryptoKit.
final class XboxTestSigner: XboxLiveSigner, @unchecked Sendable {
    private let lock = NSLock()
    private var signed: [[UInt8]] = []
    var messages: [[UInt8]] { lock.withLock { signed } }
    var publicKey: (x: [UInt8], y: [UInt8]) { ([UInt8](repeating: 0xAA, count: 32), [UInt8](repeating: 0xBB, count: 32)) }
    func sign(_ message: [UInt8]) throws -> [UInt8] {
        lock.withLock { signed.append(message) }
        return [UInt8](repeating: 0x5C, count: 64)
    }
}

final class XboxOfflineDeviceTests: XCTestCase, @unchecked Sendable {
    // The licensing fixtures' times (XboxLicensingTests): issued 2026-10-30T11:41:58Z,
    // the offline lease ends 2026-11-29T11:41:58Z.
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
    func json(_ request: XboxHTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.body.value)) as? [String: Any])
    }
    func designate(_ session: XboxSession, _ http: XboxLicensingHTTP) async throws {
        try await http.answerOfflineDevice("offline-device-on.json")
        _ = try await session.offlineDevice(set: true, signer: XboxTestSigner())
    }
    func online(_ session: XboxSession, _ http: XboxLicensingHTTP, leases: [String]? = nil) async throws {
        try await http.answer("licence-content.json", leases: leases)
        guard case .licensed(let licence) = try await session.licence(contentID: Self.content), licence.source == .microsoft else {
            return XCTFail("not granted online")
        }
    }
    func offlineStart(_ session: XboxSession) async throws -> Result<XboxLicence, XboxPlayRefusal> {
        XboxPlayRefusal.check(try await session.licence(contentID: Self.content))
    }

    // MARK: The designation API (recorded shapes)

    func testReadingTheDesignationSignsTheXboxLiveChainAndReadsTheRecordedAnswer() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http), signer = XboxTestSigner()
        try await http.answerOfflineDevice("offline-device-off.json")
        let status = try await session.offlineDevice(set: nil, signer: signer)
        XCTAssertEqual(status.isThisDevice, false)
        XCTAssertEqual(status.changesLeft, 3); XCTAssertEqual(status.changesPerPeriod, 3); XCTAssertEqual(status.periodDays, 365)
        XCTAssertNil(status.nextChangeAt, "1601-01-01 is Microsoft's no date")

        let sent = await http.liveRequests
        XCTAssertEqual(sent.map(\.url.absoluteString), ["https://device.auth.xboxlive.com/device/authenticate", "https://sisu.xboxlive.com/authorize",
                                                         "https://xsts.auth.xboxlive.com/xsts/authorize", "https://beige.xboxservices.com/pcgafd/config/offlinepc"])
        let proof: [String: String] = ["alg": "ES256", "crv": "P-256", "kty": "EC", "use": "sig",
                                       "x": "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo", "y": "u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7s"]
        // The device: its TOKEN_BROKER ticket for Xbox Live's user.auth scope, as RPS.
        let device = try json(sent[0]), deviceProperties = try XCTUnwrap(device["Properties"] as? [String: Any])
        XCTAssertEqual(device["RelyingParty"] as? String, "http://auth.xboxlive.com")
        XCTAssertEqual(deviceProperties["AuthMethod"] as? String, "RPS")
        XCTAssertEqual(deviceProperties["RpsTicket"] as? String, "t=synthetic-compact-device")
        XCTAssertEqual(deviceProperties["SiteName"] as? String, "user.auth.xboxlive.com")
        XCTAssertEqual(deviceProperties["Version"] as? String, "10.0.22621")
        XCTAssertEqual(deviceProperties["ProofKey"] as? [String: String], proof)
        XCTAssertEqual(sent[0].headers["x-xbl-contract-version"]?.value, "1")
        // SISU: the Xbox app's xboxlive.signin ticket and the device token.
        let sisu = try json(sent[1])
        XCTAssertEqual(sisu["AccessToken"] as? String, "t=synthetic-xbox-app-ticket")
        XCTAssertEqual(sisu["AppId"] as? String, "000000004424da1f")
        XCTAssertEqual(sisu["DeviceToken"] as? String, "synthetic.device.jwt")
        XCTAssertEqual(sisu["Sandbox"] as? String, "RETAIL")
        XCTAssertEqual(sisu["ProofKey"] as? [String: String], proof)
        XCTAssertNil(sent[1].headers["x-xbl-contract-version"])
        let ticket = await http.appTicketRequests.first
        XCTAssertTrue(String(decoding: try XCTUnwrap(ticket).body.value, as: UTF8.self)
            .contains("scope=xboxlive.signin&amp;api-version=2.0&amp;clientid=000000004424da1f"))
        // XSTS for the Store's relying party with the device, title and user claims.
        let xsts = try json(sent[2])
        XCTAssertEqual(xsts["RelyingParty"] as? String, "http://mp.microsoft.com/")
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(xsts["Properties"] as? [String: Any])), NSDictionary(dictionary: [
            "SandboxId": "RETAIL", "DeviceToken": "synthetic.device.jwt", "TitleToken": "synthetic.title.jwt", "UserTokens": ["synthetic.user.jwt"]]))
        // The PC Game App Front Door, as the recorded GET.
        let get = sent[3]
        XCTAssertEqual(get.method, "GET")
        XCTAssertEqual(get.headers["Authorization"]?.value, "XBL3.0 x=uhs4567;synthetic.mp.xsts")
        XCTAssertEqual(get.headers["X-MS-API-Version"]?.value, "1.0")
        XCTAssertEqual(get.headers["x-xbl-contract-version"]?.value, "1")
        XCTAssertEqual(get.headers["Accept-Language"]?.value, "en-US")
        XCTAssertNil(get.headers["Signature"])
        XCTAssertTrue(get.body.value.isEmpty)
    }

    func testEveryXboxLiveRequestIsSignedOverItsMethodPathAndBody() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http), signer = XboxTestSigner()
        try await http.answerOfflineDevice("offline-device-off.json")
        _ = try await session.offlineDevice(set: nil, signer: signer)
        let sent = await http.liveRequests
        // Version 1, FILETIME 134378347180000000 (2026-10-30T11:51:58Z), the 64-byte signature.
        let header = "AAAAAQHdaGURKwMAXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXA=="
        XCTAssertEqual(sent.prefix(3).map { $0.headers["Signature"]?.value }, [header, header, header])
        let time: [UInt8] = [0x01, 0xdd, 0x68, 0x65, 0x11, 0x2b, 0x03, 0x00]
        let paths = ["/device/authenticate", "/authorize", "/xsts/authorize"]
        XCTAssertEqual(signer.messages.count, 3)
        for (i, message) in signer.messages.enumerated() {
            let expected = [0, 0, 0, 1, 0] + time + [0] + Array("POST".utf8) + [0] + Array(paths[i].utf8) + [0, 0] + sent[i].body.value + [0]
            XCTAssertEqual(message, expected, paths[i])
        }
    }

    func testTurningItOnIsOneConfirmedChangeAndOnlyAnAppliedChangeCounts() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await http.answerOfflineDevice("offline-device-declined.json")
        do { _ = try await session.offlineDevice(set: true, signer: XboxTestSigner()); XCTFail("a declined change applied") }
        catch let error as XboxOfflineDeviceNotChanged {
            XCTAssertTrue(error.description.contains("no changes are left") && error.description.contains("2027-03-01"), error.description)
        }
        let declined = await session.isOfflineDevice
        XCTAssertFalse(declined)

        try await http.answerOfflineDevice("offline-device-on.json")
        let status = try await session.offlineDevice(set: true, signer: XboxTestSigner())
        XCTAssertTrue(status.isThisDevice); XCTAssertEqual(status.changesLeft, 2)
        let last = await http.liveRequests.last
        let post = try XCTUnwrap(last)
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.url.absoluteString, "https://beige.xboxservices.com/pcgafd/config/offlinepc/true")
        let on = await session.isOfflineDevice
        XCTAssertTrue(on)

        try await http.answerOfflineDevice("offline-device-off.json", status: 401)
        do { _ = try await session.offlineDevice(set: nil, signer: XboxTestSigner()); XCTFail("401 read") }
        catch { XCTAssertEqual(error as? XboxSessionError, .signInRequired) }
    }

    func testTheSettingIsOffByDefaultAndSignOutForgetsIt() async throws {
        let http = XboxLicensingHTTP(), store = MemorySecretStore(), session = try await signedIn(http, store)
        let initially = await session.isOfflineDevice
        XCTAssertFalse(initially, "off by default")
        try await designate(session, http)
        let designated = await session.isOfflineDevice
        XCTAssertTrue(designated)
        try await session.signOut()
        let after = await session.isOfflineDevice
        XCTAssertFalse(after)
        XCTAssertNil(try store.read("offline-device"))
    }

    func testTheConfirmationNamesTheOneDeviceLimitAndTheReplacement() throws {
        let recorded = try XboxOfflineDevice.parse(xboxFixture("offline-device-off.json"))
        let on = XboxOfflineDevice.confirmation(turningOn: true, status: recorded)
        XCTAssertEqual(on.title, "Make this phone your offline device?")
        XCTAssertTrue(on.note.contains("Microsoft allows one offline device per Xbox account."), on.note)
        XCTAssertTrue(on.note.contains("This phone replaces your current offline device"), on.note)
        XCTAssertTrue(on.note.contains("Microsoft allows 3 changes a year; 3 left."), on.note)
        let off = XboxOfflineDevice.confirmation(turningOn: false, status: nil)
        XCTAssertTrue(off.note.contains("need a connection"), off.note)
        for bad in [Array("not json".utf8), Array(#"{"offlinePermissions":{}}"#.utf8), Array(#"{"offlinePermissions":{"enabled":"yes"}}"#.utf8)] {
            XCTAssertThrowsError(try XboxOfflineDevice.parse(bad))
        }
        let minimal = try XboxOfflineDevice.parse(Array(#"{"offlinePermissions":{"enabled":true}}"#.utf8))
        XCTAssertTrue(minimal.isThisDevice); XCTAssertNil(minimal.changesLeft)
    }

    // MARK: The offline launch rule

    func testACopyLaunchedOnlineOnceStartsOfflineWhileItsLeaseLasts() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await designate(session, http)
        try await online(session, http)
        await http.setOffline(true)
        clock.now = Self.leaseEnds.addingTimeInterval(-60)
        guard case .success(let licence) = try await offlineStart(session) else { return XCTFail("offline start refused") }
        XCTAssertEqual(licence.source, .cache)
        XCTAssertEqual(licence.keys.map(\.key.value), [Array(0x40...0x5f)])

        clock.now = Self.leaseEnds
        guard case .failure(let refusal) = try await offlineStart(session) else { return XCTFail("the lease ended") }
        XCTAssertEqual(refusal, .unavailable(.connectionNeeded(.leaseEnded(Self.leaseEnds))))
        XCTAssertEqual(refusal.title, "Connection needed")
        XCTAssertTrue(refusal.description.contains("ended on 2026-11-29") && refusal.description.contains("Connect to the internet"), refusal.description)
    }

    func testWithoutTheDesignationAnOfflineStartSaysAConnectionIsNeededAndWhy() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await online(session, http)  // Microsoft grants an isOffline lease anyway (PLA-496)
        await http.setOffline(true)
        guard case .failure(let refusal) = try await offlineStart(session) else { return XCTFail("started offline without the designation") }
        XCTAssertEqual(refusal, .unavailable(.connectionNeeded(.notOfflineDevice)))
        XCTAssertEqual(refusal.title, "Connection needed")
        XCTAssertTrue(refusal.description.contains("needs this phone to be your Xbox offline device"), refusal.description)
        XCTAssertTrue(refusal.description.contains("Settings › Accounts › Xbox"), refusal.description)
    }

    func testOnlyALicenceIssuedSinceTheDesignationStartsOffline() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await online(session, http)
        clock.now = clock.now.addingTimeInterval(60)
        try await designate(session, http)
        await http.setOffline(true)
        guard case .failure(let before) = try await offlineStart(session) else { return XCTFail("a licence from before the designation") }
        XCTAssertEqual(before, .unavailable(.connectionNeeded(.notPlayedOnline)))
        XCTAssertTrue(before.description.contains("play it once"), before.description)

        await http.setOffline(false)
        try await online(session, http, leases: ["licence-lease-online.xml"])
        await http.setOffline(true)
        guard case .failure(let noLease) = try await offlineStart(session) else { return XCTFail("no offline lease") }
        XCTAssertEqual(noLease, .unavailable(.connectionNeeded(.noOfflineLease)))
    }

    func testAnotherDeviceTakingOverEndsOfflineStartsHere() async throws {
        let http = XboxLicensingHTTP(), store = MemorySecretStore(), session = try await signedIn(http, store)
        try await designate(session, http)
        try await online(session, http)
        try await http.answerOfflineDevice("offline-device-off.json")  // the account designated another device
        let status = try await session.offlineDevice(set: nil, signer: XboxTestSigner())
        XCTAssertFalse(status.isThisDevice)
        let designated = await session.isOfflineDevice
        XCTAssertFalse(designated)
        await http.setOffline(true)
        guard case .failure(.unavailable(.connectionNeeded(.notOfflineDevice))) = try await offlineStart(session) else { return XCTFail("still offline") }
    }

    func testServiceErrorsFollowTheSameRuleButKeepTheirOwnMessage() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        try await online(session, http)
        try await http.answer("device-limit.json", status: 503)
        guard case .unavailable(.service(503)) = try await session.licence(contentID: Self.content) else { return XCTFail("not designated") }
        try await designate(session, http)
        try await online(session, http)
        try await http.answer("device-limit.json", status: 503)
        guard case .licensed(let cached) = try await session.licence(contentID: Self.content) else { return XCTFail("designated") }
        XCTAssertEqual(cached.source, .cache)
    }

    // MARK: The runtime's offline identity

    func testTheGameSignsInFromTheCachedIdentityOnlyOnAnOfflineStart() async throws {
        let http = XboxLicensingHTTP(), session = try await signedIn(http)
        let account = await session.offlineIdentityAccount
        XCTAssertEqual(account, "faa296d58b7dcae9eec26d1991a5e3cc", "Nexus's accountCacheKey of the fixture's sign-in name")
        try await designate(session, http)
        try await online(session, http)
        func env(_ licence: XboxLicence, designated: Bool) -> [String: String] {
            XboxOfflineIdentity.environment(licence: licence, offlineDevice: designated, account: account).mapValues(\.value)
        }
        try await http.answer("licence-content.json")
        guard case .licensed(let granted) = try await session.licence(contentID: Self.content) else { return XCTFail("online") }
        XCTAssertEqual(env(granted, designated: true), ["XODUS_ACCOUNT_HASH": "faa296d58b7dcae9eec26d1991a5e3cc", "XODUS_OFFLINE_IDENTITY": "store"])
        XCTAssertEqual(env(granted, designated: false), ["XODUS_ACCOUNT_HASH": "faa296d58b7dcae9eec26d1991a5e3cc"])
        await http.setOffline(true)
        guard case .licensed(let cached) = try await session.licence(contentID: Self.content) else { return XCTFail("offline") }
        XCTAssertEqual(env(cached, designated: true), ["XODUS_ACCOUNT_HASH": "faa296d58b7dcae9eec26d1991a5e3cc",
                                                      "XODUS_OFFLINE_IDENTITY": "use", "XODUS_FORCE_OFFLINE": "1"])
        XCTAssertTrue(XboxOfflineIdentity.environment(licence: cached, offlineDevice: true, account: nil).isEmpty)
    }

    func testRemovingTheIdentityCachesStaysInsideThePrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix"), outside = root.appendingPathComponent("outside")
        let cache = prefix.appendingPathComponent("drive_c/users/player/AppData/Local/Xodus Nexus/offline-identity/faa296d58b7dcae9eec26d1991a5e3cc")
        let elsewhere = outside.appendingPathComponent("AppData/Local/Xodus Nexus/offline-identity/x")
        for dir in [cache, elsewhere] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("schema=1\n".utf8).write(to: cache.appendingPathComponent("identity.txt"))
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("drive_c/users/linked"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/users/Public"), withIntermediateDirectories: true)

        XCTAssertEqual(try XboxOfflineIdentity.remove(prefix: prefix), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/users/player/AppData/Local").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "a link out of the prefix is never followed")
        XCTAssertEqual(try XboxOfflineIdentity.remove(prefix: root.appendingPathComponent("missing")), 0)
    }

    func testTheLogNamesTheDesignationAndTheLicenceUsageButNoTokens() async throws {
        let http = XboxLicensingHTTP(), lines = XboxLines(), session = try await signedIn(http, log: lines.logger)
        try await designate(session, http)
        try await online(session, http)
        let text = lines.text
        XCTAssertTrue(text.contains("offline device: this device (changed); 2 change(s) left"), text)
        // The synthetic lease's URI has no query; the recorded one says policyType=Online, policyKind=Device.
        XCTAssertTrue(text.contains("licence usage: key Machine/Online; lease Machine/Online isOffline=true policyType=? policyKind=?"), text)
        for secret in ["synthetic.device.jwt", "synthetic.title.jwt", "synthetic.user.jwt", "synthetic.mp.xsts", "uhs4567",
                       "synthetic-xbox-app-ticket", "synthetic-compact-device"] {
            XCTAssertFalse(text.contains(secret), "log holds \(secret)")
        }
    }
}
