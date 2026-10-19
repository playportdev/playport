// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// Ending the Rockstar launcher at RDR2's first frame (decision 0125, amending 0124): the
/// compatibility-only setting, and the sign-in watch the Play now only logs.
final class GameSignInTests: XCTestCase {
    let signIn = PublisherLauncher.rockstar.signIn!

    /// The game's Social Club log as UTF-16LE with a byte-order mark, lines ending in CRLF.
    func log(_ lines: [String], bom: Bool = true) -> Data {
        var d = Data(bom ? [0xFF, 0xFE] : [])
        for u in (lines.map { $0 + "\r\n" }.joined()).utf16 { d.append(contentsOf: [UInt8(u & 0xff), UInt8(u >> 8)]) }
        return d
    }

    let header = "[00000000] Thu Oct 15 22:45:58 2026"
    let signedIn = [
        "[00002210] IPC system is ready, loading UI",
        "[00002400] Connected to Rockstar Games Launcher for authentication",
        "[00002410] Received ticket from Rockstar Games Launcher.",
        "[00002420] Found matching profile someone",
        "[00002430] Signed in online to profile someone",
    ]

    func testTheShippedTableAsksForItForRDR2AndTheLauncherKnowsTheLine() throws {
        let table = try CompatDefaults.load(directory: CompatDefaultsTests.shipped)
        XCTAssertEqual(table.entry(for: "app-1174180")?.settings.endLauncherAtFirstFrame, true)
        XCTAssertNil(table.entry(for: "epic-Buffalo")?.settings.endLauncherAtFirstFrame)
        XCTAssertEqual(PublisherLauncher.startedBy(game: "app-1174180")?.signIn, signIn)
        XCTAssertEqual(signIn.file(profile: URL(fileURLWithPath: "/p/drive_c/users/playport")).path,
                       "/p/drive_c/users/playport/Documents/Rockstar Games/Social Club/socialclub.log")
    }

    /// Only the compatibility table sets it: a person's (or the driver's) saved value never
    /// reaches the launch, with a default or without one, and it is no setting a person made.
    func testOverIgnoresASavedValue() {
        let compat = LaunchSettings(windowsServices: true, endLauncherAtFirstFrame: true)
        XCTAssertEqual(LaunchSettings(endLauncherAtFirstFrame: false).over(compat).endLauncherAtFirstFrame, true)
        XCTAssertEqual(LaunchSettings().over(compat).endLauncherAtFirstFrame, true)
        XCTAssertNil(LaunchSettings(endLauncherAtFirstFrame: true).over(LaunchSettings(screen: "720")).endLauncherAtFirstFrame)
        XCTAssertNil(LaunchSettings(endLauncherAtFirstFrame: true).over(nil).endLauncherAtFirstFrame)
        XCTAssertFalse(LaunchSettings.resolve(game: LaunchSettings(endLauncherAtFirstFrame: true).over(nil),
                                              global: LaunchSettings()).endLauncherAtFirstFrame)
        XCTAssertTrue(LaunchSettings.resolve(game: LaunchSettings(frameLimit: 30).over(compat),
                                             global: LaunchSettings()).endLauncherAtFirstFrame)
        XCTAssertTrue(LaunchSettings(endLauncherAtFirstFrame: true).isEmpty)
    }

    /// A settings file saved with decision 0124's name for the field carries nothing over.
    func testTheOldFieldNameIsNotRead() throws {
        let old = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"endLauncherAfterSignIn": true}"#.utf8))
        XCTAssertNil(old.endLauncherAtFirstFrame)
        XCTAssertTrue(old.isEmpty)
    }

    func testANewFileWithTheLineIsThisPlays() {
        let w = GameSignIn.Watch(signIn: signIn, baseline: nil)
        XCTAssertTrue(w.signedIn(log([header] + signedIn)))
        XCTAssertTrue(w.signedIn(log([header] + signedIn, bom: false)))
        XCTAssertFalse(w.signedIn(log([header] + signedIn.dropLast())))
        XCTAssertFalse(w.signedIn(Data()))
    }

    /// The file an earlier start left: unchanged, it says nothing of this Play; rewritten with a
    /// new header, all of it is this Play's; appended to, only what follows counts.
    func testAnEarlierStartsSignInIsStale() {
        let old = log(["[00000000] Wed Oct 14 20:00:00 2026"] + signedIn)
        let w = GameSignIn.Watch(signIn: signIn, baseline: old)
        XCTAssertFalse(w.signedIn(old))
        XCTAssertFalse(w.signedIn(log([header, "[00000100] IPC system is ready, loading UI"])))
        XCTAssertTrue(w.signedIn(log([header] + signedIn)))
        XCTAssertFalse(w.signedIn(old + log(["[00000000] Thu Oct 15 22:45:58 2026"], bom: false)))
        XCTAssertTrue(w.signedIn(old + log(["[00000000] Thu Oct 15 22:45:58 2026"] + signedIn, bom: false)))
    }

    /// The text must start the line, after its stamp: an error that quotes it is not a sign-in,
    /// and a character still half written is not read.
    func testOnlyTheLineItselfCounts() {
        let w = GameSignIn.Watch(signIn: signIn, baseline: nil)
        XCTAssertFalse(w.signedIn(log([header, "[00000010] [ERROR] Signed in online to profile failed"])))
        XCTAssertTrue(w.signedIn(log([header, "Signed in online to profile x"])))
        var half = log([header, "[00002430] Signed in online to profile"])
        half.append(0x41)
        XCTAssertTrue(w.signedIn(half))
        XCTAssertFalse(w.signedIn(log([header, "[00002430] Signed in online"])))
    }
}
