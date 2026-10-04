// SPDX-License-Identifier: GPL-3.0-or-later
// The launch screen over a title's screen until its first frame
// (Launch.dc.html: the game's art, one progress bar, the step in a word, the
// tip for the in-game menu; the steps listed only when JIT is slow), the
// screen of a launch that failed at a step (LaunchFailureView: the steps,
// what happened and the fix), what a launch that did not end cleanly says
// (LaunchMessage), and the screen shown while Playport restarts itself after
// a game (decision 0029). A clean exit says nothing: Playport restarts to
// Home. A launch refused before the runtime started (a memory limit below
// the game's need, a failed start-up self-check, a missing executable or
// Direct3D backend) says why in an alert over the page it was started from;
// one that failed at a step (JIT, the runtime, the game's start) shows the
// failure screen there or, when it had spent the runtime, once the
// restarted Playport shows Home (AppRestart); a crash or the JIT pool running
// out says why in an alert then.

import HostIOKit
import PlayportKit
import SteamClientKit
import SwiftUI

/// The launch screen over the title's black surface until its first frame
/// (Launch.dc.html): over the game's art as its page shows it (LaunchBackdrop,
/// drawn under this by RootView), its name, one progress bar and
/// the step in a word, what the checks before the Play found that does not stop
/// it (no controller, Steam signed out), and the tip for the in-game menu. The steps (JIT,
/// runtime, game) are listed only when JIT is slow (LaunchProgress.jitSlow),
/// with the fix: LocalDevVPN when its tunnel is down. The pads are the
/// guest's from Play on (TitleLaunch.begin), so this screen takes no presses.
/// A step that fails shows on LaunchFailureView once the launch has ended.
struct LaunchScreen: View {
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var setup = SetupState.shared
    @ObservedObject private var router = PadRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shown from Play: its parts come in one after another (UI/LaunchTransition.swift).
    @State private var shown = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(launch.stageSince)
            let slow = LaunchProgress.showsSteps(launch.stage, elapsed: elapsed)
            ZStack {
                VStack(spacing: 18) {
                    LaunchTitle(name: launch.title)
                        .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                        .blur(radius: shown || reduceMotion ? 0 : 4)
                        .opacity(shown ? 1 : 0)
                        .animation(LaunchMotion.partIn(0.5, delay: 0.15), value: shown)
                    LaunchBar(fraction: LaunchProgress.fraction(launch.stage, elapsed: elapsed))
                        .opacity(shown ? 1 : 0)
                        .animation(LaunchMotion.partIn(0.45, delay: 0.25), value: shown)
                    HStack(spacing: 10) {
                        ForEach(LaunchProgress.steps, id: \.self) { s in
                            Circle().fill(launch.stage > s ? PP.accent : PP.line).frame(width: 8, height: 8)
                        }
                        Text(LaunchProgress.status(launch.stage)).font(.system(size: 14)).foregroundStyle(PP.soft)
                            .accessibilityIdentifier("launch-status")
                    }
                    .opacity(shown ? 1 : 0)
                    .animation(LaunchMotion.partIn(0.45, delay: 0.3), value: shown)
                    if slow, case .waitingForJit(let until) = launch.step {
                        LaunchSteps(current: .jit, failed: nil) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Gives up in \(max(0, Int(until.timeIntervalSince(ctx.date)))) s").monospacedDigit()
                                Text(LaunchFix.slowJit(tunnelUp: LocalDevVPN.tunnelUp))
                            }
                        }
                        .frame(width: 420)
                    }
                }
                .padding(.top, slow ? 0 : 20)
                .frame(maxHeight: .infinity, alignment: slow ? .center : .top)
                .padding(.top, slow ? 0 : 98)
                VStack(spacing: 8) {
                    Spacer()
                    // What the checks before the Play found that does not stop it (SetupChecklist.notes).
                    ForEach(notes, id: \.self) { n in
                        Text(n).font(.system(size: 13, weight: .semibold)).foregroundStyle(PP.accent)
                    }
                    LaunchTip().padding(.bottom, 26)
                }
                .opacity(shown ? 1 : 0)
                .animation(LaunchMotion.partIn(0.45, delay: 0.35), value: shown)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("launch-screen")
        .onAppear { shown = true }
    }
}

