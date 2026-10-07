// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Hand-pinned message schemas. Source of truth: JavaSteam commit
// 433f2ad15c36d5e690a4fe77401ec3f6b960641e in the joshuatam/JavaSteam fork,
// src/main/proto/in/dragonbra/javasteam/protobufs/steamclient/*.proto and
// src/main/steamd/in/dragonbra/javasteam/{emsg,steammsg}.steamd. The pin is by
// SHA in that fork: the commit is not on upstream Longi94/JavaSteam master.
// Only the fields this client reads or writes are pinned; each carries its
// proto field number, and this file is the pin list.
//
// The message names, field numbers and constants below are facts taken from
// JavaSteam (MIT License, Copyright (c) 2018 Long Tran); this transcription is
// Playport code under the licence above.

public enum PinnedSchema {
    public static let javaSteamCommit = "433f2ad15c36d5e690a4fe77401ec3f6b960641e"
    /// steammsg.steamd MsgClientLogon::CurrentProtocol.
    public static let protocolVersion: UInt32 = 65581
    /// Content manifest version the CDN serves (DepotManifest / cdn Client.kt).
    public static let manifestVersion = 5
}

/// emsg.steamd values this client sends or handles.
public enum EMsg: UInt32, Sendable {
    case multi = 1
    case destJobFailed = 113
    case serviceMethod = 146
    case serviceMethodResponse = 147
    case serviceMethodCallFromClient = 151
    case serviceMethodSendToClient = 152
    case clientHeartBeat = 703
    case clientLogOff = 706
    case clientGamesPlayed = 742
    case clientLogOnResponse = 751
    case clientLoggedOff = 757
    case clientPersonaState = 766
    case clientLicenseList = 780
    case clientRequestFriendData = 815
    case clientGetUserStats = 818
    case clientGetUserStatsResponse = 819
    case clientStoreUserStatsResponse = 821
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    case clientStoreUserStats2 = 5466
    case clientServerUnavailable = 5500
    case clientLogon = 5514
    case clientRequestEncryptedAppTicket = 5526
    case clientRequestEncryptedAppTicketResponse = 5527
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906
    case serviceMethodCallFromClientNonAuthed = 9804
    case clientHello = 9805
}

public protocol ProtoMessage: Sendable {
    func encode() -> [UInt8]
}

public protocol ProtoDecodable: Sendable {
    static var protoName: String { get }
    init(_ f: ProtoFields) throws
}

extension ProtoDecodable {
    public static func decode(_ bytes: [UInt8]) throws -> Self {
        try Self(ProtoFields(bytes, message: protoName))
    }
}

// MARK: - steammessages_base.proto

/// CMsgProtoBufHeader.
public struct ProtoHeader: ProtoMessage, ProtoDecodable {
    public static let protoName = "CMsgProtoBufHeader"
    public static let noJob: UInt64 = .max
    public var steamID: UInt64?            // 1 fixed64
    public var clientSessionID: Int32?     // 2 int32
    public var jobIDSource: UInt64?        // 10 fixed64
    public var jobIDTarget: UInt64?        // 11 fixed64
    public var targetJobName: String?      // 12 string
    public var eresult: Int32?             // 13 int32 (default 2)
    public var errorMessage: String?       // 14 string

    public init() {}

    public init(_ f: ProtoFields) throws {
        steamID = try f.fixed64(1)
        clientSessionID = try f.int32(2)
        jobIDSource = try f.fixed64(10)
        jobIDTarget = try f.fixed64(11)
        targetJobName = try f.string(12)
        eresult = try f.int32(13)
        errorMessage = try f.string(14)
    }

    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.fixed64(1, steamID)
        w.int32(2, clientSessionID)
        w.fixed64(10, jobIDSource)
        w.fixed64(11, jobIDTarget)
        w.string(12, targetJobName)
        return w.bytes
    }

    public var result: EResult { EResult(eresult ?? 2) }
}

/// CMsgMulti.
public struct CMsgMulti: ProtoDecodable {
    public static let protoName = "CMsgMulti"
    public var sizeUnzipped: UInt32   // 1
    public var messageBody: [UInt8]   // 2
    public init(_ f: ProtoFields) throws {
        sizeUnzipped = try f.uint32(1) ?? 0
        messageBody = try f.require(f.bytes(2), 2, "message_body")
    }
}

// MARK: - steammessages_clientserver_login.proto

/// CMsgClientHello.
public struct CMsgClientHello: ProtoMessage {
    public var protocolVersion = PinnedSchema.protocolVersion // 1
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.uint32(1, protocolVersion); return w.bytes }
}

