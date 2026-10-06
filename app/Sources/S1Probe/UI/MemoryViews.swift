// SPDX-License-Identifier: GPL-3.0-or-later
// The app's memory limit as the player sees it (MemoryLimit): the words
// Settings › Setup check (SetupCheckSettings.swift), a game's page and a
// refused Play use (MemoryNote). A dev build's Developer section simulates a
// lower limit and a JIT pool (Dev/DeveloperSettings.swift).

import PlayportKit
import SwiftUI

/// The game page's warning under Play, following the limit as Settings' section does.
struct MemoryWarning: View {
    let need: MemoryNeed
    @State private var limitMB = MemoryLimit.read().effectiveMB

    var body: some View {
        VStack(alignment: .leading) {
            if let text = MemoryNote.warning(need, limitMB: limitMB) {
                Text(text).foregroundStyle(.orange)
            }
        }
        .task { await MemoryLimit.follow { limitMB = $0.effectiveMB } }
    }
}

/// What the player is told about the memory limit.
enum MemoryNote {
    static let footer = "The most memory iOS lets Playport use, for a game and Playport's own JIT memory together, "
        + "which is sized from it. "
        + "iOS closes a game that goes past it, so Playport does not start a game known to need more, and warns "
        + "when one may. It rises once Game Mode turns on. The Increased Memory Limit entitlement raises it; a copy "
        + "signed without it gets far less."

    static let notEntitled = "This copy of Playport was signed without the Increased Memory Limit entitlement. "
        + "Install one signed with a tool that keeps it: the Setup checklist's Memory step says how."

    /// Why a Play was refused (LaunchMessage).
    static func refused(limitMB: Int, needMB: Int) -> String {
        "iOS lets Playport use \(MemoryNeed.format(mb: limitMB)) of memory, and this game has needed about "
            + "\(MemoryNeed.format(mb: needMB)): iOS would close it partway through. " + advice
    }

    /// The game page's warning under Play; nil when the limit fits the game.
    static func warning(_ need: MemoryNeed, limitMB: Int?) -> String? {
        guard let limit = limitMB else { return nil }
        let have = MemoryNeed.format(mb: limit)
        switch need.verdict(limitMB: limit) {
        case .fits: return nil
        case .tooLow:
            return "This game has needed about \(MemoryNeed.format(mb: need.minimumMB)) of memory, and iOS lets Playport "
                + "use \(have): Playport will not start it. " + advice
        case .tight where need.measured:
            return "This game has used up to \(MemoryNeed.format(mb: need.minimumMB)) of memory, and iOS lets Playport "
                + "use \(have): iOS may close it."
        case .tight:
            return "iOS lets Playport use \(have) of memory. A larger game may need more, and iOS closes a game "
                + "that goes past it."
        }
    }

    /// The signature's entitlement decides the advice: a copy without it can get more by
    /// being signed again; one with it is at the phone's own limit.
    private static var advice: String {
        switch MemoryLimit.entitled {
        case false?: notEntitled
        case true?: "This phone cannot give Playport more."
        case nil: "A copy of Playport signed with the Increased Memory Limit entitlement gets more."
        }
    }
}
