// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

final class WireTests: XCTestCase {
    func testProtoRoundTripAndTypeChecks() throws {
        var w = ProtoWriter()
        w.uint32(1, 65581)
        w.int32(2, -500)
        w.fixed64(3, 0x0110_0001_0000_0000)
        w.string(4, "héllo")
        w.bool(5, true)
        let f = try ProtoFields(w.bytes, message: "T")
        XCTAssertEqual(try f.uint32(1), 65581)
        XCTAssertEqual(try f.int32(2), -500)
        XCTAssertEqual(try f.fixed64(3), 0x0110_0001_0000_0000)
        XCTAssertEqual(try f.string(4), "héllo")
        XCTAssertEqual(try f.bool(5), true)
        XCTAssertNil(try f.uint32(99))
        // A field whose wire type changed is a typed protocol failure.
        XCTAssertThrowsError(try f.string(1)) { e in
            guard case SteamError.protocolChanged = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try f.fixed64(1))
    }

    func testTruncatedAndMalformedInput() {
        XCTAssertThrowsError(try ProtoFields([0x0A, 0x05, 0x41], message: "T"))          // length past end
        XCTAssertThrowsError(try ProtoFields([0x08, 0xFF, 0xFF], message: "T"))          // unterminated varint
        XCTAssertThrowsError(try ProtoFields([0x0B], message: "T"))                      // group wire type
    }

    func testPackedAndUnpackedRepeated() throws {
        var w = ProtoWriter()
        w.uint32(2, 7); w.uint32(2, 300)
        w.bytes(2, [0x01, 0xAC, 0x02])
        XCTAssertEqual(try ProtoFields(w.bytes, message: "T").repeatedUInt32(2), [7, 300, 1, 300])
    }

    func testPacketFramingAndMulti() throws {
        var h = ProtoHeader(); h.jobIDSource = 42; h.targetJobName = "Authentication.BeginAuthSessionViaQR#1"
        let packet = CMPacket(emsg: .serviceMethodCallFromClientNonAuthed, header: h, body: [1, 2, 3])
        let back = try CMPacket.parse(packet.serialize())
        XCTAssertEqual(back.emsg, EMsg.serviceMethodCallFromClientNonAuthed.rawValue)
        XCTAssertEqual(back.header.jobIDSource, 42)
        XCTAssertEqual(back.header.targetJobName, h.targetJobName)
        XCTAssertEqual(back.body, [1, 2, 3])

        // Multi, uncompressed: [u32 len][packet]...
        var inner: [UInt8] = []
        for body in [[9], [8, 8]] as [[UInt8]] {
            let p = CMPacket(emsg: .clientLicenseList, body: body).serialize()
            inner.appendLE(UInt32(p.count)); inner += p
        }
        var m = ProtoWriter(); m.bytes(2, inner)
        let expanded = try CMPacket.expandMulti(m.bytes)
        XCTAssertEqual(expanded.map(\.body), [[9], [8, 8]])

        // A legacy (non-protobuf) packet in a Multi is skipped, not fatal: Steam
        // bundles ClientUpdateGuestPassesList (798) with ClientLogOnResponse.
        var mixed: [UInt8] = []
        var legacy: [UInt8] = []; legacy.appendLE(UInt32(798)); legacy += [UInt8](repeating: 0, count: 32)
        mixed.appendLE(UInt32(legacy.count)); mixed += legacy
        let logon = CMPacket(emsg: .clientLogOnResponse, body: [7]).serialize()
        mixed.appendLE(UInt32(logon.count)); mixed += logon
        var mm = ProtoWriter(); mm.bytes(2, mixed)
        var skipped: [UInt32] = []
        let kept = try CMPacket.expandMulti(mm.bytes) { skipped.append($0) }
        XCTAssertEqual(kept.map(\.emsg), [EMsg.clientLogOnResponse.rawValue])
        XCTAssertEqual(skipped, [798])

        // A Multi that lies about its unzipped size is refused before inflating.
        var lie = ProtoWriter(); lie.uint32(1, UInt32(CMPacket.maxMultiBytes + 1)); lie.bytes(2, [0x1F, 0x8B])
        XCTAssertThrowsError(try CMPacket.expandMulti(lie.bytes)) { e in
            guard case SteamError.unsafeContent = e else { return XCTFail("\(e)") }
        }
    }

