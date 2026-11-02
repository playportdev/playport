// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import PlayportKit

/// Decision 0155: after the end of the game's own Social Club, a re-sign-in allows the helper's
/// restarts until the new sign-in is done, at most twice a Play, and the end may run again after it.
final class GameSocialClubReSignInTests: XCTestCase {
    /// 0155 as amended: an allow needs footprint + 600 MB under the limit less 400 MB. Run d1's
    /// two allows came at 7,621 and 8,124 MB of 8,192, and its jetsam followed the second.
    func testAnAllowNeedsHeadroom() {
        let fits = GameSocialClubReSignIn.hasRestartHeadroom(footprintMB:limitMB:)
        XCTAssertTrue(fits(7_191, 8_192))     // 7,791 < 7,792
        XCTAssertFalse(fits(7_192, 8_192))    // 7,792 is not under 7,792
        XCTAssertFalse(fits(7_621, 8_192))    // d1's first allow
        XCTAssertFalse(fits(8_124, 8_192))    // d1's second
        XCTAssertFalse(fits(1_000, nil))      // no limit read: no headroom

        var r = GameSocialClubReSignIn()
        r.ended(at: 221.6, signIns: 1)
        XCTAssertNil(r.slice(at: 251, signIns: 1, languageCalls: 1, footprintMB: 7_610, limitMB: 8_192))
        XCTAssertEqual(r.slice(at: 253, signIns: 1, languageCalls: 3, footprintMB: 7_621, limitMB: 8_192),
                       .noHeadroom(.steamLanguage, footprintMB: 7_621))
        // the refusal stands for the rest of the Play and spends no allow; no re-end follows
        XCTAssertEqual(r.phase, .finished)
        XCTAssertFalse(r.watching)
        XCTAssertEqual(r.allows, 0)
        XCTAssertNil(r.slice(at: 300, signIns: 2, languageCalls: 0, footprintMB: 5_000, limitMB: 8_192))
        XCTAssertNil(r.reEndSignInAt)

        var log = GameSocialClubReSignIn()
        log.ended(at: 300, signIns: 1)
        XCTAssertEqual(log.slice(at: 302, signIns: 2, languageCalls: 0, footprintMB: 7_200, limitMB: 8_192),
                       .noHeadroom(.socialClubLog, footprintMB: 7_200))
        var room = GameSocialClubReSignIn()
        room.ended(at: 300, signIns: 1)
        XCTAssertEqual(room.slice(at: 302, signIns: 2, languageCalls: 0, footprintMB: 7_100, limitMB: 8_192),
                       .allow(.socialClubLog))
    }

    /// With all allows spent the answer stays "no allow left", whatever the headroom.
    func testNoAllowLeftComesBeforeHeadroom() {
        var r = GameSocialClubReSignIn()
        r.ended(at: 300, signIns: 1)
        XCTAssertEqual(r.slice(at: 302, signIns: 2, languageCalls: 0), .allow(.socialClubLog))
        XCTAssertEqual(r.slice(at: 320, signIns: 3, languageCalls: 0), .refuseAgain(signedIn: true))
        r.ended(at: 450, signIns: 3)
        XCTAssertEqual(r.slice(at: 451, signIns: 4, languageCalls: 0), .allow(.socialClubLog))
        XCTAssertEqual(r.slice(at: 460, signIns: 5, languageCalls: 0), .refuseAgain(signedIn: true))
        r.ended(at: 600, signIns: 5)
        XCTAssertEqual(r.slice(at: 601, signIns: 6, languageCalls: 0, footprintMB: 8_100, limitMB: 8_192),
                       .noAllowLeft(.socialClubLog))
    }

    func testNothingBeforeTheEnd() {
        var r = GameSocialClubReSignIn()
        XCTAssertFalse(r.watching)
        XCTAssertNil(r.slice(at: 10, signIns: 3, languageCalls: 9))
        XCTAssertEqual(r.phase, .beforeEnd)
    }

