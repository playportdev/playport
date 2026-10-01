// SPDX-License-Identifier: GPL-3.0-or-later
// A title launch from the product UI: a Home Screen launch has no
// environment, so the library (UI/) starts a catalogued title through
// TitleLaunch, which runs the one launch path (LaunchCoordinator) with a JIT
// pool sized from the memory limit (JitProvider, the built-in helper) and shows its steps over
// the title's screen. When a game that used the runtime ends, Playport restarts
// itself to the library (AppRestart, decision 0029); a launch refused before
// that says why in an alert (LaunchMessage). Progress goes to the app log
// (AppLog) as `title:` lines.

import Foundation
import PlayportKit
import SwiftUI
import WineHost

/// The title launch as the UI sees it: whether the title's screen is up, the
/// launch's step, and why the last one did not end cleanly.
@MainActor
final class TitleLaunch: ObservableObject {
    static let shared = TitleLaunch()

    @Published private(set) var running = false
    /// The launch's step; nil for none.
    @Published private(set) var step: LaunchCoordinator.Step?
    /// The launch screen (UI/LaunchViews.swift) covers the title's screen until the game's first frame.
    @Published private(set) var showsSheet = false
    @Published private(set) var title = ""
    /// The catalogue's id and the Steam app of the title launching (the
    /// launch screen's art, a failed launch's Try again).
    @Published private(set) var titleID: String?
    @Published private(set) var appID: UInt32?
    /// The launch screen's stage (PlayportKit LaunchStage) and since when.
    @Published private(set) var stage: LaunchStage = .preparing
    @Published private(set) var stageSince = Date()
    /// The game's hero art for the launch screen, from the art cache; nil until loaded or without one.
    @Published private(set) var art: UIImage?
    /// Why a launch did not end cleanly, or why Playport could not restart
    /// itself: an alert over the page (RootView), or, for a step that failed
    /// (LaunchMessage.step), the launch screen's steps with the fix
    /// (LaunchFailureView); nil once dismissed.
    @Published var message: LaunchMessage? {
        didSet { if let m = message, m.step != nil, m != oldValue { PadModal.shared.launchFailure(m) } }
    }
    /// This app process can start no other title: its JIT pool was blessed
    /// (decision 0030), and the restart after the launch failed, so another
    /// title needs Playport closed and reopened.
    @Published private(set) var spent = false
    /// When Play started this launch (the in-game menu's "Playing · 42 min").
    private(set) var startedAt = Date()
    /// The in-game menu's Quit game was chosen: the game's end says nothing,
    /// and the restart follows even if it does not end (quit()).
    private(set) var quitting = false
    private var configured = false

    /// A title picked in the library (PlayportKit's LaunchPlan): its screen,
    /// then the launch on its own thread. False when a launch is running or spent.
    @discardableResult
    func start(title: String, titleID: String? = nil, exe: String, args: [String], config: [String: String] = [:],
               screen: String? = nil, frameLimit: Int = 0, graphics: GraphicsBackend = .default, steamAppID: UInt32? = nil,
               fex: FEXProfile.Launch? = nil, steamAPI: LaunchCoordinator.SteamAPI? = nil,
               memory: MemoryNeed? = nil) -> Bool {
        guard !running, !spent else { return false }
        self.title = title
        self.titleID = titleID
        appID = steamAppID
        startedAt = Date()
        quitting = false
        message = nil
        step = .preparing
        stage = .preparing
        stageSince = Date()
        art = steamAppID.flatMap(Self.cachedHero)
        if art == nil, let app = steamAppID, let steam = SteamAccountModel.current,
           let info = steam.games.first(where: { $0.id == app })?.info {
            Task { let img = await steam.image(info, .hero); if self.running, self.appID == app { self.art = img } }
        }
        showsSheet = true
        begin(screen: screen, frameLimit: frameLimit)
        TitleMode.log("in-app start \(exe) \(args.joined(separator: " "))")
        let request = LaunchCoordinator.Request(exe: exe, args: args, config: config,
                                                steamAppID: steamAppID, graphics: graphics, fex: fex, jitWait: 180, steamAPI: steamAPI,
                                                memory: memory)
        Thread.detachNewThread {
            let outcome = LaunchCoordinator.run(request) { step in
                DispatchQueue.main.async { MainActor.assumeIsolated { TitleLaunch.shared.advance(step) } }
            }
            TitleMode.finish(outcome.line)
            DispatchQueue.main.async { MainActor.assumeIsolated { TitleLaunch.shared.end(outcome) } }
        }
        return true
    }

