// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// A live play's tickets (decision 0062): the messages, the ticket's layout,
/// the broker's limits, the CM's pushes and the service's play.
final class TicketWireTests: XCTestCase {
    func testGameConnectTokensAndOwnershipReply() throws {
        var w = ProtoWriter()
        w.uint32(1, 3)
        w.bytes(2, [1, 2]); w.bytes(2, [3])
        let t = try CMsgClientGameConnectTokens.decode(w.bytes)
        XCTAssertEqual(t.maxTokensToKeep, 3)
        XCTAssertEqual(t.tokens.map(\.value), [[1, 2], [3]])
        XCTAssertEqual(try CMsgClientGameConnectTokens.decode([]).maxTokensToKeep, 10, "Steam's default")

        XCTAssertEqual(CMsgClientGetAppOwnershipTicket(appID: 945360).encode(), [0x08, 0xD0, 0xD9, 0x39])
        var r = ProtoWriter()
        r.uint32(1, 1); r.uint32(2, 945360); r.bytes(3, [9, 9])
        let o = try CMsgClientGetAppOwnershipTicketResponse.decode(r.bytes)
        XCTAssertEqual(o.eresult, .ok)
        XCTAssertEqual(o.appID, 945360)
        XCTAssertEqual(o.ticket?.value, [9, 9])
        XCTAssertEqual(try CMsgClientGetAppOwnershipTicketResponse.decode([]).eresult, .fail, "default 2")
        XCTAssertEqual("\(o.ticket!)", "<redacted>")
    }

    func testAuthListEncoding() throws {
        let t = CMsgAuthTicket(gameID: 367520, ticketCRC: 0xDEADBEEF, ticket: Secret([1, 2, 3]), serverSecret: Array("str:x\0".utf8))
        let list = CMsgClientAuthList(tokensLeft: 4, tickets: [t], appIDs: [367520])
        let f = try ProtoFields(list.encode(), message: "CMsgClientAuthList")
        XCTAssertEqual(try f.uint32(1), 4)
        XCTAssertEqual(try f.repeatedUInt32(5), [367520])
        let inner = try f.messages(4, as: "CMsgAuthTicket")
        XCTAssertEqual(inner.count, 1)
        XCTAssertEqual(try inner[0].fixed64(4), 367520)
        XCTAssertEqual(try inner[0].uint32(6), 0xDEADBEEF)
        XCTAssertEqual(try inner[0].bytes(7), [1, 2, 3])
        XCTAssertEqual(try inner[0].bytes(8), Array("str:x\0".utf8))
        // An empty list (the play's end) still names the app.
        let empty = try ProtoFields(CMsgClientAuthList(tokensLeft: 0, tickets: [], appIDs: [7]).encode(), message: "L")
        XCTAssertTrue(try empty.messages(4, as: "T").isEmpty)
        XCTAssertEqual(try empty.repeatedUInt32(5), [7])
    }

    func testAckAndAuthComplete() throws {
        var a = ProtoWriter()
        a.uint32(1, 11); a.uint32(1, 22); a.uint32(2, 7); a.uint32(3, 5)
        let ack = try CMsgClientAuthListAck.decode(a.bytes)
        XCTAssertEqual(ack.ticketCRCs, [11, 22])
        XCTAssertEqual(ack.appIDs, [7])
        XCTAssertEqual(ack.messageSequence, 5)

        var c = ProtoWriter()
        c.fixed64(1, 76_561_197_960_287_930); c.fixed64(2, 945360); c.uint32(3, 1); c.uint32(4, 0); c.uint32(6, 22); c.uint32(7, 2)
        let done = try CMsgClientTicketAuthComplete.decode(c.bytes)
        XCTAssertEqual(done.gameID, 945360)
        XCTAssertEqual(done.estate, 1)
        XCTAssertEqual(done.authSessionResponse, 0)
        XCTAssertEqual(done.ticketCRC, 22)
        XCTAssertEqual(done.ticketSequence, 2)
    }
}

/// A fake clock the tests move by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

/// The lists a broker sent, in order.
final class SentLists: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [CMsgClientAuthList] = []
    func add(_ l: CMsgClientAuthList) { lock.withLock { v.append(l) } }
    var all: [CMsgClientAuthList] { lock.withLock { v } }
}

final class TicketBrokerTests: XCTestCase {
    let token: [UInt8] = Array(repeating: 0xAB, count: 20)
    let ownership: [UInt8] = Array(repeating: 0x0F, count: 100)

