// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The CM transport seam: one binary WebSocket message in, one out. Each CM
/// packet is exactly one message, so the transport must preserve message
/// boundaries.
protocol WebSocketTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// The next whole message.
    func receive() async throws -> [UInt8]
    func close()
}

enum WebSocketTransports {
    static let maxMessageBytes = 32 << 20

    static func open(url: URL, timeout: Double) async throws -> WebSocketTransport {
        #if os(Linux)
        // The Linux host runs only the offline tests: its URLSessionWebSocketTask
        // splits messages, which breaks CM framing.
        throw SteamError.transport("no CM transport on the Linux host")
        #else
        return try await FoundationWebSocket.open(url: url, timeout: timeout)
        #endif
    }
}

#if !os(Linux)
/// Apple platforms: URLSessionWebSocketTask (Network.framework). Message
/// boundaries hold by construction: `receive` completes with one
/// `URLSessionWebSocketTask.Message`, which Apple documents as read "once all
/// the frames of the message are available", so continuation frames are
/// joined before the caller sees anything and one CM packet is one `.data`.
/// A message over `maximumMessageSize` fails the receive instead of being
/// split. Nothing here reads a byte stream.
final class FoundationWebSocket: WebSocketTransport, @unchecked Sendable {
    let session: URLSession
    let task: URLSessionWebSocketTask

    private init(_ session: URLSession, _ task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    static func open(url: URL, timeout: Double) async throws -> WebSocketTransport {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = WebSocketTransports.maxMessageBytes
        task.resume()
        return FoundationWebSocket(session, task)
    }

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.send(.data(Data(bytes))) { error in
                if let error { c.resume(throwing: SteamError.transport("websocket send: \((error as NSError).code)")) } else { c.resume() }
            }
        }
    }

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
            task.receive { result in
                switch result {
                case let .success(.data(d)): c.resume(returning: [UInt8](d))
                case .success: c.resume(throwing: SteamError.protocolChanged("text frame on CM socket"))
                case let .failure(e): c.resume(throwing: SteamError.transport("websocket receive: \((e as NSError).code)"))
                }
            }
        }
    }

    /// One session per connection: invalidating it here keeps a QR login,
    /// which reconnects about every 65 s, from leaking a session each time.
    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}
#endif
