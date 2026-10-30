// SPDX-License-Identifier: GPL-3.0-or-later
// A play's own guest variables (an Xbox copy's bridge port and key, decision 0167):
// they go into the game's environment for its launch only. Never `setenv` into the
// app's process (the runtime's unix side and every later child would see them), never
// to the play's prerequisites, and only their names are logged.

import Foundation
import SteamClientKit

public enum GuestEnvironment {
    /// The game's environment: the launch's `environment` with the play's `guest`
    /// variables over it.
    public static func title(_ environment: [String: String], guest: [String: Secret<String>]) -> [String: String] {
        environment.merging(guest.mapValues(\.value)) { _, own in own }
    }

    /// The log line for the play's variables: their names only; nil for none.
    public static func logLine(_ guest: [String: Secret<String>]) -> String? {
        guard !guest.isEmpty else { return nil }
        return "environment: the play's own " + guest.keys.sorted().joined(separator: ", ") + " (values not logged)"
    }
}
