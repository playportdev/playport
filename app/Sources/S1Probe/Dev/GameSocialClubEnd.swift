// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer › End the game's Social Club (experiment), dev builds only
// (decision 0133, amending 0130): after the game's sign-in, once the footprint is within
// LauncherEndTrigger.headroomMB of the limit, a Play whose launcher ends at the sign-in
// (LaunchSettings.endLauncherAfterSignIn, RDR2) also asks the session root, once, to end the
// game's own Social Club helpers (PP_CONTROL_END_GAME_SOCIAL_CLUB): every SocialClubHelper.exe
// under RDR2.exe, never the game. Off by default.

import Foundation

enum GameSocialClubEnd {
    static let key = "endGameSocialClubAfterSignIn"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
}
