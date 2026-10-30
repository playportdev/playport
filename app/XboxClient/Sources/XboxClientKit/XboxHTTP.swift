// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContentKit

/// One seam for every Xbox service: request in, status and bytes out. Never logs
/// a URL, header, body or a system error's localized description (which can hold them).
public struct XboxHTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: Secret<String>]
    public let body: Secret<[UInt8]>
    public init(url: URL, method: String = "POST", headers: [String: Secret<String>] = [:], body: Secret<[UInt8]>) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}

public struct XboxHTTPResponse: Sendable {
    public let status: Int
    public let body: Secret<[UInt8]>
    /// Lower-cased names. Values are provider data: never log them.
    public let headers: [String: String]
    public init(status: Int, body: [UInt8], headers: [String: String] = [:]) {
        self.status = status; self.body = Secret(body); self.headers = headers
    }
}

public protocol XboxHTTP: Sendable {
    func send(_ request: XboxHTTPRequest) async throws -> XboxHTTPResponse
}

/// Ephemeral (no cookies or cache), no retries and no redirects. Callers classify
/// faults, rather than turning a provider refusal into an automatic new device.
public final class XboxURLSessionHTTP: XboxHTTP, @unchecked Sendable {
    private let limit: Int
    private let session: URLSession
    /// `limit` caps a response body: Microsoft's sign-in replies fit the default; a
    /// display-catalogue page of 20 products can be several MiB.
    public init(limit: Int = 1024 * 1024) {
        self.limit = limit
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: XboxNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ input: XboxHTTPRequest) async throws -> XboxHTTPResponse {
        var request = URLRequest(url: input.url)
        request.httpMethod = input.method
        if !input.body.value.isEmpty { request.httpBody = Data(input.body.value) } // a GET carries none
        for (name, value) in input.headers { request.setValue(value.value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= limit, let response = response as? HTTPURLResponse else {
                throw ClientError.protocolChanged("Xbox HTTP response is invalid or too large")
            }
            var headers: [String: String] = [:]
            for case let (name as String, value as String) in response.allHeaderFields { headers[name.lowercased()] = value }
            return XboxHTTPResponse(status: response.statusCode, body: Array(data), headers: headers)
        } catch let error as ClientError { throw error }
        catch is CancellationError { throw ClientError.cancelled }
        catch { throw ClientError.transport("Xbox request failed; check your connection") }
    }
}

private final class XboxNoRedirect: NSObject, URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
