// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs `op` with a deadline. The loser of the race is cancelled, so a
/// cancellation-aware `op` releases whatever it was waiting on.
func withDeadline<T: Sendable>(_ seconds: Double, _ what: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SteamError.timeout(what)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw SteamError.cancelled }
        return first
    }
}

/// One connection to a Steam CM over its WebSocket endpoint
/// (wss://<endpoint>/cmsocket/, WebSocketConnection.kt). TLS carries the
/// channel security, so there is no Steam-level channel encryption handshake.
///
/// Replies are matched to requests by job id; unsolicited messages the client
/// cares about (license list, logged-off) are buffered per EMsg until read.
public actor CMConnection {
    public enum Key: Hashable, Sendable { case job(UInt64), emsg(UInt32) }

    public let endpoint: String
    let log: Logger
    private var socket: WebSocketTransport?
    private var nextJob: UInt64 = 1
    private var activeJobs = Set<UInt64>()
    private var waiters: [Key: [UUID: CheckedContinuation<CMPacket, Error>]] = [:]
    private var mailbox: [Key: [CMPacket]] = [:]
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var failure: SteamError?

    public private(set) var steamID: UInt64 = 0
    public private(set) var sessionID: Int32 = 0

    /// Unsolicited messages kept for a later `next(.emsg(...))`.
    static let bufferedEMsgs: Set<UInt32> = [
        EMsg.clientLogOnResponse.rawValue, EMsg.clientLicenseList.rawValue, EMsg.clientLoggedOff.rawValue,
        EMsg.clientPersonaState.rawValue, EMsg.clientGetUserStatsResponse.rawValue,
        EMsg.clientStoreUserStatsResponse.rawValue,
    ]
    static let mailboxLimit = 8

    public init(endpoint: String, log: Logger) {
        self.endpoint = endpoint
        self.log = log
    }

    public var isOpen: Bool { socket != nil && failure == nil }

    public func connect(timeout: Double = 15) async throws {
        guard socket == nil else { return }
        guard let url = URL(string: "wss://\(endpoint)/cmsocket/") else { throw SteamError.transport("bad CM endpoint") }
        let box = try await withDeadline(timeout, "CM connect") { try await WebSocketTransports.open(url: url, timeout: timeout) }
        // ClientHello opens the session for unauthenticated service calls
        // (CMClient.java onClientConnected); its send also proves the socket is up.
        try await withDeadline(timeout, "CM connect") { try await box.send(CMPacket(emsg: .clientHello, body: CMsgClientHello().encode()).serialize()) }
        attach(box)
        log.info("cm", "connected to CM \(endpoint) (websocket)")
    }

    func attach(_ box: WebSocketTransport) {
        socket = box
        receiveTask = Task { [weak self] in await self?.receiveLoop(box) }
    }

    private func receiveLoop(_ box: WebSocketTransport) async {
        while !Task.isCancelled {
            do {
                let frame = try await box.receive()
                let packet = try CMPacket.parse(frame)
                if packet.knownEMsg == .multi {
                    let log = self.log
                    for p in try CMPacket.expandMulti(packet.body, skipped: { log.debug("cm", "skipped legacy message \($0) in a Multi") }) { dispatch(p) }
                } else {
                    dispatch(packet)
                }
            } catch let e as SteamError {
                if case .protocolChanged = e {
                    // One unparseable frame is a typed, logged failure; keep reading.
                    log.warn("cm", "dropped frame: \(e)")
                    continue
                }
                fail(e)
                return
            } catch {
                fail(.transport("\(type(of: error))"))
                return
            }
        }
    }

    private func dispatch(_ p: CMPacket) {
        if p.knownEMsg == .clientLogOnResponse {
            if let sid = p.header.steamID { steamID = sid }
            if let s = p.header.clientSessionID { sessionID = s }
        }
        if let target = p.header.jobIDTarget, target != ProtoHeader.noJob, activeJobs.contains(target) {
            deliver(.job(target), p)
            return
        }
        let key = Key.emsg(p.emsg)
        if Self.bufferedEMsgs.contains(p.emsg) || waiters[key]?.isEmpty == false {
            deliver(key, p)
        } else {
            log.debug("cm", "unhandled EMsg \(p.emsg)")
        }
    }

    private func deliver(_ key: Key, _ p: CMPacket) {
        if var w = waiters[key], let (id, c) = w.first {
            w.removeValue(forKey: id)
            waiters[key] = w
            c.resume(returning: p)
            return
        }
        var box = mailbox[key, default: []]
        box.append(p)
        if box.count > Self.mailboxLimit { box.removeFirst() }
        mailbox[key] = box
    }

    private func fail(_ e: SteamError) {
        guard failure == nil else { return }
        failure = e
        log.warn("cm", "connection closed: \(e)")
        for (_, ws) in waiters { for (_, c) in ws { c.resume(throwing: e) } }
        waiters = [:]
        heartbeatTask?.cancel()
    }

    /// Next packet for `key`, from the mailbox or as it arrives.
    public func next(_ key: Key, timeout: Double = 20) async throws -> CMPacket {
        if var box = mailbox[key], !box.isEmpty {
            let p = box.removeFirst()
            mailbox[key] = box
            return p
        }
        if let failure { throw failure }
        return try await withDeadline(timeout, "waiting for \(key)") { [self] in try await self.wait(key) }
    }

    private func wait(_ key: Key) async throws -> CMPacket {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<CMPacket, Error>) in
                if Task.isCancelled { c.resume(throwing: SteamError.cancelled); return }
                if let failure { c.resume(throwing: failure); return }
                if var box = mailbox[key], !box.isEmpty {
                    let p = box.removeFirst()
                    mailbox[key] = box
                    c.resume(returning: p)
                    return
                }
                waiters[key, default: [:]][id] = c
            }
        } onCancel: {
            Task { await self.cancelWaiter(key, id) }
        }
    }

    private func cancelWaiter(_ key: Key, _ id: UUID) {
        if let c = waiters[key]?.removeValue(forKey: id) { c.resume(throwing: SteamError.cancelled) }
    }

    public func beginJob() -> UInt64 {
        let id = nextJob
        nextJob += 1
        activeJobs.insert(id)
        return id
    }

    public func endJob(_ id: UInt64) {
        activeJobs.remove(id)
        mailbox[.job(id)] = nil
        if let ws = waiters.removeValue(forKey: .job(id)) { for (_, c) in ws { c.resume(throwing: SteamError.cancelled) } }
    }

    /// Sends one message; once logged on, the header carries the session.
    public func send(_ emsg: EMsg, _ body: some ProtoMessage, header: ProtoHeader = ProtoHeader()) async throws {
        if let failure { throw failure }
        guard let socket else { throw SteamError.transport("not connected") }
        var h = header
        if h.steamID == nil, steamID != 0 { h.steamID = steamID }
        if h.clientSessionID == nil, sessionID != 0 { h.clientSessionID = sessionID }
        try await socket.send(CMPacket(emsg: emsg, header: h, body: body.encode()).serialize())
    }

    /// A request whose reply (`reply`) may or may not target its job: the first
    /// of the job's reply and a buffered `reply` message that `accept` takes
    /// (the others, answers to earlier requests, are dropped).
    public func callEither(_ emsg: EMsg, _ body: some ProtoMessage, reply: EMsg, timeout: Double = 20,
                           accept: @escaping @Sendable (CMPacket) -> Bool) async throws -> CMPacket {
        let job = beginJob()
        defer { endJob(job) }
        var h = ProtoHeader()
        h.jobIDSource = job
        try await send(emsg, body, header: h)
        return try await withThrowingTaskGroup(of: CMPacket.self) { group in
            group.addTask { try await self.next(.job(job), timeout: timeout) }
            group.addTask {
                let deadline = Date().addingTimeInterval(timeout)
                while true {
                    let left = deadline.timeIntervalSinceNow
                    guard left > 0 else { throw SteamError.timeout("waiting for \(reply)") }
                    let p = try await self.next(.emsg(reply.rawValue), timeout: left)
                    if accept(p) { return p }
                    self.log.debug("cm", "dropped a \(reply) for another request")
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SteamError.cancelled }
            return first
        }
    }

    /// A request answered by a job-targeted reply.
    public func call(_ emsg: EMsg, _ body: some ProtoMessage, timeout: Double = 20) async throws -> CMPacket {
        let job = beginJob()
        defer { endJob(job) }
        var h = ProtoHeader()
        h.jobIDSource = job
        try await send(emsg, body, header: h)
        return try await next(.job(job), timeout: timeout)
    }

    /// Unified service method ("Service.Method#1"). Before logon it uses the
    /// non-authenticated EMsg, as SteamAuthentication does.
    public func serviceCall(_ method: String, _ body: some ProtoMessage, authed: Bool, timeout: Double = 20) async throws -> [UInt8] {
        let job = beginJob()
        defer { endJob(job) }
        var h = ProtoHeader()
        h.jobIDSource = job
        h.targetJobName = method
        if !authed { h.steamID = 0; h.clientSessionID = 0 }
        try await send(authed ? .serviceMethodCallFromClient : .serviceMethodCallFromClientNonAuthed, body, header: h)
        let reply = try await next(.job(job), timeout: timeout)
        switch reply.knownEMsg {
        case .serviceMethodResponse: break
        case .destJobFailed: throw SteamError.transport("\(method): destination job failed")
        default: throw SteamError.protocolChanged("\(method): reply EMsg \(reply.emsg)")
        }
        guard reply.header.result == .ok else {
            throw SteamError.eresult(reply.header.result, context: method)
        }
        return reply.body
    }

    public func startHeartbeat(seconds: Int) {
        heartbeatTask?.cancel()
        let interval = UInt64(max(5, seconds)) * 1_000_000_000
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }
                try? await self.send(.clientHeartBeat, CMsgClientHeartBeat())
            }
        }
    }

    public func close() {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        socket?.close()
        socket = nil
        fail(.transport("closed by client"))
    }
}
