// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import ContentKit
@testable import XboxClientKit

/// The bridge's account: tickets named by what they were minted for, a held
/// request for sign-out races, and sign-out handlers as XboxSession runs them.
actor XboxBridgeFakeAccount: XboxBridgeAccount {
    var state: XboxSessionState = .signedIn
    var calls: [String] = []
    var licenceProblem: XboxLicenceProblem?
    var licenceTokenValue = "synthetic-licence-token"
    private var handlers: [UInt64: @Sendable () -> Void] = [:]
    private var holding = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    static let expiry = Date(timeIntervalSince1970: 1_793_400_000)

    func setState(_ value: XboxSessionState) { state = value }
    func setLicence(problem: XboxLicenceProblem?, token: String = "synthetic-licence-token") { licenceProblem = problem; licenceTokenValue = token }
    func hold() { holding = true }
    func waitUntilHeld() async { if release == nil { await withCheckedContinuation { heldWaiter = $0 } } }
    func signOut() {
        state = .signedOut
        for action in handlers.values { action() }
        release?.resume(); release = nil
    }
    private func gate() async {
        guard holding else { return }
        holding = false
        await withCheckedContinuation { release = $0; heldWaiter?.resume(); heldWaiter = nil }
    }
    func userTicket(scope: String, clientID: String) async throws -> XboxTicket {
        calls.append("user \(clientID) \(scope)")
        await gate()
        guard state == .signedIn else { throw XboxSessionError.signInRequired }
        return XboxTicket(token: Secret("t=synthetic-bridge-user&p="), expiresAt: Self.expiry)
    }
    func deviceTicket(scope: String, clientID: String, policy: String) async throws -> XboxTicket {
        calls.append("device \(clientID) \(scope) \(policy)")
        return XboxTicket(token: Secret("t=synthetic-bridge-device&p="), expiresAt: Self.expiry.addingTimeInterval(60))
    }
    func licenceToken(parentProductID: String, productIDs: [String], nonce: String) async throws -> Secret<String> {
        calls.append("licence \(parentProductID) \(productIDs.joined(separator: ",")) [\(nonce)]")
        if let licenceProblem { throw licenceProblem }
        return Secret(licenceTokenValue)
    }
    func onSignOut(_ action: @escaping @Sendable () -> Void) -> UInt64 {
        let id = UInt64(handlers.count + 1); handlers[id] = action; return id
    }
    func removeSignOutHandler(_ id: UInt64) { handlers[id] = nil }
    var handlerCount: Int { handlers.count }
}

struct XboxBridgeFakeUpdates: XboxPackageUpdates {
    let answer: XboxPackageUpdateCheck
    func check(productID: String, installedVersion: String) async -> XboxPackageUpdateCheck { answer }
}

final class XboxBridgeTests: XCTestCase, @unchecked Sendable {
    static let key = Array(String(repeating: "0f", count: 32).utf8)

    func frame(_ type: UInt16, _ xml: String) -> XboxBridgeFrame { XboxBridgeFrame(type: type, body: Array(xml.utf8)) }

    // MARK: the wire

    func testAFrameIsXodussHeaderAndBodyAndWaitsForItsWholeBytes() throws {
        let bytes = frame(3, "<MSATokenRequest/>").encoded
        // Magic 0x58445358, type and length, all little-endian, as xgameruntime writes them.
        XCTAssertEqual(Array(bytes.prefix(8)), [0x58, 0x53, 0x44, 0x58, 3, 0, 18, 0])
        var reader = XboxBridgeReader(key: Self.key)
        XCTAssertEqual(try reader.receive(Self.key + bytes.prefix(5)), [])
        XCTAssertEqual(try reader.receive(bytes.dropFirst(5).prefix(9)), [])
        let frames = try reader.receive(bytes.dropFirst(14) + frame(9, "<Request/>").encoded)
        XCTAssertEqual(frames, [frame(3, "<MSATokenRequest/>"), frame(9, "<Request/>")])
    }

