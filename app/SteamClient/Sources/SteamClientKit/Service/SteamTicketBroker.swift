// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A live play's auth session and web API tickets (decision 0062). The game's
/// Steam API emulator asks for them through the runtime (WineHost
/// steam_ticket.c); the broker builds each as Steam's client does, from a game
/// connect token and the launched app's ownership ticket, reports it to Steam
/// in the client's auth list, and cancels it when the game does or the play
/// ends. Only the ticket bytes, a handle and a state cross to the game: no
/// token, no SteamID, no other app's ticket.
///
/// `create`, `status` and `cancel` run on the game's thread inside a unix
/// call, so the broker is a lock, never an actor, and nothing in it waits on
/// the network under the lock: the auth list goes out through `send`, which
/// returns at once, and Steam's ack arrives through `handle`.
public final class SteamTicketBroker: @unchecked Sendable, CustomStringConvertible {
    public enum TicketType: UInt32, Sendable {
        case authSession = 2
        case webAPI = 5

        var label: String { self == .authSession ? "auth session" : "web API" }
    }

    public enum State: UInt32, Sendable {
        case pending = 0
        /// Steam took it into the auth list (its ack named the ticket), or no ack came in `ackTimeout`.
        case acked = 1
        /// A server's check refused it, or its session ended.
        case failed = 2
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// No play is armed (before it, after `endPlay`), or the session is gone: the game gets the emulator's own.
        case notArmed
        /// More than `Limits.burst` at once, or more often than one each `Limits.interval`.
        case rateLimited
        /// `Limits.maxLive` tickets are live.
        case tooManyLive
        /// Steam has given no token, or every one is used.
        case noTokens
    }

    public struct Limits: Sendable {
        public var maxLive = 8
        /// One creation each `interval` seconds, up to `burst` at once.
        public var interval: TimeInterval = 2
        public var burst = 4
        /// A ticket Steam has not acked after this long is acked anyway, as Steam's client does.
        public var ackTimeout: TimeInterval = 10
        /// How long a creation on a closed connection waits for the reconnect.
        public var reconnectWait: TimeInterval = 5
        public init() {}
    }

    public struct Created: Sendable {
        public var handle: UInt32
        public var ticket: Secret<[UInt8]>
    }

    /// The web API ticket's size, ISteamUser's GetTicketForWebApiResponse_t buffer.
    public static let webAPITicketSize = 2560

    public let appID: UInt32
    public let limits: Limits
    private let ownership: Secret<[UInt8]>
    private let tokens: GameConnectTokens
    private let traffic: CMTraffic?
    private let log: Logger
    private let send: @Sendable (CMsgClientAuthList) -> Void
    private let reconnect: @Sendable () -> Void
    private let now: @Sendable () -> TimeInterval
    private let random: @Sendable (Int) -> [UInt8]

    private struct Live {
        var handle: UInt32
        var type: TicketType
        var auth: Secret<[UInt8]>
        var crc: UInt32
        var serverSecret: [UInt8]?
        var state: State
        var eresult: UInt32
        var created: TimeInterval
    }

    private let lock = NSLock()
    private var armed = true
    private var live: [Live] = []
    /// Apart from the emulator's own ticket numbers, which count up from 2.
    private static let firstHandle: UInt32 = 0x5050_0001
    private var nextHandle = SteamTicketBroker.firstHandle
    private var sequence: UInt32 = 0
    private var bucket: Double
    private var bucketAt: TimeInterval
    private var made = 0, acks = 0, checks = 0
    private let trafficAtArm: (received: Int, sent: Int)

    public init(appID: UInt32, ownershipTicket: Secret<[UInt8]>, tokens: GameConnectTokens, traffic: CMTraffic?,
                log: Logger, limits: Limits = Limits(),
                send: @escaping @Sendable (CMsgClientAuthList) -> Void,
                reconnect: @escaping @Sendable () -> Void = {},
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                random: @escaping @Sendable (Int) -> [UInt8] = SteamTicketBroker.randomBytes) {
        self.appID = appID
        self.ownership = ownershipTicket
        self.tokens = tokens
        self.traffic = traffic
        self.log = log
        self.limits = limits
        self.send = send
        self.reconnect = reconnect
        self.now = now
        self.random = random
        bucket = Double(limits.burst)
        bucketAt = now()
        trafficAtArm = traffic?.counts ?? (0, 0)
    }

    public var description: String {
        lock.withLock { "SteamTicketBroker(app \(appID), \(armed ? "armed" : "ended"), \(live.count) live, <redacted>)" }
    }

    public var isArmed: Bool { lock.withLock { armed } }

    // MARK: the game's calls