extension LaunchScreen {
    /// No controller (until one connects) and Steam signed out.
    private var notes: [String] {
        setup.launchNotes.filter { router.controller == nil || $0 != SetupChecklist.noController }
    }
}

/// What the player can do about a slow or failed step.
enum LaunchFix {
    static func slowJit(tunnelUp: Bool) -> String {
        tunnelUp ? JitNote.waiting
                 : "LocalDevVPN is not connected. Open LocalDevVPN and connect it: the launch goes on once JIT arrives."
    }

    static func failed(_ step: LaunchStage, tunnelUp: Bool) -> String {
        switch step {
        case .jit, .preparing:
            tunnelUp ? "JIT did not arrive. Keep Playport in front while the game starts, then try again."
                     : "LocalDevVPN is not connected. Turn it on (Y), then try again."
        case .runtime: "Try again. If it fails again, restart the iPhone."
        case .game, .drawing: "Try again. If it fails again, check the game's files in its options."
        }
    }
}

/// A game's hero art as its page and its launch screen show it: filling the whole screen,
/// centred, dimmed as the launch screen always had it (28 % over the design's dark blue,
/// darker towards the bottom). Both draw it through this, so from the page to the game it
/// does not change.
struct GameHeroArt<Art: View>: View {
    @ViewBuilder let art: Art

    var body: some View {
        ZStack {
            Color(hex: 0x131C2B)
            art
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(0.28)
            LinearGradient(colors: [.clear, Color(hex: 0x05070A).opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The art a game's page hands the shell to draw behind it (AppShell, GameDetailView).
struct PageArt: Equatable {
    let appID: UInt32?
    let name: String
    /// The store's app, when the page has it; else GameArt looks the game up.
    let info: SteamAppInfo?

    @ViewBuilder var view: some View {
        if let info {
            SteamArtView(app: info, kind: .hero, placeholder: PP.tile(for: name))
        } else {
            GameArt(appID: appID, name: name, kind: .hero)
        }
    }
}

struct PageArtKey: PreferenceKey {
    static let defaultValue: PageArt? = nil
    static func reduce(value: inout PageArt?, nextValue: () -> PageArt?) { value = value ?? nextValue() }
}

/// Behind the launch screen: the game's page as it was without its text and controls, its
/// hero art filling the screen, unchanged for the whole launch (on Play only the page's
/// text and controls leave and the launch screen's come; RootView).
struct LaunchBackdrop: View {
    let art: UIImage?
    let title: String

    var body: some View {
        ZStack {
            PP.background
            GameHeroArt { picture }
        }
        .ignoresSafeArea()
    }

    /// As SteamArtView draws it on the page: the tile colour under the art.
    private var picture: some View {
        ZStack {
            Rectangle().fill(PP.tile(for: title))
            if let art { Image(uiImage: art).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
    }
}

/// Over the game surface (which ignores the safe area) the name keeps clear
/// of the Dynamic Island on whichever side it is (WindowInsets). Long names
/// wrap to two centred lines before shrinking, rather than running off-screen.
struct LaunchTitle: View {
    let name: String
    @ObservedObject private var safe = WindowInsets.shared

    var body: some View {
        let side = max(safe.side(44, safe.insets.leading), safe.side(44, safe.insets.trailing))
        Text(name.uppercased()).font(PP.display(56)).tracking(1.1)
            .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, side)
    }
}

struct LaunchBar: View {
    let fraction: Double
    var color: Color = PP.accent

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(PP.line)
            Capsule().fill(color).frame(width: 320 * min(1, max(0, fraction)))
                .animation(.linear(duration: 0.2), value: fraction)
        }
        .frame(width: 320, height: 4)
    }
}

/// "Tip: hold ⌂ on your controller for the Playport menu".
struct LaunchTip: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Tip: hold")
            Text("⌂").font(.system(size: 11, weight: .bold)).foregroundStyle(PP.background)
                .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20).background(PP.text, in: Capsule())
            Text("on your controller for the Playport menu")
        }
        .font(.system(size: 13))
        .foregroundStyle(PP.muted)
    }
}