/// CMsgClientHeartBeat.
public struct CMsgClientHeartBeat: ProtoMessage {
    public var sendReply = false // 1
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.bool(1, sendReply); return w.bytes }
}

/// CMsgClientLogOff (no fields).
public struct CMsgClientLogOff: ProtoMessage {
    public func encode() -> [UInt8] { [] }
}

/// CMsgClientLogon (the subset SteamUser.logOn / logOnAnonymous set).
public struct CMsgClientLogon: ProtoMessage {
    public var protocolVersion = PinnedSchema.protocolVersion // 1
    public var cellID: UInt32 = 0                             // 3
    public var clientPackageVersion: UInt32?                  // 5
    public var clientLanguage = "english"                     // 6
    public var clientOSType: UInt32 = 0                       // 7 (EOSType.WinUnknown = 0)
    public var shouldRememberPassword: Bool?                  // 8
    public var machineID: Secret<[UInt8]>?                    // 30 bytes
    public var accountName: String?                           // 50
    public var machineName: String?                           // 96
    public var supportsRateLimitResponse: Bool?               // 102
    public var accessToken: Secret<String>?                   // 108 (the refresh token)

    public init() {}

    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.uint32(1, protocolVersion)
        w.uint32(3, cellID)
        w.uint32(5, clientPackageVersion)
        w.string(6, clientLanguage)
        w.uint32(7, clientOSType)
        w.bool(8, shouldRememberPassword)
        w.bytes(30, machineID?.value)
        w.string(50, accountName)
        w.string(96, machineName)
        w.bool(102, supportsRateLimitResponse)
        w.string(108, accessToken?.value)
        return w.bytes
    }
}

/// CMsgClientLogonResponse.
public struct CMsgClientLogonResponse: ProtoDecodable {
    public static let protoName = "CMsgClientLogonResponse"
    public var eresult: EResult               // 1
    public var legacyHeartbeatSeconds: Int32? // 2
    public var heartbeatSeconds: Int32?       // 3
    public var cellID: UInt32?                // 7
    public var clientSuppliedSteamID: UInt64? // 20 fixed64
    public var tokenID: UInt64?               // 30
    public init(_ f: ProtoFields) throws {
        eresult = EResult(try f.int32(1) ?? 2)
        legacyHeartbeatSeconds = try f.int32(2)
        heartbeatSeconds = try f.int32(3)
        cellID = try f.uint32(7)
        clientSuppliedSteamID = try f.fixed64(20)
        tokenID = try f.uint64(30)
    }
}

/// CMsgClientLoggedOff.
public struct CMsgClientLoggedOff: ProtoDecodable {
    public static let protoName = "CMsgClientLoggedOff"
    public var eresult: EResult // 1
    public init(_ f: ProtoFields) throws { eresult = EResult(try f.int32(1) ?? 2) }
}

// MARK: - steammessages_clientserver.proto

/// CMsgClientLicenseList.
public struct CMsgClientLicenseList: ProtoDecodable {
    public static let protoName = "CMsgClientLicenseList"
    public struct License: Sendable, Equatable {
        public var packageID: UInt32      // 1
        public var timeCreated: UInt32?   // 2 fixed32
        public var licenseType: UInt32?   // 9
        public var flags: UInt32?         // 7
        public var accessToken: UInt64    // 17 (PICS package token; not a credential)
    }
    public var eresult: EResult   // 1
    public var licenses: [License] // 2
    public init(_ f: ProtoFields) throws {
        eresult = EResult(try f.int32(1) ?? 2)
        licenses = try f.messages(2, as: "CMsgClientLicenseList.License").map { l in
            License(packageID: try l.require(l.uint32(1), 1, "package_id"),
                    timeCreated: try l.fixed32(2), licenseType: try l.uint32(9),
                    flags: try l.uint32(7), accessToken: try l.uint64(17) ?? 0)
        }
    }
}

// MARK: - steammessages_clientserver_friends.proto

/// CMsgClientRequestFriendData: ask for the persona state of the given users.
public struct CMsgClientRequestFriendData: ProtoMessage {
    /// EClientPersonaStateFlag bits (enums.steamd): PlayerName.
    public static let flagPlayerName: UInt32 = 2
    public var personaStateRequested: UInt32 // 1
    public var friends: [UInt64]             // 2 repeated fixed64
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.uint32(1, personaStateRequested)
        friends.forEach { w.fixed64(2, $0) }
        return w.bytes
    }
}

