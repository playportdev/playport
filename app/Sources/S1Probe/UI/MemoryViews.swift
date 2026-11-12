// SPDX-License-Identifier: GPL-3.0-or-later
// The app's memory limit as the player sees it (MemoryLimit): the words
// Settings › Setup check (SetupCheckSettings.swift) and a game's page use
// (MemoryNote), the page's note on a Play iOS ended for memory included
// (PlayportKit MemoryKill). Nothing refuses a Play for memory. A dev build's
// Developer section simulates a lower limit and a JIT pool
// (Dev/DeveloperSettings.swift).

import PlayportKit
import SwiftUI

/// The game page's warning under Play when the limit is low, following the limit as Settings' section does.
struct MemoryWarning: View {
    @State private var limitMB = MemoryLimit.read().effectiveMB

    var body: some View {
        VStack(alignment: .leading) {
            if let text = MemoryNote.lowLimit(limitMB) {
                Text(text).foregroundStyle(.orange)
            }
        }
        .task { await MemoryLimit.follow { limitMB = $0.effectiveMB } }
    }
}

/// What the player is told about the memory limit.
enum MemoryNote {
    /// Under this limit the game's page warns that a larger game may not fit: a 3D game's heap
    /// and textures on top of the runtime (Hollow Knight, a 2D game, reaches about 3 GB). It is
    /// the same for every game; no game carries a figure of its own.
    static let lowLimitMB = 4096

    static let footer = "The most memory iOS lets Playport use, for a game and the JIT memory it uses together. "
        + "iOS closes a game that goes past it; the game's page then says so, with the most it used. It rises once "
        + "Game Mode turns on. The Increased Memory Limit entitlement raises it; a copy signed without it gets far less."

    static let notEntitled = "This copy of Playport was signed without the Increased Memory Limit entitlement. "
        + "Install one signed with a tool that keeps it: the Setup checklist's Memory step says how."

    /// The game page's warning under Play; nil when the limit is not low or not reported.
    static func lowLimit(_ limitMB: Int?) -> String? {
        guard let limit = limitMB, limit < lowLimitMB else { return nil }
        return "iOS lets Playport use \(ByteCount.format(mb: limit)) of memory. A larger game may need more, "
            + "and iOS closes a game that goes past it."
    }

    /// The game page's note on a last Play iOS ended for memory, with its peak and the limit.
    static func killed(_ k: MemoryKill) -> String {
        "Ended for memory on its last play: it reached \(ByteCount.format(mb: k.peakMB)), and iOS lets Playport use "
            + "\(ByteCount.format(mb: k.limitMB)). " + advice
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
