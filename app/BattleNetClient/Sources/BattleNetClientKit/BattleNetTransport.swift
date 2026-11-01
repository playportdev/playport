// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a server answered: its HTTP status, the headers the client reads (lowercased names)
/// and the body.
public struct BattleNetResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: [UInt8]

    public init(status: Int, headers: [String: String] = [:], body: [UInt8]) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// How the client behaves on Blizzard's servers (decision 0174): a User-Agent naming Playport,
/// at most `maxConcurrent` requests in flight, and on HTTP 429 a pause of that host for the
/// `Retry-After` it sends (else a doubling back-off) before asking again, `retries` times.
public struct BattleNetManners: Sendable {
    public var userAgent = "Playport"
    public var maxConcurrent = 8
    public var retries = 5
    /// The first pause when a 429 names none; it doubles per retry, up to `maxBackoff`.
    public var backoff: Double = 2
    public var maxBackoff: Double = 120
    /// Waits; tests record the pauses instead.
    public var sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }

    public init() {}
}

/// The requests in flight, and the hosts paused by a 429 until a time.
actor RequestGate {
    let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var pausedUntil: [String: Date] = [:]

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    func pause(_ host: String, for seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        if until > pausedUntil[host] ?? .distantPast { pausedUntil[host] = until }
    }

    /// How long `host` is still paused.
    func pause(of host: String) -> Double {
        guard let until = pausedUntil[host] else { return 0 }
        return max(0, until.timeIntervalSinceNow)
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
/// `unsupported` are about content that did arrive; `outdated` is the install's.
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
    /// A region or language change asked of an install on another build than the region's
    /// current one (`installed`, `current`: version names): it changes after an update.
    case outdated(installed: String, current: String)

    /// Whether the failure is the network's (try later) rather than the content's.
    public var isNetwork: Bool {
        switch self {
        case .unreachable, .refused: return true
        case .damaged, .missingKey, .unsupported, .outdated: return false
        }
    }

    public var description: String {
        switch self {
        case let .unreachable(s): return "unreachable: \(s)"
        case let .refused(status, s): return "refused: HTTP \(status): \(s)"
        case let .damaged(s): return "damaged: \(s)"
        case let .missingKey(k): return "missing decryption key \(k)"
        case let .unsupported(s): return "unsupported: \(s)"
        case let .outdated(installed, current): return "outdated: the install is on \(installed), the region on \(current)"
        }
    }
}

/// The URLSession transport: HTTPS GETs with Playport's User-Agent (decision 0174), no cookies,
/// no cache, no redirects (a 3xx is the answer, so only the hosts the endpoints name are asked),
/// and a cap on the body size.
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
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.maxBytes = maxBytes
    }

    /// Declines every redirect, so the 3xx itself comes back and the client refuses it.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> BattleNetResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard data.count <= maxBytes else {
            throw BattleNetError.damaged("\(url.host ?? "?")\(url.path): \(data.count) bytes exceeds the cap \(maxBytes)")
        }
        let http = response as? HTTPURLResponse
        var fields = [String: String]()
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { fields[k.lowercased()] = v }
        }
        return BattleNetResponse(status: http?.statusCode ?? 0, headers: fields, body: [UInt8](data))
    }
}