/// CMsgClientPersonaState: the reply, one Friend per user asked about.
public struct CMsgClientPersonaState: ProtoDecodable {
    public static let protoName = "CMsgClientPersonaState"
    public struct Friend: Sendable, Equatable {
        public var friendID: UInt64     // 1 fixed64
        public var playerName: String?  // 15
    }
    public var friends: [Friend] // 2
    public init(_ f: ProtoFields) throws {
        friends = try f.messages(2, as: "CMsgClientPersonaState.Friend").map { m in
            Friend(friendID: try m.require(m.fixed64(1), 1, "friendid"), playerName: try m.string(15))
        }
    }
}

// MARK: - steammessages_clientserver_userstats.proto, steammessages_clientserver.proto

/// CMsgClientGetUserStats: a game's stat values and achievement unlock times
/// for one user, and its stats schema when the local version is older.
public struct CMsgClientGetUserStats: ProtoMessage {
    public var gameID: UInt64                // 1 fixed64
    public var crcStats: UInt32 = 0          // 2
    /// -1 asks for the schema whatever the version.
    public var schemaLocalVersion: Int32 = -1 // 3
    public var steamIDForUser: UInt64        // 4 fixed64
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.fixed64(1, gameID)
        w.uint32(2, crcStats)
        w.int32(3, schemaLocalVersion)
        w.fixed64(4, steamIDForUser)
        return w.bytes
    }
}

/// CMsgClientGetUserStatsResponse.
public struct CMsgClientGetUserStatsResponse: ProtoDecodable {
    public static let protoName = "CMsgClientGetUserStatsResponse"
    public var gameID: UInt64?                 // 1 fixed64
    public var eresult: EResult                // 2
    public var crcStats: UInt32?               // 3
    public var schema: [UInt8]?                // 4 binary KeyValues
    public var stats: [UInt32: UInt32]         // 5 {stat_id 1, stat_value 2}
    /// Per achievement block stat: the unlock time of each of its 32 bits (0 when locked).
    public var unlockTimes: [UInt32: [UInt32]] // 6 {achievement_id 1, repeated fixed32 unlock_time 2}
    public init(_ f: ProtoFields) throws {
        gameID = try f.fixed64(1)
        eresult = EResult(try f.int32(2) ?? 2)
        crcStats = try f.uint32(3)
        schema = try f.bytes(4)
        var stats: [UInt32: UInt32] = [:]
        for m in try f.messages(5, as: "CMsgClientGetUserStatsResponse.Stats") {
            stats[try m.require(m.uint32(1), 1, "stat_id")] = try m.uint32(2) ?? 0
        }
        self.stats = stats
        var times: [UInt32: [UInt32]] = [:]
        for m in try f.messages(6, as: "CMsgClientGetUserStatsResponse.Achievement_Blocks") {
            times[try m.require(m.uint32(1), 1, "achievement_id")] = try m.repeatedFixed32(2)
        }
        unlockTimes = times
    }
}

/// CMsgClientStoreUserStats2: new values for a user's stats (an achievement
/// block's value carries its unlocks as bits).
public struct CMsgClientStoreUserStats2: ProtoMessage {
    public var gameID: UInt64               // 1 fixed64
    public var settorSteamID: UInt64        // 2 fixed64
    public var setteeSteamID: UInt64        // 3 fixed64
    public var crcStats: UInt32             // 4
    public var explicitReset = false        // 5
    public var stats: [(id: UInt32, value: UInt32)] // 6 {stat_id 1, stat_value 2}
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.fixed64(1, gameID)
        w.fixed64(2, settorSteamID)
        w.fixed64(3, setteeSteamID)
        w.uint32(4, crcStats)
        if explicitReset { w.bool(5, true) }
        for s in stats {
            var m = ProtoWriter()
            m.uint32(1, s.id)
            m.uint32(2, s.value)
            w.bytes(6, m.bytes)
        }
        return w.bytes
    }
}

/// CMsgClientStoreUserStatsResponse.
public struct CMsgClientStoreUserStatsResponse: ProtoDecodable {
    public static let protoName = "CMsgClientStoreUserStatsResponse"
    public var gameID: UInt64?                 // 1 fixed64
    public var eresult: EResult                // 2
    public var crcStats: UInt32?               // 3
    /// Stats Steam refused, with the value it kept.
    public var failed: [UInt32: UInt32]        // 4 {stat_id 1, reverted_stat_value 2}
    public var outOfDate: Bool                 // 5
    public init(_ f: ProtoFields) throws {
        gameID = try f.fixed64(1)
        eresult = EResult(try f.int32(2) ?? 2)
        crcStats = try f.uint32(3)
        var failed: [UInt32: UInt32] = [:]
        for m in try f.messages(4, as: "CMsgClientStoreUserStatsResponse.Stats_Failed_Validation") {
            failed[try m.require(m.uint32(1), 1, "stat_id")] = try m.uint32(2) ?? 0
        }
        self.failed = failed
        outOfDate = try f.bool(5) ?? false
    }
}

