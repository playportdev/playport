// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounded HTTPS GET used for the CM directory and the content CDN. Responses
/// are size-capped; transient failures retry a fixed number of times with
/// backoff; cancellation propagates. URLs are never logged unscrubbed.
public struct HTTPClient: Sendable {
    public var maxAttempts = 3
    public var timeout: TimeInterval = 30
    let session: URLSession
    let log: Logger

    public init(log: Logger) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Valve/Steam HTTP Client 1.0"]
        // The installer keeps several chunk requests in flight per CDN host.
        config.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: config)
        self.log = log
    }

    public func get(_ url: URL, maxBytes: Int, label: String) async throws -> [UInt8] {
        var lastError: SteamError = .transport("\(label): no attempt")
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard data.count <= maxBytes else {
                    throw SteamError.unsafeContent("\(label): \(data.count) bytes exceeds cap \(maxBytes)")
                }
                switch status {
                case 200: return [UInt8](data)
                case 401, 403, 404, 410:
                    throw SteamError.eresult(.accessDenied, context: "\(label): HTTP \(status)")
                default:
                    lastError = .transport("\(label): HTTP \(status)")
                }
            } catch let e as SteamError {
                if case .transport = e {} else { throw e }
                lastError = e
            } catch is CancellationError {
                throw SteamError.cancelled
            } catch let e as URLError where e.code == .cancelled {
                throw SteamError.cancelled
            } catch {
                lastError = .transport("\(label): \(type(of: error)) \((error as NSError).code)")
            }
            log.warn("http", "\(label) attempt \(attempt)/\(maxAttempts) failed: \(lastError)")
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 750_000_000)
            }
        }
        throw SteamError.retriesExhausted(lastError.description)
    }
}

extension HTTPClient {
    /// One request as Steam hands it out for a cloud file body (a GET to
    /// download, a PUT per upload block), with Steam's headers. Not retried:
    /// the caller redoes the whole transfer. Returns the body of a 2xx reply.
    public func send(_ r: CloudHTTPRequest, body: [UInt8]?, maxBytes: Int, label: String) async throws -> [UInt8] {
        guard let url = r.url else { throw SteamError.protocolChanged("\(label): bad URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = [1: "GET", 2: "HEAD", 3: "POST", 4: "PUT", 5: "DELETE"][r.method] ?? "PUT"
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body { request.httpBody = Data(body) }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw SteamError.transport("\(label): HTTP \(status)") }
            guard data.count <= maxBytes else { throw SteamError.unsafeContent("\(label): \(data.count) bytes exceeds cap \(maxBytes)") }
            return [UInt8](data)
        } catch let e as SteamError {
            throw e
        } catch is CancellationError {
            throw SteamError.cancelled
        } catch {
            throw SteamError.transport("\(label): \(type(of: error)) \((error as NSError).code)")
        }
    }
}

/// Steam directory: which CM WebSocket endpoints to use.
public enum CMDirectory {
    public static func websocketEndpoints(http: HTTPClient, cellID: UInt32 = 0) async throws -> [String] {
        let url = URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=\(cellID)&maxcount=20")!
        let body = try await http.get(url, maxBytes: 1 << 20, label: "ISteamDirectory/GetCMListForConnect")
        struct Envelope: Decodable {
            struct Response: Decodable {
                struct Server: Decodable { let endpoint: String; let type: String }
                let serverlist: [Server]
                let success: Bool
            }
            let response: Response
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: Data(body)), env.response.success else {
            throw SteamError.protocolChanged("GetCMListForConnect: unexpected JSON shape")
        }
        let endpoints = env.response.serverlist.filter { $0.type == "websockets" }.map(\.endpoint)
        guard !endpoints.isEmpty else { throw SteamError.notFound("no websocket CM endpoints") }
        return endpoints
    }
}
