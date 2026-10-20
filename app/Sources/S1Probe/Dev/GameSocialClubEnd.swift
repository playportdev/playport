// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer › End the game's Social Club (experiment), dev builds only
// (decision 0133, amending 0130): 120 s or more after the game's sign-in (decision 0141), once the
// footprint is within
// LauncherEndTrigger.headroomMB of the limit, a Play whose launcher ends at the sign-in
// (LaunchSettings.endLauncherAfterSignIn, RDR2) also asks the session root, once, to end the
// game's own Social Club helpers (PP_CONTROL_END_GAME_SOCIAL_CLUB): every SocialClubHelper.exe
// under RDR2.exe, never the game. Off by default.
// Refuse its restarts (decision 0138, with the end on): the app sets
// PLAYPORT_REFUSE_GAME_SC_RESTART=1 for that Play, and ntdll refuses every SocialClubHelper.exe
// start by RDR2.exe after the first (pp_game_sc_refuse.h), instead of the session root ending
// each restart a quarter of a second after it starts (decision 0135). Off by default.

import Foundation

enum GameSocialClubEnd {
    static let key = "endGameSocialClubAfterSignIn"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    static let refuseRestartKey = "refuseGameSocialClubRestart"
    static var refuseRestart: Bool { UserDefaults.standard.bool(forKey: refuseRestartKey) }
    static let refuseRestartVariable = "PLAYPORT_REFUSE_GAME_SC_RESTART"
}
