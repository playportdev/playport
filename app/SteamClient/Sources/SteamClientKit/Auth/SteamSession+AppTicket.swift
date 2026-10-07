// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's encrypted app ticket for the logged-on account (decision 0017).
extension SteamSession {
    /// Steam's encrypted app ticket for `appID` (EMsg 5526, the reply 5527):
    /// the bytes a game's GetEncryptedAppTicket returns, encrypted with the
    /// publisher's key. It is returned, never kept or logged. Steam answers
    /// Fail unless the session is in the game, as Steam's client is when a
    /// running game asks: the session is in it for the call, then in none.
    public func encryptedAppTicket(appID: UInt32, timeout: Double = 5) async throws -> Secret<[UInt8]> {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let cm = try requireCM()
        let packet = try await oneStatsCallAtATime {
            try await cm.send(.clientGamesPlayed, CMsgClientGamesPlayed(gameIDs: [UInt64(appID)]))
            do {
                let p = try await cm.callEither(.clientRequestEncryptedAppTicket, CMsgClientRequestEncryptedAppTicket(appID: appID),
                                                reply: .clientRequestEncryptedAppTicketResponse, timeout: timeout,
                                                accept: Self.ticketReply(forApp: appID))
                try? await cm.send(.clientGamesPlayed, CMsgClientGamesPlayed(gameIDs: []))
                return p
            } catch {
                try? await cm.send(.clientGamesPlayed, CMsgClientGamesPlayed(gameIDs: []))
                throw error
            }
        }
        let r = try CMsgClientRequestEncryptedAppTicketResponse.decode(packet.body)
        guard r.eresult == .ok else { throw SteamError.eresult(r.eresult, context: "ClientRequestEncryptedAppTicket \(appID)") }
        guard let ticket = r.ticket, !ticket.value.isEmpty else { throw SteamError.notFound("no encrypted app ticket for app \(appID)") }
        return ticket
    }

    /// A ticket reply that names another app answers another request.
    static func ticketReply(forApp appID: UInt32) -> @Sendable (CMPacket) -> Bool {
        { p in (try? ProtoFields(p.body, message: "ticket reply").uint32(1)).map { $0 == appID } ?? true }
    }
}