/// CMsgClientGamesPlayed: which games the session is in (an empty list: none).
public struct CMsgClientGamesPlayed: ProtoMessage {
    public var gameIDs: [UInt64]            // 1 repeated GamePlayed {game_id 2 fixed64}
    /// EOSType, as at logon (Windows10 = 16).
    public var clientOSType: UInt32 = 16    // 2
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        for id in gameIDs {
            var m = ProtoWriter()
            m.fixed64(2, id)
            w.bytes(1, m.bytes)
        }
        w.uint32(2, clientOSType)
        return w.bytes
    }
}

// MARK: - steammessages_clientserver_appinfo.proto

/// CMsgClientPICSAccessTokenRequest.
public struct CMsgClientPICSAccessTokenRequest: ProtoMessage {
    public var packageIDs: [UInt32] = [] // 1
    public var appIDs: [UInt32] = []     // 2
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        packageIDs.forEach { w.uint32(1, $0) }
        appIDs.forEach { w.uint32(2, $0) }
        return w.bytes
    }
}

/// CMsgClientPICSAccessTokenResponse.
public struct CMsgClientPICSAccessTokenResponse: ProtoDecodable {
    public static let protoName = "CMsgClientPICSAccessTokenResponse"
    public var packageTokens: [UInt32: UInt64] // 1 {packageid 1, access_token 2}
    public var packageDenied: [UInt32]         // 2
    public var appTokens: [UInt32: UInt64]     // 3 {appid 1, access_token 2}
    public var appDenied: [UInt32]             // 4
    public init(_ f: ProtoFields) throws {
        func tokens(_ field: Int, _ name: String) throws -> [UInt32: UInt64] {
            var out: [UInt32: UInt64] = [:]
            for m in try f.messages(field, as: name) {
                out[try m.require(m.uint32(1), 1, "id")] = try m.uint64(2) ?? 0
            }
            return out
        }
        packageTokens = try tokens(1, "PackageToken")
        packageDenied = try f.repeatedUInt32(2)
        appTokens = try tokens(3, "AppToken")
        appDenied = try f.repeatedUInt32(4)
    }
}

/// CMsgClientPICSProductInfoRequest.
public struct CMsgClientPICSProductInfoRequest: ProtoMessage {
    public var packages: [(id: UInt32, token: UInt64)] = [] // 1 {packageid 1, access_token 2}
    public var apps: [(id: UInt32, token: UInt64)] = []     // 2 {appid 1, access_token 2}
    public var metaDataOnly = false                         // 3
    public var singleResponse = false                       // 7
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        for p in packages {
            var m = ProtoWriter(); m.uint32(1, p.id); if p.token != 0 { m.uint64(2, p.token) }
            w.bytes(1, m.bytes)
        }
        for a in apps {
            var m = ProtoWriter(); m.uint32(1, a.id); if a.token != 0 { m.uint64(2, a.token) }
            w.bytes(2, m.bytes)
        }
        w.bool(3, metaDataOnly)
        w.bool(7, singleResponse)
        return w.bytes
    }
}

/// CMsgClientPICSProductInfoResponse.
public struct CMsgClientPICSProductInfoResponse: ProtoDecodable {
    public static let protoName = "CMsgClientPICSProductInfoResponse"
    public struct Item: Sendable {
        public var id: UInt32            // appid 1 / packageid 1
        public var changeNumber: UInt32? // 2
        public var missingToken: Bool    // 3
        public var sha: [UInt8]?         // 4
        public var buffer: [UInt8]?      // 5
    }
    public var apps: [Item]              // 1
    public var unknownAppIDs: [UInt32]   // 2
    public var packages: [Item]          // 3
    public var unknownPackageIDs: [UInt32] // 4
    public var responsePending: Bool     // 6
    public var httpHost: String?         // 8
    public init(_ f: ProtoFields) throws {
        func items(_ field: Int, _ name: String) throws -> [Item] {
            try f.messages(field, as: name).map { m in
                Item(id: try m.require(m.uint32(1), 1, "id"), changeNumber: try m.uint32(2),
                     missingToken: try m.bool(3) ?? false, sha: try m.bytes(4), buffer: try m.bytes(5))
            }
        }
        apps = try items(1, "AppInfo")
        unknownAppIDs = try f.repeatedUInt32(2)
        packages = try items(3, "PackageInfo")
        unknownPackageIDs = try f.repeatedUInt32(4)
        responsePending = try f.bool(6) ?? false
        httpHost = try f.string(8)
    }
}

