// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Steam account: the sign-in's status, Sign in to Steam
// (SignInView.swift: the account name on this phone, or a QR code a second
// device scans), refreshing the library, and sign-out (confirmed in a
// picker). Every control is a row on the ring.

import SteamClientKit
import SwiftUI

struct SteamAccountSettings: View {
    @EnvironmentObject private var model: SteamAccountModel

    var body: some View {
        SettingsNote(text: "Your Steam library, cloud saves and achievements come from this account.")
        SettingsInfoRow(id: "steam:status", title: AccountCopy.status(model.state), subtitle: detail)
        switch model.state {
        case let .signedIn(a), let .offline(a, _):
            signedIn(a)
        case .unknown, .restoring:
            EmptyView()
        case .signedOut, .pairing, .expired:
            // Sign in to Steam (SignInView.swift): the account name on this phone, or a QR code.
            PadRow(id: "set:steam:signin", title: "Sign in to Steam", subtitle: "With your account name, or a QR code from another device",
                   accessory: .chevron, hint: "Sign in") { SignInState.shared.open(preview: false) }
        }
    }

    private var detail: String? {
        switch model.state {
        case let .signedIn(a), let .offline(a, _):
            AccountCopy.pairedUntil(a) { $0.formatted(date: .abbreviated, time: .omitted) }
        case .unknown, .restoring: "Checking…"
        default: nil
        }
    }

    @ViewBuilder
    private func signedIn(_ a: SteamService.Account) -> some View {
        #if !PLAYPORT_RELEASE
        // The service's raw renewal result ("not-due", "failed: …"); a release build shows none.
        if let r = model.lastRenewal {
            SettingsInfoRow(id: "steam:renewal", title: "Last renewal check",
                            subtitle: r.at.formatted(.relative(presentation: .named)), value: r.result)
        }
        #endif
        PadRow(id: "set:steam:refresh", title: "Refresh library",
               subtitle: model.gamesError ?? model.gamesFetchedAt.map { "Fetched " + $0.formatted(.relative(presentation: .named)) },
               value: model.gamesLoading ? "Asking Steam…" : nil, hint: "Refresh") {
            guard !model.gamesLoading else { return }
            Task { await model.loadGames(refresh: true) }
        }
        PadRow(id: "set:steam:signout", title: model.signingOut ? "Signing out…" : "Sign out", subtitle: AccountCopy.signOutNote,
               destructive: true, hint: "Sign out") {
            guard !model.signingOut else { return }
            PadModal.shared.picker(
                title: "Sign out of Steam?", context: "Settings · Steam account", note: AccountCopy.signOutNote,
                options: [PadOption(id: "keep", label: "Stay signed in"), PadOption(id: "out", label: "Sign out")],
                selected: "keep") { if $0 == "out" { Task { await model.signOut() } } }
        }
        #if !PLAYPORT_RELEASE
        // The sign-in screen while signed in: its steps shown, and nothing goes to Steam.
        PadRow(id: "set:steam:signinPreview", title: "Preview sign-in", subtitle: "The sign-in screen; nothing goes to Steam",
               accessory: .chevron, hint: "Preview") { SignInState.shared.open(preview: true) }
        #endif
    }
}
