// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import ContentKit
@testable import XboxClientKit

/// The player's answers, scripted; every question kept.
actor XboxFakeConflictAsker: XboxSaveConflictAsker {
    var asked: [(XboxSaveConflict, String)] = []
    var answer: XboxSaveChoice
    private var holding = false
    private var held: CheckedContinuation<XboxSaveChoice, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    init(answer: XboxSaveChoice) { self.answer = answer }
    func hold() { holding = true }
    func waitUntilHeld() async { if held == nil { await withCheckedContinuation { heldWaiter = $0 } } }
    func release(_ choice: XboxSaveChoice) { held?.resume(returning: choice); held = nil }

    func choose(_ conflict: XboxSaveConflict, productID: String) async -> XboxSaveChoice {
        asked.append((conflict, productID))
        guard holding else { return answer }
        holding = false
        return await withCheckedContinuation { held = $0; heldWaiter?.resume(); heldWaiter = nil }
    }
}

final class XboxCloudSavesTests: XCTestCase, @unchecked Sendable {
    static let pilot = XboxBridgeTests.pilot

    /// What patches/xgameruntime/0002's ask_save_conflict sends: field per element, escaped.
    func conflict(display: String = "save1", cloudTime: String = "2026-10-22T12:00:00Z", device: String = "") -> XboxBridgeFrame {
        XboxBridgeFrame(type: 0x5001, body: Array(("<SaveConflictRequest><Scid>00000000-0000-0000-0000-00007abd14db</Scid>"
            + "<Container>save1</Container><DisplayName>\(display)</DisplayName>"
            + "<LocalTime>2026-10-20T12:00:00.0000000Z</LocalTime><CloudTime>\(cloudTime)</CloudTime>"
            + "<CloudDevice>\(device)</CloudDevice></SaveConflictRequest>").utf8))
    }

    func service(_ account: XboxBridgeFakeAccount, saves: (any XboxSaveConflictAsker)?, lines: XboxLines = XboxLines()) -> XboxBridgeService {
        XboxBridgeService(copy: Self.pilot, account: account, updates: nil, saves: saves, log: lines.logger)
    }

    func choice(_ s: XboxBridgeService, _ request: XboxBridgeFrame, file: StaticString = #filePath, line: UInt = #line) async throws -> String? {
        guard let reply = await s.handle(request) else { XCTFail("no reply", file: file, line: line); return nil }
        XCTAssertEqual(reply.type, 0x5002, file: file, line: line)
        let xml = try XboxXML.parse(reply.body)
        XCTAssertEqual(xml.local, "SaveConflictResponse", file: file, line: line)
        return xml.value("Choice")
    }

    // MARK: the conflict question, round trip

    func testTheRuntimesQuestionReachesThePlayerWithEachSidesTimeAndDeviceAndTheChoiceGoesBack() async throws {
        let account = XboxBridgeFakeAccount(), asker = XboxFakeConflictAsker(answer: .cloud), lines = XboxLines()
        let s = service(account, saves: asker, lines: lines)
        let first = try await choice(s, conflict(display: "Slot &lt;1&gt; &amp; more", device: "LIVING-ROOM-XBOX"))
        XCTAssertEqual(first, "cloud")
        let asked = await asker.asked
        XCTAssertEqual(asked.count, 1)
        let (q, product) = try XCTUnwrap(asked.first)
        XCTAssertEqual(product, "9MW9469V91LM")
        XCTAssertEqual(q.scid, "00000000-0000-0000-0000-00007abd14db")
        XCTAssertEqual(q.container, "save1")
        XCTAssertEqual(q.displayName, "Slot <1> & more")
        XCTAssertEqual(q.local, XboxSaveVersion(time: Date(timeIntervalSince1970: 1_792_497_600), device: nil))
        XCTAssertEqual(q.cloud, XboxSaveVersion(time: Date(timeIntervalSince1970: 1_792_670_400), device: "LIVING-ROOM-XBOX"))
        // The log names the request and the answer, never the save's name or device.
        let log = lines.text
        XCTAssertTrue(log.contains("SAVE_CONFLICT_REQUEST"), log)
        XCTAssertTrue(log.contains("SAVE_CONFLICT_RESPONSE served: cloud"), log)
        XCTAssertFalse(log.contains("Slot") || log.contains("LIVING-ROOM"), log)

        await asker.setAnswer(.local)
        let local = try await choice(s, conflict())
        XCTAssertEqual(local, "local")
        await asker.setAnswer(.none)
        let none = try await choice(s, conflict())
        XCTAssertEqual(none, "none")
    }

    func testAMissingDeviceOrAFractionalOrUnreadableTimeIsShownAsUnknownNotGuessed() throws {
        let q = try XCTUnwrap(XboxSaveConflict(body: conflict(cloudTime: "2012-01-01T01:02:03.1234567Z").body))
        XCTAssertNil(q.cloud.device)
        XCTAssertEqual(q.cloud.time, Date(timeIntervalSince1970: 1_325_379_723))
        XCTAssertNil(try XCTUnwrap(XboxSaveConflict(body: conflict(cloudTime: "").body)).cloud.time)
        XCTAssertNil(try XCTUnwrap(XboxSaveConflict(body: conflict(cloudTime: "yesterday").body)).cloud.time)
        XCTAssertNil(XboxSaveConflict(body: Array("<SaveConflictRequest><Container></Container></SaveConflictRequest>".utf8)))
        XCTAssertNil(XboxSaveConflict(body: Array("<Other><Container>a</Container></Other>".utf8)))
        XCTAssertNil(XboxSaveConflict(body: Array("<SaveConflictRequest>".utf8)))
    }