    func broker(tokens n: Int = 10, limits: SteamTicketBroker.Limits = .init(), traffic: CMTraffic? = nil,
                reconnect: @escaping @Sendable () -> Void = {}) -> (SteamTicketBroker, FakeClock, SentLists, GameConnectTokens) {
        let clock = FakeClock(), sent = SentLists(), tokens = GameConnectTokens()
        tokens.add((0..<n).map { i in Secret(token.map { $0 ^ UInt8(i) }) }, keep: 10)
        let b = SteamTicketBroker(appID: 367520, ownershipTicket: Secret(ownership), tokens: tokens, traffic: traffic,
                                  log: .silent, limits: limits, send: { sent.add($0) }, reconnect: reconnect,
                                  now: { clock.now }, random: { [UInt8](repeating: 0x5A, count: $0) })
        return (b, clock, sent, tokens)
    }

    func testTheTicketsLayout() throws {
        let auth = SteamTicketBroker.authPart(token: token, type: .authSession, random: [1, 2, 3, 4, 5, 6, 7, 8],
                                              timestamp: 0x11223344, sequence: 9)
        XCTAssertEqual(auth.count, 4 + 20 + 28)
        XCTAssertEqual(auth.readLE32(at: 0), 20)
        XCTAssertEqual(Array(auth[4..<24]), token)
        XCTAssertEqual(auth.readLE32(at: 24), 24, "the session header's size")
        XCTAssertEqual(auth.readLE32(at: 28), 1)
        XCTAssertEqual(auth.readLE32(at: 32), 2, "an auth session ticket")
        XCTAssertEqual(Array(auth[36..<44]), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(auth.readLE32(at: 44), 0x11223344)
        XCTAssertEqual(auth.readLE32(at: 48), 9)

        let session = SteamTicketBroker.combined(auth: auth, ownership: ownership, type: .authSession, random: { [UInt8](repeating: 0, count: $0) })
        XCTAssertEqual(session.count, auth.count + 4 + 100)
        XCTAssertEqual(session.readLE32(at: auth.count), 100)
        XCTAssertEqual(Array(session[(auth.count + 4)...]), ownership)

        let web = SteamTicketBroker.combined(auth: auth, ownership: ownership, type: .webAPI, random: { [UInt8](repeating: 0xEE, count: $0) })
        XCTAssertEqual(web.count, 2560, "padded to GetTicketForWebApiResponse_t's buffer")
        XCTAssertEqual(Array(web[..<session.count]), session)
        XCTAssertEqual(web.last, 0xEE)

        XCTAssertEqual(SteamTicketBroker.serverSecret(type: .webAPI, identity: "epiconlineservices"), Array("str:epiconlineservices\0".utf8))
        XCTAssertEqual(SteamTicketBroker.serverSecret(type: .authSession, identity: "steamid:1"), Array("steamid:1\0".utf8))
        XCTAssertNil(SteamTicketBroker.serverSecret(type: .webAPI, identity: ""))
    }

    func testCreateReportsTheTicketByItsAuthPartsCRC() throws {
        let (b, _, sent, tokens) = broker()
        let made = try b.create(type: .webAPI, identity: "svc").get()
        XCTAssertEqual(made.ticket.value.count, 2560)
        XCTAssertEqual(tokens.count, 9, "one token per ticket")
        XCTAssertEqual(sent.all.count, 1)
        let list = sent.all[0]
        XCTAssertEqual(list.appIDs, [367520], "the launched app, whatever the game asks")
        XCTAssertEqual(list.tokensLeft, 9)
        XCTAssertEqual(list.tickets.count, 1)
        let auth = list.tickets[0].ticket.value
        XCTAssertEqual(Array(made.ticket.value[..<auth.count]), auth)
        XCTAssertEqual(list.tickets[0].ticketCRC, CRC32.checksum(auth), "the CRC of the auth part only")
        XCTAssertEqual(list.tickets[0].serverSecret, Array("str:svc\0".utf8))
        XCTAssertEqual(b.status(made.handle)?.state, .pending)
        XCTAssertFalse("\(b)".contains("171"), "\(b)")
    }

    func testAckTimeoutCancelAndEndPlay() throws {
        let (b, clock, sent, _) = broker()
        let one = try b.create(type: .authSession, identity: "").get()
        clock.advance(2)
        let two = try b.create(type: .authSession, identity: "").get()
        XCTAssertEqual(sent.all.last?.tickets.count, 2, "the whole list each time")
        // Steam's ack names the first ticket by its CRC.
        var a = ProtoWriter()
        a.uint32(1, sent.all.last!.tickets[0].ticketCRC)
        b.handle(CMPacket(emsg: .clientAuthListAck, body: a.bytes))
        XCTAssertEqual(b.status(one.handle)?.state, .acked)
        XCTAssertEqual(b.status(two.handle)?.state, .pending)
        // No ack in 10 s: given anyway.
        clock.advance(10)
        XCTAssertEqual(b.status(two.handle)?.state, .acked)
        // A server refused the second.
        var c = ProtoWriter()
        c.uint32(4, 8); c.uint32(6, sent.all.last!.tickets[1].ticketCRC)
        b.handle(CMPacket(emsg: .clientTicketAuthComplete, body: c.bytes))
        XCTAssertEqual(b.status(two.handle)?.state, .failed)
        XCTAssertEqual(b.status(two.handle)?.eresult, 8)
        // Cancel takes the first out of the list by its auth part's CRC.
        let crcTwo = sent.all.last!.tickets[1].ticketCRC
        b.cancel(one.handle)
        XCTAssertEqual(sent.all.last?.tickets.map(\.ticketCRC), [crcTwo])
        XCTAssertNil(b.status(one.handle))
        // The play's end: an empty list, then nothing more.
        let end = b.endPlay()
        XCTAssertEqual(end?.tickets.count, 0)
        XCTAssertEqual(end?.appIDs, [367520])
        XCTAssertNil(b.endPlay())
        XCTAssertEqual(b.create(type: .authSession, identity: "").failure, .notArmed)
    }

    func testLimits() throws {
        let (b, clock, _, _) = broker()
        for _ in 0..<4 { _ = try b.create(type: .authSession, identity: "").get() }
        XCTAssertEqual(b.create(type: .authSession, identity: "").failure, .rateLimited, "a burst of 4")
        clock.advance(2)
        _ = try b.create(type: .authSession, identity: "").get()
        XCTAssertEqual(b.create(type: .authSession, identity: "").failure, .rateLimited, "then one each 2 s")
        for _ in 0..<3 { clock.advance(2); _ = try b.create(type: .authSession, identity: "").get() }
        clock.advance(60)
        XCTAssertEqual(b.create(type: .authSession, identity: "").failure, .tooManyLive, "8 live at most")

        let (few, _, _, _) = broker(tokens: 1)
        _ = try few.create(type: .authSession, identity: "").get()
        XCTAssertEqual(few.create(type: .authSession, identity: "").failure, .noTokens)
    }

    func testAClosedConnectionAsksForAReconnect() throws {
        let traffic = CMTraffic()
        let asked = Counter()
        var limits = SteamTicketBroker.Limits()
        limits.reconnectWait = 0.2
        let clock = FakeClock(), tokens = GameConnectTokens()
        tokens.add([Secret(token)], keep: 10)
        let b = SteamTicketBroker(appID: 1, ownershipTicket: Secret(ownership), tokens: tokens, traffic: traffic, log: .silent,
                                  limits: limits, send: { _ in }, reconnect: { asked.add("reconnect") },
                                  now: { ProcessInfo.processInfo.systemUptime + clock.now - 1000 })
        XCTAssertEqual(b.create(type: .authSession, identity: "").failure, .notArmed, "no connection: the emulator's own")
        XCTAssertEqual(asked.values, ["reconnect"])
        traffic.setOpen(true)
        XCTAssertNotNil(try? b.create(type: .authSession, identity: "").get())
        XCTAssertEqual(asked.values.count, 1)
    }

    func testTokensKeepTheNewest() {
        let t = GameConnectTokens()
        t.add([Secret([1]), Secret([2]), Secret([3])], keep: 2)
        XCTAssertEqual(t.take()?.value, [2])
        XCTAssertEqual(t.take()?.value, [3])
        XCTAssertNil(t.take())
    }
}

extension Result {
    var failure: Failure? { if case let .failure(e) = self { return e } else { return nil } }
}

final class TicketPushTests: XCTestCase {
    func testPushesReachTheHandlerNotTheMailbox() async throws {
        var tw = ProtoWriter()
        tw.uint32(1, 10); tw.bytes(2, [7, 7])
        let tokens = CMPacket(emsg: .clientGameConnectTokens, body: tw.bytes)
        var aw = ProtoWriter()
        aw.uint32(1, 5)
        let ack = CMPacket(emsg: .clientAuthListAck, body: aw.bytes)
        let got = Counter()
        let traffic = CMTraffic()
        let cm = CMConnection(endpoint: "loopback", log: .silent, traffic: traffic, push: { got.add("\($0.emsg)") })
        let loop = LoopbackCM { _ in [tokens, ack] }
        await cm.attach(loop)
        defer { loop.close() }
        XCTAssertTrue(traffic.isOpen)
        try await cm.send(.clientHeartBeat, CMsgClientHeartBeat())
        for _ in 0..<100 where got.values.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(got.values, ["779", "5575"])
        XCTAssertEqual(traffic.counts.received, 2)
        XCTAssertEqual(traffic.counts.sent, 1)
        do { _ = try await cm.next(.emsg(EMsg.clientAuthListAck.rawValue), timeout: 0.1); XCTFail("mailboxed") } catch SteamError.timeout(_) {}
        await cm.close()
        XCTAssertFalse(traffic.isOpen)
    }