    private func advance(_ step: LaunchCoordinator.Step) {
        // The first frame may beat the .running that follows wine_host_session_launch.
        guard running, self.step != .drawing else { return }
        self.step = step
        let next = Self.stage(of: step)
        if next != stage {
            stage = next
            stageSince = Date()
        }
        switch step {
        case .drawing:
            showsSheet = false
        case .running:
            // The sheet covers the black surface until the game's first frame (.drawing);
            // one that never comes through the game layer still uncovers the title.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { MainActor.assumeIsolated {
                if case .running = TitleLaunch.shared.step { TitleLaunch.shared.showsSheet = false }
            } }
        default:
            break
        }
    }

    /// The game's hero art as the art cache keeps it (`<app>/…library_hero.jpg`), with no
    /// network and no games list: a Play right after the app starts has neither yet.
    static func cachedHero(_ app: UInt32) -> UIImage? {
        let dir = SteamPaths.art.appendingPathComponent(String(app), isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = files.filter({ $0.hasSuffix("library_hero.jpg") }).sorted().last else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(name).path)
    }

    static func stage(of step: LaunchCoordinator.Step) -> LaunchStage {
        switch step {
        case .preparing: .preparing
        case .waitingForJit: .jit
        case .startingRuntime: .runtime
        case .startingGame, .running: .game
        case .drawing: .drawing
        }
    }

    /// The title's screen (the whole app is landscape, PlayportApp.swift's AppDelegate),
    /// set from the launch environment and this title's screen and frame rate
    /// limit (TitleScreen.configure) at every start, so a title that follows one
    /// that was refused gets its own; host I/O starts once.
    private func begin(screen: String? = nil, frameLimit: Int = 0) {
        running = true
        // Steam work stops before the runtime starts (decision 0004); the JIT
        // wait ahead of wine_host_init leaves it ample time to disconnect.
        if let steam = SteamAccountModel.current { Task { await steam.suspendForLaunch() } }
        TitleScreen.configure(title: screen, frameLimit: frameLimit)
        // The pads are the guest's from here, not the app screens' (UI/Pad/PadRouter.swift).
        PadRouter.shared.handOff()
        if !configured {
            configured = true
            HostIO.shared.start()
        } else {
            HostIO.shared.attachPads()
        }
    }

    /// Back to the app's screens. A launch that used the runtime (the JIT pool was
    /// blessed) leaves this process's Wine session, pool and threads behind:
    /// Playport restarts itself, and a launch that did not end cleanly says
    /// why once the new process shows the library. The session root has put
    /// the registry on disk before it reported the end (playport-session.c).
    /// A launch refused before that leaves the process as it was: its alert
    /// shows here.
    private func end(_ outcome: LaunchCoordinator.Outcome) {
        guard running else { return }   // quit() already ended it
        spent = WineHostRuntime.shared.poolAcquired
        step = nil
        showsSheet = false
        running = false
        InGameMenu.shared.gameEnded()
        var why = LaunchMessage.of(outcome, title: title, spent: spent)
        // The player quit: a game that exits with a code, or that the session root ended, is not a surprise.
        if quitting, outcome.kind != .refused { why = nil }
        if why?.step != nil { why?.titleID = titleID; why?.appID = appID }
        // The play time, on disk before the restart ends this process.
        LibraryModel.shared.sessionEnded(counted: spent)
        if spent {
            AppRestart.shared.restart(notice: why)
        } else {
            PadRouter.shared.takeBack()
            message = why
        }
    }
}

extension TitleLaunch {
    /// Whether the in-game menu may open now: the game has started and the
    /// launch screen is gone.
    var acceptsMenu: Bool {
        guard running, !showsSheet, !quitting else { return false }
        switch step {
        case .running, .drawing: return true
        default: return false
        }
    }

    /// The in-game menu's Quit game (docs/ARCHITECTURE.md, "The in-game menu"):
    /// the session root posts WM_CLOSE to the game's windows, so it saves and
    /// exits as it would when its window is closed on Windows, and ends the
    /// game's processes if they are still running `closeWait` seconds later;
    /// the game's end then restarts Playport (decision 0029). One that has
    /// still not ended `giveUp` seconds after the request (the root itself
    /// stuck) restarts Playport anyway: the new process has no game in it.
    static let closeWait: UInt32 = 10
    static let giveUp: TimeInterval = 25

    func quit() {
        guard running, !quitting else { return }
        quitting = true
        TitleMode.log("quit: the in-game menu's Quit game; WM_CLOSE, ended after \(Self.closeWait) s if still running")
        HostIO.sessionControl(Int(PP_CONTROL_CLOSE), "close", wait: Self.closeWait * 1000) { rc, _ in
            if rc != 0 { TitleMode.log("quit: the session root did not take the close (\(rc)); Playport restarts to end the game") }
            DispatchQueue.main.asyncAfter(deadline: .now() + (rc == 0 ? Self.giveUp : 0)) {
                MainActor.assumeIsolated { TitleLaunch.shared.forceEnd() }
            }
        }
    }

    /// Quit game's last resort: the game is still running, so this process ends with it.
    private func forceEnd() {
        guard running, quitting else { return }
        let s = Int(Date().timeIntervalSince(startedAt))
        TitleMode.log("quit: the game is still running; Playport restarts to end it")
        TitleMode.finish("launch=quit still-running after_s=\(s)")
        end(LaunchCoordinator.Outcome(kind: .failed, line: "launch=quit still-running after_s=\(s)"))
    }
}

enum TitleMode {
    #if !PLAYPORT_RELEASE
    /// A driven launch's nonce (Dev/UIDriver.swift), echoed in the `title: done` line.
    static let nonce = ProcessInfo.processInfo.environment["TITLE_NONCE"] ?? "-"
    #endif

    static func log(_ line: String) { WineHostRuntime.appendLog("title: " + line) }

    /// The `title: done` line, which a dev build also reports to the driver (RunEvents).
    static func finish(_ outcome: String) {
        #if PLAYPORT_RELEASE
        WineHostRuntime.appendLog("title: done " + outcome)
        #else
        WineHostRuntime.appendLog("title: done nonce=\(nonce) \(outcome)")
        RunEvents.emit("title-done", ["outcome": outcome])
        #endif
    }
}
