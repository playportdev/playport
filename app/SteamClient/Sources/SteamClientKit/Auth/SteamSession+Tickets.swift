// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The game connect tokens Steam pushes to a logged-on session
/// (ClientGameConnectTokens): each auth session or web API ticket is built
/// on one (SteamTicketBroker, decision 0062). In memory only; Steam says how
/// many to keep and the oldest go first. Read by a play's broker on a guest
/// thread, so a lock, not an actor.
public final class GameConnectTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Secret<[UInt8]>] = []

    public init() {}

    public var count: Int { lock.withLock { tokens.count } }

    /// Adds Steam's tokens and keeps the newest `keep`.
    public func add(_ new: [Secret<[UInt8]>], keep: Int) {
        lock.withLock {
            tokens.append(contentsOf: new)
            if tokens.count > keep { tokens.removeFirst(tokens.count - keep) }
        }
    }

    /// The oldest token, taken: each is used for one ticket.
    public func take() -> Secret<[UInt8]>? {
        lock.withLock { tokens.isEmpty ? nil : tokens.removeFirst() }
    }

    public func clear() { lock.withLock { tokens.removeAll() } }
}

/// Where a session sends ClientAuthListAck and ClientTicketAuthComplete: a
/// play's ticket broker while one is armed, otherwise nowhere.
public final class TicketPushRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CMPacket) -> Void)?

    public init() {}

    public func set(_ h: (@Sendable (CMPacket) -> Void)?) { lock.withLock { handler = h } }

    func deliver(_ p: CMPacket) { lock.withLock { handler }?(p) }
}

/// A live play's tickets (decision 0062): the app's ownership ticket, the
/// auth list, and the game being played.
extension SteamSession {
    /// What a connection does with a push (CMConnection.pushedEMsgs): tokens
    /// to the queue, the rest to the play's broker.
    nonisolated func pushHandler() -> CMConnection.PushHandler {
        let tokens = connectTokens, route = ticketPushes, log = log
        return { p in
            switch p.knownEMsg {
            case .clientGameConnectTokens:
                do {
                    let m = try CMsgClientGameConnectTokens.decode(p.body)
                    tokens.add(m.tokens, keep: Int(m.maxTokensToKeep))
                    log.debug("ticket", "game connect tokens: \(m.tokens.count) new, \(tokens.count) kept (at most \(m.maxTokensToKeep))")
                } catch {
                    log.warn("ticket", "game connect tokens unreadable: \(error)")
                }
            default:
                route.deliver(p)
            }
        }
    }

    /// Steam's ownership ticket for `appID` (EMsg 857, the reply 858): the
    /// signed proof of ownership that ends every ticket the game is given.
    /// Returned, never kept or logged.
    public func appOwnershipTicket(appID: UInt32, timeout: Double = 5) async throws -> Secret<[UInt8]> {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let cm = try requireCM()
        let p = try await cm.callEither(.clientGetAppOwnershipTicket, CMsgClientGetAppOwnershipTicket(appID: appID),
                                        reply: .clientGetAppOwnershipTicketResponse, timeout: timeout,
                                        accept: { p in (try? ProtoFields(p.body, message: "ownership reply").uint32(2)).map { $0 == appID } ?? true })
        let r = try CMsgClientGetAppOwnershipTicketResponse.decode(p.body)
        guard r.eresult == .ok else { throw SteamError.eresult(r.eresult, context: "ClientGetAppOwnershipTicket \(appID)") }
        guard let ticket = r.ticket, !ticket.value.isEmpty else { throw SteamError.notFound("no ownership ticket for app \(appID)") }
        return ticket
    }

    /// Sends the client's whole list of live tickets (an empty one ends them all).
    public func sendAuthList(_ list: CMsgClientAuthList) async throws {
        try await requireCM().send(.clientAuthList, list)
    }

    /// Tells Steam which games the session is in (an empty list: none), taking
    /// its turn with the calls that set it for themselves (oneStatsCallAtATime).
    public func setGamesPlayed(_ appIDs: [UInt32]) async throws {
        guard case .loggedOn(anonymous: false) = state else { throw SteamError.notLoggedOn }
        let cm = try requireCM()
        try await oneStatsCallAtATime { try await cm.send(.clientGamesPlayed, CMsgClientGamesPlayed(gameIDs: appIDs.map(UInt64.init))) }
    }
}