// MARK: - steammessages_clientserver_2.proto

/// CMsgClientGetDepotDecryptionKey.
public struct CMsgClientGetDepotDecryptionKey: ProtoMessage {
    public var depotID: UInt32 // 1
    public var appID: UInt32   // 2
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.uint32(1, depotID); w.uint32(2, appID); return w.bytes }
}

/// CMsgClientGetDepotDecryptionKeyResponse.
public struct CMsgClientGetDepotDecryptionKeyResponse: ProtoDecodable {
    public static let protoName = "CMsgClientGetDepotDecryptionKeyResponse"
    public var eresult: EResult          // 1
    public var depotID: UInt32?          // 2
    public var key: Secret<[UInt8]>?     // 3 depot_encryption_key
    public init(_ f: ProtoFields) throws {
        eresult = EResult(try f.int32(1) ?? 2)
        depotID = try f.uint32(2)
        key = try f.bytes(3).map(Secret.init)
    }
}

// MARK: - steammessages_clientserver.proto (encrypted app ticket, decision 0017)

/// CMsgClientRequestEncryptedAppTicket. The userdata field (2) is never sent:
/// the ticket is fetched before the game runs, so there is none to include.
public struct CMsgClientRequestEncryptedAppTicket: ProtoMessage {
    public var appID: UInt32 // 1
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.uint32(1, appID); return w.bytes }
}

/// CMsgClientRequestEncryptedAppTicketResponse. The ticket is the
/// EncryptedAppTicket message (encrypted_app_ticket.proto) as Steam serialised
/// it, the bytes ISteamUser::GetEncryptedAppTicket gives a game.
public struct CMsgClientRequestEncryptedAppTicketResponse: ProtoDecodable {
    public static let protoName = "CMsgClientRequestEncryptedAppTicketResponse"
    public var appID: UInt32?                  // 1
    public var eresult: EResult                // 2
    public var ticket: Secret<[UInt8]>?        // 3 encrypted_app_ticket
    public init(_ f: ProtoFields) throws {
        appID = try f.uint32(1)
        eresult = EResult(try f.int32(2) ?? 2)
        ticket = try f.bytes(3).map(Secret.init)
    }
}

// MARK: - steammessages_auth.steamclient.proto (service Authentication)

public enum AuthPlatform: UInt32, Sendable { case unknown = 0, steamClient = 1, webBrowser = 2, mobileApp = 3 }

/// CAuthentication_BeginAuthSessionViaQR_Request.
public struct BeginAuthSessionViaQRRequest: ProtoMessage {
    public var deviceFriendlyName: String       // 1
    public var platformType: AuthPlatform       // 2
    public var osType: Int32 = 0                // 3.3 device_details.os_type
    public var websiteID = "Client"             // 4
    public func encode() -> [UInt8] {
        var d = ProtoWriter()
        d.string(1, deviceFriendlyName)
        d.uint32(2, platformType.rawValue)
        d.int32(3, osType)
        var w = ProtoWriter()
        w.string(1, deviceFriendlyName)
        w.uint32(2, platformType.rawValue)
        w.bytes(3, d.bytes)
        w.string(4, websiteID)
        return w.bytes
    }
}

/// CAuthentication_BeginAuthSessionViaQR_Response.
public struct BeginAuthSessionViaQRResponse: ProtoDecodable {
    public static let protoName = "CAuthentication_BeginAuthSessionViaQR_Response"
    public var clientID: UInt64                 // 1
    public var challengeURL: Secret<String>     // 2
    public var requestID: Secret<[UInt8]>       // 3
    public var interval: Float                  // 4
    public var allowedConfirmations: [UInt32]   // 5.1 confirmation_type
    public var version: Int32?                  // 6
    public init(_ f: ProtoFields) throws {
        clientID = try f.require(f.uint64(1), 1, "client_id")
        challengeURL = Secret(try f.require(f.string(2), 2, "challenge_url"))
        requestID = Secret(try f.require(f.bytes(3), 3, "request_id"))
        interval = try f.float(4) ?? 5
        allowedConfirmations = try f.messages(5, as: "CAuthentication_AllowedConfirmation").compactMap { try $0.uint32(1) }
        version = try f.int32(6)
    }
}

/// CAuthentication_PollAuthSessionStatus_Request.
public struct PollAuthSessionStatusRequest: ProtoMessage {
    public var clientID: UInt64              // 1
    public var requestID: Secret<[UInt8]>    // 2
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.uint64(1, clientID); w.bytes(2, requestID.value); return w.bytes }
}