    /// A new ticket of `type` for the launched app. `identity` binds it to the
    /// service it is for: a web API ticket's identity string, or a session
    /// ticket's SteamNetworkingIdentity in its string form; empty binds nothing.
    public func create(type: TicketType, identity: String) -> Result<Created, Refusal> {
        guard isArmed else { return .failure(.notArmed) }
        if let traffic, !traffic.isOpen {
            // The socket dropped (the app was in the background, the network changed):
            // reconnect on demand (decision 0062), and wait a little for its tokens.
            log.info("ticket", "the CM connection is closed; reconnecting for the game's ticket")
            reconnect()
            let until = now() + limits.reconnectWait
            while now() < until, !(traffic.isOpen && tokens.count > 0) { usleep(100_000) }
            guard traffic.isOpen, isArmed else {
                log.warn("ticket", "no CM connection for the game's \(type.label) ticket; it gets the emulator's own")
                return .failure(.notArmed)
            }
        }
        let t = now()
        let refusal: Refusal? = lock.withLock {
            if live.count >= limits.maxLive { return .tooManyLive }
            bucket = min(Double(limits.burst), bucket + (t - bucketAt) / limits.interval)
            bucketAt = t
            return bucket < 1 ? .rateLimited : nil
        }
        if let refusal {
            log.warn("ticket", "\(type.label) ticket refused: \(refusal)")
            return .failure(refusal)
        }
        guard let token = tokens.take() else {
            log.warn("ticket", "\(type.label) ticket refused: Steam has no game connect token left")
            return .failure(.noTokens)
        }
        let secret = Self.serverSecret(type: type, identity: identity)
        let seq: UInt32 = lock.withLock { sequence &+= 1; return sequence }
        let auth = Self.authPart(token: token.value, type: type, random: random(8),
                                 timestamp: UInt32(truncatingIfNeeded: UInt64(t * 1000)), sequence: seq)
        let crc = CRC32.checksum(auth)
        let ticket = Self.combined(auth: auth, ownership: ownership.value, type: type, random: random)
        let outcome: (UInt32, CMsgClientAuthList)? = lock.withLock {
            guard armed else { return nil }
            bucket -= 1
            let h = nextHandle
            nextHandle &+= 1
            if nextHandle == 0 { nextHandle = Self.firstHandle }
            live.append(Live(handle: h, type: type, auth: Secret(auth), crc: crc, serverSecret: secret,
                             state: .pending, eresult: 0, created: t))
            made += 1
            return (h, authList())
        }
        guard let (handle, list) = outcome else { return .failure(.notArmed) }
        send(list)
        log.info("ticket", "ticket \(handle): \(type.label) for app \(appID), \(ticket.count) bytes"
                 + (secret == nil ? "" : ", bound to an identity") + "; \(tokens.count) token(s) left")
        return .success(Created(handle: handle, ticket: Secret(ticket)))
    }

    /// Where a ticket stands, and a refusing server's EAuthSessionResponse; nil for a handle that is not live.
    public func status(_ handle: UInt32) -> (state: State, eresult: UInt32)? {
        let t = now()
        return lock.withLock {
            guard let i = live.firstIndex(where: { $0.handle == handle }) else { return nil }
            if live[i].state == .pending, t - live[i].created >= limits.ackTimeout {
                live[i].state = .acked
                log.info("ticket", "ticket \(handle): no ack from Steam in \(Int(limits.ackTimeout)) s; given to the game as Steam's client does")
            }
            return (live[i].state, live[i].eresult)
        }
    }

    /// The game is done with a ticket: it leaves the auth list, so Steam no longer accepts it.
    public func cancel(_ handle: UInt32) {
        let list: CMsgClientAuthList? = lock.withLock {
            guard let i = live.firstIndex(where: { $0.handle == handle }) else { return nil }
            live.remove(at: i)
            return armed ? authList() : nil
        }
        guard let list else { return }
        send(list)
        log.info("ticket", "ticket \(handle): cancelled by the game; \(list.tickets.count) live")
    }

    // MARK: Steam's pushes

    /// ClientAuthListAck and ClientTicketAuthComplete (TicketPushRoute).
    public func handle(_ p: CMPacket) {
        switch p.knownEMsg {
        case .clientAuthListAck:
            guard let m = try? CMsgClientAuthListAck.decode(p.body) else { return log.warn("ticket", "auth list ack unreadable") }
            let named: [UInt32] = lock.withLock {
                acks += 1
                var hs: [UInt32] = []
                for i in live.indices where m.ticketCRCs.contains(live[i].crc) {
                    if live[i].state == .pending { live[i].state = .acked }
                    hs.append(live[i].handle)
                }
                return hs
            }
            log.info("ticket", "auth list acked by Steam: \(m.ticketCRCs.count) ticket(s)"
                     + (named.isEmpty ? "" : ", handle(s) \(named.map(String.init).joined(separator: ","))"))
        case .clientTicketAuthComplete:
            guard let m = try? CMsgClientTicketAuthComplete.decode(p.body) else { return log.warn("ticket", "ticket check unreadable") }
            let response = m.authSessionResponse ?? 0
            let handle: UInt32? = lock.withLock {
                checks += 1
                guard let i = live.firstIndex(where: { $0.crc == m.ticketCRC }) else { return nil }
                if response != 0 { live[i].state = .failed; live[i].eresult = response }
                return live[i].handle
            }
            log.info("ticket", "ticket \(handle.map(String.init) ?? "(not live)") checked by a server: "
                     + "EAuthSessionResponse \(response) (\(Self.responseName(response))), state \(m.estate ?? 0)")
        default:
            break
        }
    }

