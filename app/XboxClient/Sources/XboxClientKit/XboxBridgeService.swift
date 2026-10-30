// SPDX-License-Identifier: GPL-3.0-only
// Xodus 53ea781dcd073e31d7ea68e894134e9c959bff04 crates/xodus-service/src/connection/
// xml.rs (MSA_TOKEN_REQUEST), and Xodus Nexus e0668a12f1da931aed13537ef04295599011317b's
// xodus-store-license, xodus-license-sku and xodus-store-updates patches
// (store_license.rs, store_updates.rs) and the xgameruntime patches that send them;
// translated to Swift by the Playport authors, 2026-10-30. Modified: bound to the
// playing copy's client ID, Product ID and related products; refused before
// sign-in; ended by sign-out; the package update check is injected.
import Foundation
import ContentKit

/// What the bridge serves one play: the copy's Product ID (Store ID), the related
/// products and `MSAAppId` its MicrosoftGame.config declares, read by the host from
/// the copy's folder at launch (0167).
public struct XboxBridgeCopy: Sendable {
    public let productID: String
    public let relatedProductIDs: [String]
    public let msaAppID: String?
    public let msaFullTrust: Bool
    public init(productID: String, relatedProductIDs: [String], msaAppID: String?, msaFullTrust: Bool = false) {
        self.productID = productID; self.relatedProductIDs = relatedProductIDs
        self.msaAppID = msaAppID; self.msaFullTrust = msaFullTrust
    }
}

/// The account side of the bridge. `XboxSession` is the real one.
public protocol XboxBridgeAccount: AnyObject, Sendable {
    var state: XboxSessionState { get async }
    func userTicket(scope: String, clientID: String) async throws -> XboxTicket
    func deviceTicket(scope: String, clientID: String, policy: String) async throws -> XboxTicket
    /// Throws `XboxLicenceProblem` when Microsoft gives no token.
    func licenceToken(parentProductID: String, productIDs: [String], nonce: String) async throws -> Secret<String>
    func onSignOut(_ action: @escaping @Sendable () -> Void) async -> UInt64
    func removeSignOutHandler(_ id: UInt64) async
}

extension XboxSession: XboxBridgeAccount {}

/// An installed copy's version against the Store's latest package.
public enum XboxPackageUpdateCheck: Sendable, Equatable {
    case current(latest: String)
    case available(latest: String)
    /// Not checked, or the answer could not be verified.
    case unknown
}

public protocol XboxPackageUpdates: Sendable {
    func check(productID: String, installedVersion: String) async -> XboxPackageUpdateCheck
}

