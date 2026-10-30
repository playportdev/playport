// SPDX-License-Identifier: GPL-3.0-only
// Xodus Nexus e0668a12f1da931aed13537ef04295599011317b src/main/xodus-service.ts
// (startXodusBridge: a free loopback port, a 64-character key first, a 10 s wait for
// it) and the xgameruntime-tcp-bridge patch (XODUS_BRIDGE_PORT/KEY); translated to
// Swift by the Playport authors, 2026-10-30, after Playport's GalaxyListener.
// Modified: the frames are answered here, not relayed; sign-out closes it.
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import ContentKit

/// The bridge's socket for one Xbox play (decision 0167): 127.0.0.1 on a free port,
/// from the play's start to its end. A connection must send the play's key before
/// anything else; each frame then goes to the service in order and its reply is
/// written back. A wrong key, a malformed or oversized frame ends that connection, and
/// so does sending nothing for `idleLimit` once keyed (a reply being waited for, such
/// as the player's save choice, doesn't count). The account's sign-out ends the service
/// and closes every connection and the port. Connections are logged, their bytes never are.
public final class XboxBridgeListener: @unchecked Sendable {
    static let maxConnections = 8
    /// Nexus closes a connection that has not sent the key in 10 s.
    static let keyDeadline: TimeInterval = 10
    /// A keyed connection quiet this long is closed, so idle ones can't hold every slot.
    public static let idleDefault: TimeInterval = 300

    let service: XboxBridgeService
    let log: Logger
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var connections: Set<Int32> = []
    private var stopped = false
    private var accepted = 0
    private var boundPort: UInt16 = 0
    private var signOutHandler: UInt64?

    let idleLimit: TimeInterval

    public init(service: XboxBridgeService, log: Logger, idleLimit: TimeInterval = XboxBridgeListener.idleDefault) {
        self.service = service
        self.log = log
        self.idleLimit = idleLimit
    }

    public enum StartError: Error, CustomStringConvertible {
        case socket(Int32), bind(Int32), listen(Int32)
        public var description: String {
            switch self {
            case let .socket(e): "socket: errno \(e)"
            case let .bind(e): "bind: errno \(e)"
            case let .listen(e): "listen: errno \(e)"
            }
        }
    }

    /// The port the system chose; 0 before `start()`.
    public var port: UInt16 { lock.withLock { boundPort } }

    /// For the title's environment only, never the app's: the runtime connects to
    /// `XODUS_BRIDGE_PORT` and sends `XODUS_BRIDGE_KEY` first. Never log the key.
    public var guestEnvironment: [String: Secret<String>] {
        ["XODUS_BRIDGE_PORT": Secret(String(port)), "XODUS_BRIDGE_KEY": service.key]
    }

    /// Binds 127.0.0.1 on a free port, follows the account's sign-out and starts accepting.
    public func start() async throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw StartError.socket(errno) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else {
            let e = errno
            close(fd)
            throw StartError.bind(e)
        }
        guard listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            throw StartError.listen(e)
        }
        lock.withLock { listenFD = fd; boundPort = UInt16(bigEndian: addr.sin_port) }
        let id = await service.account.onSignOut { [weak self] in self?.signedOut() }
        let late = lock.withLock { () -> Bool in
            if !stopped { signOutHandler = id }
            return stopped
        }
        if late { await service.account.removeSignOutHandler(id) }
        let t = Thread { [self] in acceptLoop(fd) }
        t.name = "xbox-bridge-listener"
        t.start()
        log.info("xbox", "bridge: listening on 127.0.0.1:\(port) for this play")
    }

    /// Ends the play's bridge: stops accepting and ends every connection; the
    /// threads leave within a quarter second.
    public func stop() {
        // Under the lock, as every close is: no descriptor here can have been reused.
        let (fds, handler): ([Int32], UInt64?) = lock.withLock {
            guard !stopped else { return ([], nil) }
            stopped = true
            let fds = [listenFD] + Array(connections)
            for fd in fds where fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }
            defer { signOutHandler = nil }
            return (fds, signOutHandler)
        }
        guard !fds.isEmpty else { return }
        let service = self.service, log = self.log, connections = lock.withLock { accepted }
        Task.detached {
            if let handler { await service.account.removeSignOutHandler(handler) }
            let summary = await service.summary
            log.info("xbox", "bridge: stopped; \(connections) connection(s) in the play; \(summary)")
        }
    }

    private func signedOut() {
        service.revoke()
        log.info("xbox", "bridge: signed out; the channel is closed")
        stop()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    /// Waits up to 250 ms for `fd` to be readable; false when it was not.
    private func readable(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 250) > 0
    }

    private func acceptLoop(_ fd: Int32) {
        defer {
            lock.withLock {
                listenFD = -1
                close(fd)
            }
        }
        while !isStopped {
            guard readable(fd) else { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            let admitted: Bool = lock.withLock {
                guard !stopped, connections.count < Self.maxConnections else { return false }
                connections.insert(c)
                accepted += 1
                return true
            }
            guard admitted else {
                close(c)
                continue
            }
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            log.info("xbox", "bridge: a connection from the game")
            let t = Thread { [self] in serve(c) }
            t.name = "xbox-bridge-connection"
            t.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.withLock {
                connections.remove(fd)
                close(fd)
            }
        }
        var reader = XboxBridgeReader(key: Array(service.key.value.utf8))
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        let opened = Date()
        var active = opened
        var received = 0, frames = 0
        while !isStopped {
            if !reader.authenticated, Date().timeIntervalSince(opened) > Self.keyDeadline {
                log.warn("xbox", "bridge: no key in \(Int(Self.keyDeadline)) s: connection closed")
                return
            }
            if reader.authenticated, Date().timeIntervalSince(active) > idleLimit {
                log.info("xbox", "bridge: idle for \(Int(idleLimit)) s after \(frames) frame(s): connection closed")
                return
            }
            guard readable(fd) else { continue }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else {
                let why = n == 0 ? "the game closed a connection" : "a connection failed (errno \(errno))"
                log.info("xbox", "bridge: \(why) after \(received) bytes in \(frames) frame(s)")
                return
            }
            received += n
            active = Date()
            let parsed: [XboxBridgeFrame]
            do { parsed = try reader.receive(chunk[0..<n]) } catch {
                log.warn("xbox", "bridge: \(error): connection closed")
                return
            }
            for frame in parsed {
                frames += 1
                guard let reply = handle(frame), !isStopped, write(fd, reply.encoded) else { return }
                active = Date()
            }
        }
    }

    /// The service's reply to one frame, waited for on this connection's thread.
    private func handle(_ frame: XboxBridgeFrame) -> XboxBridgeFrame? {
        final class Box: @unchecked Sendable { var frame: XboxBridgeFrame? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let service = self.service
        Task.detached {
            box.frame = await service.handle(frame)
            done.signal()
        }
        done.wait()
        return box.frame
    }

    private func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var at = 0
        while at < bytes.count {
            #if canImport(Glibc)
            let flags = Int32(MSG_NOSIGNAL)
            #else
            let flags: Int32 = 0
            #endif
            let n = bytes[at...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, flags) }
            guard n > 0 else { return false }
            at += n
        }
        return true
    }
}
