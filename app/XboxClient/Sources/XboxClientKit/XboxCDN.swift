// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import ContentKit

/// Random access to a package's bytes: the CDN while installing, a file in tests.
public protocol XboxPackageBytes: Sendable {
    var size: UInt64 { get }
    /// Exactly `count` bytes from `offset`, or throws.
    func read(_ offset: UInt64, _ count: Int) async throws -> [UInt8]
}

/// A package file on disk (tests and host checks).
public final class XboxFilePackage: XboxPackageBytes, @unchecked Sendable {
    private let file: XboxLocalFile
    public let size: UInt64
    public init(_ url: URL) throws {
        file = try XboxLocalFile(url)
        size = file.size
    }
    public func read(_ offset: UInt64, _ count: Int) async throws -> [UInt8] { try file.read(offset, count) }
}

/// The package on Microsoft's CDN, read with HTTP range requests. Its roots are
/// plain HTTP (assets1/assets2.xboxlive.com have no certificate for their names), so
/// the bytes are trusted only after the package's hash tree checks them. A plain-HTTP
/// root goes over a socket of our own (App Transport Security would refuse it in
/// URLSession); HTTPS through the injected transport.
public struct XboxCDNPackage: XboxPackageBytes {
    public let size: UInt64
    let urls: [URL]
    let client: XboxRangeClient
    let https: any XboxHTTP
    let log: Logger

    public init(_ location: XboxPackageLocation, client: XboxRangeClient = XboxRangeClient(), https: any XboxHTTP = XboxURLSessionHTTP(limit: 8 << 20),
                log: Logger = .silent) {
        size = location.size; urls = location.urls; self.client = client; self.https = https; self.log = log
    }

    public func read(_ offset: UInt64, _ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        guard offset <= size, UInt64(count) <= size - offset else { throw XboxXVD.damaged("a read runs past the package's end") }
        var last: Error = ClientError.transport("Xbox CDN unreachable")
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let url = urls[attempt % urls.count]
            do {
                if url.scheme == "https" {
                    let r = try await https.send(XboxHTTPRequest(url: url, method: "GET",
                        headers: ["Range": Secret("bytes=\(offset)-\(offset + UInt64(count) - 1)")], body: Secret([])))
                    guard r.status == 206, r.body.value.count == count else { throw ClientError.transport("Xbox CDN returned HTTP \(r.status)") }
                    return r.body.value
                }
                return try await client.range(url, offset: offset, count: count, total: size)
            } catch let error as ClientError where error == .cancelled {
                throw error
            } catch is CancellationError {
                throw ClientError.cancelled
            } catch {
                last = error
                if attempt < 3 { try await Task.sleep(nanoseconds: UInt64(200_000_000) << UInt64(attempt)) }
            }
        }
        log.warn("xbox", "CDN range failed after 4 attempts")
        throw last
    }
}

/// HTTP/1.1 range GETs over keep-alive sockets: no redirects, no compression, no
/// chunked bodies; a 206 whose Content-Range is exactly the range asked for, or an
/// error. Blocking socket calls run off Swift's cooperative pool.
public final class XboxRangeClient: @unchecked Sendable {
    private let allows: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var idle: [String: [Int32]] = [:]
    static let timeout: Int32 = 30
    static let userAgent = "xodus-cli/0.1.0"

    /// `allows` vets a URL's host; by default Microsoft's xboxlive.com CDN only.
    public init(allows: @escaping @Sendable (String) -> Bool = { $0.hasSuffix(".xboxlive.com") }) {
        self.allows = allows
    }

    deinit { for fds in idle.values { for fd in fds { _ = sysClose(fd) } } }

