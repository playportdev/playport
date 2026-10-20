// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// When RDR2's Play ends the Rockstar launcher (decisions 0130, 0140): at the game's sign-in, or
/// before it once the footprint comes within 400 MB of the limit.
final class LauncherEndTriggerTests: XCTestCase {
    func testTheSignInEndsItWhateverTheFootprint() {
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: true, footprintMB: 3_000, limitMB: 8_192), .signedIn)
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: true, footprintMB: 7_500, limitMB: 8_192), .signedIn)
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: true, footprintMB: 3_000, limitMB: nil), .signedIn)
    }

    func testTheFootprintEndsItBeforeTheSignInOnlyNearTheLimit() {
        XCTAssertEqual(LauncherEndTrigger.beforeSignInThresholdMB(limitMB: 8_192), 7_792)
        // Runs s4 and f1 (2026-10-20) ended it at 7,020-7,027 MB, and the game did not sign in.
        XCTAssertNil(LauncherEndTrigger.check(signedIn: false, footprintMB: 7_027, limitMB: 8_192))
        XCTAssertNil(LauncherEndTrigger.check(signedIn: false, footprintMB: 7_791, limitMB: 8_192))
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: false, footprintMB: 7_792, limitMB: 8_192),
                       .memory(footprintMB: 7_792, limitMB: 8_192))
        // The limit before Game Mode is about 6 GB on the reference phone.
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: false, footprintMB: 5_744, limitMB: 6_144),
                       .memory(footprintMB: 5_744, limitMB: 6_144))
    }

    func testTheGameSocialClubEndKeepsItsHeadroom() {
        XCTAssertEqual(LauncherEndTrigger.memoryThresholdMB(limitMB: 8_192), 6_992)
    }

    func testTheGameSocialClubEndWaits120SecondsAfterTheSignIn() {
        // Run f2: the footprint was over the threshold at the sign-in itself.
        XCTAssertFalse(LauncherEndTrigger.endsGameSocialClub(sinceSignInS: nil, footprintMB: 7_018, limitMB: 8_192))
        XCTAssertFalse(LauncherEndTrigger.endsGameSocialClub(sinceSignInS: 0, footprintMB: 7_018, limitMB: 8_192))
        XCTAssertFalse(LauncherEndTrigger.endsGameSocialClub(sinceSignInS: 119.9, footprintMB: 7_500, limitMB: 8_192))
        XCTAssertTrue(LauncherEndTrigger.endsGameSocialClub(sinceSignInS: 120, footprintMB: 6_992, limitMB: 8_192))
        XCTAssertFalse(LauncherEndTrigger.endsGameSocialClub(sinceSignInS: 150, footprintMB: 6_991, limitMB: 8_192))
        XCTAssertFalse(LauncherEndTrigger.endsGameSocialClub(sinceSignInS: 150, footprintMB: 9_000, limitMB: nil))
    }

    func testNoReportedLimitNeverEndsItForMemory() {
        XCTAssertNil(LauncherEndTrigger.check(signedIn: false, footprintMB: 9_000, limitMB: nil))
        XCTAssertFalse(LauncherEndTrigger.near(footprintMB: 9_000, limitMB: nil))
    }

    func testReadingsWithin2000MBOfTheLimitAreLogged() {
        XCTAssertFalse(LauncherEndTrigger.near(footprintMB: 6_191, limitMB: 8_192))
        XCTAssertTrue(LauncherEndTrigger.near(footprintMB: 6_192, limitMB: 8_192))
    }
}
