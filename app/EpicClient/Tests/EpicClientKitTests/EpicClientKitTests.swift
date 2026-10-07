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
        XCTAssertTrue(g.mayPlayOffline)
        // A Play signs these in (decision 0059): no refusal.
        g.attributes = ["OwnershipToken": "true"]
        XCTAssertNil(g.refusal)
        XCTAssertTrue(g.needsOwnershipToken)
        XCTAssertFalse(g.mayPlayOffline)
        g.attributes = ["CanRunOffline": "false"]
        XCTAssertNil(g.refusal)
        XCTAssertFalse(g.needsOwnershipToken)
        XCTAssertFalse(g.mayPlayOffline)
        g.attributes = ["UseAccessControl": "false", "CanRunOffline": "true"]
        XCTAssertNil(g.refusal)
        XCTAssertTrue(g.mayPlayOffline)
        // Anti-cheat and other companies' launchers stay out, each saying which.
        g.attributes = ["UseAccessControl": "true"]
        XCTAssertEqual(g.refusal, EpicManifest.usesAntiCheat)
        g.attributes = ["ThirdPartyManagedProvider": "UbisoftConnect"]
        XCTAssertEqual(g.refusal, "This game is installed and started through Ubisoft Connect, which Playport does not run.")
        g.attributes = ["ThirdPartyManagedProvider": "Origin"]
        XCTAssertEqual(g.refusal, "This game is installed through another company's launcher, which Playport does not run.")
        g.attributes = [:]
        for (app, word) in [("9c203b6ed35846e8a4a9ff1e314f6593", "Frontier"), ("0fb6e06aacd14e88b1aaea8f54dd8525", "Cryptic"),
                            ("575efd0b5dd54429b035ffc8fe2d36d0", "anti-cheat")] {
            g.id = app
            XCTAssertTrue(g.refusal?.contains(word) ?? false, app)
        }
    }

    // MARK: a game's sign-in (decision 0059)

    func testTheLaunchSignInRepliesParse() throws {
        let code = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(try EpicSession.parseExchange(Array(#"{"expiresInSeconds":299,"code":"\#(code)","creatingClientId":"34a02cf8f4414e29b15921876da36f9a"}"#.utf8)).value, code)
        XCTAssertThrowsError(try EpicSession.parseExchange(Array(#"{"code":"short"}"#.utf8)))
        XCTAssertThrowsError(try EpicSession.parseExchange(Array("{}".utf8)))
        let ovt = "egoc1~" + "eyJhbGciOiJFUzI1NiJ9.e30.c2ln"   // split, so that pp secrets does not find it
        // The reply as Epic sent it, which the -epicovt file holds (a bare token fails a game's DRM).
        XCTAssertEqual(try EpicSession.parseOwnershipToken(Array(#"{"token":"\#(ovt)"}"#.utf8)).value, #"{"token":"\#(ovt)"}"#)
        XCTAssertThrowsError(try EpicSession.parseOwnershipToken(Array(ovt.utf8)), "a bare token is not Epic's reply")
        XCTAssertThrowsError(try EpicSession.parseOwnershipToken(Array(#"{"token":"\#(String(repeating: "a", count: 1 << 15))"}"#.utf8)))
        XCTAssertThrowsError(try EpicSession.parseOwnershipToken(Array(#"{"token":""}"#.utf8)))
        XCTAssertThrowsError(try EpicSession.parseOwnershipToken(Array(#"{"token":"a b"}"#.utf8)))
        // Epic's verify reply, as served: `display_name`.
        let who = try EpicSession.parseVerify(Array(#"{"token":"x","account_id":"\#(code)","display_name":"Some One"}"#.utf8))
        XCTAssertEqual(who.accountID.value, code)
        XCTAssertEqual(who.displayName.value, "Some One")
        XCTAssertThrowsError(try EpicSession.parseVerify(Array(#"{"account_id":"../x"}"#.utf8)))
        let t = try EpicSession.parseTokens(Array(#"{"access_token":"a","refresh_token":"r","account_id":"\#(code)","displayName":"Some One"}"#.utf8), now: Date())
        XCTAssertEqual(t.accountID, code)
        XCTAssertEqual(t.displayName, "Some One")
        XCTAssertTrue(EpicSession.isName("9707a7d2a6b34b1e8d4f0f6c3a0e6b11"))
        XCTAssertFalse(EpicSession.isName("a/b"))
    }

    func testTheSignedInArgumentsAndTheirRedaction() throws {
        let rec = EpicInstalled(appName: "Test", namespace: "ns", catalogItemID: "c", buildVersion: "1", installDir: "My Game",
                                launchExe: "game.exe", launchCommand: "", files: 1, bytes: 1)
        let code = "0123456789abcdef0123456789abcdef", user = "fedcba9876543210fedcba9876543210"
        let auth = EpicLaunchAuth(exchangeCode: Secret(code),
                                  account: EpicAccountIdentity(accountID: Secret(user), displayName: Secret("Some One")),
                                  namespace: "ns", ownershipFile: EpicOwnershipFile.windowsPath(installDir: rec.installDir))
        let args = EpicInstaller.arguments(rec, game: nil, auth: auth)
        XCTAssertEqual(args, ["-epicapp=Test", "-epicenv=Prod", "-EpicPortal", "-epiclocale=en",
                              "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=\(code)", "-AUTH_TYPE=exchangecode",
                              "-epicusername=Some One", "-epicuserid=\(user)", "-epicsandboxid=ns",
                              "-epicovt=C:\\Games\\My Game\\playport-epic.ovt"])
        XCTAssertEqual(EpicInstaller.arguments(rec, game: nil), Array(args.prefix(4)), "the receipt's arguments carry no sign-in")
        var noToken = auth
        noToken.ownershipFile = nil
        XCTAssertFalse(EpicInstaller.authArguments(noToken).contains { $0.hasPrefix("-epicovt") })
        let shown = EpicInstaller.redacted(args).joined(separator: " ")
        for secret in [code, user, "Some One"] { XCTAssertFalse(shown.contains(secret), secret) }
        XCTAssertTrue(shown.contains("-AUTH_PASSWORD=<redacted>"))
        XCTAssertTrue(shown.contains("-epicsandboxid=ns"))
        // And Redactor, for any line that reaches a log.
        let line = Redactor.scrub(args.joined(separator: " "))
        XCTAssertFalse(line.contains(code))
        XCTAssertFalse(line.contains(user))
        XCTAssertFalse(Redactor.scrub("-epicusername=\"Some One\" next").contains("Some"))
        XCTAssertEqual(Redactor.scrub("ovt egoc1~" + "eyJhbGciOiJFUzI1NiJ9.e30.c2lnbmF0dXJl end"), "ovt <ovt:redacted> end")
    }

    func testTheOwnershipFileIsWrittenForTheOwnerAndRemoved() throws {
        let root = try temp()
        try EpicOwnershipFile.write(Secret(#"{"token":"egoc1~token"}"#), in: root)
        let file = root.appendingPathComponent(EpicOwnershipFile.name)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"token":"egoc1~token"}"#)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        // A write a kill cut short leaves its temporary file: removed too.
        try Data("egoc1~half".utf8).write(to: root.appendingPathComponent(EpicOwnershipFile.temporary))
        XCTAssertEqual(try EpicOwnershipFile.remove(in: root), 2)
        XCTAssertEqual(try EpicOwnershipFile.remove(in: root), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
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

    // MARK: the JSON manifest form

    func testAJSONManifestParses() throws {
        // Football Manager 2022 Resource Archiver's manifest as Epic serves it (14 799 bytes).
        let raw = try fixture("fm22-resource-archiver.json")
        XCTAssertEqual(raw.count, 14_799)
        XCTAssertEqual(SHA1.hash(raw).hex, "c8b54c7d0606d300d34847d59319a5212711eee2")
        let m = try EpicManifest.parse(raw)
        XCTAssertEqual(m.featureLevel, 13)
        XCTAssertEqual(m.chunkDirectory, "ChunksV3")
        XCTAssertEqual(m.files.count, 11)
        XCTAssertEqual(m.chunks.count, 36)
        XCTAssertEqual(m.installBytes, 37_542_307)
        XCTAssertEqual(m.downloadBytes, 16_030_123)
        XCTAssertEqual(m.launchExe, "resource archiver.exe")
        XCTAssertEqual(m.buildVersion, "642-win-epic-resource_archiver")
        XCTAssertNotEqual(m.appName, "678fd78b68e7432b82d6cbc2928d33fb", "the manifest's app name is not the library's: installs key on EpicGame.id")
        XCTAssertTrue(m.chunks.allSatisfy { $0.window == 1 << 20 })
        let exe = try XCTUnwrap(m.files.first { $0.path == "resource archiver.exe" })
        XCTAssertEqual(exe.sha1.hex, "8bd02129c6a9993cd399186dd83906018ec6b41a")
        XCTAssertEqual(exe.parts.count, 13)
        XCTAssertEqual(exe.size, 12_116_992)
        XCTAssertEqual(m.chunkPath(m.chunks[exe.parts[0].chunk]), "ChunksV3/96/3C86AC09C6EB0174_E936C35D4B961D22D48F409EF4873AA4.chunk")
        XCTAssertTrue(EpicChunkSource.safe(m.chunkPath(m.chunks[0])))
        XCTAssertNil(m.refusal)
        let plan = try EpicContent.plan(m)
        XCTAssertEqual(plan.files.count, 11)
        XCTAssertEqual(plan.chunks.count, 36)
        XCTAssertEqual(plan.totalBytes, 37_542_307)
        XCTAssertTrue(plan.files.flatMap(\.parts).contains { $0.offsetInChunk != 0 }, "the JSON form's files slice chunks too")
    }

    func testJSONNumbersAndGUIDs() throws {
        XCTAssertEqual(try EpicManifest.blob("000000016000", width: 4), 1 << 20)
        XCTAssertEqual(try EpicManifest.blob("013000000000", width: 4), 13)
        XCTAssertEqual(try EpicManifest.blob("255", width: 1), 255)
        XCTAssertThrowsError(try EpicManifest.blob("256", width: 1))
        XCTAssertThrowsError(try EpicManifest.blob("0000", width: 4), "not whole bytes")
        XCTAssertThrowsError(try EpicManifest.blob("", width: 4))
        XCTAssertThrowsError(try EpicManifest.blob("00a", width: 1))
        XCTAssertThrowsError(try EpicManifest.blob("000000", width: 1), "wider than the field")
        XCTAssertThrowsError(try EpicManifest.blob(String(repeating: "000", count: 9), width: 8))
        XCTAssertEqual(try EpicManifest.blobBytes("001002255", count: 3), [1, 2, 255])
        XCTAssertThrowsError(try EpicManifest.blobBytes("001002", count: 3))
        let guid = try EpicManifest.jsonGUID("447127814817C45B19ADE5B796CA79A9")
        XCTAssertEqual(Array(guid[0..<4]), [0x81, 0x27, 0x71, 0x44], "each word little-endian, as the binary form")
        XCTAssertEqual(EpicManifest.Chunk(guid: guid, hash: 0, sha1: [], group: 0, window: 1, fileSize: 0).guidHex,
                       "447127814817C45B19ADE5B796CA79A9")
        XCTAssertThrowsError(try EpicManifest.jsonGUID("447127814817C45B19ADE5B796CA79A"))
        XCTAssertThrowsError(try EpicManifest.jsonGUID("447127814817C45B19ADE5B796CA79AZ"))
    }

    func testADamagedJSONManifestThrowsAndNeverCrashes() throws {
        let raw = try fixture("fm22-resource-archiver.json")
        for n in stride(from: 1, to: raw.count, by: 97) { XCTAssertThrowsError(try EpicManifest.parse(Array(raw[0..<n]))) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var b = raw
            for _ in 0..<4 { b[Int.random(in: 1..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? EpicManifest.parse(b)
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any])
        func mutated(_ change: (inout [String: Any]) -> Void) throws -> [UInt8] {
            var j = json
            change(&j)
            return [UInt8](try JSONSerialization.data(withJSONObject: j))
        }
        XCTAssertNoThrow(try EpicManifest.parse(try mutated { _ in }), "the unchanged form, written again, parses")
        func files(_ j: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            var list = j["FileManifestList"] as! [[String: Any]]
            change(&list[0])
            j["FileManifestList"] = list
        }
        func part(_ j: inout [String: Any], _ key: String, _ value: String) {
            files(&j) { f in
                var parts = f["FileChunkParts"] as! [[String: Any]]
                parts[0][key] = value
                f["FileChunkParts"] = parts
            }
        }
        let cases: [(String, [UInt8])] = [
            ("a part naming a missing chunk", try mutated { part(&$0, "Guid", "00000000000000000000000000000000") }),
            ("a part past 1 MiB", try mutated { part(&$0, "Offset", "000000016000") }),
            ("an empty part", try mutated { part(&$0, "Size", "000000000000") }),
            ("a path out of the folder", try mutated { files(&$0) { $0["Filename"] = "../evil.dll" } }),
            ("a short file hash", try mutated { files(&$0) { $0["FileHash"] = "001002" } }),
            ("chunk lists that disagree", try mutated { j in
                var sha = j["ChunkShaList"] as! [String: String]
                sha.removeValue(forKey: sha.keys.first!)
                j["ChunkShaList"] = sha
            }),
            ("a 31-digit GUID", try mutated { j in
                for name in ["ChunkHashList", "ChunkShaList", "DataGroupList", "ChunkFilesizeList"] {
                    var d = j[name] as! [String: String]
                    let k = d.keys.sorted().first!
                    d[String(k.dropLast())] = d.removeValue(forKey: k)
                    j[name] = d
                }
            }),
            ("no version", try mutated { $0.removeValue(forKey: "ManifestFileVersion") }),
        ]
        for (what, data) in cases { XCTAssertThrowsError(try EpicManifest.parse(data), what) }
    }

    func testABinaryManifestAndItsJSONFormAgree() throws {
        let m = try EpicManifest.parse(try fixture("hazelnut.manifest"))
        let j = try EpicManifest.parse(ManifestWriter.json(m))
        let key = { (c: EpicManifest.Chunk) in c.guidHex }
        XCTAssertEqual(j.chunks.sorted { key($0) < key($1) }.map { [$0.guidHex, String($0.hash), $0.sha1.hex, String($0.group), String($0.fileSize)] },
                       m.chunks.sorted { key($0) < key($1) }.map { [$0.guidHex, String($0.hash), $0.sha1.hex, String($0.group), String($0.fileSize)] })
        XCTAssertEqual(j.files.map(\.path), m.files.map(\.path))
        XCTAssertEqual(j.files.map(\.sha1), m.files.map(\.sha1))
        XCTAssertEqual(j.files.map(\.flags), m.files.map(\.flags))
        let parts = { (x: EpicManifest) in x.files.map { $0.parts.map { [x.chunks[$0.chunk].guidHex, String($0.offset), String($0.size)] } } }
        XCTAssertEqual(parts(j), parts(m))
        XCTAssertEqual(j.installBytes, m.installBytes)
        XCTAssertEqual(j.downloadBytes, m.downloadBytes)
        XCTAssertEqual(j.launchExe, m.launchExe)
    }

    func testAnInstallFromAJSONManifestVerifies() async throws {
        let window = 1 << 20
        let c0 = (0..<window).map { UInt8($0 % 251) }, c1 = (0..<window).map { UInt8(($0 * 7) % 253) }
        let a = c0 + c1[0..<200], b = Array(c1[200..<1200])
        let chunks = [EpicManifest.Chunk(guid: Array(1...16), hash: 0x1234, sha1: SHA1.hash(c0), group: 4, window: UInt32(window), fileSize: 1100),
                      EpicManifest.Chunk(guid: Array(17...32), hash: 0x5678, sha1: SHA1.hash(c1), group: 7, window: UInt32(window), fileSize: 700)]
        let m = EpicManifest(featureLevel: 13, appName: "Test", buildVersion: "1", launchExe: "game.exe", launchCommand: "",
                             prerequisites: [], chunks: chunks,
                             files: [.init(path: "game.exe", symlinkTarget: "", sha1: SHA1.hash(a), flags: 0, installTags: [],
                                           parts: [.init(chunk: 0, offset: 0, size: UInt32(window)), .init(chunk: 1, offset: 0, size: 200)]),
                                     .init(path: "data/b.bin", symlinkTarget: "", sha1: SHA1.hash(b), flags: 0, installTags: [],
                                           parts: [.init(chunk: 1, offset: 200, size: 1000)])],
                             custom: [:])
        let raw = ManifestWriter.json(m)
        let parsed = try EpicManifest.parse(raw)
        XCTAssertEqual(parsed.chunkPath(parsed.chunks[0]), "ChunksV3/04/0000000000001234_04030201080706050C0B0A09100F0E0D.chunk")
        let root = try temp()
        let layout = InstallLayout.root(root)
        let source = MapSource(files: [parsed.chunkPath(parsed.chunks[0]): ManifestWriter.chunkFile(chunks[0], c0, zlib: true),
                                       parsed.chunkPath(parsed.chunks[1]): ManifestWriter.chunkFile(chunks[1], c1, zlib: false)],
                               manifest: parsed)
        let engine = InstallEngine(tree: layout.gamesRoot.appendingPathComponent("Test"), journal: root.appendingPathComponent("j"),
                                   source: source, log: .silent)
        _ = try await engine.run(try EpicContent.plan(parsed))
        let installer = EpicInstaller(layout: layout, session: EpicSession(store: MemorySecretStore(), log: .silent), log: .silent)
        try installer.save(installer.record(EpicGame(id: "Test", namespace: "n", catalogItemID: "c", title: "Test"), parsed, folder: "Test"),
                           manifest: raw)
        let r = try await installer.verify("Test")
        XCTAssertEqual(r.files, 2)
        XCTAssertEqual(r.bad, [], "the kept JSON manifest is read again for verify")
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

    /// The model in Epic's JSON form (each chunk's window must be 1 MiB, as the form assumes).
    static func json(_ m: EpicManifest) -> [UInt8] {
        func blob(_ v: UInt64, _ width: Int) -> String { (0..<width).map { String(format: "%03d", Int(v >> UInt64(8 * $0) & 0xFF)) }.joined() }
        var j: [String: Any] = ["ManifestFileVersion": blob(UInt64(m.featureLevel), 4), "bIsFileData": false, "AppID": blob(0, 4),
                                "AppNameString": m.appName, "BuildVersionString": m.buildVersion, "LaunchExeString": m.launchExe,
                                "LaunchCommand": m.launchCommand, "PrereqIds": m.prerequisites, "PrereqName": "", "PrereqPath": "",
                                "PrereqArgs": "", "CustomFields": m.custom]
        j["ChunkHashList"] = Dictionary(uniqueKeysWithValues: m.chunks.map { ($0.guidHex, blob($0.hash, 8)) })
        j["ChunkShaList"] = Dictionary(uniqueKeysWithValues: m.chunks.map { ($0.guidHex, $0.sha1.hex) })
        j["DataGroupList"] = Dictionary(uniqueKeysWithValues: m.chunks.map { ($0.guidHex, blob(UInt64($0.group), 1)) })
        j["ChunkFilesizeList"] = Dictionary(uniqueKeysWithValues: m.chunks.map { ($0.guidHex, blob($0.fileSize, 8)) })
        j["FileManifestList"] = m.files.map { f -> [String: Any] in
            ["Filename": f.path, "FileHash": f.sha1.map { String(format: "%03d", Int($0)) }.joined(),
             "bIsReadOnly": f.flags & 1 != 0, "bIsCompressed": f.flags & 2 != 0, "bIsUnixExecutable": f.flags & 4 != 0,
             "FileChunkParts": f.parts.map { ["Guid": m.chunks[$0.chunk].guidHex, "Offset": blob(UInt64($0.offset), 4),
                                               "Size": blob(UInt64($0.size), 4)] }]
        }
        return [UInt8](try! JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]))
    }

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