/// CAuthentication_PollAuthSessionStatus_Response.
public struct PollAuthSessionStatusResponse: ProtoDecodable {
    public static let protoName = "CAuthentication_PollAuthSessionStatus_Response"
    public var newClientID: UInt64?              // 1
    public var newChallengeURL: Secret<String>?  // 2
    public var refreshToken: Secret<String>?     // 3
    public var accessToken: Secret<String>?      // 4
    public var hadRemoteInteraction: Bool        // 5
    public var accountName: String?              // 6
    public var newGuardData: Secret<String>?     // 7
    public init(_ f: ProtoFields) throws {
        newClientID = try f.uint64(1)
        newChallengeURL = try f.string(2).flatMap { $0.isEmpty ? nil : Secret($0) }
        refreshToken = try f.string(3).flatMap { $0.isEmpty ? nil : Secret($0) }
        accessToken = try f.string(4).flatMap { $0.isEmpty ? nil : Secret($0) }
        hadRemoteInteraction = try f.bool(5) ?? false
        accountName = try f.string(6).flatMap { $0.isEmpty ? nil : $0 }
        newGuardData = try f.string(7).flatMap { $0.isEmpty ? nil : Secret($0) }
    }
}

/// EAuthSessionGuardType: how Steam wants a credential sign-in confirmed.
public enum AuthGuardType: Sendable, Equatable, Hashable {
    case none, emailCode, deviceCode, deviceConfirmation, emailConfirmation, machineToken, legacyMachineAuth
    case other(UInt32)

    public init(_ raw: UInt32) {
        switch raw {
        case 1: self = .none
        case 2: self = .emailCode
        case 3: self = .deviceCode
        case 4: self = .deviceConfirmation
        case 5: self = .emailConfirmation
        case 6: self = .machineToken
        case 7: self = .legacyMachineAuth
        default: self = .other(raw)
        }
    }

    public var raw: UInt32 {
        switch self {
        case .none: 1
        case .emailCode: 2
        case .deviceCode: 3
        case .deviceConfirmation: 4
        case .emailConfirmation: 5
        case .machineToken: 6
        case .legacyMachineAuth: 7
        case let .other(r): r
        }
    }
}