/// JIT, runtime and game, each done, running, failed or still to come; the
/// running or failed one carries `detail`.
struct LaunchSteps<Detail: View>: View {
    let current: LaunchStage
    let failed: LaunchStage?
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(LaunchProgress.steps, id: \.self) { s in
                let at = failed ?? current
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if s < at {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(PP.ok)
                        } else if s == at, failed != nil {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xFF7A6B))
                        } else if s == at {
                            Image(systemName: "circle").hidden().overlay { ProgressView().tint(PP.text).scaleEffect(0.7) }
                        } else {
                            Image(systemName: "circle").foregroundStyle(PP.line)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LaunchProgress.stepName(s)).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(s > at ? PP.muted : PP.text)
                        if s == at { detail().font(.system(size: 12)).foregroundStyle(PP.soft).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(PP.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PP.line))
    }
}

/// A launch that stopped at a step (LaunchMessage.step), over the page it
/// was started from or, after the restart that follows a spent launch, over
/// the new process's Home: the steps with the failed one marked, what
/// happened, and the fix. A Try again, Y Turn on LocalDevVPN (a JIT step with
/// its tunnel down), B Back.
@MainActor
final class LaunchFailureSession: ObservableObject {
    let message: LaunchMessage
    @Published private(set) var tunnelUp = LocalDevVPN.tunnelUp

    init(_ message: LaunchMessage) { self.message = message }

    var offersVPN: Bool { (message.step == .jit || message.step == .preparing) && !tunnelUp }

    func press(_ b: NavButton) {
        switch b {
        case .a: retry()
        case .y where offersVPN: turnOnVPN()
        case .b: close()
        default: break
        }
    }

    func close() {
        PadModal.shared.close()
        if TitleLaunch.shared.message == message { TitleLaunch.shared.message = nil }
    }

    func retry() {
        guard let id = message.titleID else { return close() }
        close()
        Task {
            if (try? await LibraryModel.shared.play(id)) != true, !TitleLaunch.shared.running, !PadModal.shared.isUp {
                AppNavigation.shared.openTitle(id)
            }
        }
    }

    func turnOnVPN() {
        LocalDevVPN.connect { _ in
            LaunchFailureSession.refresh()
        }
    }

    static func refresh() {
        if case .launchFailure(let s) = PadModal.shared.content { s.tunnelUp = LocalDevVPN.tunnelUp }
    }
}

struct LaunchFailureView: View {
    @ObservedObject var session: LaunchFailureSession