    func testNonProtobufFrameIsTyped() {
        XCTAssertThrowsError(try CMPacket.parse([0x05, 0, 0, 0, 0, 0, 0, 0])) { e in
            guard case SteamError.protocolChanged = e else { return XCTFail("\(e)") }
        }
    }

    func testQRResponseSchemaAndSecretsStayOutOfDescriptions() throws {
        var w = ProtoWriter()
        w.uint64(1, 123456789)
        w.string(2, "https://s.team/q/1/123456789")
        w.bytes(3, [1, 2, 3, 4])
        w.fixed32(4, Float(5).bitPattern)
        let r = try BeginAuthSessionViaQRResponse.decode(w.bytes)
        XCTAssertEqual(r.clientID, 123456789)
        XCTAssertEqual(r.interval, 5)
        XCTAssertEqual("\(r.challengeURL)", "<redacted>")
        XCTAssertFalse(String(describing: r).contains("s.team"))
        XCTAssertFalse(String(reflecting: r.requestID).contains("1, 2"))
    }

    func testKeyValuesTextAndBinary() throws {
        let text = """
        "appinfo"
        {
            "appid"  "1007"
            "common" { "name" "Steamworks SDK Redist" "type" "Tool" }
            "depots"
            {
                "1004" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "7604377918839582995" "size" "67863136" } } }
                "1006" { "config" { "oslist" "linux" } "manifests" { "public" "4559160656493359681" } }
                "branches" { "public" { "buildid" "25329704" } }
            }
        }
        """
        let kv = try KeyValue.parseText(Array(text.utf8) + [0])
        let d = try Library.parseDepots(appID: 1007, kv)
        XCTAssertEqual(d.name, "Steamworks SDK Redist")
        XCTAssertEqual(d.publicBuildID, 25329704)
        XCTAssertEqual(d.windowsDepots.map(\.depotID), [1004])
        XCTAssertEqual(d.depots.first { $0.depotID == 1006 }?.publicManifestGID, 4559160656493359681) // legacy flat form

        // Binary: 00 "17906" { 00 "appids" { 02 "0" <i32 7> } } 08 08
        var b: [UInt8] = [0] + Array("17906".utf8) + [0, 0] + Array("appids".utf8) + [0, 2, 0x30, 0]
        b.appendLE(UInt32(7)); b += [8, 8, 8]
        let pkg = try KeyValue.parseBinary(b[...])
        XCTAssertEqual(pkg["appids"]?.children.first?.uint32, 7)
        XCTAssertThrowsError(try KeyValue.parseBinary([0x0C, 0x41, 0][...]))
    }
}

final class SafetyTests: XCTestCase {
    func testPathPolicy() throws {
        XCTAssertEqual(try SafePath.normalize("bin\\win64\\game.exe"), "bin/win64/game.exe")
        for bad in ["..\\..\\evil.dll", "/etc/passwd", "C:\\Windows\\x", "a/../../b", "a/./b", "file.txt:ads", "a\u{0}b", ""] {
            XCTAssertThrowsError(try SafePath.normalize(bad), bad) { e in
                guard case SteamError.unsafeContent = e else { return XCTFail("\(bad): \(e)") }
            }
        }
        XCTAssertNoThrow(try SafePath.checkLink(from: "a/b/link", target: "../c"))
        XCTAssertThrowsError(try SafePath.checkLink(from: "a/link", target: "../../outside"))
        XCTAssertThrowsError(try SafePath.checkLink(from: "link", target: "/abs"))
    }

