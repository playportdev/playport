// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Graphics › End a game's own Social Club, in dev and release builds, on unless turned
// off (decision 0153, amending 0133 and 0141): 120 s or more after the game's sign-in, once the
// footprint is within LauncherEndTrigger.headroomMB of the limit, a Play whose launcher ends at the
// sign-in (LaunchSettings.endLauncherAfterSignIn with a PublisherLauncher, which only Rockstar's
// game has) also asks the session root, once, to end the game's own Social Club helpers
// (PP_CONTROL_END_GAME_SOCIAL_CLUB): every SocialClubHelper.exe under RDR2.exe, never the game.
// Refuse its restarts (decision 0138, with the end on, also on by default): the app sets
// PLAYPORT_REFUSE_GAME_SC_RESTART=1 for that Play, and ntdll refuses every SocialClubHelper.exe
// start by RDR2.exe after the first (pp_game_sc_refuse.h), instead of the session root ending
// each restart a quarter of a second after it starts (decision 0135). A Play with no publisher's
// launcher sets neither.
// After an end the game may sign in again and need its helper (decision 0155,
// GameSocialClubReSignIn): the steamclient trace's GetCurrentGameLanguage calls are counted
// here for that watch's fallback detector.

import Foundation
import PlayportKit

enum GameSocialClubEnd {
    static let key = "endGameSocialClubAfterSignIn"
    static var enabled: Bool { setting(key) }
    static let refuseRestartKey = "refuseGameSocialClubRestart"
    static var refuseRestart: Bool { setting(refuseRestartKey) }
    static let refuseRestartVariable = "PLAYPORT_REFUSE_GAME_SC_RESTART"

    private static let languageLock = NSLock()
    nonisolated(unsafe) private static var languageCallCount = 0

    /// A steamclient trace line (SteamClientHost): its GetCurrentGameLanguage calls are counted.
    static func noteSteamTrace(_ line: String) {
        let n = GameSocialClubReSignIn.languageCalls(inTraceLine: line)
        if n > 0 { languageLock.withLock { languageCallCount += n } }
    }

    /// The GetCurrentGameLanguage calls counted since the last take.
    static func takeLanguageCalls() -> Int {
        languageLock.withLock {
            defer { languageCallCount = 0 }
            return languageCallCount
        }
    }

    /// On when never set (decision 0153); a stored value, Bool or the driver's `set:` string, wins.
    private static func setting(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}