    func testAFrameOverTheCapOrWithAnotherMagicEndsTheConnection() throws {
        // 64 KiB a frame, header included: the largest body is 65,528 bytes.
        var reader = XboxBridgeReader(key: Self.key)
        let largest = XboxBridgeFrame(type: 5, body: [UInt8](repeating: 0x41, count: XboxBridgeFrame.maxBody))
        XCTAssertEqual(largest.encoded.count, 64 * 1024)
        XCTAssertEqual(try reader.receive(Self.key + largest.encoded), [largest])
        XCTAssertThrowsError(try reader.receive([0x58, 0x53, 0x44, 0x58, 5, 0, 0xF9, 0xFF])) {
            XCTAssertEqual($0 as? XboxBridgeWireError, .oversized)
        }
        var other = XboxBridgeReader(key: Self.key)
        XCTAssertThrowsError(try other.receive(Self.key + [0x58, 0x53, 0x44, 0x59, 3, 0, 0, 0])) {
            XCTAssertEqual($0 as? XboxBridgeWireError, .badMagic)
        }
    }

    func testAConnectionWithoutThePlaysKeyOrWithAnotherIsRefusedBeforeAnyFrame() throws {
        // Missing: the runtime's frame arrives first.
        var missing = XboxBridgeReader(key: Self.key)
        let request = frame(3, "<MSATokenRequest><ClientId>000000004823914A</ClientId></MSATokenRequest>").encoded
        XCTAssertThrowsError(try missing.receive(request)) { XCTAssertEqual($0 as? XboxBridgeWireError, .wrongKey) }
        // Wrong: one character differs, sent in two pieces.
        var wrong = XboxBridgeReader(key: Self.key)
        var other = Self.key; other[63] = UInt8(ascii: "e")
        XCTAssertEqual(try wrong.receive(other.prefix(40)), [])
        XCTAssertFalse(wrong.authenticated)
        XCTAssertThrowsError(try wrong.receive(other.dropFirst(40) + request)) { XCTAssertEqual($0 as? XboxBridgeWireError, .wrongKey) }
        // A play's key is 64 random hex characters, new each time.
        let a = XboxBridgeService.newKey(), b = XboxBridgeService.newKey()
        XCTAssertEqual(a.value.count, 64)
        XCTAssertTrue(a.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(a.value, b.value)
    }

    // MARK: the service

    static let pilot = XboxBridgeCopy(productID: "9MW9469V91LM", relatedProductIDs: ["9NXQXXLFST89"], msaAppID: "000000004823914A")
    static let denied = "2147942405", invalid = "2147942487", fail = "2147500037"

    func service(_ account: XboxBridgeFakeAccount, copy: XboxBridgeCopy = pilot, updates: (any XboxPackageUpdates)? = nil,
                 lines: XboxLines = XboxLines()) -> XboxBridgeService {
        XboxBridgeService(copy: copy, account: account, updates: updates, log: lines.logger)
    }
    func msa(_ client: String, fullTrust: Bool = false) -> XboxBridgeFrame {
        frame(3, "<?xml version=\"1.0\"?>\n<MSATokenRequest><ClientId>\(client)</ClientId><AllowUi>true</AllowUi><MSAFullTrust>\(fullTrust)</MSAFullTrust></MSATokenRequest>\n")
    }
    func licence(parent: String = "9MW9469V91LM", _ ids: [String], nonce: String = "  nonce&lt;&amp;&gt;\u{e9}  ") -> XboxBridgeFrame {
        frame(5, "<StoreLicenseTokenRequest><ParentProductId>\(parent)</ParentProductId>" + ids.map { "<ProductId>\($0)</ProductId>" }.joined()
              + "<CustomDeveloperString>\(nonce)</CustomDeveloperString></StoreLicenseTokenRequest>")
    }
    func updates(_ product: String = "9MW9469V91LM", _ version: String = "1.5.12620.0") -> XboxBridgeFrame {
        frame(9, "<Request><ProductId>\(product)</ProductId><InstalledVersion>\(version)</InstalledVersion></Request>")
    }
    func ask(_ s: XboxBridgeService, _ request: XboxBridgeFrame, type: UInt16, file: StaticString = #filePath, line: UInt = #line) async throws -> XboxXML? {
        guard let frame = await s.handle(request) else { XCTFail("no reply", file: file, line: line); return nil }
        XCTAssertEqual(frame.type, type, file: file, line: line)
        return frame.body.isEmpty ? nil : try XboxXML.parse(frame.body)
    }

    func testTheTitlesClientIDGetsAUserAndADeviceTicket() async throws {
        let account = XboxBridgeFakeAccount(), s = service(account)
        let r1 = try await ask(s, msa("000000004823914A"), type: 4)
        let xml = r1
        XCTAssertEqual(xml?.local, "MSATokenResponse")
        XCTAssertEqual(xml?.value("Token"), "t=synthetic-bridge-user&p=")
        XCTAssertEqual(xml?.value("Expiry"), "1793400000")
        XCTAssertEqual(xml?.value("DeviceRps"), "t=synthetic-bridge-device&p=")
        XCTAssertEqual(xml?.value("DeviceExpiry"), "1793400060")
        // Xodus's exchange: the title's own TokenBroker ticket, and the device's for user.auth.
        let calls = await account.calls
        XCTAssertEqual(calls, ["user 000000004823914A scope=xboxlive.signin&api-version=2.0&clientid=000000004823914A",
                               "device {28C08266-F973-4AE6-FFE4-409B249F138F} scope=service::user.auth.xboxlive.com::MBI_SSL TOKEN_BROKER"])
    }

    func testOnlyTheCopysClientIDIsServedAndXboxsPlatformIDOnlyForACopyWithoutOne() async throws {
        let account = XboxBridgeFakeAccount(), s = service(account)
        let r2 = try await ask(s, msa(XboxBridgeService.platformClientID), type: 4)
        XCTAssertNil(r2, "refused: empty, as Xodus's failure")
        let r3 = try await ask(s, msa("0000000048239999"), type: 4)
        XCTAssertNil(r3)
        let r4 = try await ask(s, msa("000000004823914A", fullTrust: true), type: 4)
        XCTAssertNil(r4, "full trust the copy does not declare")
        let none = await account.calls
        XCTAssertEqual(none, [])

        let bare = XboxBridgeCopy(productID: "9MW9469V91LM", relatedProductIDs: [], msaAppID: nil)
        let platform = service(account, copy: bare)
        let r5 = try await ask(platform, msa("0000000040159362"), type: 4)
        XCTAssertEqual(r5?.value("Token"), "t=synthetic-bridge-user&p=")
        let r6 = try await ask(platform, msa("000000004823914A"), type: 4)
        XCTAssertNil(r6)
        let trusted = service(account, copy: XboxBridgeCopy(productID: "9MW9469V91LM", relatedProductIDs: [], msaAppID: "000000004823914A", msaFullTrust: true))
        let r7 = try await ask(trusted, msa("000000004823914a", fullTrust: true), type: 4)
        XCTAssertNotNil(r7)
        let calls = await account.calls.filter { $0.hasPrefix("user") }
        XCTAssertEqual(calls, ["user 0000000040159362 scope=xboxlive.signin&api-version=2.0&clientid=0000000040159362",
                               "user 000000004823914A scope=service::user.auth.xboxlive.com::MBI_SSL&api-version=2.0&clientid=000000004823914A"])
    }

    func testTheLicenceTokenIsForTheCopysProductAndItsDeclaredRelatedProductsOnly() async throws {
        let account = XboxBridgeFakeAccount(), s = service(account)
        let r8 = try await ask(s, licence(["9MW9469V91LM", "9nxqxxlfst89/0010"]), type: 6)
        let granted = r8
        XCTAssertEqual(granted?.local, "StoreLicenseTokenResponse")
        XCTAssertEqual(granted?.value("Hresult"), "0")
        XCTAssertEqual(granted?.value("Token"), "synthetic-licence-token")
        var calls = await account.calls
        XCTAssertEqual(calls, ["licence 9MW9469V91LM 9MW9469V91LM,9nxqxxlfst89/0010 [  nonce<&>\u{e9}  ]"], "ids and nonce as sent")

        for refused in [licence(["9MW9469V91LM", "9WZDNCRFJ3TJ"]), licence(parent: "9WZDNCRFJ3TJ", ["9MW9469V91LM"])] {
            let r9 = try await ask(s, refused, type: 6)
            let xml = r9
            XCTAssertEqual(xml?.value("Hresult"), Self.denied)
            XCTAssertEqual(xml?.value("Token"), "")
        }
        for malformed in [licence(["9MW9469V91LM"], nonce: ""), licence([]), licence(["9MW9469V91LM/001"]), frame(5, "<StoreLicenseTokenRequest>")] {
            let r10 = try await ask(s, malformed, type: 6)
            XCTAssertEqual(r10?.value("Hresult"), Self.invalid)
        }
        calls = await account.calls
        XCTAssertEqual(calls.count, 1, "nothing minted for a refused request")

        await account.setLicence(problem: .rejected(403))
        let r11 = try await ask(s, licence(["9MW9469V91LM"]), type: 6)
        XCTAssertEqual(r11?.value("Hresult"), Self.denied)
        await account.setLicence(problem: .network)
        let r12 = try await ask(s, licence(["9MW9469V91LM"]), type: 6)
        XCTAssertEqual(r12?.value("Hresult"), Self.fail)
        // A reply over the 64 KiB cap is never sent.
        await account.setLicence(problem: nil, token: String(repeating: "A", count: XboxBridgeFrame.maxBody))
        let r13 = try await ask(s, licence(["9MW9469V91LM"]), type: 6)
        let big = r13
        XCTAssertEqual(big?.value("Hresult"), Self.fail)
    }

    func testPackageUpdateQueriesAreAnsweredForTheCopyOnly() async throws {
        let account = XboxBridgeFakeAccount()
        let current = service(account, updates: XboxBridgeFakeUpdates(answer: .current(latest: "1.5.12620.0")))
        let r14 = try await ask(current, updates(), type: 10)
        let xml = r14
        XCTAssertEqual(xml?.value("HResult"), "0")
        XCTAssertEqual(xml?.value("Checked"), "true")
        XCTAssertEqual(xml?.value("Count"), "0")
        XCTAssertEqual(xml?.value("LatestVersion"), "1.5.12620.0")
        let r15 = try await ask(current, updates("9WZDNCRFJ3TJ"), type: 10)
        let other = r15
        XCTAssertEqual(other?.value("HResult"), Self.denied)
        XCTAssertEqual(other?.value("Checked"), "false")
        let r16 = try await ask(current, updates("9MW9469V91LM", "1.5"), type: 10)
        XCTAssertEqual(r16?.value("HResult"), Self.invalid)

        let newer = service(account, updates: XboxBridgeFakeUpdates(answer: .available(latest: "1.6.0.0")))
        let r17 = try await ask(newer, updates(), type: 10)
        let available = r17
        XCTAssertEqual(available?.value("HResult"), "2147500033", "Nexus's unsupported: no update is installed from the game")
        XCTAssertEqual(available?.value("Checked"), "false")
        XCTAssertEqual(available?.value("LatestVersion"), "1.6.0.0")
        // Unknown is never an empty success.
        for s in [service(account), service(account, updates: XboxBridgeFakeUpdates(answer: .unknown))] {
            let r18 = try await ask(s, updates(), type: 10)
            let unknown = r18
            XCTAssertEqual(unknown?.value("HResult"), Self.fail)
            XCTAssertEqual(unknown?.value("Checked"), "false")
        }
    }

    func testEveryRequestBeforeSignInAndEveryUnservedTypeIsRefused() async throws {
        let account = XboxBridgeFakeAccount(), s = service(account, updates: XboxBridgeFakeUpdates(answer: .current(latest: "1.5.12620.0")))
        await account.setState(.signedOut)
        let r19 = try await ask(s, msa("000000004823914A"), type: 4)
        XCTAssertNil(r19)
        let r20 = try await ask(s, licence(["9MW9469V91LM"]), type: 6)
        XCTAssertEqual(r20?.value("Hresult"), Self.denied)
        let r21 = try await ask(s, updates(), type: 10)
        XCTAssertEqual(r21?.value("HResult"), Self.denied)
        let calls = await account.calls
        XCTAssertEqual(calls, [])
        await account.setState(.signedIn)
        let r22 = try await ask(s, frame(1, "<Ping/>"), type: 2)
        XCTAssertNil(r22, "PING is not served")
        let r23 = try await ask(s, frame(7, "<Request/>"), type: 8)
        XCTAssertNil(r23)
        let last = await s.handle(frame(.max, ""))
        XCTAssertNil(last, "no reply type: the connection ends")
    }

    func testTicketsStayOutOfTheLogWhichNamesEachRequestAndReply() async throws {
        let account = XboxBridgeFakeAccount(), lines = XboxLines()
        let s = service(account, updates: XboxBridgeFakeUpdates(answer: .current(latest: "1.5.12620.0")), lines: lines)
        _ = await s.handle(msa("000000004823914A"))
        _ = await s.handle(licence(["9MW9469V91LM"]))
        _ = await s.handle(licence(["9WZDNCRFJ3TJ"]))
        _ = await s.handle(updates())
        let text = lines.text
        for secret in ["synthetic-bridge-user", "synthetic-bridge-device", "synthetic-licence-token", "nonce", s.key.value] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("MSA_TOKEN_REQUEST (152 bytes) -> MSA_TOKEN_RESPONSE served"), text)
        XCTAssertTrue(text.contains("STORE_LICENSE_TOKEN_RESPONSE refused: another product"), text)
        XCTAssertTrue(text.contains("STORE_PACKAGE_UPDATES_RESPONSE served"), text)
    }

