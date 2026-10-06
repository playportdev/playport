// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Setup check: what a game needs from this phone, each a row with
// its state, and the rows that fix one. The controller; JIT, from the app's
// own helper (BuiltInJit.swift) with its pairing (on iOS 27 made on the
// phone, JitSetup; the import from Files is touch only); LocalDevVPN, which
// Playport turns on (LocalDevVPN.swift); and the memory iOS lets Playport use
// (MemoryLimit), with the JIT memory a Play gets from it; Steam, optional. Its
// first row opens the first-run checklist (SetupView.swift), which shows the
// pairing, LocalDevVPN, Increased Memory Limit and Steam (PlayportKit
// SetupChecklist) as four steps.
//
// The JIT method row picks where JIT comes from (JitMethodPicker, decision
// 0051). With StikDebug or another app, the built-in helper's rows give way
// to what that method needs; the pairing stays offered outside LiveContainer,
// since Playport restarts itself after a game with it (AppRestart).
//
// A dev build's built-in JIT rows are the full panel (the helper's raw readiness and
// reason, the disk image reset); a release build's show what a player acts
// on (decision 0009). A dev build's memory rows add the footprint and the
// phone's RAM; its simulations are in Developer.

import PlayportKit
import SwiftUI

struct SetupCheckSettings: View {
    @ObservedObject private var builtIn = BuiltInJitStatus.shared
    @ObservedObject private var setup = JitSetup.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var router = PadRouter.shared
    @ObservedObject private var state = SetupState.shared
    @EnvironmentObject private var model: SteamAccountModel
    @State private var reading = MemoryLimit.read()
    /// Read for its changes only; JitProvider.method is the choice.
    @AppStorage(JitMethod.key) private var storedMethod = ""
    private var method: JitMethod { _ = storedMethod; return JitProvider.method }

    private var tunnelUp: Bool? { state.tunnelUp }

    var body: some View {
        SettingsNote(text: "What a game needs from this phone. Playport checks it again by itself before every game.")
        PadRow(id: "set:setup:checklist", title: "Setup checklist",
               subtitle: "The steps a first run shows",
               value: "\(SetupChecklist.doneCount(state.facts)) of \(SetupStep.allCases.count) done", accessory: .chevron,
               hint: "Open") {
            AppNavigation.shared.openSetup()
        }
        #if !PLAYPORT_RELEASE
        // A dev build sees the checklist as a first run shows it, without deleting the
        // pairing or the Steam session: A completes each simulated step.
        PadRow(id: "set:setup:preview", title: "Preview a first run", subtitle: "Dev: A completes simulated steps; nothing changes on the phone",
               accessory: .chevron, hint: "Preview") { preview(onPhone: SetupState.pairsOnPhone) }
        PadRow(id: "set:setup:preview26", title: "Preview a first run on iOS 26", subtitle: "Dev: a pairing file from Files",
               accessory: .chevron, hint: "Preview") { preview(onPhone: false) }
        #endif
        SettingsInfoRow(id: "setup:controller", title: "Controller",
                        subtitle: router.controller.map { "\($0.name) connected" } ?? "None connected; touch works too",
                        value: router.controller == nil ? "Optional" : "Ready")
        jitRows
        PadRow(id: "set:setup:vpn", title: "LocalDevVPN", subtitle: "JIT reaches this phone through it",
               value: tunnelUp.map { $0 ? "Connected" : "Not connected" } ?? "Checking…", accessory: .chevron,
               hint: "Connect") {
            LocalDevVPN.connect { outcome in
                if outcome != .notInstalled, builtIn.pairingFile { builtIn.check() }
                state.readTunnel()
            }
        }
        steamRow
        memoryRows
            .task { await MemoryLimit.follow { reading = $0 } }
            .onAppear { state.follow() }
            .onDisappear { state.stopFollowing() }
    }

    #if !PLAYPORT_RELEASE
    private func preview(onPhone: Bool) {
        SetupState.log("preview a first run" + (onPhone ? "" : " on iOS 26"))
        state.previewFirstRun(onPhone: onPhone)
    }
    #endif

    /// Accounts, optional: A opens Settings › Accounts.
    private var steamRow: some View {
        let f = state.facts
        let stores = f.signedInStores
        return PadRow(id: "set:setup:steam", title: "Accounts", subtitle: stores.isEmpty ? "Optional: Steam, GOG or Epic Games, for your games" : nil,
                      value: stores.isEmpty ? "Signed out" : stores.joined(separator: ", "), accessory: .chevron, hint: "Open") {
            AppNavigation.shared.openSettings(section: .accounts)
        }
    }

    // MARK: JIT

    @ViewBuilder private var jitRows: some View {
        PadRow(id: "set:setup:jitMethod", title: "JIT method",
               subtitle: JitProvider.inLiveContainer ? "Playport runs inside LiveContainer" : nil,
               value: method.label, accessory: .chevron, hint: "Change") {
            guard !TitleLaunch.shared.running else { return }
            JitMethodPicker.show()
        }
        if method == .builtIn {
            builtInRows
        } else {
            SettingsInfoRow(id: "setup:jit", title: "JIT", subtitle: externalAdvice, value: method.label)
            if !JitProvider.inLiveContainer {
                pairingRow
                importRow
            }
        }
    }

