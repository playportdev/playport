// SPDX-License-Identifier: GPL-3.0-or-later
// Whether a Play ends the game's own Social Club helper after its sign-in (GameSocialClubEnd in the
// app; decisions 0133, 0141, 0153, 0169).
//
// - Without the Social Club layout (Rockstar's own CEF, single-process): on unless the Settings switch
//   turned it off, in both builds (decision 0153). That is a Rockstar Play whose game folder holds no
//   verified Rockstar bootstrap (SocialClubBootstrap).
// - Under the layout (decision 0169), which a Play holds when its game folder holds a verified Rockstar
//   bootstrap (SocialClubBootstrap; 0183, PLA-840): off. In l19 the game signed in again after the end, 0155
//   refused the new helper (no headroom) and the game left Story for a black spinner; after the end
//   d1's game went back to its title menu, and l13 was killed after the restarts 0155 allowed. A dev
//   build's stored switch is an override, so a run can still measure the end there; a release build
//   ignores it.
// The refusal of the helper's restarts (0138) and 0155's re-sign-in watch go with the end: a Play
// that never ends the helper refuses none of its starts and never watches for a re-sign-in.

public enum GameSocialClubEndPolicy {
    /// The variable that turns the layout on for wine_host.c and ntdll at the runtime's start: the launch
    /// sets it to 1 for a Play whose game folder holds a verified Rockstar bootstrap and unsets it for
    /// every other, whatever a runtime key says.
    public static let layoutVariable = "PLAYPORT_SC_LAYOUT"

    /// Whether the Play ends the game's own Social Club: `stored` is the switch's stored value, nil
    /// when never set.
    public static func ends(stored: Bool?, socialClubLayout: Bool, release: Bool) -> Bool {
        guard socialClubLayout else { return stored ?? true }
        return release ? false : stored ?? false
    }

    /// Whether ntdll refuses the game's helper starts after the first (decision 0138), which also
    /// arms 0155's re-sign-in watch: only with the end, on unless its switch (`stored`) turned it off.
    public static func refusesRestarts(ends: Bool, stored: Bool?) -> Bool {
        ends && (stored ?? true)
    }
}
