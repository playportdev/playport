// SPDX-License-Identifier: GPL-3.0-or-later
// An Xbox copy's cloud saves (PLA-500), dev app only (decisions 0166, 0167). The game's
// runtime syncs with the account's Xbox cloud itself at each play's start and uploads as
// the game saves; with the cloud unreachable it plays on the phone's saves and syncs at
// the next connected play (patches/xgameruntime/0002 for file saves). When both sides
// changed since they last matched it asks here, over the play's bridge
// (XboxClientKit XboxBridgeService, SAVE_CONFLICT_REQUEST), once for each save that
// conflicts: a card over the paused game names that save and shows each side's time and
// device. A or B decides later (the default: this play on the phone's saves, both sides
// kept, the question again next time), X keeps the cloud's (the runtime sets the phone's
// aside as a copy), and keeping the phone's, which replaces the cloud's (the runtime keeps
// the cloud's as a copy first), takes Y twice. The game's end or a sign-out answers later.
// A copy's unsynced saves are read from the runtime's index (XboxSaves).

import ContentKit
import Foundation
import HostIOKit
import PlayportKit
import SwiftUI
import UIKit
import XboxClientKit

enum XboxCloudSaves {
    /// Whether the installed copy `productID` has saves not yet in the account's cloud: nil
    /// with no install record, no SCID in its MicrosoftGame.config or an unreadable index.
    nonisolated static func unsynced(productID: String) -> Bool? {
        let record = LibraryModel.paths.layout.manifestsDir
            .appendingPathComponent(StoreGameKey(store: .xbox, id: productID).fileStem + ".json")
        guard let data = try? Data(contentsOf: record), let rec = try? JSONDecoder().decode(XboxInstalled.self, from: data),
              let scid = rec.scid else { return nil }
        return XboxSaves.unsynced(scid: scid, localAppData: XboxInstalls.localAppData)
    }

    /// The lapse rule's view (PLA-505): an Xbox copy's removal waits while this is not false.
    static var lapseSaves: StoreUnsyncedSaves { StoreUnsyncedSaves(.xbox) { unsynced(productID: $0) } }

    /// The game page's line for an installed copy with unsynced saves; nil otherwise (an
    /// unknown answer still holds a lapse's removal, but says nothing on the page).
    nonisolated static func note(productID: String) -> String? {
        unsynced(productID: productID) == true
            ? "Saves on this phone are not in the Xbox cloud yet: they upload at the next play with a connection." : nil
    }
}

/// The bridge's side of the question: the card over the game.
struct XboxSavePromptAsker: XboxSaveConflictAsker {
    func choose(_ conflict: XboxSaveConflict, productID: String) async -> XboxSaveChoice {
        await XboxSaveConflictPrompt.shared.ask(conflict, productID: productID)
    }
}

@MainActor
final class XboxSaveConflictPrompt: ObservableObject {
    static let shared = XboxSaveConflictPrompt()

    struct Shown {
        let conflict: XboxSaveConflict
        let productID: String
        let game: String
    }
    @Published private(set) var shown: Shown?
    /// Y pressed once: the card asks for Y again before the phone's saves replace the cloud's.
    @Published private(set) var confirmingLocal = false
    private var answer: CheckedContinuation<XboxSaveChoice, Never>?
    private var nav = PadNavigation()
    private var shownAt = Date.distantPast
    /// The last answer, for `pp ui` (Dev/XboxSaveDriver.swift).
    private(set) var lastChoice: XboxSaveChoice?

    var isUp: Bool { shown != nil }
    private func log(_ line: String) { XboxInstalls.log.info("xbox", "saves: " + line) }

    func ask(_ conflict: XboxSaveConflict, productID: String) async -> XboxSaveChoice {
        choose(.none, why: "another question")
        let game = TitleLaunch.shared.running && !TitleLaunch.shared.title.isEmpty ? TitleLaunch.shared.title : "This game"
        return await withCheckedContinuation { c in
            answer = c
            nav.reset()
            shownAt = Date()
            lastChoice = nil
            confirmingLocal = false
            shown = Shown(conflict: conflict, productID: productID, game: game)
            HostIO.shared.holdGuest()
            log("\(StoreGameKey(store: .xbox, id: productID)): conflict asked")
        }
    }