    /// A run that plays on: no new sign-in line and no burst, so no step at all, ever.
    func testAFineRunGetsNoStep() {
        var r = GameSocialClubReSignIn()
        XCTAssertFalse(r.ended(at: 300, signIns: 1))
        XCTAssertTrue(r.watching)
        for t in stride(from: 301.0, to: 1_000, by: 1) {
            // a call or two a minute in play, as in run n2; a burst only long after the window
            XCTAssertNil(r.slice(at: t, signIns: 1, languageCalls: t == 330 ? 2 : (t > 361 ? 4 : 0)))
        }
        XCTAssertNil(r.reEndSignInAt)
        XCTAssertEqual(r.allows, 0)
    }

    func testANewSignInLineAllowsUntilTheNextOrTheCap() {
        var r = GameSocialClubReSignIn()
        r.ended(at: 300, signIns: 1)
        XCTAssertNil(r.slice(at: 301, signIns: 1, languageCalls: 0))
        XCTAssertEqual(r.slice(at: 302, signIns: 2, languageCalls: 0), .allow(.socialClubLog))
        XCTAssertEqual(r.allows, 1)
        XCTAssertNil(r.slice(at: 391, signIns: 2, languageCalls: 0))
        XCTAssertEqual(r.slice(at: 392, signIns: 2, languageCalls: 0), .refuseAgain(signedIn: false))
        // the line that allowed it is the re-sign-in 0141's 120 s count from
        XCTAssertEqual(r.reEndSignInAt, 302)

        var s = GameSocialClubReSignIn()
        s.ended(at: 300, signIns: 1)
        XCTAssertEqual(s.slice(at: 302, signIns: 2, languageCalls: 0), .allow(.socialClubLog))
        XCTAssertEqual(s.slice(at: 340, signIns: 3, languageCalls: 0), .refuseAgain(signedIn: true))
        XCTAssertEqual(s.reEndSignInAt, 340)
    }

    /// The fallback: GetCurrentGameLanguage calls counted from the end, over slices, within 60 s.
    func testALanguageBurstAfterTheEndAllows() {
        var r = GameSocialClubReSignIn()
        r.ended(at: 300, signIns: 1)
        XCTAssertNil(r.slice(at: 320, signIns: 1, languageCalls: 1))
        XCTAssertNil(r.slice(at: 321, signIns: 1, languageCalls: 2))
        XCTAssertEqual(r.slice(at: 330, signIns: 1, languageCalls: 1), .allow(.steamLanguage))
        // the game's sign-in line ends the allow, and is the sign-in the re-end counts from
        XCTAssertNil(r.slice(at: 340, signIns: 1, languageCalls: 5))
        XCTAssertEqual(r.slice(at: 350, signIns: 2, languageCalls: 0), .refuseAgain(signedIn: true))
        XCTAssertEqual(r.reEndSignInAt, 350)

        var late = GameSocialClubReSignIn()
        late.ended(at: 300, signIns: 1)
        XCTAssertNil(late.slice(at: 361, signIns: 1, languageCalls: 4))   // past the window
        // without a sign-in line the cap ends it, and the allow's time stands in for the sign-in
        var capped = GameSocialClubReSignIn()
        capped.ended(at: 300, signIns: 1)
        XCTAssertEqual(capped.slice(at: 360, signIns: 1, languageCalls: 4), .allow(.steamLanguage))
        XCTAssertEqual(capped.slice(at: 450, signIns: 1, languageCalls: 0), .refuseAgain(signedIn: false))
        XCTAssertEqual(capped.reEndSignInAt, 360)
    }

