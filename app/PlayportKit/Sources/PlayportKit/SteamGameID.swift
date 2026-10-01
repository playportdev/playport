// SPDX-License-Identifier: GPL-3.0-or-later
// Steam's game id in a Steam game's launch environment, set as Steam sets it
// for a game it starts, which Proton passes on to Wine unchanged: SteamAppId,
// SteamGameId and STEAM_COMPAT_APP_ID, each the game's Steam app ID. Valve's
// per-game fixes in patches/wine-valve key on them: SteamGameId (gdiplus,
// advapi32, kernelbase, msvcrt, rsaenh, user32, d2d1, ddraw and d3d8) and
// STEAM_COMPAT_APP_ID (msi), as Proton's own script reads all three. A title
// with no Steam app ID gets none of them. The backend's variables
// (GraphicsBackend.runtimeEnvironment) win over these. See
// docs/evidence/2026-09-28-steam-game-id.md.

public enum SteamGameID {
    /// The variables Steam sets to a game's app ID, in the order the launch logs them.
    public static let names = ["SteamAppId", "SteamGameId", "STEAM_COMPAT_APP_ID"]

    /// Each of `names` set to the app ID in decimal; empty for a title with none.
    public static func environment(appID: UInt32?) -> [String: String] {
        guard let appID else { return [:] }
        return Dictionary(uniqueKeysWithValues: names.map { ($0, String(appID)) })
    }

    /// One launch's environment: Steam's game id, then the backend's, which wins.
    public static func launchEnvironment(appID: UInt32?, backend: [String: String]) -> [String: String] {
        environment(appID: appID).merging(backend) { _, b in b }
    }
}
