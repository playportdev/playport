// SPDX-License-Identifier: GPL-3.0-or-later
// First run (docs/design/2026-09-28-gamepad-ui/Setup.dc.html): "Let's get
// you playing", four steps side by side (PlayportKit SetupChecklist): the
// controller; the pairing JIT uses (on iOS 27 made on this iPhone, JitSetup
// and decision 0033; on iOS 26 a file chosen from Files, by touch); LocalDevVPN's
// tunnel, which A turns on (LocalDevVPN.swift); and Steam, optional, whose A
// opens Sign in to Steam (SignInView.swift). A done step has a green tick.
//
// It replaces the shell's pages (AppNavigation.setup): by itself on a first
// run (no pairing, and the checklist never left), and from Settings › Setup
// check's first row afterwards. The ring moves along the steps with left and
// right or LB and RB (the design's "RB Next"); A does the ringed step; Y (iOS
// 26) says how a pairing file is made; B leaves, back to Settings when it
// came from there.
//
// The same facts are checked before every launch (`SetupState.beforePlay`,
// called by LibraryModel.play): a missing pairing on iOS 27 or LocalDevVPN
// down Playport fixes itself (JitSetup, which then goes on with the Play); a
// missing pairing file on iOS 26 opens this checklist on that step with the
// fix and the Play does not start. No controller and a signed-out Steam never
// stop a launch; the launch screen names them (`launchNotes`).

import HostIOKit
import PlayportKit
import SteamClientKit
import SwiftUI

@MainActor
final class SetupState: ObservableObject {
    static let shared = SetupState()

    /// Set once the player has left the checklist: it no longer opens by itself.
    static let leftKey = "setup.left"

    /// LocalDevVPN's tunnel; nil before the first read.
    @Published private(set) var tunnelUp: Bool?
    /// Why the checklist is up, when a Play sent the player here (the fix).
    @Published var message: String?
    /// What a launch's screen names: no controller, Steam signed out (SetupChecklist.notes).
    @Published private(set) var launchNotes: [String] = []
    /// A dev build's preview of a first run (Setup check's dev rows): the checklist shows
    /// these facts and its steps do nothing. Launches never read it; leaving the checklist ends it.
    @Published var preview: SetupFacts?
    private var clock: Timer?

    static var pairsOnPhone: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    static func log(_ line: String) { WineHostRuntime.appendLog("setup: " + line) }

    var facts: SetupFacts {
        // Paired (signed in, offline, restoring a stored session); unknown before the first read.
        let signedIn: Bool?
        switch SteamAccountModel.current?.state {
        case nil, .unknown?: signedIn = nil
        case .restoring(let account)?: signedIn = account == nil ? nil : true
        case .signedIn?, .offline?: signedIn = true
        case .signedOut?, .pairing?, .expired?: signedIn = false
        }
        return SetupFacts(controller: PadRouter.shared.controller?.name, pairing: BuiltInJitStatus.shared.pairingFile,
                          pairsOnPhone: Self.pairsOnPhone, tunnelUp: tunnelUp, steamSignedIn: signedIn)
    }

    /// What the checklist shows: the facts, or a dev build's preview.
    var shown: SetupFacts { preview ?? facts }

    func readTunnel() {
        Task.detached {
            let up = LocalDevVPN.tunnelUp
            await MainActor.run { if SetupState.shared.tunnelUp != up { SetupState.shared.tunnelUp = up } }
        }
    }

    /// While the checklist or Setup check shows: the tunnel read every 2 s.
    func follow() {
        readTunnel()
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SetupState.shared.readTunnel() }
        }
    }

    func stopFollowing() {
        clock?.invalidate()
        clock = nil
    }

    /// When the shell first appears: the checklist on a first run.
    func showAtStartIfFirstRun() {
        let left = UserDefaults.standard.bool(forKey: Self.leftKey)
        guard SetupChecklist.showsAtStart(left: left, pairing: BuiltInJitStatus.shared.pairingFile) else { return }
        Self.log("first run: the checklist")
        AppNavigation.shared.openSetup()
    }

    /// The check a Play runs before JIT. False when the player has to act
    /// first: the checklist opens on the step, with the fix. A step Playport
    /// fixes itself (pairing on iOS 27, LocalDevVPN) goes on to JitSetup.
    func beforePlay(steamGame: Bool) -> Bool {
        var f = facts
        let up = LocalDevVPN.tunnelUp
        tunnelUp = up
        f.tunnelUp = up
        let check = SetupChecklist.beforeLaunch(f)
        launchNotes = SetupChecklist.notes(f, steamGame: steamGame)
        switch check {
        case .go:
            Self.log("before play: " + SetupChecklist.summary(f) + ": ready")
        case .fixesItself(let step):
            Self.log("before play: " + SetupChecklist.summary(f) + ": Playport sets up \(step.rawValue) first")
        case .needs(let step, let fix):
            Self.log("before play: " + SetupChecklist.summary(f) + ": needs \(step.rawValue); the checklist")
            message = fix
            AppNavigation.shared.openSetup(on: step)
            return false
        }
        return true
    }
}

extension SetupStep {
    var item: String { "setup:step:" + rawValue }

    var number: Int { (SetupStep.allCases.firstIndex(of: self) ?? 0) + 1 }
}

struct SetupView: View {
    @ObservedObject private var state = SetupState.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var builtIn = BuiltInJitStatus.shared
    @ObservedObject private var router = PadRouter.shared
    @EnvironmentObject private var model: SteamAccountModel

