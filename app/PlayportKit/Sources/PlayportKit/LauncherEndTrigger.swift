// SPDX-License-Identifier: GPL-3.0-or-later
// When a Play whose compatibility entry ends the publisher launcher (decision 0130, amending
// 0125) asks the session root to end the launcher's whole tree: once the game has signed in
// (GameSignIn), or earlier when the app's footprint comes within `beforeSignInHeadroomMB` of
// its memory limit, so the launcher's memory is freed before iOS ends the app (decision 0140,
// amending 0130: the game cannot sign in once the launcher is gone, so the early end waits
// until a kill is close).
//
// The headroom comes from the [xp] fpMB lines of runs 20261019T153520 to 20261019T185116:
// - over 20 s the footprint grows 110-180 MB/s, but in single bursts by up to 1.2 GB in 1-2 s
//   (at the game's first frame and at its socialclub.dll and libcef load);
// - the end freed about 500 MB within a second (run 20261019T185116).
// The app reads the footprint once a second while the end is pending. 1,200 MB covered one such
// burst between two readings (decision 0130), but RDR2's footprint reached it before the game's
// sign-in in runs 20261020T125218-rdr2-s4 and T142311-rdr2-f1 (7,020-7,027 MB, 16-19 s before the
// sign-in), and the game then showed "Not signed in". Before the sign-in the end now comes at
// 400 MB below the limit (decision 0140); the dev end of the game's own Social Club (decision
// 0133) keeps `headroomMB`. Readings within `nearMB` of the limit are logged, so a Play's log
// shows the margin.

public enum LauncherEndTrigger: Equatable, Sendable {
    /// The game logged its sign-in line.
    case signedIn
    /// The footprint reached the limit minus beforeSignInHeadroomMB before the sign-in.
    case memory(footprintMB: Int, limitMB: Int)

    /// After the sign-in, a dev build ends the game's own Social Club when the footprint is
    /// this close to the limit (decision 0133).
    public static let headroomMB = 1_200
    /// Before the sign-in, the launcher ends when the footprint is this close to the limit
    /// (decision 0140).
    public static let beforeSignInHeadroomMB = 400
    /// Readings this close to the limit are logged.
    public static let nearMB = 2_000

    /// The footprint at which a dev build ends the game's own Social Club after the sign-in,
    /// under `limitMB` (decision 0133).
    public static func memoryThresholdMB(limitMB: Int) -> Int { limitMB - headroomMB }

    /// The footprint at which the launcher's end comes before the sign-in, under `limitMB`.
    public static func beforeSignInThresholdMB(limitMB: Int) -> Int { limitMB - beforeSignInHeadroomMB }

    /// Whether to end the launcher now, and why: the sign-in first, then the memory. A limit of
    /// nil (iOS reports none) never ends it for memory.
    public static func check(signedIn: Bool, footprintMB: Int, limitMB: Int?) -> LauncherEndTrigger? {
        if signedIn { return .signedIn }
        if let limitMB, footprintMB >= beforeSignInThresholdMB(limitMB: limitMB) {
            return .memory(footprintMB: footprintMB, limitMB: limitMB)
        }
        return nil
    }

    /// Whether a reading is close enough to the limit to log.
    public static func near(footprintMB: Int, limitMB: Int?) -> Bool {
        guard let limitMB else { return false }
        return footprintMB >= limitMB - nearMB
    }
}