    func testWithNobodyToAskSignedOutOrMalformedTheAnswerIsNoneSoBothSidesAreKept() async throws {
        let account = XboxBridgeFakeAccount(), asker = XboxFakeConflictAsker(answer: .local)
        let nobody = try await choice(service(account, saves: nil), conflict())
        XCTAssertEqual(nobody, "none")
        let s = service(account, saves: asker)
        let malformed = try await choice(s, XboxBridgeFrame(type: 0x5001, body: Array("<SaveConflictRequest/>".utf8)))
        XCTAssertEqual(malformed, "none")
        await account.setState(.signedOut)
        let signedOut = try await choice(s, conflict())
        XCTAssertEqual(signedOut, "none")
        let asked = await asker.asked
        XCTAssertTrue(asked.isEmpty)
    }

    func testSignOutWhileThePlayerIsDecidingEndsTheConnectionWithNoAnswer() async throws {
        let account = XboxBridgeFakeAccount(), asker = XboxFakeConflictAsker(answer: .cloud)
        await asker.hold()
        let s = service(account, saves: asker)
        let pending = Task { await s.handle(self.conflict()) }
        await asker.waitUntilHeld()
        s.revoke()
        await asker.release(.cloud)
        let reply = await pending.value
        XCTAssertNil(reply)
    }

    // MARK: unsynced saves

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xbox-saves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    static let scid = "00000000-0000-0000-0000-00007abd14db"

    /// A container's index as the runtime's save_state writes it.
    func container(_ local: URL, root: String = "XodusGameSave", leaf: String = scid, name: String = "73617665",
                   dirty: Int, remote: String) throws {
        let dir = local.appendingPathComponent("\(root)/2535400000000001/\(leaf)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("display 7361766531\ntime 1792497600\nremote \(remote)\ndirty \(dirty)\nrevision 3\nblob 6f6e65 7 atom-A\n".utf8)
            .write(to: dir.appendingPathComponent("index"))
    }

    func testACopyHasUnsyncedSavesWhileAContainerIsDirtyOrWasNeverUploaded() throws {
        let local = try scratch()
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), false, "no saves at all")
        try container(local, dirty: 0, remote: "2026-10-22T12:00:00Z")
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), false, "synced")
        try container(local, name: "74776f", dirty: 1, remote: "2026-10-22T12:00:00Z")
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), true, "changed since the last sync")
        try container(local, name: "74776f", dirty: 0, remote: "-")
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), true, "never uploaded")
        try container(local, name: "74776f", dirty: 0, remote: "2026-10-22T12:00:00Z")
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), false)
    }

    func testRecoveryCopiesAndOtherTitlesDoNotCountButFileSavesDo() throws {
        let local = try scratch()
        try container(local, name: ".recovery-73617665-{0}", dirty: 1, remote: "-")
        try container(local, name: ".incoming-{0}", dirty: 1, remote: "-")
        try container(local, leaf: "00000000-0000-0000-0000-000000000042", dirty: 1, remote: "-")
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), false)
        // XGameSaveFiles: the index sits in the cache, under the SCID's hex, a hash per container.
        let hex = Array(Self.scid.utf8).map { String(format: "%02x", $0) }.joined()
        try container(local, root: "XodusGameSaveFilesCache", leaf: hex, name: String(repeating: "ab", count: 32), dirty: 1, remote: "-")
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), true)
    }

    func testAnIndexThatCannotBeReadIsUnknownNotSynced() throws {
        let local = try scratch()
        try container(local, dirty: 0, remote: "2026-10-22T12:00:00Z")
        let broken = local.appendingPathComponent("XodusGameSave/2535400000000001/\(Self.scid)/74776f/index", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        XCTAssertNil(XboxSaves.unsynced(scid: Self.scid, localAppData: local))
        // A container folder with no index yet (a game mid-write) is not a save.
        try FileManager.default.removeItem(at: broken)
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), false)
    }

    /// A copy with no cloud-save identity (no install record, or no SCID in its
    /// MicrosoftGame.config) has nothing the cloud could lack: false, never unknown, so a
    /// lapse's removal (PlayportKit LicenceLapses, held while this isn't false) isn't held.
    func testACopyWithoutACloudSaveIdentityHasNothingUnsynced() throws {
        let local = try scratch()
        try container(local, dirty: 1, remote: "-")
        XCTAssertEqual(XboxSaves.unsynced(scid: nil, localAppData: local), false)
        XCTAssertEqual(XboxSaves.unsynced(scid: Self.scid, localAppData: local), true)
    }
}

extension XboxFakeConflictAsker {
    func setAnswer(_ choice: XboxSaveChoice) { answer = choice }
}
