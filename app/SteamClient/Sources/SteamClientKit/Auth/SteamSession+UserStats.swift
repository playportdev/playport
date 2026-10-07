// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's stats and achievements for the logged-on account (UserStats.swift).
extension SteamSession {
    /// Steam's values, unlock times and schema for `appID`.
    public func userStats(appID: UInt32, timeout: Double = 20) async throws -> UserStatsSnapshot {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let cm = try requireCM()
        let me = await cm.steamID
        let packet = try await oneStatsCallAtATime {
            try await cm.callEither(.clientGetUserStats, CMsgClientGetUserStats(gameID: UInt64(appID), steamIDForUser: me),
                                    reply: .clientGetUserStatsResponse, timeout: timeout, accept: Self.statsReply(forApp: appID))
        }
        let r = try CMsgClientGetUserStatsResponse.decode(packet.body)
        guard r.eresult == .ok else { throw SteamError.eresult(r.eresult, context: "ClientGetUserStats \(appID)") }
        guard let bytes = r.schema, !bytes.isEmpty else { throw SteamError.notFound("app \(appID) has no stats schema") }
        let schema = try StatsSchema.parse(try KeyValue.parseBinary(bytes[...]))
        return UserStatsSnapshot(appID: appID, crc: r.crcStats ?? 0, schema: schema, values: r.stats,
                                 unlockTimes: r.unlockTimes, fetchedAt: Date())
    }

    /// Stores new values (by stat ID) for `appID`, as the game would with
    /// Steam running: the session is in the game for the call, then in none.
    public func storeUserStats(appID: UInt32, crc: UInt32, values: [UInt32: UInt32], timeout: Double = 20) async throws
        -> CMsgClientStoreUserStatsResponse {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let cm = try requireCM()
        let me = await cm.steamID
        let msg = CMsgClientStoreUserStats2(gameID: UInt64(appID), settorSteamID: me, setteeSteamID: me, crcStats: crc,
                                            stats: values.keys.sorted().map { ($0, values[$0]!) })
        let packet = try await oneStatsCallAtATime {
            try await cm.send(.clientGamesPlayed, CMsgClientGamesPlayed(gameIDs: [UInt64(appID)]))
            do {
                let p = try await cm.callEither(.clientStoreUserStats2, msg, reply: .clientStoreUserStatsResponse, timeout: timeout,
                                                accept: Self.statsReply(forApp: appID))
                try? await cm.send(.clientGamesPlayed, CMsgClientGamesPlayed(gameIDs: []))
                return p
            } catch {
                try? await cm.send(.clientGamesPlayed, CMsgClientGamesPlayed(gameIDs: []))
                throw error
            }
        }
        let r = try CMsgClientStoreUserStatsResponse.decode(packet.body)
        guard r.eresult == .ok else { throw SteamError.eresult(r.eresult, context: "ClientStoreUserStats2 \(appID)") }
        return r
    }

    /// A stats reply that names another game answers an earlier request
    /// (one that timed out), never this one.
    static func statsReply(forApp appID: UInt32) -> @Sendable (CMPacket) -> Bool {
        { p in (try? ProtoFields(p.body, message: "stats reply").fixed64(1)).map { $0 == UInt64(appID) } ?? true }
    }

    /// Stats replies may come without a job, so a session has one stats
    /// request out at a time and each reply is its game's. The calls that set
    /// the game being played (a stats store, an encrypted app ticket) take
    /// turns here too, so one never ends another's game.
    func oneStatsCallAtATime<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = statsCall
        let call = Task { await previous?.value; return try await body() }
        statsCall = Task { _ = await call.result }
        return try await withTaskCancellationHandler { try await call.value } onCancel: { call.cancel() }
    }
}
