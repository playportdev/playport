// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import EpicClientKit
@testable import ContentKit

final class EpicClientKitTests: XCTestCase {
    func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil))))
    }

    func temp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("epic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    // MARK: sign-in

    func testTheRedirectPageGivesTheCodeOrSaysWhatEpicWants() {
        let code = "fc17d388a24a41e38c52349098f58aff"
        XCTAssertEqual(EpicAPI.redirectPage(Array(#"{"warning":"x","redirectUrl":"https://localhost/launcher/authorized?code=\#(code)","authorizationCode":"\#(code)","sid":null}"#.utf8)),
                       .code(Secret(code)))
        XCTAssertEqual(EpicAPI.redirectPage(Array(#"{"redirectUrl":"https://localhost/launcher/authorized?code=\#(code)","authorizationCode":null}"#.utf8)),
                       .code(Secret(code)))
        XCTAssertEqual(EpicAPI.redirectPage(Array(#"{"redirectUrl":"https://evil.example/?code=\#(code)","authorizationCode":null}"#.utf8)), .none)
        XCTAssertEqual(EpicAPI.redirectPage(Array(#"{"errorCode":"errors.com.epicgames.oauth.corrective_action_required","metadata":{"correctiveAction":"PRIVACY_POLICY_ACCEPTANCE","continuation":"x"}}"#.utf8)),
                       .correctiveAction("PRIVACY_POLICY_ACCEPTANCE"))
        XCTAssertEqual(EpicAPI.redirectPage(Array("<html>".utf8)), .none)
        XCTAssertTrue(EpicAPI.isRedirect(EpicAPI.redirectURL))
        XCTAssertFalse(EpicAPI.isRedirect(URL(string: "https://www.epicgames.com/id/login")!))
        XCTAssertTrue(EpicAPI.loginURL.absoluteString.hasPrefix("https://www.epicgames.com/id/login?redirectUrl=https://www.epicgames.com/id/api/redirect"))
    }

    func testTokensParseAndTheSessionIsKeptUntilSignOut() async throws {
        let now = Date()
        let t = try EpicSession.parseTokens(Array(#"{"access_token":"eg1~a","refresh_token":"eg1~r","expires_in":129600,"refresh_expires":31540000,"account_id":"x"}"#.utf8), now: now)
        XCTAssertEqual(t.expiresAt.timeIntervalSince(now), 129600, accuracy: 1)
        XCTAssertEqual(t.refreshExpiresAt.timeIntervalSince(now), 31540000, accuracy: 1)
        XCTAssertThrowsError(try EpicSession.parseTokens(Array("{}".utf8), now: now))

        let store = MemorySecretStore()
        try store.write(EpicSession.key, Secret([UInt8](try JSONEncoder.epic.encode(t))))
        let s = EpicSession(store: store, log: .silent)
        let up = await s.state
        XCTAssertEqual(up, .signedIn)
        let token = try await s.accessToken()
        XCTAssertEqual(token.value, "eg1~a", "a token with hours left is not refreshed")

        // An expired access token: sign-out skips Epic's kill (no network here) and deletes the item.
        var old = t
        old.expiresAt = now.addingTimeInterval(-10)
        try store.write(EpicSession.key, Secret([UInt8](try JSONEncoder.epic.encode(old))))
        let again = EpicSession(store: store, log: .silent)
        await again.signOut()
        XCTAssertNil(try store.read(EpicSession.key))
        let gone = await again.state
        XCTAssertEqual(gone, .signedOut)

        // A refresh token past its date is no session.
        old.refreshExpiresAt = now.addingTimeInterval(-10)
        try store.write(EpicSession.key, Secret([UInt8](try JSONEncoder.epic.encode(old))))
        let lapsed = await EpicSession(store: store, log: .silent).state
        XCTAssertEqual(lapsed, .signedOut)
    }

    func testTokensAreRedactedInLogs() {
        XCTAssertEqual(Redactor.scrub("got eg1~abc.def-ghi now"), "got <eg1:redacted> now")
        XCTAssertFalse(Redactor.scrub(#"{"authorizationCode":"fc17d388a24a41e38c52349098f58aff"}"#).contains("fc17d388"))
    }

    // MARK: library

    func testTheLibraryPagesAndTheCatalogue() throws {
        let page = try EpicLibrary.parseLibrary(Array(#"{"records":[{"appName":"Hazelnut","namespace":"ns1","catalogItemId":"c1","sandboxType":"PUBLIC","recordType":"APPLICATION"}],"responseMetadata":{"nextCursor":"abc"}}"#.utf8))
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(page.next, "abc")
        XCTAssertNil(try EpicLibrary.parseLibrary(Array(#"{"records":[],"responseMetadata":{}}"#.utf8)).next)

        let items = try EpicLibrary.parseCatalog(Array(#"""
        {"c1":{"title":"Limbo","keyImages":[{"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/t"},{"type":"DieselGameBox","url":"https://cdn1.epicgames.com/w"}],
               "customAttributes":{"FolderName":{"type":"STRING","value":"Limbo"},"CanRunOffline":{"type":"STRING","value":"true"},"PresenceId":{"value":"x"}},
               "releaseInfo":[{"platform":["Win32","Windows"]}]},
         "c2":{"title":"A DLC","mainGameItem":{"id":"c1"},"releaseInfo":[{"platform":["Windows"]}]},
         "c3":{"title":"Mac only","releaseInfo":[{"platform":["Mac"]}]}}
        """#.utf8))
        let r = EpicLibrary.Record(appName: "Hazelnut", namespace: "ns1", catalogItemId: "c1", sandboxType: "PUBLIC")
        let g = try XCTUnwrap(items["c1"]?.game(r))
        XCTAssertEqual(g.id, "Hazelnut")
        XCTAssertEqual(g.folderName, "Limbo")
        XCTAssertEqual(g.attributes.keys.sorted(), ["CanRunOffline", "FolderName"], "only the attributes Playport uses are kept")
        XCTAssertEqual(g.art(width: 800)?.absoluteString, "https://cdn1.epicgames.com/w?w=800&resize=1")
        XCTAssertNil(g.refusal)
        XCTAssertNil(items["c2"]?.game(r), "a DLC is not a game")
        XCTAssertNil(items["c3"]?.game(r), "no Windows release")
    }

    func testRefusalsFromTheCatalogue() {
        var g = EpicGame(id: "a", namespace: "n", catalogItemID: "c", title: "T")
        XCTAssertNil(g.refusal)
        g.attributes = ["OwnershipToken": "true"]
        XCTAssertEqual(g.refusal, EpicGame.needsOnlineSignIn)
        g.attributes = ["CanRunOffline": "false"]
        XCTAssertEqual(g.refusal, EpicGame.needsOnlineSignIn)
        g.attributes = ["UseAccessControl": "true"]
        XCTAssertEqual(g.refusal, EpicGame.needsOnlineSignIn)
        g.attributes = ["UseAccessControl": "false", "CanRunOffline": "true"]
        XCTAssertNil(g.refusal)
        g.attributes = ["ThirdPartyManagedProvider": "Origin"]
        XCTAssertNotNil(g.refusal)
    }

    func testTheAssetKeepsTheTokenForTheManifestOnlyAndTheBaseForChunks() throws {
        let a = try EpicContent.parseAsset(Array(#"""
        {"elements":[{"appName":"x","buildVersion":"1150","hash":"5bdbfe8594a9ec6ee6f3d1d8d30c741a65c44f6d","manifests":[
          {"uri":"https://egs-cloudfront-chunks.epicgamescdn.com/Builds/Org/o-1/d3/default/UW1.manifest","queryParams":[{"name":"cf_token","value":"T"}]},
          {"uri":"http://insecure.example/x.manifest"},
          {"uri":"https://egdownload.fastly-edge.com/Builds/Org/o-1/d3/default/UW1.manifest","queryParams":[]}]}]}
        """#.utf8))
        XCTAssertEqual(a.buildVersion, "1150")
        XCTAssertEqual(a.hash?.hex, "5bdbfe8594a9ec6ee6f3d1d8d30c741a65c44f6d")
        XCTAssertEqual(a.locations.count, 2, "an http manifest is dropped")
        XCTAssertEqual(a.locations[0].manifest.absoluteString, "https://egs-cloudfront-chunks.epicgamescdn.com/Builds/Org/o-1/d3/default/UW1.manifest?cf_token=T")
        XCTAssertEqual(a.locations[0].base.absoluteString, "https://egs-cloudfront-chunks.epicgamescdn.com/Builds/Org/o-1/d3/default/")
        XCTAssertNil(a.locations[1].manifest.query)
    }

    // MARK: manifest

    func testARealManifestParses() throws {
        let m = try EpicManifest.parse(try fixture("hazelnut.manifest"))
        XCTAssertEqual(m.appName, "Hazelnut")
        XCTAssertEqual(m.buildVersion, "1.0.1")
        XCTAssertEqual(m.launchExe, "LimboLauncher.exe")
        XCTAssertEqual(m.featureLevel, 17)
        XCTAssertEqual(m.chunks.count, 100)
        XCTAssertEqual(m.files.count, 44)
        XCTAssertEqual(m.installBytes, 103_357_949)
        XCTAssertEqual(m.downloadBytes, 87_849_993)
        let d3d = try XCTUnwrap(m.files.first { $0.path == "D3DCompiler_43.dll" })
        XCTAssertEqual(d3d.size, 2_106_216)
        XCTAssertEqual(d3d.sha1.hex, "98be17e1d324790a5b206e1ea1cc4e64fbe21240")
        XCTAssertEqual(m.chunks[d3d.parts[0].chunk].guidHex, "5165827046ED6C3F035A2CB7EE39C984")
        XCTAssertTrue(m.chunkPath(m.chunks[0]).hasPrefix("ChunksV4/"))
        XCTAssertTrue(EpicChunkSource.safe(m.chunkPath(m.chunks[0])))
        XCTAssertNil(m.refusal)

        let plan = try EpicContent.plan(m)
        XCTAssertEqual(plan.files.count, 44)
        XCTAssertEqual(plan.chunks.count, 100)
        XCTAssertEqual(plan.totalBytes, 103_357_949)
        XCTAssertTrue(plan.files.flatMap(\.parts).contains { $0.offsetInChunk != 0 }, "Epic's files slice chunks")
        XCTAssertEqual(try EpicContent.plan(m, only: ["d3dcompiler_43.dll"]).files.map(\.path), ["D3DCompiler_43.dll"])
    }

    func testATruncatedOrDamagedManifestThrowsAndNeverCrashes() throws {
        let raw = try fixture("hazelnut.manifest")
        for n in stride(from: 0, to: raw.count, by: 97) { XCTAssertThrowsError(try EpicManifest.parse(Array(raw[0..<n]))) }
        var flipped = raw
        flipped[raw.count / 2] ^= 0x55
        XCTAssertThrowsError(try EpicManifest.parse(flipped), "the body's SHA-1 catches a flipped byte")

        // The decoded body, cut and mutated, through the field parser itself.
        let m = try EpicManifest.parse(raw)
        let body = ManifestWriter.body(m)
        XCTAssertEqual(try EpicManifest.parseBody(body).files.count, 44, "the writer round-trips")
        for n in stride(from: 0, to: body.count, by: 211) { XCTAssertThrowsError(try EpicManifest.parseBody(Array(body[0..<n]))) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var b = body
            for _ in 0..<4 { b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? EpicManifest.parseBody(b)
        }
        // An oversized count is refused before anything is allocated.
        var big = body
        let fmlCount = ManifestWriter.offsetOfFileCount(m)
        big.replaceSubrange(fmlCount..<(fmlCount + 4), with: [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertThrowsError(try EpicManifest.parseBody(big))
    }

    func testAnUnsafePathIsRefused() throws {
        var m = try EpicManifest.parse(try fixture("hazelnut.manifest"))
        m.files[0].path = "../evil.dll"
        XCTAssertThrowsError(try EpicManifest.parseBody(ManifestWriter.body(m)))
        var anti = try EpicManifest.parse(try fixture("hazelnut.manifest"))
        anti.files[0].path = "EasyAntiCheat/EasyAntiCheat_Setup.exe"
        XCTAssertNotNil(try EpicManifest.parseBody(ManifestWriter.body(anti)).refusal)
    }

    // MARK: chunks, install, verify

    func testAChunkFileDecodesAndIsChecked() throws {
        let plain = (0..<4096).map { UInt8($0 & 0xFF) }
        let c = EpicManifest.Chunk(guid: Array(1...16), hash: 7, sha1: SHA1.hash(plain), group: 3, window: 4096, fileSize: 0)
        XCTAssertEqual(try EpicChunkFile.decode(ManifestWriter.chunkFile(c, plain, zlib: true), expect: c), plain)
        XCTAssertEqual(try EpicChunkFile.decode(ManifestWriter.chunkFile(c, plain, zlib: false), expect: c), plain)
        var other = c
        other.guid = Array(2...17)
        XCTAssertThrowsError(try EpicChunkFile.decode(ManifestWriter.chunkFile(c, plain, zlib: true), expect: other))
        var bad = plain
        bad[9] ^= 1
        XCTAssertThrowsError(try EpicChunkFile.decode(ManifestWriter.chunkFile(c, bad, zlib: true), expect: c))
        XCTAssertThrowsError(try EpicChunkFile.decode(Array(ManifestWriter.chunkFile(c, plain, zlib: true).prefix(60)), expect: c))
    }

    func testAnInstallOfSlicedChunksVerifiesAndAFlippedByteIsFound() async throws {
        // Two chunks; a.bin is all of chunk 0 and the head of chunk 1, b.bin the tail of chunk 1.
        let c0 = (0..<1000).map { UInt8($0 % 251) }, c1 = (0..<600).map { UInt8(($0 * 7) % 253) }
        let a = c0 + c1[0..<200], b = Array(c1[200...])
        let chunks = [EpicManifest.Chunk(guid: Array(repeating: 1, count: 16), hash: 1, sha1: SHA1.hash(c0), group: 1, window: 1000, fileSize: 1100),
                      EpicManifest.Chunk(guid: Array(repeating: 2, count: 16), hash: 2, sha1: SHA1.hash(c1), group: 2, window: 600, fileSize: 700)]
        let m = EpicManifest(featureLevel: 17, appName: "Test", buildVersion: "1", launchExe: "bin/game.exe", launchCommand: "-x \"a b\"",
                             prerequisites: [], chunks: chunks,
                             files: [.init(path: "bin/game.exe", symlinkTarget: "", sha1: SHA1.hash(a), flags: 4, installTags: [],
                                           parts: [.init(chunk: 0, offset: 0, size: 1000), .init(chunk: 1, offset: 0, size: 200)]),
                                     .init(path: "data/b.bin", symlinkTarget: "", sha1: SHA1.hash(b), flags: 0, installTags: [],
                                           parts: [.init(chunk: 1, offset: 200, size: 400)])],
                             custom: [:])
        let raw = ManifestWriter.file(m)
        let parsed = try EpicManifest.parse(raw)
        XCTAssertEqual(parsed.files.map(\.size), [1200, 400])

        let root = try temp()
        let layout = InstallLayout.root(root)
        let plan = try EpicContent.plan(parsed)
        let source = MapSource(files: [m.chunkPath(chunks[0]): ManifestWriter.chunkFile(chunks[0], c0, zlib: true),
                                       m.chunkPath(chunks[1]): ManifestWriter.chunkFile(chunks[1], c1, zlib: true)], manifest: parsed)
        let engine = InstallEngine(tree: layout.gamesRoot.appendingPathComponent("Test"), journal: root.appendingPathComponent("j"),
                                   source: source, log: .silent)
        _ = try await engine.run(plan)
        XCTAssertEqual([UInt8](try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Test/bin/game.exe"))), a)
        XCTAssertEqual([UInt8](try Data(contentsOf: layout.gamesRoot.appendingPathComponent("Test/data/b.bin"))), b)

        let installer = EpicInstaller(layout: layout, session: EpicSession(store: MemorySecretStore(), log: .silent), log: .silent)
        let g = EpicGame(id: "Test", namespace: "n", catalogItemID: "c", title: "Test")
        let rec = installer.record(g, parsed, folder: "Test")
        XCTAssertEqual(rec.launchExe, "bin\\game.exe")
        try installer.save(rec, manifest: raw)
        XCTAssertEqual(installer.loadRecord("Test"), rec)
        var r = try await installer.verify("Test")
        XCTAssertEqual(r.files, 2)
        XCTAssertEqual(r.bad, [])
        let h = try FileHandle(forUpdating: layout.gamesRoot.appendingPathComponent("Test/data/b.bin"))
        try h.seek(toOffset: 10)
        h.write(Data([b[10] ^ 0xFF]))
        try h.close()
        r = try await installer.verify("Test")
        XCTAssertEqual(r.bad, ["data/b.bin"])

        XCTAssertEqual(EpicInstaller.arguments(rec, game: nil), ["-x", "a b", "-epicapp=Test", "-epicenv=Prod", "-EpicPortal", "-epiclocale=en"])
        installer.forget("Test")
        XCTAssertNil(installer.loadRecord("Test"))
    }

    func testUniqueFolders() throws {
        let root = try temp()
        XCTAssertEqual(EpicInstaller.unique("Limbo", in: root), "Limbo")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("limbo"), withIntermediateDirectories: true)
        XCTAssertEqual(EpicInstaller.unique("Limbo", in: root), "Limbo (Epic)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Limbo (Epic)"), withIntermediateDirectories: true)
        XCTAssertEqual(EpicInstaller.unique("Limbo", in: root), "Limbo (Epic) 2")
    }
}

/// Chunk files from memory, decoded as the CDN source does.
struct MapSource: ContentChunkSource {
    var files: [String: [UInt8]]
    var manifest: EpicManifest

    func chunk(_ c: ContentChunk) async throws -> [UInt8] {
        guard let f = files[c.locator ?? ""], let m = manifest.chunks.first(where: { $0.guid == c.key }) else { throw ClientError.notFound("chunk") }
        return try EpicChunkFile.decode(f, expect: m)
    }
}

/// Writes Epic's binary forms (version 0 sections), for round trips and fuzzing.
enum ManifestWriter {
    static func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    static func u64(_ v: UInt64) -> [UInt8] { u32(UInt32(v & 0xFFFF_FFFF)) + u32(UInt32(v >> 32)) }
    static func str(_ s: String) -> [UInt8] { s.isEmpty ? u32(0) : u32(UInt32(s.utf8.count + 1)) + Array(s.utf8) + [0] }

    static func section(_ version: UInt8, _ content: [UInt8]) -> [UInt8] { u32(UInt32(content.count + 5)) + [version] + content }

    static func meta(_ m: EpicManifest) -> [UInt8] {
        section(0, u32(m.featureLevel) + [0] + u32(0) + str(m.appName) + str(m.buildVersion) + str(m.launchExe) + str(m.launchCommand)
                + u32(UInt32(m.prerequisites.count)) + m.prerequisites.flatMap(str) + str("") + str("") + str(""))
    }

    static func cdl(_ m: EpicManifest) -> [UInt8] {
        var b = u32(UInt32(m.chunks.count))
        b += m.chunks.flatMap(\.guid)
        b += m.chunks.flatMap { u64($0.hash) }
        b += m.chunks.flatMap(\.sha1)
        b += m.chunks.map(\.group)
        b += m.chunks.flatMap { u32($0.window) }
        b += m.chunks.flatMap { u64($0.fileSize) }
        return section(0, b)
    }

    static func fml(_ m: EpicManifest) -> [UInt8] {
        var b = u32(UInt32(m.files.count))
        b += m.files.flatMap { str($0.path) }
        b += m.files.flatMap { str($0.symlinkTarget) }
        b += m.files.flatMap(\.sha1)
        b += m.files.map(\.flags)
        b += m.files.flatMap { u32(UInt32($0.installTags.count)) + $0.installTags.flatMap(str) }
        b += m.files.flatMap { f in
            u32(UInt32(f.parts.count)) + f.parts.flatMap { p in u32(28) + m.chunks[p.chunk].guid + u32(p.offset) + u32(p.size) }
        }
        return section(0, b)
    }

    static func body(_ m: EpicManifest) -> [UInt8] { meta(m) + cdl(m) + fml(m) }

    /// Where the file list's count is in `body(m)`.
    static func offsetOfFileCount(_ m: EpicManifest) -> Int { meta(m).count + cdl(m).count + 5 }

    /// A whole manifest file, its body zlib-stored.
    static func file(_ m: EpicManifest) -> [UInt8] {
        let plain = body(m), z = zlib(plain)
        return u32(EpicManifest.magic) + u32(41) + u32(UInt32(plain.count)) + u32(UInt32(z.count)) + SHA1.hash(plain) + [1] + u32(17) + z
    }

    static func chunkFile(_ c: EpicManifest.Chunk, _ plain: [UInt8], zlib z: Bool) -> [UInt8] {
        let data = z ? zlib(plain) : plain
        return u32(EpicChunkFile.magic) + u32(3) + u32(66) + u32(UInt32(data.count)) + c.guid + u64(c.hash) + [z ? 1 : 0]
            + SHA1.hash(plain) + [3] + u32(UInt32(plain.count)) + data
    }

    /// zlib with stored deflate blocks (no compression; valid for any inflater).
    static func zlib(_ d: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, d.count - i)
            let last: UInt8 = i + n >= d.count ? 1 : 0
            out += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)] + d[i..<(i + n)]
            i += n
        } while i < d.count
        let a = SteamAdler32.checksum(d, seed: 1)
        return out + [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)]
    }
}
