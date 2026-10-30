// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b assets/xodus-offline-license.patch
// and xodus-offline-license-revocation.patch (xodus-cli commands/offline_pc.rs) and
// src/renderer/OfflinePermissions.tsx (the confirmation); translated to Swift by the
// Playport authors, 2026-10-30. Modified: injected HTTP and signer, no CLI hop; the
// designation and every licence stored before a change are the session's Keychain
// items, deleted at sign-out.
import Foundation
import ContentKit

/// Whether this app's synthetic device is the account's offline device, as Microsoft's
/// PC Game App Front Door (`beige.xboxservices.com/pcgafd/config/offlinepc`) answers,
/// with how many changes Microsoft still allows.
public struct XboxOfflineDevice: Sendable, Equatable {
    /// Microsoft names this device the account's offline device.
    public let isThisDevice: Bool
    /// Changes left in the current period, the most per period and the period's length.
    public let changesLeft: Int?
    public let changesPerPeriod: Int?
    public let periodDays: Int?
    /// When Microsoft next allows a change; nil for its "no date" (1601-01-01).
    public let nextChangeAt: Date?
    /// Microsoft's `requestData.success`: a change it applied, when the request made one.
    let accepted: Bool

    static let endpoint = URL(string: "https://beige.xboxservices.com/pcgafd/config/offlinepc")!
    static let relyingParty = "http://mp.microsoft.com/"

    /// The recorded response (PLA-487): `offlinePermissions.enabled` and its `requestData`.
    /// Only `enabled` is required; a request field of another type, a count above 10 000
    /// and a pre-1970 date read as unknown.
    static func parse(_ bytes: [UInt8]) throws -> XboxOfflineDevice {
        struct Request: Decodable {
            let success: Bool?, most: Int?, left: Int?, days: Int?, next: String?
            enum Keys: String, CodingKey {
                case success, maxTogglesPerPeriod, remainingTogglesForPeriod, periodLengthDays, nextTimeToAdd
            }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                success = try? c.decode(Bool.self, forKey: .success)
                most = try? c.decode(Int.self, forKey: .maxTogglesPerPeriod)
                left = try? c.decode(Int.self, forKey: .remainingTogglesForPeriod)
                days = try? c.decode(Int.self, forKey: .periodLengthDays)
                next = try? c.decode(String.self, forKey: .nextTimeToAdd)
            }
        }
        struct Reply: Decodable {
            struct Permissions: Decodable { let enabled: Bool; let requestData: Request? }
            let offlinePermissions: Permissions
        }
        guard bytes.count <= 64 * 1024, let reply = try? JSONDecoder().decode(Reply.self, from: Data(bytes)) else {
            throw ClientError.protocolChanged("Xbox offline device answer has an unexpected shape")
        }
        let request = reply.offlinePermissions.requestData
        func count(_ n: Int?) -> Int? { n.flatMap { (0...10_000).contains($0) ? $0 : nil } }
        let next = request?.next.flatMap(XboxLicensing.date).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        return XboxOfflineDevice(isThisDevice: reply.offlinePermissions.enabled, changesLeft: count(request?.left),
                                 changesPerPeriod: count(request?.most), periodDays: count(request?.days),
                                 nextChangeAt: next, accepted: request?.success == true)
    }

    /// The confirmation before a change: Microsoft's one offline device per account, that
    /// turning it on replaces the current one, and the changes this uses up.
    public static func confirmation(turningOn: Bool, status: XboxOfflineDevice?) -> (title: String, note: String, confirm: String) {
        var limit = "Microsoft allows only a few changes a year."
        if let status, let most = status.changesPerPeriod {
            let period = status.periodDays.map { $0 == 365 ? "a year" : "every \($0) days" } ?? "a year"
            limit = "Microsoft allows \(most) changes \(period)" + (status.changesLeft.map { "; \($0) left." } ?? ".")
        }
        if turningOn {
            return ("Make this phone your offline device?",
                    "Microsoft allows one offline device per Xbox account. This phone replaces your current offline device, "
                    + "which can then no longer play offline. \(limit) Then play each game once online on this phone; "
                    + "it can start without a connection while its licence's offline lease lasts (up to 30 days).",
                    "Make offline device")
        }
        return ("Stop using this phone offline?",
                "Games on this phone will need a connection to start. This uses one of your changes: \(limit)",
                "Turn off")
    }
}

