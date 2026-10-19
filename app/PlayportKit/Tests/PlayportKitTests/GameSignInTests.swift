// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PlayportKit

/// Ending the Rockstar launcher once RDR2 signed in (decision 0124): the compatibility-only
/// setting and the log watch.
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
        XCTAssertEqual(table.entry(for: "app-1174180")?.settings.endLauncherAfterSignIn, true)
        XCTAssertNil(table.entry(for: "epic-Buffalo")?.settings.endLauncherAfterSignIn)
        XCTAssertEqual(PublisherLauncher.startedBy(game: "app-1174180")?.signIn, signIn)
        XCTAssertEqual(signIn.file(profile: URL(fileURLWithPath: "/p/drive_c/users/playport")).path,
                       "/p/drive_c/users/playport/Documents/Rockstar Games/Social Club/socialclub.log")
    }

    /// Only the compatibility table sets it: a person's (or the driver's) saved value never
    /// reaches the launch, with a default or without one, and it is no setting a person made.
    func testOverIgnoresASavedValue() {
        let compat = LaunchSettings(windowsServices: true, endLauncherAfterSignIn: true)
        XCTAssertEqual(LaunchSettings(endLauncherAfterSignIn: false).over(compat).endLauncherAfterSignIn, true)
        XCTAssertEqual(LaunchSettings().over(compat).endLauncherAfterSignIn, true)
        XCTAssertNil(LaunchSettings(endLauncherAfterSignIn: true).over(LaunchSettings(screen: "720")).endLauncherAfterSignIn)
        XCTAssertNil(LaunchSettings(endLauncherAfterSignIn: true).over(nil).endLauncherAfterSignIn)
        XCTAssertFalse(LaunchSettings.resolve(game: LaunchSettings(endLauncherAfterSignIn: true).over(nil),
                                              global: LaunchSettings()).endLauncherAfterSignIn)
        XCTAssertTrue(LaunchSettings.resolve(game: LaunchSettings(frameLimit: 30).over(compat),
                                             global: LaunchSettings()).endLauncherAfterSignIn)
        XCTAssertTrue(LaunchSettings(endLauncherAfterSignIn: true).isEmpty)
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
