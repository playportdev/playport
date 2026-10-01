// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Depot access material and CDN transfers: the depot
/// decryption key, the manifest request code and content-server list over the
/// CM, then manifest and chunk downloads over HTTPS. Keys, request codes and
/// full CDN URLs stay in memory; logs name only the host.
public struct ContentClient: Sendable {
    let session: SteamSession
    let http: HTTPClient
    let log: Logger

    public init(session: SteamSession) async {
        self.session = session
        self.http = await session.http
        self.log = await session.log
    }

    private func cm() async throws -> CMConnection {
        guard let c = await session.cm else { throw SteamError.transport("not connected") }
        return c
    }

    public func depotKey(appID: UInt32, depotID: UInt32) async throws -> Secret<[UInt8]> {
        let p = try await cm().call(.clientGetDepotDecryptionKey, CMsgClientGetDepotDecryptionKey(depotID: depotID, appID: appID))
        guard p.knownEMsg == .clientGetDepotDecryptionKeyResponse else { throw SteamError.protocolChanged("depot key reply EMsg \(p.emsg)") }
        let r = try CMsgClientGetDepotDecryptionKeyResponse.decode(p.body)
        guard r.eresult == .ok else { throw SteamError.eresult(r.eresult, context: "GetDepotDecryptionKey(\(depotID))") }
        guard let key = r.key, key.value.count == 32 else { throw SteamError.protocolChanged("depot key missing or not 32 bytes") }
        return key
    }

    public func manifestRequestCode(appID: UInt32, depotID: UInt32, gid: UInt64, branch: String = "public") async throws -> Secret<UInt64> {
        let body = try await cm().serviceCall("ContentServerDirectory.GetManifestRequestCode#1",
                                              GetManifestRequestCodeRequest(appID: appID, depotID: depotID, manifestID: gid, appBranch: branch),
                                              authed: true)
        let code = try GetManifestRequestCodeResponse.decode(body).code
        guard code.value != 0 else { throw SteamError.eresult(.accessDenied, context: "GetManifestRequestCode returned 0") }
        return code
    }

    /// HTTPS-capable content servers, least loaded first, that serve `appID`.
    public func servers(appID: UInt32) async throws -> [GetServersForSteamPipeResponse.Server] {
        let cell = await session.cellID
        let body = try await cm().serviceCall("ContentServerDirectory.GetServersForSteamPipe#1",
                                              GetServersForSteamPipeRequest(cellID: cell), authed: true)
        let all = try GetServersForSteamPipeResponse.decode(body).servers
        let usable = all.filter { s in
            (s.type == "SteamCache" || s.type == "CDN")
                && (s.allowedAppIDs.isEmpty || s.allowedAppIDs.contains(appID))
                && s.httpsSupport != "unavailable"
        }.sorted { ($0.priorityClass ?? 0, $0.weightedLoad ?? 0) < ($1.priorityClass ?? 0, $1.weightedLoad ?? 0) }
        guard !usable.isEmpty else { throw SteamError.notFound("no HTTPS content server for app \(appID)") }
        return usable
    }

    public static let maxManifestDownload = 64 << 20
    public static let maxManifestUnzipped = 256 << 20

    public func manifest(appID: UInt32, depotID: UInt32, gid: UInt64, depotKey: Secret<[UInt8]>,
                         servers: [GetServersForSteamPipeResponse.Server], branch: String = Branch.publicName)
        async throws -> (DepotManifest, rawSHA1: String) {
        let code = try await manifestRequestCode(appID: appID, depotID: depotID, gid: gid, branch: branch)
        var last: Error = SteamError.notFound("manifest")
        for server in servers.prefix(3) {
            try Task.checkCancellation()
            let url = URL(string: "https://\(server.vhost)/depot/\(depotID)/manifest/\(gid)/\(PinnedSchema.manifestVersion)/\(code.value)")!
            do {
                let zipped = try await http.get(url, maxBytes: Self.maxManifestDownload, label: "manifest \(depotID) via \(server.vhost)")
                let raw = try ZipSingleEntry.extract(zipped, maxSize: Self.maxManifestUnzipped)
                let m = try DepotManifest(raw, depotKey: depotKey, expectDepot: depotID, expectGID: gid)
                return (m, SHA1.hash(raw).hex)
            } catch SteamError.cancelled {
                throw SteamError.cancelled
            } catch {
                log.warn("cdn", "manifest from \(server.vhost) failed: \(error)")
                last = error
            }
        }
        throw last
    }

    /// Downloads, decrypts, decompresses and verifies one chunk: length,
    /// Adler-32 (manifest crc) and SHA-1 (the chunk id).
    public func chunk(depotID: UInt32, _ c: ContentManifestPayload.Chunk, depotKey: AES256Decryptor,
                      servers: [GetServersForSteamPipeResponse.Server]) async throws -> [UInt8] {
        var last: Error = SteamError.notFound("chunk")
        for server in servers.prefix(3) {
            try Task.checkCancellation()
            let url = URL(string: "https://\(server.vhost)/depot/\(depotID)/chunk/\(c.sha.hex)")!
            do {
                let enc = try await http.get(url, maxBytes: Int(DepotManifest.maxChunkBytes) + 64, label: "chunk via \(server.vhost)")
                if c.cbCompressed != 0, enc.count != Int(c.cbCompressed) {
                    throw SteamError.verificationFailed("chunk \(c.sha.hex.prefix(12)) is \(enc.count) bytes, manifest says \(c.cbCompressed)")
                }
                return try Self.processChunk(enc, c, key: depotKey)
            } catch SteamError.cancelled {
                throw SteamError.cancelled
            } catch let e as SteamError {
                if case .unsupported = e { throw e }
                log.warn("cdn", "chunk \(c.sha.hex.prefix(12)) from \(server.vhost) failed: \(e)")
                last = e
            }
        }
        throw last
    }

    /// One chunk from one server, verified; failover is the caller's
    /// (`CDNChunkSource` spreads chunks over the server list).
    public func chunk(depotID: UInt32, _ c: ContentManifestPayload.Chunk, depotKey: AES256Decryptor,
                      server: GetServersForSteamPipeResponse.Server) async throws -> [UInt8] {
        let url = URL(string: "https://\(server.vhost)/depot/\(depotID)/chunk/\(c.sha.hex)")!
        let enc = try await http.get(url, maxBytes: Int(DepotManifest.maxChunkBytes) + 64, label: "chunk via \(server.vhost)")
        if c.cbCompressed != 0, enc.count != Int(c.cbCompressed) {
            throw SteamError.verificationFailed("chunk \(c.sha.hex.prefix(12)) is \(enc.count) bytes, manifest says \(c.cbCompressed)")
        }
        return try Self.processChunk(enc, c, key: depotKey)
    }

    public static func processChunk(_ enc: [UInt8], _ c: ContentManifestPayload.Chunk, key: AES256Decryptor) throws -> [UInt8] {
        let decrypted = try key.decryptSteam(enc)
        let plain = try ChunkCodec.decompress(decrypted, expectedSize: Int(c.cbOriginal))
        guard plain.count == Int(c.cbOriginal) else { throw SteamError.verificationFailed("chunk length \(plain.count) != \(c.cbOriginal)") }
        guard SteamAdler32.checksum(plain) == c.crc else { throw SteamError.verificationFailed("chunk \(c.sha.hex.prefix(12)) Adler-32 mismatch") }
        guard SHA1.hash(plain) == c.sha else { throw SteamError.verificationFailed("chunk \(c.sha.hex.prefix(12)) SHA-1 mismatch") }
        return plain
    }
}
