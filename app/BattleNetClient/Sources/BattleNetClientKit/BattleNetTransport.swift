// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a server answered: its HTTP status and body.
public struct BattleNetResponse: Sendable, Equatable {
    public var status: Int
    public var body: [UInt8]

    public init(status: Int, body: [UInt8]) {
        self.status = status
        self.body = body
    }
}

/// The client's one way to the network: a request in, a status and bytes out. It throws only
/// when no answer came (no route, refused connection, timeout, TLS); any answer, whatever its
/// status, is returned. Tests inject recorded responses through it.
public protocol BattleNetTransport: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> BattleNetResponse
}

/// Every failure the client reports. `unreachable` and `refused` are the network's (no answer,
/// or an answer that is not the content: 404, 403, 429, 5xx); `damaged`, `missingKey` and
/// `unsupported` are about content that did arrive.
public enum BattleNetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No answer: the transport threw (offline, DNS, refused connection, timeout).
    case unreachable(String)
    /// An answer other than the content: the HTTP status and what was asked.
    case refused(status: Int, String)
    /// The content arrived but is wrong: truncated, a bad magic or hash, a missing field.
    case damaged(String)
    /// An encrypted BLTE block whose key (the 16-hex-digit lookup) is not in the keyring.
    case missingKey(String)
    /// A well-formed format this client does not read (LZ4 or nested BLTE blocks, ARC4).
    case unsupported(String)

    /// Whether the failure is the network's (try later) rather than the content's.
    public var isNetwork: Bool {
        switch self {
        case .unreachable, .refused: return true
        case .damaged, .missingKey, .unsupported: return false
        }
    }

    public var description: String {
        switch self {
        case let .unreachable(s): return "unreachable: \(s)"
        case let .refused(status, s): return "refused: HTTP \(status): \(s)"
        case let .damaged(s): return "damaged: \(s)"
        case let .missingKey(k): return "missing decryption key \(k)"
        case let .unsupported(s): return "unsupported: \(s)"
        }
    }
}

/// The URLSession transport: HTTPS GETs with Playport's User-Agent (decision 0168), no cookies,
/// no cache, and a cap on the body size.
public struct URLSessionTransport: BattleNetTransport {
    public let session: URLSession
    public var timeout: TimeInterval = 30
    public var maxBytes: Int

    public init(userAgent: String = "Playport", maxBytes: Int = 512 << 20) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
        self.maxBytes = maxBytes
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> BattleNetResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard data.count <= maxBytes else {
            throw BattleNetError.damaged("\(url.host ?? "?")\(url.path): \(data.count) bytes exceeds the cap \(maxBytes)")
        }
        return BattleNetResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: [UInt8](data))
    }
}