    func testTheSessionsHandlerQueuesTokensAndRoutesTheRest() async throws {
        let session = SteamSession(store: MemorySecretStore(), log: .silent)
        let handler = session.pushHandler()
        var tw = ProtoWriter()
        tw.uint32(1, 2); tw.bytes(2, [1]); tw.bytes(2, [2]); tw.bytes(2, [3])
        handler(CMPacket(emsg: .clientGameConnectTokens, body: tw.bytes))
        XCTAssertEqual(session.connectTokens.count, 2)
        let routed = Counter()
        session.ticketPushes.set { routed.add("\($0.emsg)") }
        handler(CMPacket(emsg: .clientTicketAuthComplete, body: []))
        XCTAssertEqual(routed.values, ["5429"])
        await session.disconnect()
        XCTAssertEqual(session.connectTokens.count, 0, "tokens go with the logon")
    }
}

final class TicketServiceTests: XCTestCase {
    func signedIn(_ b: FakeBackend) async -> SteamService {
        await b.set(stored: FakeBackend.session(exp: 2_000_000_000))
        let s = SteamService(backend: b, log: .silent, stateDirectory: nil)
        _ = await s.restoreIfPossible()
        return s
    }

    func testAPlayKeepsTheCMForItsTicketsOnly() async throws {
        let b = FakeBackend()
        let s = await signedIn(b)
        b.connectTokens.add([Secret([1, 2, 3])], keep: 10)
        b.traffic.setOpen(true)
        let broker = await s.prepareTicketSession(appID: 945360)
        XCTAssertNotNil(broker)
        let played = await b.gamesPlayed
        XCTAssertEqual(played, [[945360]], "in the game for the play (decision 0062)")
        await s.suspendForLaunch()
        let on = await b.loggedOn
        XCTAssertTrue(on.connected, "the CM stays for the tickets")
        do { _ = try await s.ownedGames(refresh: true); XCTFail() } catch SteamError.unsupported(_) {}
        do { _ = try await s.refreshGameProfile(appID: 945360); XCTFail() } catch SteamError.unsupported(_) {}
        // A push reaches the play's broker.
        let made = try broker!.create(type: .authSession, identity: "").get()
        for _ in 0..<100 { if await !b.authLists.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let lists = await b.authLists
        XCTAssertEqual(lists.count, 1)
        var a = ProtoWriter()
        a.uint32(1, lists[0].tickets[0].ticketCRC)
        b.ticketPushes.deliver(CMPacket(emsg: .clientAuthListAck, body: a.bytes))
        XCTAssertEqual(broker!.status(made.handle)?.state, .acked)
        // The end: an empty list, out of the game, disarmed.
        await s.endPlay()
        let after = await b.authLists, playedAfter = await b.gamesPlayed
        XCTAssertEqual(after.last?.tickets.count, 0)
        XCTAssertEqual(playedAfter.last, [])
        XCTAssertFalse(broker!.isArmed)
    }

    func testNoTicketsWithoutASessionTokensOrOwnership() async throws {
        let b = FakeBackend()
        let off = SteamService(backend: b, log: .silent, stateDirectory: nil)
        let none = await off.prepareTicketSession(appID: 1)
        XCTAssertNil(none, "not signed in")

        let s = await signedIn(b)
        let noTokens = await s.prepareTicketSession(appID: 1)
        XCTAssertNil(noTokens, "Steam gave no token in 2 s")

        b.connectTokens.add([Secret([1])], keep: 10)
        await b.set(ownership: .failure(SteamError.eresult(.accessDenied, context: "ClientGetAppOwnershipTicket 1")))
        let notOwned = await s.prepareTicketSession(appID: 1)
        XCTAssertNil(notOwned)

        // Without a broker the launch closes the CM, as before.
        await s.suspendForLaunch()
        let on = await b.loggedOn
        XCTAssertFalse(on.connected)
        let suspended = await s.prepareTicketSession(appID: 1)
        XCTAssertNil(suspended)
    }
}