    func testSignOutEndsTheServiceAndATicketMintedDuringItIsNeverSent() async throws {
        let account = XboxBridgeFakeAccount(), s = service(account)
        let id = await account.onSignOut { s.revoke() }
        await account.hold()
        let pending = Task { await s.handle(self.msa("000000004823914A")) }
        await account.waitUntilHeld()
        await account.signOut()
        let late = await pending.value
        XCTAssertNil(late, "no reply: the connection ends")
        XCTAssertTrue(s.revoked)
        await account.setState(.signedIn)
        let after = await s.handle(msa("000000004823914A"))
        XCTAssertNil(after, "a revoked service answers nothing, even signed in again")
        await account.removeSignOutHandler(id)
    }

    // MARK: the session's licence token

    func signedInForLicensing(_ http: XboxLicensingHTTP, log: Logger = .silent) async throws -> XboxSession {
        let session = XboxSession(store: MemorySecretStore(), http: http, log: log, now: { Date(timeIntervalSince1970: 1_793_318_400) })
        _ = try await session.prepareSignIn()
        guard case .signedIn = try await session.signIn(xboxSignInToken()) else { throw ClientError.noCredentials }
        try await http.tickets.reply("renew", "store-ticket.xml")
        return session
    }

    func testTheLicenceTokenIsNexussRequestWithTheStoreTickets() async throws {
        let http = XboxLicensingHTTP(), lines = XboxLines(), session = try await signedInForLicensing(http, log: lines.logger)
        await http.answer(body: Array(#"{"licenseToken":"synthetic-licence-token"}"#.utf8))
        let token = try await session.licenceToken(parentProductID: "9MW9469V91LM", productIDs: ["9MW9469V91LM", "9NXQXXLFST89/0010"], nonce: "nonce<&>")
        XCTAssertEqual(token.value, "synthetic-licence-token")
        let requests = await http.requests
        let sent = try XCTUnwrap(requests.last)
        XCTAssertEqual(sent.url.absoluteString, "https://licensing.mp.microsoft.com/v8.0/licenseToken")
        XCTAssertEqual(sent.headers["from"]?.value, "XboxLicenseManager")
        XCTAssertEqual(sent.headers["User-Agent"]?.value, "XboxGameRuntime")
        XCTAssertEqual(sent.headers["Authorization"]?.value.isEmpty, false, "the device's Store ticket")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent.body.value)) as? [String: Any])
        XCTAssertEqual(json["parentProductId"] as? String, "9MW9469V91LM")
        XCTAssertEqual(json["relatedProductIds"] as? [String], ["9MW9469V91LM", "9NXQXXLFST89/0010"])
        XCTAssertEqual(json["customDeveloperString"] as? String, "nonce<&>")
        XCTAssertEqual(json["enforceSellableBy"] as? Bool, true)
        let user = try XCTUnwrap((json["beneficiaries"] as? [[String: String]])?.first)
        XCTAssertEqual(user["identityType"], "Msa")
        XCTAssertEqual(user["identityValue"], "t=synthetic-store-ticket&p=")
        XCTAssertEqual(user["localTicketReference"]?.isEmpty, false, "the account's PUID")

