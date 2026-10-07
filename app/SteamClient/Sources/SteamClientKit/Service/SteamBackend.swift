// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What `SteamService` needs from a Steam session. `SteamSession` is the real
/// one; the unit tests drive the service through a fake that emits each
/// pairing state without a network or an account.
public protocol SteamBackend: Sendable {
    func storedSession() async throws -> StoredSession?
    func isLoggedOn() async -> (loggedOn: Bool, anonymous: Bool, connected: Bool)
    func connect(maxEndpoints: Int) async throws
    func disconnect() async
    func loginWithQR(deadline: TimeInterval, onEvent: @escaping @Sendable (QREvent) -> Void) async throws -> AccountSummary
    func loginWithCredentials(accountName: String, password: Secret<String>, codes: GuardCodeInbox, deadline: TimeInterval,
                              onEvent: @escaping @Sendable (CredentialEvent) -> Void) async throws -> AccountSummary
    func restore() async throws -> AccountSummary
    func logOnAnonymous() async throws -> AccountSummary
    func renewTokens() async throws -> Bool
    func awaitLicenses(timeout: Double) async throws -> [CMsgClientLicenseList.License]
    /// The apps the licenses grant (package -> app), sorted by app ID.
    func ownedAppIDs(licenses: [CMsgClientLicenseList.License]) async throws -> [UInt32]
    /// PICS app records for the given apps; absent ones are withheld by Steam.
    func appRecords(_ appIDs: [UInt32]) async throws -> [UInt32: KeyValue]
    /// The account's persona name, the one games are told (nil when Steam has none).
    func personaName() async throws -> String?
    /// A game's stats, achievements and schema for the account (UserStats.swift).
    func userStats(appID: UInt32) async throws -> UserStatsSnapshot
    /// Stores stat values (by stat ID) for the account.
    func storeUserStats(appID: UInt32, crc: UInt32, values: [UInt32: UInt32]) async throws -> CMsgClientStoreUserStatsResponse
    /// The app's Steam Cloud files for the account (Cloud.swift).
    func cloudChangelist(appID: UInt32) async throws -> CCloudGetAppFileChangelistResponse
    /// One cloud file's content, checked against Steam's SHA-1.
    func cloudDownload(appID: UInt32, name: String) async throws -> [UInt8]
    /// Uploads files in one batch; the names Steam committed.
    func cloudUpload(appID: UInt32, files: [(name: String, data: [UInt8], time: UInt64)]) async throws -> [String]
    /// The app's encrypted app ticket for the account (decision 0017), within `timeout` seconds.
    func encryptedAppTicket(appID: UInt32, timeout: Double) async throws -> Secret<[UInt8]>
    func logout(revoke: Bool) async throws -> LogoutReport
    /// The app's ownership ticket for the account (decision 0062), within `timeout` seconds.
    func appOwnershipTicket(appID: UInt32, timeout: Double) async throws -> Secret<[UInt8]>
    /// Sends the client's list of live tickets.
    func sendAuthList(_ list: CMsgClientAuthList) async throws
    /// The games the session is in (an empty list: none).
    func setGamesPlayed(_ appIDs: [UInt32]) async throws
    /// The current logon's game connect tokens, where ticket pushes go, and the CM's traffic.
    var connectTokens: GameConnectTokens { get }
    var ticketPushes: TicketPushRoute { get }
    var traffic: CMTraffic { get }
}

extension SteamSession: SteamBackend {
    public func isLoggedOn() async -> (loggedOn: Bool, anonymous: Bool, connected: Bool) {
        let connected = await cm?.isOpen ?? false
        if case let .loggedOn(anonymous) = state { return (true, anonymous, connected) }
        return (false, false, connected)
    }

    public func ownedAppIDs(licenses: [CMsgClientLicenseList.License]) async throws -> [UInt32] {
        try await Library(session: self).ownedAppIDs(packages: licenses.map { ($0.packageID, $0.accessToken) }).keys.sorted()
    }

    public func appRecords(_ appIDs: [UInt32]) async throws -> [UInt32: KeyValue] {
        try await Library(session: self).appRecords(appIDs)
    }

    public func personaName() async throws -> String? { try await personaName(timeout: 10) }

    public func userStats(appID: UInt32) async throws -> UserStatsSnapshot { try await userStats(appID: appID, timeout: 20) }

    public func storeUserStats(appID: UInt32, crc: UInt32, values: [UInt32: UInt32]) async throws -> CMsgClientStoreUserStatsResponse {
        try await storeUserStats(appID: appID, crc: crc, values: values, timeout: 20)
    }

    public func cloudChangelist(appID: UInt32) async throws -> CCloudGetAppFileChangelistResponse {
        try await cloudChangelist(appID: appID, timeout: 20)
    }

    public func cloudDownload(appID: UInt32, name: String) async throws -> [UInt8] {
        try await cloudDownload(appID: appID, name: name, timeout: 20)
    }

    public func cloudUpload(appID: UInt32, files: [(name: String, data: [UInt8], time: UInt64)]) async throws -> [String] {
        try await cloudUpload(appID: appID, files: files, timeout: 30)
    }
}