/// CAuthentication_AllowedConfirmation.
public struct AuthConfirmation: Sendable, Equatable {
    public var type: AuthGuardType   // 1 confirmation_type
    /// 2 associated_message: for an e-mail code, the address's domain. Shown, never logged.
    public var message: String?
    public init(type: AuthGuardType, message: String? = nil) { self.type = type; self.message = message }
    init(_ f: ProtoFields) throws {
        type = AuthGuardType(try f.uint32(1) ?? 0)
        message = try f.string(2).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// CAuthentication_GetPasswordRSAPublicKey_Request.
public struct GetPasswordRSAPublicKeyRequest: ProtoMessage {
    public var accountName: String   // 1
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.string(1, accountName); return w.bytes }
}

/// CAuthentication_GetPasswordRSAPublicKey_Response.
public struct GetPasswordRSAPublicKeyResponse: ProtoDecodable {
    public static let protoName = "CAuthentication_GetPasswordRSAPublicKey_Response"
    public var modulusHex: String    // 1 publickey_mod
    public var exponentHex: String   // 2 publickey_exp
    public var timestamp: UInt64     // 3
    public init(_ f: ProtoFields) throws {
        modulusHex = try f.require(f.string(1), 1, "publickey_mod")
        exponentHex = try f.require(f.string(2), 2, "publickey_exp")
        timestamp = try f.require(f.uint64(3), 3, "timestamp")
    }
}

/// CAuthentication_BeginAuthSessionViaCredentials_Request.
public struct BeginAuthSessionViaCredentialsRequest: ProtoMessage {
    public var deviceFriendlyName: String        // 1 (and 9.1)
    public var accountName: String               // 2
    /// 3: the password, RSA-encrypted with the account's key and base64 encoded.
    public var encryptedPassword: Secret<String>
    public var encryptionTimestamp: UInt64       // 4, the key's timestamp
    public var rememberLogin = true              // 5
    public var platformType: AuthPlatform        // 6 (and 9.2)
    public var persistence: UInt32 = 1           // 7 ESessionPersistence (k_ESessionPersistence_Persistent = 1)
    public var websiteID = "Client"              // 8
    public var osType: Int32 = 0                 // 9.3 device_details.os_type
    public var guardData: Secret<String>?        // 10
    public func encode() -> [UInt8] {
        var d = ProtoWriter()
        d.string(1, deviceFriendlyName)
        d.uint32(2, platformType.rawValue)
        d.int32(3, osType)
        var w = ProtoWriter()
        w.string(1, deviceFriendlyName)
        w.string(2, accountName)
        w.string(3, encryptedPassword.value)
        w.uint64(4, encryptionTimestamp)
        w.bool(5, rememberLogin)
        w.uint32(6, platformType.rawValue)
        w.uint32(7, persistence)
        w.string(8, websiteID)
        w.bytes(9, d.bytes)
        w.string(10, guardData?.value)
        return w.bytes
    }
}

/// CAuthentication_BeginAuthSessionViaCredentials_Response.
public struct BeginAuthSessionViaCredentialsResponse: ProtoDecodable {
    public static let protoName = "CAuthentication_BeginAuthSessionViaCredentials_Response"
    public var clientID: UInt64                    // 1
    public var requestID: Secret<[UInt8]>          // 2
    public var interval: Float                     // 3
    public var allowedConfirmations: [AuthConfirmation] // 4
    public var steamID: UInt64                     // 5
    public var extendedError: String?              // 8 extended_error_message
    public init(_ f: ProtoFields) throws {
        clientID = try f.require(f.uint64(1), 1, "client_id")
        requestID = Secret(try f.require(f.bytes(2), 2, "request_id"))
        interval = try f.float(3) ?? 5
        allowedConfirmations = try f.messages(4, as: "CAuthentication_AllowedConfirmation").map(AuthConfirmation.init)
        steamID = try f.uint64(5) ?? 0
        extendedError = try f.string(8).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// CAuthentication_UpdateAuthSessionWithSteamGuardCode_Request.
public struct UpdateAuthSessionWithSteamGuardCodeRequest: ProtoMessage {
    public var clientID: UInt64         // 1
    public var steamID: UInt64          // 2 fixed64
    public var code: Secret<String>     // 3
    public var codeType: AuthGuardType  // 4
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.uint64(1, clientID)
        w.fixed64(2, steamID)
        w.string(3, code.value)
        w.uint32(4, codeType.raw)
        return w.bytes
    }
}

/// CAuthentication_AccessToken_GenerateForApp_Request.
public struct GenerateAccessTokenForAppRequest: ProtoMessage {
    public var refreshToken: Secret<String> // 1
    public var steamID: UInt64              // 2 fixed64
    public var allowRenewal = true          // 3 renewal_type (k_ETokenRenewalType_Allow = 1)
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.string(1, refreshToken.value)
        w.fixed64(2, steamID)
        w.uint32(3, allowRenewal ? 1 : 0)
        return w.bytes
    }
}

/// CAuthentication_AccessToken_GenerateForApp_Response.
public struct GenerateAccessTokenForAppResponse: ProtoDecodable {
    public static let protoName = "CAuthentication_AccessToken_GenerateForApp_Response"
    public var accessToken: Secret<String>?  // 1
    public var refreshToken: Secret<String>? // 2 (set only when Steam renewed it)
    public init(_ f: ProtoFields) throws {
        accessToken = try f.string(1).flatMap { $0.isEmpty ? nil : Secret($0) }
        refreshToken = try f.string(2).flatMap { $0.isEmpty ? nil : Secret($0) }
    }
}

/// CAuthentication_Token_Revoke_Request.
public struct TokenRevokeRequest: ProtoMessage {
    public var token: Secret<String>  // 1
    public var revokeAction: UInt32 = 1 // 2 EAuthTokenRevokeAction (k_EAuthTokenRevokePermanent = 1)
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.string(1, token.value); w.uint32(2, revokeAction); return w.bytes }
}

// MARK: - steammessages_contentsystem.steamclient.proto (service ContentServerDirectory)

/// CContentServerDirectory_GetManifestRequestCode_Request.
public struct GetManifestRequestCodeRequest: ProtoMessage {
    public var appID: UInt32      // 1
    public var depotID: UInt32    // 2
    public var manifestID: UInt64 // 3
    public var appBranch = "public" // 4
    public func encode() -> [UInt8] {
        var w = ProtoWriter()
        w.uint32(1, appID); w.uint32(2, depotID); w.uint64(3, manifestID); w.string(4, appBranch)
        return w.bytes
    }
}

/// CContentServerDirectory_GetManifestRequestCode_Response.
public struct GetManifestRequestCodeResponse: ProtoDecodable {
    public static let protoName = "CContentServerDirectory_GetManifestRequestCode_Response"
    public var code: Secret<UInt64> // 1
    public init(_ f: ProtoFields) throws { code = Secret(try f.uint64(1) ?? 0) }
}

