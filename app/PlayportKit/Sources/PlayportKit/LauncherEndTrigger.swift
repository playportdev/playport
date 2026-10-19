// SPDX-License-Identifier: GPL-3.0-or-later
// When a Play whose compatibility entry ends the publisher launcher (decision 0130, amending
// 0125) asks the session root to end the launcher's whole tree: once the game has signed in
// (GameSignIn), or earlier when the app's footprint comes within `headroomMB` of its memory
// limit, so the launcher's memory is freed before iOS ends the app.
//
// The headroom comes from the [xp] fpMB lines of runs 20261019T153520 to 20261019T185116:
// - over 20 s the footprint grows 110-180 MB/s, but in single bursts by up to 1.2 GB in 1-2 s
//   (at the game's first frame and at its socialclub.dll and libcef load);
// - the end freed about 500 MB within a second (run 20261019T185116).
// The app reads the footprint once a second while the end is pending, so 1,200 MB covers one
// such burst between two readings. Readings within `nearMB` of the limit are logged, so a
// Play's log shows the margin.

public enum LauncherEndTrigger: Equatable, Sendable {
    /// The game logged its sign-in line.
    case signedIn
    /// The footprint reached the limit minus headroomMB before the sign-in.
    case memory(footprintMB: Int, limitMB: Int)

    /// The end comes at the latest when the footprint is this close to the limit.
    public static let headroomMB = 1_200
    /// Readings this close to the limit are logged.
    public static let nearMB = 2_000

    /// The footprint at which the end comes before the sign-in, under `limitMB`.
    public static func memoryThresholdMB(limitMB: Int) -> Int { limitMB - headroomMB }

    /// Whether to end the launcher now, and why: the sign-in first, then the memory. A limit of
    /// nil (iOS reports none) never ends it for memory.
    public static func check(signedIn: Bool, footprintMB: Int, limitMB: Int?) -> LauncherEndTrigger? {
        if signedIn { return .signedIn }
        if let limitMB, footprintMB >= memoryThresholdMB(limitMB: limitMB) {
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