    var body: some View {
        let f = state.shown
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let's get you playing").font(PP.display(30))
                Text("Four steps, once. Playport checks them again by itself before every game.")
                    .font(.system(size: 13)).foregroundStyle(PP.muted)
                if let m = state.message {
                    Text(m).font(.system(size: 13, weight: .semibold)).foregroundStyle(PP.accent)
                        .accessibilityIdentifier("setup-message")
                }
            }
            .padding(.top, 24).padding(.bottom, 16)
            HStack(alignment: .top, spacing: 12) {
                ForEach(SetupChecklist.items(f), id: \.step) { item in
                    card(item)
                }
            }
            // The cards as tall as the tallest, 190 pt at least (Setup.dc.html: 176, with room for the button).
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(PP.text)
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { state.follow() }
        .onDisappear {
            state.stopFollowing()
            state.message = nil
            state.preview = nil
        }
        // `pad:` log lines name the steps' states (a dev build's driver reads them).
        .onChange(of: SetupChecklist.summary(f)) { _, s in SetupState.log("checklist: " + s) }
    }

    private func card(_ item: SetupItem) -> some View {
        let ringed = focus.focused == item.step.item
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if item.done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(PP.background).frame(width: 26, height: 26)
                        .background(Color(hex: 0x7FD49A), in: Circle())
                } else {
                    Text("\(item.step.number)").font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 26).background(PP.line, in: Circle())
                }
            }
            Text(item.title).font(PP.display(18))
            Text(item.detail).font(.system(size: 12)).foregroundStyle(PP.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if ringed, let action = item.action {
                HStack(spacing: 6) {
                    PadGlyph(button: .a, inverted: true)
                    Text(action).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(PP.onAccent)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PP.accent, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity, alignment: .topLeading)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
        .padItem(item.step.item, hint: item.action == nil ? "" : "Do this step", cornerRadius: 14) { run(item) }
    }

    private func run(_ item: SetupItem) {
        guard item.action != nil else { return }
        guard SetupState.shared.preview == nil else { return SetupState.log("preview: \(item.step.rawValue) does nothing") }
        SetupState.log("do \(item.step.rawValue)")
        switch item.step {
        case .controller:
            break
        case .pairing:
            guard !builtIn.busy, !OnDevicePairing.shared.busy, !TitleLaunch.shared.spent else { return }
            if SetupState.pairsOnPhone {
                JitSetup.shared.begin(repair: builtIn.pairingFile)
            } else {
                SettingsImport.requests.send()
            }
        case .vpn:
            LocalDevVPN.connect { outcome in
                SetupState.log("LocalDevVPN: \(outcome)")
                if outcome != .notInstalled, BuiltInJitStatus.shared.pairingFile { BuiltInJitStatus.shared.check() }
                SetupState.shared.readTunnel()
            }
        case .steam:
            SignInState.shared.open(preview: false)
        }
    }

    /// The footer (Setup.dc.html): A the ringed step, RB the next, Y how a pairing
    /// file is made (iOS 26), B out.
    static func hints() -> [PadHint] {
        var h: [PadHint] = []
        let focus = PadFocus.shared
        if let a = focus.hint, !a.isEmpty { h.append(PadHint(button: .a, label: a) { focus.activate() }) }
        h.append(PadHint(button: .rb, label: "Next") { _ = SetupRing.press(.rb) })
        if !SetupState.shared.shown.pairsOnPhone { h.append(PadHint(button: .y, label: "How to make the file") { SetupRing.howTo() }) }
        let ready = SetupChecklist.beforeLaunch(SetupState.shared.shown) == .go
        h.append(PadHint(button: .b, label: ready ? "Done" : "Later") { _ = AppNavigation.shared.back() })
        return h
    }

    /// The footer's grey note at the left.
    static var footerNote: String {
        SetupState.shared.shown.pairsOnPhone ? "Pairing asks for your approval in iOS Settings" : "Choosing a file uses touch"
    }
}

/// Presses on the checklist (AppShell sends them here).
@MainActor
enum SetupRing {
    static func press(_ b: NavButton) -> Bool {
        let focus = PadFocus.shared
        switch b {
        case .left, .lb: step(-1)
        case .right, .rb: step(1)
        case .up, .down: break
        case .a: focus.activate()
        case .y: if !SetupState.shared.shown.pairsOnPhone { howTo() }
        case .b, .menu: _ = AppNavigation.shared.back()
        case .x, .view: break
        }
        return true
    }

    private static func step(_ by: Int) {
        let all = SetupStep.allCases
        let at = all.firstIndex { $0.item == PadFocus.shared.focused } ?? 0
        let next = min(max(at + by, 0), all.count - 1)
        PadFocus.shared.ring(all[next].item)
    }

    /// Y: how a pairing file is made, for a phone that cannot pair with itself.
    static func howTo() {
        PadModal.shared.picker(
            title: "Making a pairing file",
            note: "A pairing file comes from a computer the iPhone trusts: connect it by cable, "
                + "tap Trust on the iPhone, and make an RP pairing file with a pairing tool there. "
                + "Send the file to the iPhone (AirDrop or Files), then choose it here. "
                + "Keep it private: it lets that computer debug this iPhone.",
            options: [PadOption(id: "ok", label: "OK")], selected: "ok") { _ in }
    }
}