    func range(_ url: URL, offset: UInt64, count: Int, total: UInt64) async throws -> [UInt8] {
        guard url.scheme == "http", let host = url.host?.lowercased(), allows(host),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClientError.unsafeContent("Xbox CDN URL is not an allowed plain-HTTP host")
        }
        let port = url.port ?? 80
        var target = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let q = parts.percentEncodedQuery { target += "?" + q }
        let request = "GET \(target) HTTP/1.1\r\nHost: \(host)\(port == 80 ? "" : ":\(port)")\r\nUser-Agent: \(Self.userAgent)\r\n"
            + "Accept: */*\r\nAccept-Encoding: identity\r\nConnection: keep-alive\r\n"
            + "Range: bytes=\(offset)-\(offset + UInt64(count) - 1)\r\n\r\n"
        let box = XboxSocketBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<[UInt8], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { k.resume(returning: try self.exchange(host: host, port: port, request: Array(request.utf8), offset: offset,
                                                               count: count, total: total, box: box)) }
                    catch { k.resume(throwing: box.cancelled ? ClientError.cancelled : error) }
                }
            }
        } onCancel: { box.cancel() }
    }

    private func exchange(host: String, port: Int, request: [UInt8], offset: UInt64, count: Int, total: UInt64, box: XboxSocketBox) throws -> [UInt8] {
        let key = "\(host):\(port)"
        // A pooled connection the server has since closed fails before any reply byte: try once more on a new one.
        for reuse in [true, false] {
            let pooled = reuse ? take(key) : nil
            if reuse && pooled == nil { continue }
            let fd = try pooled ?? Self.connect(host: host, port: port)
            guard box.set(fd) else { _ = sysClose(fd); throw ClientError.cancelled }
            do {
                let (body, keep) = try Self.roundTrip(fd, request: request, offset: offset, count: count, total: total)
                box.clear()
                if keep { give(key, fd) } else { _ = sysClose(fd) }
                return body
            } catch XboxSocketError.closedBeforeReply where pooled != nil {
                box.clear(); _ = sysClose(fd)
            } catch {
                box.clear(); _ = sysClose(fd)
                throw error is XboxSocketError ? ClientError.transport("Xbox CDN connection failed") : error
            }
        }
        throw ClientError.transport("Xbox CDN connection failed")
    }

    private func take(_ key: String) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return idle[key]?.popLast()
    }
    private func give(_ key: String, _ fd: Int32) {
        lock.lock()
        if idle[key, default: []].count < 32 { idle[key, default: []].append(fd); lock.unlock() } else { lock.unlock(); _ = sysClose(fd) }
    }

    static func connect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { throw XboxSocketError.resolve }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let a = node {
            node = a.pointee.ai_next
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            #if canImport(Darwin)
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var ok = socketConnect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
            if !ok, errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, timeout * 1000) == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    ok = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0
                }
            }
            guard ok else { _ = sysClose(fd); continue }
            _ = fcntl(fd, F_SETFL, flags)
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        throw XboxSocketError.connect
    }

    /// Sends the request and reads one response; the body and whether the connection may be reused.
    static func roundTrip(_ fd: Int32, request: [UInt8], offset: UInt64, count: Int, total: UInt64) throws -> ([UInt8], Bool) {
        var sent = 0
        while sent < request.count {
            #if canImport(Glibc)
            let n = request.withUnsafeBytes { send(fd, $0.baseAddress! + sent, request.count - sent, Int32(MSG_NOSIGNAL)) }
            #else
            let n = request.withUnsafeBytes { send(fd, $0.baseAddress! + sent, request.count - sent, 0) }
            #endif
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw XboxSocketError.io }
            sent += n
        }
        var buffer = [UInt8](), chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var headerEnd: Int?
        while headerEnd == nil {
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw buffer.isEmpty ? XboxSocketError.closedBeforeReply : XboxSocketError.io }
            buffer += chunk[0..<n]
            if let end = find(buffer, [13, 10, 13, 10]) { headerEnd = end }
            guard buffer.count <= 64 * 1024 || headerEnd != nil else { throw XboxSocketError.protocolError("headers too long") }
        }
        let head = String(decoding: buffer[0..<headerEnd!], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else { throw XboxSocketError.protocolError("status") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard code == 206 else {
            if code == 404 || code == 403 || code == 410 { throw ClientError.notFound("Xbox CDN has no such package (HTTP \(code))") }
            throw ClientError.transport("Xbox CDN returned HTTP \(code)")
        }
        guard headers["transfer-encoding"] == nil, (headers["content-encoding"] ?? "identity") == "identity" else {
            throw XboxSocketError.protocolError("encoded body")
        }
        let end = offset + UInt64(count) - 1
        guard headers["content-range"]?.lowercased() == "bytes \(offset)-\(end)/\(total)" else {
            throw ClientError.verificationFailed("Xbox CDN answered for a different range or package size")
        }
        guard Int(headers["content-length"] ?? "") == count else { throw XboxSocketError.protocolError("length") }
        var body = Array(buffer[(headerEnd! + 4)...])
        guard body.count <= count else { throw XboxSocketError.protocolError("extra bytes") }
        body.reserveCapacity(count)
        while body.count < count {
            let want = min(chunk.count, count - body.count)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, want, 0) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw XboxSocketError.io }
            body += chunk[0..<n]
        }
        let keep = status[0] == "HTTP/1.1" && headers["connection"]?.lowercased() != "close"
        return (body, keep)
    }

    static func find(_ b: [UInt8], _ needle: [UInt8]) -> Int? {
        guard b.count >= needle.count else { return nil }
        for i in 0...(b.count - needle.count) where b[i] == needle[0] && Array(b[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}

enum XboxSocketError: Error { case resolve, connect, io, closedBeforeReply, protocolError(String) }

/// The socket a request is using, so cancellation can shut it down mid-read.
final class XboxSocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var cancelled = false
    func set(_ value: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; fd = value; return !cancelled }
    func clear() { lock.lock(); fd = -1; lock.unlock() }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { _ = shutdown(fd, Int32(SHUT_RDWR)) }
    }
}

@inline(__always) private func socketConnect(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>!, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return Glibc.connect(fd, addr, len)
    #else
    return Darwin.connect(fd, addr, len)
    #endif
}

/// A local file read with `pread` from any thread.
final class XboxLocalFile: @unchecked Sendable {
    let fd: Int32
    let size: UInt64
    init(_ url: URL) throws {
        fd = sysOpen(url.path, O_RDONLY | O_CLOEXEC, 0)
        guard fd >= 0 else { throw ClientError.transport("cannot open \(url.lastPathComponent) (errno \(errno))") }
        var st = stat()
        guard fstat(fd, &st) == 0 else { _ = sysClose(fd); throw ClientError.transport("cannot stat \(url.lastPathComponent)") }
        size = UInt64(st.st_size)
    }
    deinit { _ = sysClose(fd) }
    func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
        guard offset <= size, UInt64(count) <= size - offset else { throw XboxXVD.damaged("a read runs past its end") }
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw XboxXVD.damaged("a read came back short") }
            done += n
        }
        return out
    }
}