/// Microsoft read the request but changed nothing (no changes left, or another refusal).
public struct XboxOfflineDeviceNotChanged: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: XboxOfflineDevice
    public var description: String {
        guard status.changesLeft == 0 else { return "Microsoft didn't change your offline device. Try again later." }
        let next = status.nextChangeAt.map { " The next change is possible on \(XboxOfflineRefusal.day($0))." } ?? ""
        return "Microsoft didn't change your offline device: no changes are left this year.\(next)"
    }
}

/// What this session last learned from Microsoft: whether this device is the offline
/// device, and since when. Only licences stored at or after `since` start offline.
struct XboxOfflineDesignation: Codable {
    let designated: Bool
    let since: Date
}

extension XboxSession {
    /// The setting's state: true only after Microsoft confirmed this device as the
    /// account's offline device to this session. Off by default and after sign-out.
    public var isOfflineDevice: Bool { ((try? read(XboxOfflineDesignation.self, "offline-device")) ?? nil)?.designated ?? false }

    /// Reads Microsoft's answer. "Not this device" ends offline play here: the stored
    /// licences are deleted (Nexus's revocation when another device took over).
    public func offlineDevice() async throws -> XboxOfflineDevice {
        try await offlineDevice(set: nil, signer: XboxProofKey())
    }
    /// Makes this device the account's offline device, or stops it being one. Either
    /// change starts over, as the Xbox app does: no licence stored before it starts a
    /// game offline. Throws `XboxOfflineDeviceNotChanged` when Microsoft applies nothing.
    public func setOfflineDevice(_ on: Bool) async throws -> XboxOfflineDevice {
        try await offlineDevice(set: on, signer: XboxProofKey())
    }

    func offlineDevice(set: Bool?, signer: any XboxLiveSigner) async throws -> XboxOfflineDevice {
        let epoch = generation
        let device = try await deviceTicket()
        let user = try await userTicket(scope: XboxLiveDevice.userScope, clientID: XboxSignIn.clientID)
        try check(epoch)
        let xsts = try await XboxLiveDevice.xsts(http, signer: signer, device: device, user: user,
                                                 relyingParty: XboxOfflineDevice.relyingParty, now: now())
        try check(epoch)
        let url = set.map { XboxOfflineDevice.endpoint.appendingPathComponent($0 ? "true" : "false") } ?? XboxOfflineDevice.endpoint
        let response = try await XboxLive.send(http, XboxHTTPRequest(url: url, method: set == nil ? "GET" : "POST", headers: [
            "Authorization": Secret("XBL3.0 x=\(xsts.userHash.value);\(xsts.token.value)"), "Accept": Secret("application/json"),
            "Accept-Language": Secret("en-US"), "X-MS-API-Version": Secret("1.0"), "x-xbl-contract-version": Secret("1"),
            "MS-CV": Secret(XboxLicensing.correlationVector())], body: Secret([])))
        try check(epoch)
        if response.status == 401 || response.status == 403 { throw XboxSessionError.signInRequired }
        guard (200..<300).contains(response.status) else { throw ClientError.transport("Xbox offline device returned HTTP \(response.status)") }
        let status = try XboxOfflineDevice.parse(response.body.value)
        let applied = set != nil && status.accepted && status.isThisDevice == set
        let previous = try read(XboxOfflineDesignation.self, "offline-device")
        if applied || previous?.designated != status.isThisDevice {
            try write(XboxOfflineDesignation(designated: status.isThisDevice, since: now()), "offline-device")
        }
        if applied || !status.isThisDevice { try write([String: XboxStoredLicence](), "licences") }
        log.info("xbox", "offline device: " + (status.isThisDevice ? "this device" : "not this device")
                 + (set == nil ? "" : applied ? " (changed)" : " (Microsoft changed nothing)")
                 + (status.changesLeft.map { "; \($0) change(s) left" } ?? ""))
        if set != nil, !applied { throw XboxOfflineDeviceNotChanged(status: status) }
        return status
    }
}