/// Answers one play's runtime (decision 0167). Each request is bound to the copy:
/// tickets only for its client ID (or Xbox's platform client ID when it has none),
/// the licence token only for its Product ID and declared related products, update
/// queries only for its package. Before sign-in everything is refused; after
/// `revoke()` (sign-out) nothing is answered and a reply minted meanwhile is dropped.
/// Logs name each request and reply with sizes and status, never a payload.
public actor XboxBridgeService {
    /// The runtime's MSA client ID for a title without an MSAAppId
    /// (xgameruntime's `platform_client_id`).
    public static let platformClientID = "0000000040159362"
    /// The device ticket Xodus mints for every MSA_TOKEN_REQUEST.
    static let deviceApp = "{28C08266-F973-4AE6-FFE4-409B249F138F}"
    static let deviceScope = "scope=service::user.auth.xboxlive.com::MBI_SSL"
    // HRESULTs Xodus Nexus answers with.
    static let fail: UInt32 = 0x8000_4005, invalid: UInt32 = 0x8007_0057
    static let denied: UInt32 = 0x8007_0005, unsupported: UInt32 = 0x8000_4001

    /// The play's key: 64 random hex characters the runtime sends first.
    public nonisolated let key: Secret<String>
    nonisolated let account: any XboxBridgeAccount
    private let copy: XboxBridgeCopy
    private let updates: (any XboxPackageUpdates)?
    private let log: Logger
    private nonisolated let fence = Fence()
    private(set) var served = 0, refused = 0

    public init(copy: XboxBridgeCopy, account: any XboxBridgeAccount, updates: (any XboxPackageUpdates)?, log: Logger) {
        self.copy = copy; self.account = account; self.updates = updates; self.log = log
        key = Self.newKey()
    }

    static func newKey() -> Secret<String> {
        Secret(XboxCrypto.random(32).map { String(format: "%02x", $0) }.joined())
    }

    /// Sign-out: nothing more is answered, including a request in flight.
    public nonisolated func revoke() { fence.revoke() }
    public nonisolated var revoked: Bool { fence.revoked }

    var summary: String { "\(served) served, \(refused) refused" }

    /// The reply to one request, or nil to end the connection.
    func handle(_ frame: XboxBridgeFrame) async -> XboxBridgeFrame? {
        guard !revoked, frame.type < .max else { return nil }
        let reply = frame.type + 1
        var outcome: Outcome
        switch XboxBridgeMessage(rawValue: frame.type) {
        case .msaTokenRequest: outcome = await msaTickets(frame.body)
        case .storeLicenseTokenRequest: outcome = await licenceToken(frame.body)
        case .storePackageUpdatesRequest: outcome = await packageUpdates(frame.body)
        default: outcome = Outcome(body: [], status: "refused: not served")
        }
        guard !revoked else { return nil }
        if outcome.body.count > XboxBridgeFrame.maxBody {
            outcome = XboxBridgeMessage(rawValue: reply) == .storeLicenseTokenResponse
                ? Self.licenceReply(Self.fail, status: "refused: over 64 KiB") : Outcome(body: [], status: "refused: over 64 KiB")
        }
        if outcome.status == "served" { served += 1 } else { refused += 1 }
        log.info("xbox", "bridge: \(XboxBridgeMessage.name(frame.type)) (\(frame.body.count) bytes) -> "
                 + "\(XboxBridgeMessage.name(reply)) \(outcome.status) (\(outcome.body.count) bytes)")
        return XboxBridgeFrame(type: reply, body: outcome.body)
    }

    struct Outcome { let body: [UInt8]; let status: String }

    private var signedIn: Bool { get async { await account.state == .signedIn } }

    // MARK: MSA_TOKEN_REQUEST

    /// Xodus's MSATokenResponse: the title's user ticket and the device's, with
    /// their expiries in Unix seconds. A refusal is an empty body, as Xodus's.
    private func msaTickets(_ body: [UInt8]) async -> Outcome {
        guard await signedIn else { return Outcome(body: [], status: "refused: signed out") }
        guard let xml = try? XboxXML.parse(body), xml.local == "MSATokenRequest", let client = xml.value("ClientId") else {
            return Outcome(body: [], status: "refused: malformed")
        }
        let expected = copy.msaAppID ?? Self.platformClientID
        guard client.caseInsensitiveCompare(expected) == .orderedSame else { return Outcome(body: [], status: "refused: another client") }
        let fullTrust = xml.value("MSAFullTrust") == "true"
        guard !fullTrust || (copy.msaAppID != nil && copy.msaFullTrust) else {
            return Outcome(body: [], status: "refused: full trust not declared")
        }
        let scope = fullTrust ? "service::user.auth.xboxlive.com::MBI_SSL" : "xboxlive.signin"
        let user: XboxTicket, device: XboxTicket
        do {
            user = try await account.userTicket(scope: "scope=\(scope)&api-version=2.0&clientid=\(expected)", clientID: expected)
            device = try await account.deviceTicket(scope: Self.deviceScope, clientID: Self.deviceApp, policy: "TOKEN_BROKER")
        } catch {
            return Outcome(body: [], status: "refused: tickets unavailable")
        }
        return Outcome(body: Self.xml("MSATokenResponse", [
            ("Token", user.token.value), ("Expiry", String(Int64(user.expiresAt.timeIntervalSince1970))),
            ("DeviceRps", device.token.value), ("DeviceExpiry", String(Int64(device.expiresAt.timeIntervalSince1970))),
        ]), status: "served")
    }

    // MARK: STORE_LICENSE_TOKEN_REQUEST

    private func licenceToken(_ body: [UInt8]) async -> Outcome {
        guard await signedIn else { return Self.licenceReply(Self.denied, status: "refused: signed out") }
        guard let xml = try? XboxXML.parse(body), xml.local == "StoreLicenseTokenRequest",
              let parent = xml.child("ParentProductId")?.text, let nonce = xml.child("CustomDeveloperString")?.text else {
            return Self.licenceReply(Self.invalid, status: "refused: malformed")
        }
        let ids = xml.children.filter { $0.local == "ProductId" }.map(\.text)
        // Nexus's limits: plain IDs or a 12-character product with a 4-character SKU.
        guard Self.plainID(parent), (1...64).contains(ids.count), ids.allSatisfy(Self.productSelector),
              (1...4096).contains(nonce.utf8.count) else { return Self.licenceReply(Self.invalid, status: "refused: malformed") }
        let allowed = Set(([copy.productID] + copy.relatedProductIDs).map { $0.uppercased() })
        guard parent.caseInsensitiveCompare(copy.productID) == .orderedSame,
              ids.allSatisfy({ allowed.contains(String($0.split(separator: "/")[0]).uppercased()) }) else {
            return Self.licenceReply(Self.denied, status: "refused: another product")
        }
        do {
            let token = try await account.licenceToken(parentProductID: parent, productIDs: ids, nonce: nonce)
            guard !token.value.isEmpty else { return Self.licenceReply(Self.fail, status: "refused: no token") }
            return Outcome(body: Self.xml("StoreLicenseTokenResponse", [("Hresult", "0"), ("Token", token.value)]), status: "served")
        } catch let problem as XboxLicenceProblem {
            switch problem {
            case .session, .rejected(401), .rejected(403): return Self.licenceReply(Self.denied, status: "refused: \(Self.label(problem))")
            default: return Self.licenceReply(Self.fail, status: "refused: \(Self.label(problem))")
            }
        } catch {
            return Self.licenceReply(Self.fail, status: "refused: unavailable")
        }
    }

    static func licenceReply(_ hresult: UInt32, status: String) -> Outcome {
        Outcome(body: xml("StoreLicenseTokenResponse", [("Hresult", String(hresult)), ("Token", "")]), status: status)
    }
    private static func label(_ problem: XboxLicenceProblem) -> String {
        switch problem {
        case .network: "network"
        case .service(let status), .rejected(let status): "HTTP \(status)"
        case .invalidResponse: "invalid response"
        case .session: "signed out"
        case .connectionNeeded: "offline"
        }
    }
    static func plainID(_ id: String) -> Bool { (1...32).contains(id.utf8.count) && id.utf8.allSatisfy(isAlphanumeric) }
    static func productSelector(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return plainID(id)
        case 2: return parts[0].utf8.count == 12 && parts[1].utf8.count == 4 && plainID(String(parts[0])) && plainID(String(parts[1]))
        default: return false
        }
    }
    private static func isAlphanumeric(_ c: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c)
    }

    // MARK: STORE_PACKAGE_UPDATES_REQUEST

    /// Nexus's answer: `Checked` true and `Count` 0 only when the installed package
    /// is verified current; anything unknown fails, never an empty success.
    private func packageUpdates(_ body: [UInt8]) async -> Outcome {
        guard await signedIn else { return Self.updatesReply(Self.denied, stage: "sign-in", status: "refused: signed out") }
        guard let xml = try? XboxXML.parse(body), xml.local == "Request",
              let product = xml.value("ProductId"), product.utf8.count == 12, Self.plainID(product) else {
            return Self.updatesReply(Self.invalid, stage: "product-id", status: "refused: malformed")
        }
        guard let version = xml.value("InstalledVersion"), Self.version(version) else {
            return Self.updatesReply(Self.invalid, stage: "installed-version", status: "refused: malformed")
        }
        guard product.caseInsensitiveCompare(copy.productID) == .orderedSame else {
            return Self.updatesReply(Self.denied, stage: "product-id", status: "refused: another product")
        }
        switch await updates?.check(productID: copy.productID, installedVersion: version) ?? .unknown {
        case .current(let latest):
            return Self.updatesReply(0, checked: true, latest: latest, stage: "", status: "served")
        case .available(let latest):
            return Self.updatesReply(Self.unsupported, latest: latest, stage: "version-comparison", status: "served: update available")
        case .unknown:
            return Self.updatesReply(Self.fail, stage: "package-query", status: "refused: not checked")
        }
    }

    static func updatesReply(_ hresult: UInt32, checked: Bool = false, latest: String = "", stage: String, status: String) -> Outcome {
        // Nexus passes on only a plain version string.
        let safe = latest.utf8.count <= 80 && latest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".,_- ".contains($0)) }
        return Outcome(body: xml("Response", [("HResult", String(hresult)), ("Checked", checked ? "true" : "false"),
                                              ("LatestVersion", safe ? latest : ""), ("Count", "0"), ("ErrorStage", stage)]),
                       status: status)
    }
    /// Four dot-separated 16-bit numbers, as Nexus's `version`.
    static func version(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt16($0) != nil }
    }

    // MARK: XML

    /// The element-per-field form quick-xml writes for Xodus's structs.
    static func xml(_ root: String, _ fields: [(String, String)]) -> [UInt8] {
        var out = "<" + root + ">"
        for (name, value) in fields { out += "<\(name)>" + XboxXML.escape(value) + "</\(name)>" }
        return Array((out + "</" + root + ">").utf8)
    }

    final class Fence: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func revoke() { lock.withLock { value = true } }
        var revoked: Bool { lock.withLock { value } }
    }
}