    /// What JIT from another app needs; its own setup is that app's.
    private var externalAdvice: String {
        let lc = JitProvider.inLiveContainer
        switch method {
        case .stikDebug:
            return lc ? "Play opens StikDebug. Turn on Use LiveContainer's Bundle ID in LiveContainer's settings."
                : "Play opens StikDebug, which enables JIT with its universal.js script and comes back to Playport."
        default:
            return lc ? "Launch Playport with JIT from LiveContainer, with the universal.js script. Each game needs a fresh launch."
                : "Play waits for JIT from another app. Its script must be universal.js."
        }
    }

    #if PLAYPORT_RELEASE
    /// The built-in helper's rows. What it reports is worded for a
    /// player; its raw reason stays in the log.
    @ViewBuilder private var builtInRows: some View {
        SettingsInfoRow(id: "setup:jit", title: "JIT", subtitle: advice, value: statusText)
        pairingRow
        importRow
        if builtIn.pairingFile, !builtIn.busy, builtIn.status != "ready" {
            PadRow(id: "set:setup:check", title: "Check again", hint: "Check") { builtIn.check() }
        }
        if builtIn.pairingFile, !builtIn.busy, builtIn.status == "not ready" {
            PadRow(id: "set:setup:ddi", title: "Download the disk image again", hint: "Download") { builtIn.resetDDI() }
        }
    }

    private var statusText: String {
        if !builtIn.pairingFile {
            if #available(iOS 27.0, *) { return "Needs setup" }
            return "Needs a pairing file"
        }
        if builtIn.busy { return "Checking…" }
        switch builtIn.status {
        case "ready": return "Ready"
        case "unreachable": return "Can't connect"
        case "not ready": return "Not ready"
        default: return "Not checked yet"
        }
    }

    private var advice: String? {
        if builtIn.detail?.hasPrefix("import failed") ?? false { return "That file is not a pairing file." }
        guard builtIn.pairingFile, !builtIn.busy else { return "Games need it to run fast" }
        switch builtIn.status {
        case "unreachable": return "LocalDevVPN is not connected. Playport turns it on when you press Play."
        case "not ready": return "Playport could not prepare the phone. Check again."
        default: return "Games need it to run fast"
        }
    }
    #else
    /// The full panel: the helper's raw readiness and reason, the reset.
    @ViewBuilder private var builtInRows: some View {
        SettingsInfoRow(id: "setup:jit", title: "JIT", subtitle: builtIn.detail,
                        value: builtIn.busy ? "Checking…" : builtIn.readiness)
        SettingsInfoRow(id: "setup:pairingFile", title: "Pairing file", value: builtIn.pairingFile ? "Imported" : "Missing")
        pairingRow
        importRow
        PadRow(id: "set:setup:check", title: "Check readiness", hint: "Check") {
            if builtIn.pairingFile, !builtIn.busy { builtIn.check() }
        }
        PadRow(id: "set:setup:ddi", title: "Reset Developer Disk Image",
               subtitle: "It downloads and mounts by itself once per boot", hint: "Reset") {
            if builtIn.pairingFile, !builtIn.busy { builtIn.resetDDI() }
        }
    }
    #endif

    @ViewBuilder private var pairingRow: some View {
        if #available(iOS 27.0, *) {
            PadRow(id: "set:setup:pair", title: builtIn.pairingFile ? "Pair again" : "Pair this iPhone",
                   subtitle: method == .builtIn ? "Developer Mode and LocalDevVPN need your approval"
                       : "Lets Playport restart itself after a game", accessory: .chevron, hint: "Pair") {
                guard !builtIn.busy, !pairing.busy, !TitleLaunch.shared.spent else { return }
                setup.begin(repair: builtIn.pairingFile)
            }
        }
    }

    private var importRow: some View {
        PadRow(id: "set:setup:import", title: "Import pairing file", subtitle: "Advanced; choosing a file uses touch",
               accessory: .chevron, hint: "Choose file") {
            guard !builtIn.busy, !pairing.busy else { return }
            SettingsImport.requests.send()
        }
    }

    // MARK: memory

    @ViewBuilder private var memoryRows: some View {
        SettingsInfoRow(id: "setup:memory", title: "Memory limit", subtitle: "For a game and Playport's JIT memory together",
                        value: reading.effectiveMB.map { MemoryNeed.format(mb: $0) } ?? "Not reported")
        SettingsInfoRow(id: "setup:iml", title: "Increased Memory Limit",
                        subtitle: reading.entitled == false ? "This copy was signed without it" : nil,
                        value: reading.entitled.map { $0 ? "On" : "Off" } ?? "Unknown")
        SettingsInfoRow(id: "setup:pool", title: "JIT memory", value: MemoryNeed.format(mb: MemoryLimit.poolMB(reading)))
        #if !PLAYPORT_RELEASE
        if reading.simulatedMB != nil {
            SettingsInfoRow(id: "setup:realLimit", title: "Real limit",
                            value: reading.limitMB.map { MemoryNeed.format(mb: $0) } ?? "Not reported")
        }
        SettingsInfoRow(id: "setup:footprint", title: "In use now", value: MemoryNeed.format(mb: reading.footprintMB))
        SettingsInfoRow(id: "setup:phone", title: "Phone", value: MemoryNeed.format(mb: reading.physicalMB))
        #endif
        SettingsNote(text: reading.entitled == false ? MemoryNote.notEntitled + " " + MemoryNote.footer : MemoryNote.footer)
    }
}
