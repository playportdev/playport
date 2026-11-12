// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// Decisions 0153 and 0169: the game's own Social Club is ended after its sign-in unless turned off,
/// except under the Social Club layout, where only a dev build's stored switch ends it; a Play holds
/// the layout when its game folder holds a verified Rockstar bootstrap (SocialClubBootstrapTests).
final class GameSocialClubEndPolicyTests: XCTestCase {
    func testWithoutTheLayoutTheEndIsOnUnlessTurnedOffInBothBuilds() {
        for release in [false, true] {
            XCTAssertTrue(GameSocialClubEndPolicy.ends(stored: nil, socialClubLayout: false, release: release))
            XCTAssertTrue(GameSocialClubEndPolicy.ends(stored: true, socialClubLayout: false, release: release))
            XCTAssertFalse(GameSocialClubEndPolicy.ends(stored: false, socialClubLayout: false, release: release))
        }
    }

    /// l19: the end, a refused re-sign-in and a black spinner; the layout leaves the helper alone.
    func testUnderTheLayoutTheEndIsOffAndOnlyADevBuildsSwitchOverridesIt() {
        XCTAssertFalse(GameSocialClubEndPolicy.ends(stored: nil, socialClubLayout: true, release: false))
        XCTAssertFalse(GameSocialClubEndPolicy.ends(stored: false, socialClubLayout: true, release: false))
        XCTAssertTrue(GameSocialClubEndPolicy.ends(stored: true, socialClubLayout: true, release: false))
        XCTAssertFalse(GameSocialClubEndPolicy.ends(stored: nil, socialClubLayout: true, release: true))
        XCTAssertFalse(GameSocialClubEndPolicy.ends(stored: true, socialClubLayout: true, release: true))
    }

    /// 0138's refusal, and with it 0155's re-sign-in watch, go only with the end.
    func testRestartsAreRefusedOnlyWithTheEnd() {
        XCTAssertTrue(GameSocialClubEndPolicy.refusesRestarts(ends: true, stored: nil))
        XCTAssertTrue(GameSocialClubEndPolicy.refusesRestarts(ends: true, stored: true))
        XCTAssertFalse(GameSocialClubEndPolicy.refusesRestarts(ends: true, stored: false))
        XCTAssertFalse(GameSocialClubEndPolicy.refusesRestarts(ends: false, stored: nil))
        XCTAssertFalse(GameSocialClubEndPolicy.refusesRestarts(ends: false, stored: true))
        let layoutDefault = GameSocialClubEndPolicy.ends(stored: nil, socialClubLayout: true, release: false)
        XCTAssertFalse(GameSocialClubEndPolicy.refusesRestarts(ends: layoutDefault, stored: nil))
    }

    /// A never-ended helper never reaches 0155: the watch arms only at an end.
    func testANeverEndedHelperNeverWatchesForAReSignIn() {
        var r = GameSocialClubReSignIn()
        XCTAssertFalse(r.watching)
        XCTAssertNil(r.slice(at: 400, signIns: 3, languageCalls: 20, footprintMB: 5_000, limitMB: 8_192))
        XCTAssertFalse(r.watching)
        XCTAssertEqual(r.allows, 0)
    }
}