    // MARK: the play's end

    /// The connection was replaced (a reconnect): tickets of the old logon are dead.
    public func connectionReplaced() {
        let n: Int = lock.withLock {
            let n = live.count
            for i in live.indices { live[i].state = .failed }
            live.removeAll()
            return n
        }
        if n > 0 { log.info("ticket", "\(n) live ticket(s) ended with the old CM connection") }
    }

    /// Disarms the broker and returns the list that ends every live ticket
    /// (the caller sends it). Nothing is created after this.
    public func endPlay() -> CMsgClientAuthList? {
        let (list, summary): (CMsgClientAuthList?, String) = lock.withLock {
            guard armed else { return (nil, "") }
            armed = false
            let s = "\(made) ticket(s) made, \(live.count) live at the end, \(acks) ack(s), \(checks) server check(s)"
            live.removeAll()
            return (authList(), s)
        }
        guard let list else { return nil }
        log.info("ticket", "play ended: \(summary)")
        if let c = traffic?.counts {
            log.info("ticket", "cm: \(c.received - trafficAtArm.received) in / \(c.sent - trafficAtArm.sent) out during the play")
        }
        return list
    }

    /// Under the lock: the whole list, as Steam's client sends it each time.
    private func authList() -> CMsgClientAuthList {
        CMsgClientAuthList(tokensLeft: UInt32(tokens.count),
                           tickets: live.map { CMsgAuthTicket(gameID: UInt64(appID), ticketCRC: $0.crc, ticket: $0.auth,
                                                              serverSecret: $0.serverSecret) },
                           appIDs: [appID])
    }

    // MARK: the ticket's layout

    /// The auth part: the token with its length, then the 24-byte session
    /// header (its size, 1, the type, 8 random bytes where Steam's client puts
    /// its public and private IPv4, a timestamp, a sequence number).
    static func authPart(token: [UInt8], type: TicketType, random: [UInt8], timestamp: UInt32, sequence: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(4 + token.count + 4 + 24)
        out.appendLE(UInt32(token.count))
        out.append(contentsOf: token)
        out.appendLE(UInt32(24))
        out.appendLE(UInt32(1))
        out.appendLE(type.rawValue)
        out.append(contentsOf: random.prefix(8))
        out.append(contentsOf: [UInt8](repeating: 0, count: max(0, 8 - random.count)))
        out.appendLE(timestamp)
        out.appendLE(sequence)
        return out
    }

    /// The ticket the game gets: the auth part, the ownership ticket with its
    /// length, and for a web API ticket random bytes up to `webAPITicketSize`.
    static func combined(auth: [UInt8], ownership: [UInt8], type: TicketType, random: (Int) -> [UInt8]) -> [UInt8] {
        var out = auth
        out.appendLE(UInt32(ownership.count))
        out.append(contentsOf: ownership)
        if type == .webAPI, out.count < webAPITicketSize { out.append(contentsOf: random(webAPITicketSize - out.count)) }
        return out
    }

    /// What binds a ticket to its service: `str:<identity>` for a web API
    /// ticket, a session ticket's identity as given (its `steamid:`, `ip:` or
    /// `str:` form), NUL-terminated; nil when there is none.
    static func serverSecret(type: TicketType, identity: String) -> [UInt8]? {
        guard !identity.isEmpty else { return nil }
        return Array(((type == .webAPI ? "str:" : "") + identity).utf8) + [0]
    }

    static func responseName(_ r: UInt32) -> String {
        switch r {
        case 0: "OK"
        case 1: "user not connected to Steam"
        case 2: "no license or expired"
        case 3: "VAC banned"
        case 4: "logged in elsewhere"
        case 5: "VAC check timed out"
        case 6: "ticket cancelled"
        case 7: "ticket already used"
        case 8: "ticket invalid"
        case 9: "publisher-issued ban"
        case 10: "ticket invalid for this identity"
        default: "unknown"
        }
    }

    public static func randomBytes(_ n: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }
}
