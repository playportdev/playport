// SPDX-License-Identifier: GPL-3.0-or-later
// The driver's actions on an Xbox game's save conflict (Dev/XboxCloudSaves.swift, PLA-500),
// as a controller's presses do them (decision 0012):
//
//   xbox-save:wait     after a play:, waits (3 min at most) for the runtime's question and logs
//                      both sides' times and devices, leaving it up (a screenshot sees it)
//   xbox-save:local    the same, then A: keep this phone's saves (they replace the cloud's)
//   xbox-save:cloud    the same, then X: keep the cloud's (the phone's set aside by the runtime)
//   xbox-save:later    the same, then B: decide later (this play on the phone's saves)
//
// Lines go to the log as `ui: xbox-save …`, without the save's name.

import ContentKit
import Foundation
import HostIOKit
import XboxClientKit

@MainActor
enum XboxSaveDriver {
    /// nil when the action did what it says, else why not.
    static func run(_ id: String, log: (String) -> Void) async throws -> String? {
        let press: NavButton?
        switch id {
        case "wait": press = nil
        case "local": press = .a
        case "cloud": press = .x
        case "later": press = .b
        default: return "not xbox-save:wait, local, cloud or later"
        }
        try UIDriver.checkpoint()
        let prompt = XboxSaveConflictPrompt.shared
        let deadline = Date().addingTimeInterval(180)
        while !prompt.isUp, TitleLaunch.shared.running, Date() < deadline {
            try await UIDriver.pause(.milliseconds(250))
        }
        guard let summary = prompt.summary else { return "the game asked no save conflict question" }
        log("xbox-save: conflict up: \(summary)")
        try await UIDriver.pause(.milliseconds(1000))   // the card drawn, for a screenshot
        guard let press else { return nil }
        prompt.press(press)
        guard let choice = prompt.lastChoice, !prompt.isUp else { return "the question did not take the answer" }
        log("xbox-save: answered \(choice.rawValue)")
        try await UIDriver.pause(.milliseconds(500))
        return nil
    }

    /// `xbox:saves:<ProductId>`: whether the installed copy has saves the cloud lacks.
    static func status(_ product: String, log: (String) -> Void) -> String? {
        guard StoreGameKey.isProductID(product) else { return "not a Product ID" }
        let unsynced = XboxCloudSaves.unsynced(productID: product)
        log("xbox: \(StoreGameKey(store: .xbox, id: product)) saves "
            + (unsynced.map { $0 ? "unsynced (the game page says so)" : "synced" } ?? "unknown (no record, no SCID or an unreadable index)"))
        return nil
    }
}
