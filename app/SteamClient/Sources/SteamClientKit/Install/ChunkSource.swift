// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where the install engine gets a chunk's plaintext. An implementation
/// returns bytes already checked against the chunk's length, Adler-32 and
/// SHA-1, or throws.
public protocol ChunkSource: Sendable {
    func chunk(depotID: UInt32, _ c: ContentManifestPayload.Chunk) async throws -> [UInt8]
}

/// The content servers a job spreads its chunk requests over, round-robin. A
/// server that fails `dropAfter` times in a row is dropped for the rest of the
/// job; when every server is dropped the job fails.
public actor ServerPool {
    public typealias Server = GetServersForSteamPipeResponse.Server
    let servers: [Server]
    let dropAfter: Int
    let log: Logger
    private var next = 0
    private var failures: [Int] = []
    private var dropped = Set<Int>()

    public init(_ servers: [Server], use: Int = 8, dropAfter: Int = 4, log: Logger) {
        self.servers = Array(servers.prefix(max(1, use)))
        self.dropAfter = dropAfter
        self.log = log
        failures = Array(repeating: 0, count: self.servers.count)
    }

    public var count: Int { servers.count - dropped.count }

    func pick() throws -> (Int, Server) {
        guard dropped.count < servers.count else { throw SteamError.retriesExhausted("every content server was dropped after repeated failures") }
        while dropped.contains(next % servers.count) { next += 1 }
        let i = next % servers.count
        next += 1
        return (i, servers[i])
    }

    func succeeded(_ i: Int) { failures[i] = 0 }

    func failed(_ i: Int) {
        failures[i] += 1
        if failures[i] >= dropAfter, dropped.insert(i).inserted {
            log.warn("cdn", "dropping \(servers[i].vhost) after \(failures[i]) consecutive failures; \(servers.count - dropped.count) servers left")
        }
    }
}

/// Chunks from the Steam CDN: each request goes to the pool's next server and
/// fails over to others. A depot every server refuses with HTTP 401/403/404 is
/// reported as needing a CDN auth token, which this client does not implement.
public struct CDNChunkSource: ChunkSource {
    let content: ContentClient
    let keys: [UInt32: AES256Decryptor]
    let pool: ServerPool
    let log: Logger
    public var attemptsPerChunk = 4

    public init(content: ContentClient, keys: [UInt32: AES256Decryptor], pool: ServerPool, log: Logger) {
        self.content = content
        self.keys = keys
        self.pool = pool
        self.log = log
    }

    public func chunk(depotID: UInt32, _ c: ContentManifestPayload.Chunk) async throws -> [UInt8] {
        guard let key = keys[depotID] else { throw SteamError.notFound("no depot key held for depot \(depotID)") }
        var last: Error = SteamError.notFound("chunk")
        var denied = 0
        let attempts = min(attemptsPerChunk, max(1, await pool.count))
        for _ in 0..<attempts {
            try Task.checkCancellation()
            let (i, server) = try await pool.pick()
            do {
                let plain = try await content.chunk(depotID: depotID, c, depotKey: key, server: server)
                await pool.succeeded(i)
                return plain
            } catch SteamError.cancelled {
                throw SteamError.cancelled
            } catch let e as SteamError {
                if case .unsupported = e { throw e }
                if case .eresult(.accessDenied, _) = e { denied += 1 }
                log.warn("cdn", "chunk \(c.sha.hex.prefix(12)) from \(server.vhost) failed: \(e)")
                await pool.failed(i)
                last = e
            }
        }
        if denied == attempts {
            throw SteamError.unsupported("the CDN refused depot \(depotID) chunks from \(denied) servers (HTTP 401/403/404): CDN auth tokens (GetCDNAuthToken) are not supported")
        }
        throw last
    }
}
