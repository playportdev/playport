// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import BattleNetClientKit

/// A one-thread HTTP server on 127.0.0.1: `/start` answers 302 to `/elsewhere`, anything else
/// 200. It records the paths it was asked for.
final class RedirectingServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var seen = [String]()
    var paths: [String] { lock.withLock { seen } }

    init() throws {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) == 0 && listen(s, 8) == 0 && getsockname(s, $0, &len) == 0 }
        }
        guard bound else { close(s); throw BattleNetError.unreachable("test server: errno \(errno)") }
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var request = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
            while !String(decoding: request, as: UTF8.self).contains("\r\n\r\n") {
                let n = recv(c, &chunk, chunk.count, 0)
                guard n > 0 else { break }
                request += chunk[..<n]
            }
            let path = String(decoding: request, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.withLock { seen.append(path) }
            let answer = path == "/start"
                ? "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nmoved"
            _ = Array(answer.utf8).withUnsafeBytes { send(c, $0.baseAddress, $0.count, 0) }
            close(c)
        }
    }
}

final class BattleNetTransportTests: XCTestCase {
    /// A redirect is not followed to a host the endpoints never named (decision 0174): the 3xx
    /// is the answer, which the client refuses.
    func testARedirectIsReturnedNotFollowed() async throws {
        let server = try RedirectingServer()
        defer { server.stop() }
        let response = try await URLSessionTransport().get(URL(string: "http://127.0.0.1:\(server.port)/start")!, headers: [:])
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(response.headers["location"], "http://127.0.0.1:\(server.port)/elsewhere")
        XCTAssertEqual(server.paths, ["/start"])
    }
}
