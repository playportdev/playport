// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// When RDR2's Play ends the Rockstar launcher (decision 0130): at the game's sign-in, or before
/// it once the footprint comes within 1,200 MB of the limit.
final class LauncherEndTriggerTests: XCTestCase {
    func testTheSignInEndsItWhateverTheFootprint() {
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: true, footprintMB: 3_000, limitMB: 8_192), .signedIn)
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: true, footprintMB: 7_500, limitMB: 8_192), .signedIn)
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: true, footprintMB: 3_000, limitMB: nil), .signedIn)
    }

    func testTheFootprintEndsItAtTheLimitLessTheHeadroom() {
        XCTAssertEqual(LauncherEndTrigger.memoryThresholdMB(limitMB: 8_192), 6_992)
        XCTAssertNil(LauncherEndTrigger.check(signedIn: false, footprintMB: 6_991, limitMB: 8_192))
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: false, footprintMB: 6_992, limitMB: 8_192),
                       .memory(footprintMB: 6_992, limitMB: 8_192))
        // The limit before Game Mode is about 6 GB on the reference phone.
        XCTAssertEqual(LauncherEndTrigger.check(signedIn: false, footprintMB: 4_944, limitMB: 6_144),
                       .memory(footprintMB: 4_944, limitMB: 6_144))
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