    /// Two allows and two re-ends a Play; a third re-sign-in is only noted.
    func testAtMostTwoAllows() {
        var r = GameSocialClubReSignIn()
        r.ended(at: 300, signIns: 1)
        XCTAssertEqual(r.slice(at: 302, signIns: 2, languageCalls: 0), .allow(.socialClubLog))
        XCTAssertEqual(r.slice(at: 320, signIns: 3, languageCalls: 0), .refuseAgain(signedIn: true))
        XCTAssertTrue(r.ended(at: 450, signIns: 3))
        XCTAssertNil(r.reEndSignInAt)
        XCTAssertEqual(r.slice(at: 470, signIns: 3, languageCalls: 4), .allow(.steamLanguage))
        XCTAssertEqual(r.slice(at: 560, signIns: 3, languageCalls: 0), .refuseAgain(signedIn: false))
        XCTAssertTrue(r.ended(at: 700, signIns: 3))
        XCTAssertEqual(r.slice(at: 701, signIns: 4, languageCalls: 0), .noAllowLeft(.socialClubLog))
        XCTAssertEqual(r.phase, .finished)
        XCTAssertFalse(r.watching)
        XCTAssertNil(r.slice(at: 702, signIns: 5, languageCalls: 9))
        XCTAssertEqual(r.allows, GameSocialClubReSignIn.maxAllows)
    }

    func testAnAllowTheRootRefusedEndsIt() {
        var r = GameSocialClubReSignIn()
        r.ended(at: 300, signIns: 1)
        XCTAssertEqual(r.slice(at: 302, signIns: 2, languageCalls: 0), .allow(.socialClubLog))
        r.allowFailed()
        XCTAssertNil(r.slice(at: 303, signIns: 3, languageCalls: 0))
        XCTAssertNil(r.reEndSignInAt)
        XCTAssertFalse(r.watching)
    }

    /// The steamclient trace's summaries, as runs qe2c and x8 logged them.
    func testLanguageCallsInTraceLines() {
        let count = GameSocialClubReSignIn.languageCalls(inTraceLine:)
        XCTAssertEqual(count("trace +225921ms summary ISteamApps008.GetCurrentGameLanguagex4 ISteamUtils008.RunFramex4 "
                             + "SteamController004.slot2x4 export.Steam_BGetCallbackx4 ISteamFriends015.SetRichPresencex2"), 4)
        XCTAssertEqual(count("trace +4101ms summary+ ISteamClient017.GetISteamControllerx1 ISteamApps008.GetCurrentGameLanguagex1"), 1)
        XCTAssertEqual(count("trace +9ms summary ISteamApps008.GetCurrentGameLanguagex2 ISteamApps009.GetCurrentGameLanguagex3"), 5)
        XCTAssertEqual(count("trace +4102ms t3e8 ISteamApps008 GetCurrentGameLanguage() -> \"english\" #2"), 0)
        XCTAssertEqual(count("trace +4102ms summary ISteamApps008.GetAvailableGameLanguagesx3 ISteamUtils008.RunFramex1"), 0)
        XCTAssertEqual(count("client connected (protocol 3)"), 0)
    }

    /// The log's sign-in lines are counted, so a second one after the end shows.
    func testTheWatchCountsSignInLines() {
        let signIn = PublisherLauncher.rockstar.signIn!
        func log(_ lines: [String]) -> Data {
            var d = Data([0xFF, 0xFE])
            for u in (lines.map { $0 + "\r\n" }.joined()).utf16 { d.append(contentsOf: [UInt8(u & 0xff), UInt8(u >> 8)]) }
            return d
        }
        let w = GameSignIn.Watch(signIn: signIn, baseline: nil)
        let first = ["[00000000] Thu Oct 15 22:45:58 2026", "[00002430] Signed in online to profile someone"]
        XCTAssertEqual(w.signIns(log(first)), 1)
        XCTAssertEqual(w.signIns(log(first + ["[00300000] Signed out", "[00301000] Signed in online to profile someone"])), 2)
        XCTAssertEqual(w.signIns(log(["[00000000] Thu Oct 15 22:45:58 2026"])), 0)
    }
}

private extension GameSocialClubReSignIn {
    /// A slice with room for a restart (5,000 of 8,192 MB), for the tests that are not about headroom.
    mutating func slice(at elapsed: Double, signIns: Int, languageCalls: Int) -> Step? {
        slice(at: elapsed, signIns: signIns, languageCalls: languageCalls, footprintMB: 5_000, limitMB: 8_192)
    }
}