    /// The player's answer (or the game's end: none); the game gets its input back.
    func choose(_ choice: XboxSaveChoice, why: String) {
        guard let c = answer else { return }
        answer = nil
        shown = nil
        confirmingLocal = false
        lastChoice = choice
        HostIO.shared.releaseGuest()
        log("keeping \(choice == .none ? "both, this play on the phone's" : choice == .local ? "the phone's" : "the cloud's") (\(why))")
        c.resume(returning: choice)
    }

    /// The play ended (XboxPlay's atEnd) with the question up: decided later.
    nonisolated static func gameEnded() {
        Task { @MainActor in shared.choose(.none, why: "the game ended") }
    }

    func padInput(_ p: PadInput) {
        let presses = nav.update(p, at: ProcessInfo.processInfo.systemUptime)
        guard Date().timeIntervalSince(shownAt) > 0.3 else { return }
        for b in presses { press(b) }
    }

    /// A and B: decide later. X: the cloud's. Y twice: the phone's (Y once, then anything
    /// else, decides nothing).
    func press(_ b: NavButton) {
        switch b {
        case .a, .b: choose(.none, why: b == .a ? "A" : "B")
        case .x: choose(.cloud, why: "X")
        case .y:
            if confirmingLocal { choose(.local, why: "Y, confirmed") } else { confirmingLocal = true }
        default: confirmingLocal = false
        }
    }

    /// What the driver's log names: the two sides' times and devices, not the save's name.
    var summary: String? {
        guard let s = shown else { return nil }
        return "phone \(Self.when(s.conflict.local.time)) on \(Self.phone), cloud \(Self.when(s.conflict.cloud.time)) on \(Self.device(s.conflict.cloud))"
            + (confirmingLocal ? "; asking to confirm the phone's" : "")
    }

    static var phone: String { "this \(UIDevice.current.model)" }
    static func device(_ v: XboxSaveVersion) -> String { v.device ?? "another device (Windows or Xbox)" }
    static func when(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "time unknown" }
}

/// The card over the running game.
struct XboxSaveConflictView: View {
    @ObservedObject private var prompt = XboxSaveConflictPrompt.shared

    var body: some View {
        if let s = prompt.shown {
            ZStack {
                Color.black.opacity(0.82).ignoresSafeArea()
                VStack(spacing: 18) {
                    Image(systemName: "icloud.and.arrow.down").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("\(s.game): which “\(s.conflict.displayName)” do you want to keep?").font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("This save changed on this phone and in your Xbox cloud since they last matched. Only this save is asked about; "
                         + "another one that conflicts gets its own question.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(alignment: .top, spacing: 16) {
                        card("This phone", when: s.conflict.local.time, device: XboxSaveConflictPrompt.phone,
                             button: prompt.confirmingLocal ? "Replace the cloud's  Ⓨ" : "Keep these  Ⓨ",
                             destructive: prompt.confirmingLocal) { prompt.press(.y) }
                        card("Xbox cloud", when: s.conflict.cloud.time, device: XboxSaveConflictPrompt.device(s.conflict.cloud),
                             button: "Keep these  Ⓧ", destructive: false) { prompt.press(.x) }
                    }
                    if prompt.confirmingLocal {
                        Text("Press Ⓨ again to replace the cloud's “\(s.conflict.displayName)” with this phone's. "
                             + "The cloud's is kept as a copy on this phone first.")
                            .font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                    } else {
                        Text("Keeping one side replaces the other; the side you don't keep stays on this phone as a copy.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button("Decide later  Ⓑ") { prompt.press(.b) }.buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: 640)
            }
            .foregroundStyle(.white)
            .tint(.white)
            .transition(.opacity)
        }
    }

    private func card(_ heading: String, when: Date?, device: String, button: String, destructive: Bool,
                      action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(heading).font(.headline)
            Text(XboxSaveConflictPrompt.when(when)).font(.body.monospacedDigit())
            Text("on \(device)").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(button, role: destructive ? .destructive : nil, action: action).buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}
