// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