    var body: some View {
        let m = session.message
        ZStack {
            VStack(spacing: 14) {
                Text(m.title).font(PP.display(30)).multilineTextAlignment(.center).lineLimit(2)
                LaunchSteps(current: m.step ?? .jit, failed: m.step ?? .jit) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.text)
                        Text(LaunchFix.failed(m.step ?? .jit, tunnelUp: session.tunnelUp)).foregroundStyle(PP.accent)
                    }
                }
                .frame(width: 460)
            }
            .padding(.bottom, 20)
            VStack {
                Spacer()
                HStack(spacing: 18) {
                    Spacer()
                    if m.titleID != nil { PadModalHint(button: .a, label: "Try again") { session.press(.a) } }
                    if session.offersVPN { PadModalHint(button: .y, label: "Turn on LocalDevVPN") { session.press(.y) } }
                    PadModalHint(button: .b, label: "Back") { session.press(.b) }
                }
                .padding(.horizontal, 36)
                .frame(height: 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The dimmed game art is a background, not a ZStack child: as a child
            // its ignoresSafeArea inflated the stack to the full window and pushed
            // the footer's right-aligned buttons into the side safe-area insets.
            Group {
                if let app = m.appID { GameArt(appID: app, name: m.title, kind: .hero).opacity(0.28) } else { Color.clear }
            }
            .background(Color(hex: 0x131C2B))
            .overlay(LinearGradient(colors: [.clear, Color(hex: 0x05070A).opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .clipped()
            .ignoresSafeArea()
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("launch-failure")
    }
}

/// Why a launch did not end cleanly, as an alert says it; nil for a clean exit.
struct LaunchMessage: Codable, Equatable, Identifiable {
    var title: String
    var text: String
    /// The step that failed (LaunchProgress.failedStage): the launch screen
    /// shows the steps and the fix instead of an alert. Nil for the rest.
    var step: LaunchStage?
    /// The title, for the failure screen's art and its Try again.
    var titleID: String?
    var appID: UInt32?
    var id: String { title + "\n" + text }

    init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    static func of(_ outcome: LaunchCoordinator.Outcome, title: String, spent: Bool) -> LaunchMessage? {
        guard var m = message(outcome, title: title, spent: spent) else { return nil }
        if outcome.kind == .failed { m.step = LaunchProgress.failedStage(outcome.line) }
        return m
    }

    private static func message(_ outcome: LaunchCoordinator.Outcome, title: String, spent: Bool) -> LaunchMessage? {
        let line = outcome.line
        switch outcome.kind {
        case .exited(0):
            return nil
        case .exited(let code):
            #if PLAYPORT_RELEASE
            return .init(title: "\(title) stopped unexpectedly", text: "The game ended with an error.")
            #else
            return .init(title: "\(title) stopped unexpectedly", text: "It exited with code \(String(format: "0x%08X", code)).")
            #endif
        case .refused where MemoryNeed.parseRefusal(line) != nil:
            let m = MemoryNeed.parseRefusal(line)!
            return .init(title: "Not enough memory for \(title)", text: MemoryNote.refused(limitMB: m.limitMB, needMB: m.needMB))
        case .refused where SelfCheck.failure(in: line) != nil, .failed where SelfCheck.failure(in: line) != nil:
            return .init(title: "\(title) could not start", text: SelfCheck.explanation(SelfCheck.failure(in: line)!))
        case .refused where sessionFull(line):
            return .init(title: "Playport needs to restart",
                         text: "Playport could not restart itself after the last game. Close it and reopen it from the Home Screen to play \(title).")
        case .refused where line.contains(" graphics="):
            return .init(title: "\(title) could not start",
                         text: "This build of Playport does not include the Direct3D backend the game is set to. "
                            + "Pick another under Graphics on its page or in Settings.")
        case .refused:
            return .init(title: "\(title) could not be found",
                         text: "Its executable is not where the library expects it. Pull down on the library to look again.")
        case .outOfJitMemory(let part):
            return .init(title: "\(title) ran out of JIT memory",
                         text: JitNote.outOfMemory(part, poolMB: outcome.poolMB))
        case .failed:
            return .init(title: "\(title) could not start", text: failedText(line, spent: spent))
        }
    }

    private static func failedText(_ line: String, spent: Bool) -> String {
        // WineHostRuntime.start's detail: `JIT pool (<n> MiB): <JitProvider failure>`.
        if let r = line.range(of: "JIT pool ("), let colon = line[r.upperBound...].range(of: "): ") {
            let why = line[colon.upperBound...]
            #if PLAYPORT_RELEASE
            // The helper's raw reason is in the log; the player gets what to do.
            if why.contains("no pairing file") { return "Import a pairing file in Settings, then try again." }
            return "JIT could not be set up. Check that LocalDevVPN is connected, then try again."
            #else
            return why.hasPrefix("wine_host_jit_pool_acquire")
                ? "JIT did not arrive in time (\(why)). Check that LocalDevVPN is connected, then try again."
                : "JIT could not be requested: \(why)."
            #endif
        }
        return spent ? "JIT was enabled, but the runtime or the game failed to start."
                     : "The runtime or the game failed to start."
    }

    /// A Play in a process that already played its title (LaunchCoordinator:
    /// `launch=refused session=spent`): only after a restart that failed.
    private static func sessionFull(_ line: String) -> Bool {
        line.contains("launch=refused session=spent")
    }
}