/// CContentServerDirectory_GetServersForSteamPipe_Request.
public struct GetServersForSteamPipeRequest: ProtoMessage {
    public var cellID: UInt32      // 1
    public var maxServers: UInt32 = 20 // 2
    public func encode() -> [UInt8] { var w = ProtoWriter(); w.uint32(1, cellID); w.uint32(2, maxServers); return w.bytes }
}

/// CContentServerDirectory_GetServersForSteamPipe_Response (ServerInfo subset).
public struct GetServersForSteamPipeResponse: ProtoDecodable {
    public static let protoName = "CContentServerDirectory_GetServersForSteamPipe_Response"
    public struct Server: Sendable, Equatable {
        public var type: String          // 1
        public var sourceID: Int32?      // 2
        public var cellID: Int32?        // 3
        public var load: Int32?          // 4
        public var weightedLoad: Float?  // 5
        public var host: String          // 8
        public var vhost: String         // 9
        public var httpsSupport: String? // 12
        public var allowedAppIDs: [UInt32] // 13
        public var priorityClass: UInt32?  // 15
    }
    public var servers: [Server] // 1
    public init(_ f: ProtoFields) throws {
        servers = try f.messages(1, as: "CContentServerDirectory_ServerInfo").map { s in
            let host = try s.require(s.string(8), 8, "host")
            return Server(type: try s.string(1) ?? "", sourceID: try s.int32(2), cellID: try s.int32(3),
                          load: try s.int32(4), weightedLoad: try s.float(5), host: host,
                          vhost: try s.string(9) ?? host, httpsSupport: try s.string(12),
                          allowedAppIDs: try s.repeatedUInt32(13), priorityClass: try s.uint32(15))
        }
    }
}

// MARK: - content_manifest.proto

/// ContentManifestPayload.
public struct ContentManifestPayload: ProtoDecodable {
    public static let protoName = "ContentManifestPayload"
    public struct Chunk: Sendable, Equatable {
        public var sha: [UInt8]      // 1 (chunk id: SHA-1 of the plaintext)
        public var crc: UInt32       // 2 fixed32 (Adler-32 of the plaintext, seed 0)
        public var offset: UInt64    // 3
        public var cbOriginal: UInt32   // 4
        public var cbCompressed: UInt32 // 5
    }
    public struct FileMapping: Sendable {
        public var filename: String      // 1
        public var size: UInt64          // 2
        public var flags: UInt32         // 3 EDepotFileFlag
        public var shaFilename: [UInt8]? // 4
        public var shaContent: [UInt8]?  // 5
        public var chunks: [Chunk]       // 6
        public var linkTarget: String?   // 7
    }
    public var mappings: [FileMapping] // 1
    public init(_ f: ProtoFields) throws {
        mappings = try f.messages(1, as: "ContentManifestPayload.FileMapping").map { m in
            FileMapping(
                filename: try m.require(m.string(1), 1, "filename"),
                size: try m.uint64(2) ?? 0, flags: try m.uint32(3) ?? 0,
                shaFilename: try m.bytes(4), shaContent: try m.bytes(5),
                chunks: try m.messages(6, as: "ContentManifestPayload.FileMapping.ChunkData").map { c in
                    Chunk(sha: try c.require(c.bytes(1), 1, "sha"), crc: try c.fixed32(2) ?? 0,
                          offset: try c.uint64(3) ?? 0, cbOriginal: try c.uint32(4) ?? 0,
                          cbCompressed: try c.uint32(5) ?? 0)
                },
                linkTarget: try m.string(7).flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

/// ContentManifestMetadata.
public struct ContentManifestMetadata: ProtoDecodable {
    public static let protoName = "ContentManifestMetadata"
    public var depotID: UInt32            // 1
    public var gidManifest: UInt64        // 2
    public var creationTime: UInt32?      // 3
    public var filenamesEncrypted: Bool   // 4
    public var cbDiskOriginal: UInt64?    // 5
    public var cbDiskCompressed: UInt64?  // 6
    public var uniqueChunks: UInt32?      // 7
    public var crcEncrypted: UInt32?      // 8
    public var crcClear: UInt32?          // 9
    public init(_ f: ProtoFields) throws {
        depotID = try f.require(f.uint32(1), 1, "depot_id")
        gidManifest = try f.require(f.uint64(2), 2, "gid_manifest")
        creationTime = try f.uint32(3)
        filenamesEncrypted = try f.bool(4) ?? false
        cbDiskOriginal = try f.uint64(5)
        cbDiskCompressed = try f.uint64(6)
        uniqueChunks = try f.uint32(7)
        crcEncrypted = try f.uint32(8)
        crcClear = try f.uint32(9)
    }
}