        await http.answer(body: Array("{}".utf8), status: 403)
        do { _ = try await session.licenceToken(parentProductID: "9MW9469V91LM", productIDs: ["9MW9469V91LM"], nonce: "n"); XCTFail("403 gave a token") }
        catch { XCTAssertEqual(error as? XboxLicenceProblem, .rejected(403)) }
        await http.answer(body: Array(#"{"licenseToken":""}"#.utf8))
        do { _ = try await session.licenceToken(parentProductID: "9MW9469V91LM", productIDs: ["9MW9469V91LM"], nonce: "n"); XCTFail("empty token") }
        catch { XCTAssertEqual(error as? XboxLicenceProblem, .invalidResponse) }
        await http.setOffline(true)
        do { _ = try await session.licenceToken(parentProductID: "9MW9469V91LM", productIDs: ["9MW9469V91LM"], nonce: "n"); XCTFail("offline") }
        catch { XCTAssertEqual(error as? XboxLicenceProblem, .network) }
        XCTAssertFalse(lines.text.contains("synthetic-"), lines.text)
    }

    // MARK: the socket

    func dial(_ port: UInt16) -> Int32? {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(fd); return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }
    func put(_ fd: Int32, _ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } }
    /// One reply frame, or nil when the bridge closed the connection.
    func answer(_ fd: Int32) -> XboxBridgeFrame? {
        var got: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if got.count >= 8 {
                let length = Int(got[6]) | Int(got[7]) << 8
                if got.count >= 8 + length { return XboxBridgeFrame(type: UInt16(got[4]) | UInt16(got[5]) << 8, body: Array(got[8..<(8 + length)])) }
            }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return nil }
            got += chunk[0..<n]
        }
    }
    func closed(_ fd: Int32) -> Bool {
        var b = [UInt8](repeating: 0, count: 16)
        return b.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) } == 0
    }

    func testTheSocketAnswersAKeyedFrameSplitAcrossWritesAndEndsAnOversizedOne() async throws {
        let account = XboxBridgeFakeAccount(), s = service(account)
        let listener = XboxBridgeListener(service: s, log: .silent)
        try await listener.start()
        defer { listener.stop() }
        let port = listener.port
        XCTAssertNotEqual(port, 0)
        let env = listener.guestEnvironment
        XCTAssertEqual(env["XODUS_BRIDGE_PORT"]?.value, String(port))
        XCTAssertEqual(env["XODUS_BRIDGE_KEY"]?.value, s.key.value)
        let key = Array(s.key.value.utf8)

        let fd = try XCTUnwrap(dial(port))
        defer { close(fd) }
        let bytes = key + msa("000000004823914A").encoded
        put(fd, Array(bytes.prefix(70)))  // the key and part of the header
        usleep(50_000)
        put(fd, Array(bytes.dropFirst(70)))
        let reply = try XCTUnwrap(answer(fd))
        XCTAssertEqual(reply.type, 4)
        XCTAssertEqual(try XboxXML.parse(reply.body).value("Token"), "t=synthetic-bridge-user&p=")

        let big = try XCTUnwrap(dial(port))
        defer { close(big) }
        put(big, key + [0x58, 0x53, 0x44, 0x58, 5, 0, 0xF9, 0xFF] + [UInt8](repeating: 0x41, count: 1024))
        XCTAssertTrue(closed(big), "an oversized frame ends the connection")

        let wrong = try XCTUnwrap(dial(port))
        defer { close(wrong) }
        put(wrong, Array(String(repeating: "0", count: 64).utf8) + msa("000000004823914A").encoded)
        XCTAssertTrue(closed(wrong), "the wrong key ends the connection")
        let calls = await account.calls.filter { $0.hasPrefix("user") }
        XCTAssertEqual(calls.count, 1)
    }

    func testSignOutClosesTheChannelAndTheHostKeepsNoTicketItIssued() async throws {
        let store = MemorySecretStore(), http = XboxFixtureHTTP(), lines = XboxLines()
        let session = XboxSession(store: store, http: http, log: lines.logger, now: { Date(timeIntervalSince1970: 1_793_318_400) })
        _ = try await session.prepareSignIn()
        guard case .signedIn = try await session.signIn(xboxSignInToken()) else { return XCTFail("sign-in not finished") }
        try await http.reply("renew", "game-ticket.xml")
        let s = XboxBridgeService(copy: Self.pilot, account: session, updates: nil, log: lines.logger)
        let listener = XboxBridgeListener(service: s, log: lines.logger)
        try await listener.start()
        defer { listener.stop() }
        let port = listener.port, key = Array(s.key.value.utf8)

        let game = try XCTUnwrap(dial(port))
        defer { close(game) }
        put(game, key + msa("000000004823914A").encoded)
        let tickets = try XboxXML.parse(try XCTUnwrap(answer(game)).body)
        XCTAssertEqual(tickets.value("Token"), "t=synthetic-game-ticket&p=")
        XCTAssertEqual(tickets.value("DeviceRps")?.isEmpty, false)
        let open = try XCTUnwrap(dial(port))
        defer { close(open) }
        put(open, key)

        try await session.signOut()
        XCTAssertTrue(closed(game) && closed(open), "every connection is closed")
        XCTAssertTrue(s.revoked)
        usleep(400_000)  // the accept thread closes the port within a quarter second
        if let late = dial(port) {
            defer { close(late) }
            put(late, key + msa("000000004823914A").encoded)
            XCTAssertNil(answer(late), "nothing is answered after sign-out")
        }
        // The host holds no ticket it issued: the session's are deleted and none is minted again.
        XCTAssertNil(try store.read("session")); XCTAssertNil(try store.read("device-token"))
        do { _ = try await session.userTicket(scope: "scope=xboxlive.signin&api-version=2.0&clientid=000000004823914A", clientID: "000000004823914A"); XCTFail("a ticket after sign-out") }
        catch { XCTAssertEqual(error as? XboxSessionError, .signInRequired) }
        XCTAssertFalse(lines.text.contains("synthetic-"), lines.text)
        XCTAssertFalse(lines.text.contains(s.key.value))
        XCTAssertTrue(lines.text.contains("bridge: signed out; the channel is closed"))
    }
}
