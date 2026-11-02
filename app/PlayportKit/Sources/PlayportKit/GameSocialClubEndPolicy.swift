// SPDX-License-Identifier: GPL-3.0-or-later
// Whether a Play ends the game's own Social Club helper after its sign-in (GameSocialClubEnd in the
// app; decisions 0133, 0141, 0153, 0169).
//
// - Without the Social Club layout (Rockstar's own CEF, single-process; PLAYPORT_SC_LAYOUT=1):
//   on unless the Settings switch turned it off, in both builds (decision 0153). That is only a
//   Rockstar Play whose dev build's `env.PLAYPORT_SC_LAYOUT=0` turned the layout off.
// - Under the layout (decision 0169), which every Play of Rockstar's launcher runs with its key
//   (PublisherLauncher.rockstar's runtime, both builds): off. In l19 the game signed in again after the end, 0155
//   refused the new helper (no headroom) and the game left Story for a black spinner; after the end
//   d1's game went back to its title menu, and l13 was killed after the restarts 0155 allowed. A dev
//   build's stored switch is an override, so a run can still measure the end there; a release build
//   ignores it.
// The refusal of the helper's restarts (0138) and 0155's re-sign-in watch go with the end: a Play
// that never ends the helper refuses none of its starts and never watches for a re-sign-in.

public enum GameSocialClubEndPolicy {
    /// The runtime key that turns the layout on, read by wine_host.c and ntdll at the runtime's start;
    /// PublisherLauncher.rockstar's runtime sets it for every Rockstar Play.
    public static let layoutVariable = "PLAYPORT_SC_LAYOUT"

    /// Whether this Play runs the layout: its config's `env.PLAYPORT_SC_LAYOUT` key (the Rockstar
    /// launcher's, or a dev build's `=0` over it), which the launch exports over the app's
    /// environment, else that environment's value; "1" only, as wine_host.c reads it.
    /// The runtime holds the layout for such a Play or refuses its launch.
    public static func socialClubLayout(config: [String: String], environment: String?) -> Bool {
        (config["env." + layoutVariable] ?? environment) == "1"
    }

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