    /// A manifest with one traversal entry is rejected as a whole.
    func testManifestWithTraversalIsRejected() throws {
        func manifest(_ names: [String]) -> [UInt8] {
            var payload = ProtoWriter()
            for n in names {
                var m = ProtoWriter(); m.string(1, n); m.uint64(2, 0)
                payload.bytes(1, m.bytes)
            }
            var meta = ProtoWriter(); meta.uint32(1, 1004); meta.uint64(2, 99)
            var out: [UInt8] = []
            for (magic, body) in [(DepotManifest.payloadMagic, payload.bytes), (DepotManifest.metadataMagic, meta.bytes),
                                  (DepotManifest.signatureMagic, [])] {
                out.appendLE(magic); out.appendLE(UInt32(body.count)); out += body
            }
            out.appendLE(DepotManifest.endMagic)
            return out
        }
        XCTAssertEqual(try DepotManifest(manifest(["a\\b.dll", "c.txt"]), depotKey: nil, expectDepot: 1004, expectGID: 99).files.map(\.path),
                       ["a/b.dll", "c.txt"])
        XCTAssertThrowsError(try DepotManifest(manifest(["ok.dll", "..\\..\\escape.dll"]), depotKey: nil, expectDepot: 1004, expectGID: 99)) { e in
            guard case SteamError.unsafeContent = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try DepotManifest(manifest(["A.dll", "a.DLL"]), depotKey: nil, expectDepot: 1004, expectGID: 99))
        XCTAssertThrowsError(try DepotManifest(manifest(["x"]), depotKey: nil, expectDepot: 1004, expectGID: 100)) { e in
            guard case SteamError.verificationFailed = e else { return XCTFail("\(e)") }
        }
    }

    func testStagingRefusesPlantedSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("w4-symlink-\(UUID().uuidString)")
        let outside = base.appendingPathComponent("outside")
        let stage = base.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent("bin"), withDestinationURL: outside)
        XCTAssertThrowsError(try InstallFS.resolveInside(stage, "bin/game.exe", createParents: true)) { e in
            guard case SteamError.unsafeContent = e else { return XCTFail("\(e)") }
        }
        XCTAssertNoThrow(try InstallFS.resolveInside(stage, "data/x.bin", createParents: true))
    }

    func testRedactor() {
        let jwt = "eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiI3NjU2MTE5OCJ9.c2lnbmF0dXJlLWJ5dGVz"
        let line = "token=\(jwt) url=https://s.team/q/1/9876543210 cdn=https://cache1.steamcontent.com/depot/1/chunk/ab?token=xyz path=/home/someone/x"
        let s = Redactor.scrub(line)
        XCTAssertFalse(s.contains("eyJ"))
        XCTAssertFalse(s.contains("9876543210"))
        XCTAssertFalse(s.contains("xyz"))
        XCTAssertFalse(s.contains("someone"))
        XCTAssertEqual(Redactor.scrub("Bearer abc.def"), "Bearer <redacted>")
    }

    func testRedactorScrubsTheEncryptedAppTicket() {
        // Made up: the shape of gbe_fork's configs.user.ini line (decision 0017).
        XCTAssertEqual(Redactor.scrub("ticket=CAIQ/wB/AAEC+3=="), "ticket=<redacted>")
        XCTAssertEqual(Redactor.scrub("cat configs.user.ini: [user::general] Ticket = CAIQ_wB-AAEC ok"),
                       "cat configs.user.ini: [user::general] Ticket = <redacted> ok")
        XCTAssertFalse(Redactor.scrub(#"{"ticket": "CAIQ/wB/AAEC"}"#).contains("CAIQ"))
        // The launch's own lines name the ticket without a value and stay as they are.
        let line = "ticket: the encrypted app ticket (240 bytes) written to 1 configs.user.ini"
        XCTAssertEqual(Redactor.scrub(line), line)
    }

    func testEncryptedAppTicketMessages() throws {
        XCTAssertEqual(CMsgClientRequestEncryptedAppTicket(appID: 367520).encode(), [0x08, 0xa0, 0xb7, 0x16])
        var t = ProtoWriter(); t.uint32(1, 2); t.bytes(5, [1, 2, 3])
        var w = ProtoWriter(); w.uint32(1, 367520); w.int32(2, 1); w.bytes(3, t.bytes)
        let r = try CMsgClientRequestEncryptedAppTicketResponse.decode(w.bytes)
        XCTAssertEqual(r.appID, 367520)
        XCTAssertEqual(r.eresult, .ok)
        XCTAssertEqual(r.ticket?.value, t.bytes, "the EncryptedAppTicket message as Steam serialised it")
        XCTAssertEqual("\(r.ticket!)", "<redacted>")
        let other = CMPacket(emsg: .clientRequestEncryptedAppTicketResponse, header: ProtoHeader(), body: w.bytes)
        XCTAssertTrue(SteamSession.ticketReply(forApp: 367520)(other))
        XCTAssertFalse(SteamSession.ticketReply(forApp: 10)(other))
    }

    func testMaskTeam() {
        // A free-team group carries the team twice; a paid-team group once.
        XCTAssertEqual(Redactor.maskTeam(accessGroup: "A1B2C3D4E5.XTL-A1B2C3D4E5.dev.playport.app"),
                       "<team>.XTL-<team>.dev.playport.app")
        XCTAssertEqual(Redactor.maskTeam(accessGroup: "A1B2C3D4E5.dev.playport.app"),
                       "<team>.dev.playport.app")
        XCTAssertEqual(Redactor.maskTeam(accessGroup: "?"), "?")
        XCTAssertEqual(Redactor.maskTeam(accessGroup: "A1B2C3D4E5"), "<group:redacted>")
        XCTAssertEqual(Redactor.maskTeam(accessGroup: ".x"), "<group:redacted>")
    }
}

final class SessionTests: XCTestCase {
    static func jwt(sub: String, exp: TimeInterval) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return b64(#"{"alg":"EdDSA"}"#) + "." + b64(#"{"sub":"\#(sub)","exp":\#(Int(exp)),"aud":["client","web"]}"#) + ".c2ln"
    }

    func testJWTClaims() throws {
        let c = try JWTClaims(token: Secret(Self.jwt(sub: "76561197960287930", exp: Date().timeIntervalSince1970 + 3600)))
        XCTAssertEqual(c.subject, 76561197960287930)
        XCTAssertFalse(c.isExpired())
        XCTAssertEqual(c.audience, ["client", "web"])
        XCTAssertThrowsError(try JWTClaims(token: Secret("not-a-jwt")))
    }

    func testExpiredStoredTokenIsRefusedWithoutNetwork() async throws {
        let store = MemorySecretStore()
        let s = StoredSession(accountName: "someone", steamID: 1,
                              refreshToken: Self.jwt(sub: "1", exp: Date().timeIntervalSince1970 - 10), guardData: nil, savedAt: Date())
        try store.write(SecretKeys.session, Secret([UInt8](try JSONEncoder().encode(s))))
        let session = SteamSession(store: store, log: .silent)
        do {
            _ = try await session.restore()
            XCTFail("restore succeeded with an expired token")
        } catch SteamError.eresult(.expired, _) {}
        XCTAssertFalse("\(s)".contains(s.refreshToken))
    }

    func testRestoreWithoutCredentials() async {
        let session = SteamSession(store: MemorySecretStore(), log: .silent)
        do { _ = try await session.restore(); XCTFail() } catch SteamError.noCredentials {} catch { XCTFail("\(error)") }
    }

    /// Logout without a connection still deletes the stored session and
    /// never reaches beyond the credential store.
    func testOfflineLogoutDeletesCredentials() async throws {
        let store = MemorySecretStore()
        let s = StoredSession(accountName: "a", steamID: 1, refreshToken: Self.jwt(sub: "1", exp: 9_999_999_999),
                              guardData: nil, savedAt: Date())
        try store.write(SecretKeys.session, Secret([UInt8](try JSONEncoder().encode(s))))
        try store.write(SecretKeys.machineID, Secret([1, 2, 3]))
        let session = SteamSession(store: store, log: .silent)
        let r = try await session.logout(revoke: false)
        XCTAssertTrue(r.credentialsDeleted)
        XCTAssertNil(try store.read(SecretKeys.session))
        XCTAssertNotNil(try store.read(SecretKeys.machineID))
    }

    func testFileStandInIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w4-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileSecretStore(directory: dir)
        try store.write("session", Secret([1, 2, 3]))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("session").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try store.read("session")?.value, [1, 2, 3])
        XCTAssertThrowsError(try store.write("../escape", Secret([1])))
        try store.delete("session")
        XCTAssertNil(try store.read("session"))
    }
}
