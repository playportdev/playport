// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// A play's in-place swap (an Xbox copy's kept-encrypted files, decision 0166) on a
/// temporary folder: the plaintext stands under the original names for the play only,
/// and nothing of it is left after the play's end or after a crash.
final class InPlaceSwapTests: XCTestCase {
    private var root: URL!
    private var games: URL { root.appendingPathComponent("Games", isDirectory: true) }
    private var markers: URL { root.appendingPathComponent("state/plays", isDirectory: true) }
    private var folder: URL { games.appendingPathComponent("Hollow Knight", isDirectory: true) }
    private let encrypted: [String: [UInt8]] = [
        "Hollow Knight.exe": Array("encrypted game executable".utf8),
        "Tools/UnityCrashHandler64.exe": Array("encrypted crash handler".utf8),
    ]
    private let plain: [String: [UInt8]] = [
        "Hollow Knight.exe": Array("MZ plaintext game executable".utf8),
        "Tools/UnityCrashHandler64.exe": Array("MZ plaintext crash handler".utf8),
    ]
    private let beside = Array("UnityPlayer.dll bytes".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Tools"), withIntermediateDirectories: true)
        for (path, bytes) in encrypted { try Data(bytes).write(to: folder.appendingPathComponent(path)) }
        try Data(beside).write(to: folder.appendingPathComponent("UnityPlayer.dll"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var swapper: InPlaceSwap { InPlaceSwap(games: games, markers: markers) }

    /// The test's "decryption": the plaintext of `path`, from its original as the swap gives it.
    private func decrypt(_ path: String, _ original: URL, _ out: URL) throws {
        XCTAssertEqual(try [UInt8](Data(contentsOf: original)), encrypted[path], "the original is read, not a plaintext")
        try Data(plain[path]!).write(to: out)
    }

    private func bytes(_ path: String) -> [UInt8]? {
        (try? Data(contentsOf: folder.appendingPathComponent(path))).map { [UInt8]($0) }
    }

    /// Every regular file under the root, by content.
    private func everyFile() -> [[UInt8]] {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).compactMap { url in
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else { return nil }
            return (try? Data(contentsOf: url)).map { [UInt8]($0) }
        }
    }

    private func assertOriginalsBackAndNoPlaintext(file: StaticString = #filePath, line: UInt = #line) {
        for (path, original) in encrypted { XCTAssertEqual(bytes(path), original, path, file: file, line: line) }
        XCTAssertEqual(bytes("UnityPlayer.dll"), beside, file: file, line: line)
        let files = everyFile()
        for (path, p) in plain { XCTAssertFalse(files.contains(p), "\(path)'s plaintext is left", file: file, line: line) }
        XCTAssertEqual(files.count, encrypted.count + 1, "only the copy's own files remain", file: file, line: line)
    }

    func testAPlayRunsThePlaintextUnderTheOriginalNamesAndItsEndPutsTheOriginalsBack() throws {
        try swapper.swap(play: "xbox-9MW9469V91LM", folder: "Hollow Knight", files: Array(encrypted.keys), plaintext: decrypt)
        // The game finds its executables where they always are, beside its other files.
        for (path, p) in plain { XCTAssertEqual(bytes(path), p, path) }
        XCTAssertEqual(bytes("UnityPlayer.dll"), beside)
        XCTAssertEqual(swapper.pending, ["xbox-9MW9469V91LM"], "the play's marker is kept while it runs")

        try swapper.restore(play: "xbox-9MW9469V91LM")
        assertOriginalsBackAndNoPlaintext()
        XCTAssertEqual(swapper.pending, [])
        // A second end (the launch's and the app's) finds nothing to do.
        XCTAssertNoThrow(try swapper.restore(play: "xbox-9MW9469V91LM"))
        assertOriginalsBackAndNoPlaintext()
    }

    func testTheNextAppStartFinishesAPlayThatCrashed() throws {
        try swapper.swap(play: "xbox-9MW9469V91LM", folder: "Hollow Knight", files: Array(encrypted.keys), plaintext: decrypt)
        // The app dies with the game: no restore. The next start, a new process:
        let restored = InPlaceSwap(games: games, markers: markers).restoreAfterCrash()
        XCTAssertEqual(restored, ["xbox-9MW9469V91LM"])
        assertOriginalsBackAndNoPlaintext()
        XCTAssertEqual(InPlaceSwap(games: games, markers: markers).restoreAfterCrash(), [], "nothing left for the start after")
    }

    func testACrashPartWayThroughTheSwapLeavesNothingTheNextStartCannotUndo() throws {
        let files = ["Hollow Knight.exe", "Tools/UnityCrashHandler64.exe"]
        var calls = 0
        XCTAssertThrowsError(try swapper.swap(play: "xbox-9MW9469V91LM", folder: "Hollow Knight", files: files) { path, original, out in
            calls += 1
            if calls == 1 { return try self.decrypt(path, original, out) }
            // The second file's plaintext half written, the first already swapped, when the app dies:
            try Data(self.plain[files[1]]!.prefix(5)).write(to: out)
            XCTAssertEqual(InPlaceSwap(games: self.games, markers: self.markers).restoreAfterCrash(), ["xbox-9MW9469V91LM"])
            self.assertOriginalsBackAndNoPlaintext()
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(calls, 2)
        assertOriginalsBackAndNoPlaintext()
        XCTAssertEqual(swapper.pending, [])
    }

    func testAFailedDecryptionPutsBackWhatWasSwappedAndReportsTheError() throws {
        var calls = 0
        XCTAssertThrowsError(try swapper.swap(play: "xbox-9MW9469V91LM", folder: "Hollow Knight",
                                              files: ["Hollow Knight.exe", "Tools/UnityCrashHandler64.exe"]) { path, original, out in
            calls += 1
            if calls == 2 { throw CocoaError(.fileReadCorruptFile) }
            try self.decrypt(path, original, out)
        }) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadCorruptFile) }
        assertOriginalsBackAndNoPlaintext()
        XCTAssertEqual(swapper.pending, [])
    }

    func testAPlayAfterAnUnfinishedOneStartsFromTheOriginals() throws {
        try swapper.swap(play: "xbox-9MW9469V91LM", folder: "Hollow Knight", files: Array(encrypted.keys), plaintext: decrypt)
        // No restore and no new start (the marker is still there): the next Play decrypts the originals again.
        try swapper.swap(play: "xbox-9MW9469V91LM", folder: "Hollow Knight", files: Array(encrypted.keys), plaintext: decrypt)
        for (path, p) in plain { XCTAssertEqual(bytes(path), p, path) }
        try swapper.restore(play: "xbox-9MW9469V91LM")
        assertOriginalsBackAndNoPlaintext()
    }

    func testPathsOutsideTheCopysFolderAreRefusedBeforeAnythingChanges() throws {
        for (dir, files) in [("Hollow Knight", ["../Other/game.exe"]), ("../Hollow Knight", ["Hollow Knight.exe"]),
                             ("Hollow Knight", ["/etc/passwd"])] {
            XCTAssertThrowsError(try swapper.swap(play: "xbox-9MW9469V91LM", folder: dir, files: files, plaintext: decrypt))
        }
        XCTAssertThrowsError(try swapper.swap(play: "../xbox", folder: "Hollow Knight", files: ["Hollow Knight.exe"], plaintext: decrypt))
        assertOriginalsBackAndNoPlaintext()
        XCTAssertEqual(swapper.pending, [])
    }
}
