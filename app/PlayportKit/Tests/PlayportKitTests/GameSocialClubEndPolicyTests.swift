// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// Decisions 0153 and 0169: the game's own Social Club is ended after its sign-in unless turned off,
/// except under the Social Club layout, where only a dev build's stored switch ends it; every Play
/// of Rockstar's launcher runs the layout (PLA-602).
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

    /// The Play's `env.PLAYPORT_SC_LAYOUT` key wins over the app's environment; "1" only.
    func testTheLayoutIsTheConfigKeyElseTheEnvironment() {
        let layout = GameSocialClubEndPolicy.socialClubLayout(config:environment:)
        XCTAssertTrue(layout(["env.PLAYPORT_SC_LAYOUT": "1"], nil))
        XCTAssertFalse(layout(["env.PLAYPORT_SC_LAYOUT": "0"], "1"))
        XCTAssertFalse(layout(["env.PLAYPORT_SC_LAYOUT": "yes"], nil))
        XCTAssertTrue(layout([:], "1"))
        XCTAssertFalse(layout([:], nil))
        XCTAssertFalse(layout(["env.PLAYPORT_SC_SINGLE": "1"], nil))   // d1: single-process, no layout
    }

    /// PLA-602: a Rockstar Play's config carries the launcher's layout key, so with no key of a
    /// person's the end is off in both builds; a dev build's `=0` brings back decision 0153's end.
    func testARockstarPlayRunsTheLayoutSoTheEndIsOffUnlessADevKeyTurnsItOff() {
        let rockstar = PublisherLauncher.rockstar.openSettings(saved: nil).config
        let layout = GameSocialClubEndPolicy.socialClubLayout(config: rockstar, environment: nil)
        XCTAssertTrue(layout)
        for release in [false, true] {
            let ends = GameSocialClubEndPolicy.ends(stored: nil, socialClubLayout: layout, release: release)
            XCTAssertFalse(ends)
            XCTAssertFalse(GameSocialClubEndPolicy.refusesRestarts(ends: ends, stored: nil))
        }
        let off = PublisherLauncher.rockstar.openSettings(saved: LaunchSettings(runtime: "env.PLAYPORT_SC_LAYOUT=0")).config
        let devOff = GameSocialClubEndPolicy.socialClubLayout(config: off, environment: "1")
        XCTAssertFalse(devOff)
        XCTAssertTrue(GameSocialClubEndPolicy.ends(stored: nil, socialClubLayout: devOff, release: false))
    }
}
