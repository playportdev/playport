// SPDX-License-Identifier: GPL-3.0-or-later
// S1_MODE=ui (`pp ui`, tools/ui.py), dev builds only: the
// product UI, driven, and the one way the workstation drives the app
// (decision 0012). The app shows the same screens as a Home Screen launch and
// performs UI_ACTIONS through the same model calls the buttons make, once the
// first library scan has finished and the opening animation (UI/AppOpening.swift) is over:
//
//   verify:<title id>          Verify files; the next action waits for its result
//   play:<title id>            Play; the launch ends with its `title-done` event. Playport
//                              then restarts itself (AppRestart), and the actions after it
//                              run in the new process, under this run (DriverContinuation);
//                              a Play refused before the runtime started (its alert shows)
//                              goes on here
//   install:<app id>           Install from Steam (the paired account's session);
//                              waits until the title is in the library
//   install:gog-<id>[@<build>] Install from GOG (signed in on the phone), the newest build or
//                              <build>; an installed game's install is its update
//   pause-resume:<app id>      Install, Pause once a quarter is staged, check the
//                              stage is kept, then Resume and wait as install does
//   queue:<app id>             Install from Steam, as a game page's Install does, and go on
//                              at once: the download runs in the queue (SteamInstalls)
//   downloading:<app id>       Waits (2 min at most) until the queue runs that app's download
//                              with progress, as after the restart after a game, and logs
//                              the queue
//   uninstall:<title id>       Uninstall; waits until its folder and record are gone
//   import:<path>              Hands Documents/<path> (a folder or a .zip the workstation
//                              put in the container) to Add a game, as the Files picker
//                              returns what the player picked (the picker itself is touch,
//                              iOS's, and cannot be driven); waits until the import is in
//                              the library (owner, 2026-10-06)
//   settings:<title id>        Saves UI_SETTINGS (a PlayportKit LaunchSettings as JSON;
//                              `{}` clears them) as the game's own launch settings,
//                              as its page does
//   hud:on | hud:off           Sets Settings' Metal HUD, as its toggle does
//   open:<screen | title id>   Shows a screen (home, library, games, downloads, settings,
//                              account, setup: the first-run checklist, signin: Sign in to
//                              Steam, a preview while Steam is signed in; AppNavigation.screens)
//                              or a title's page over the
//                              Library, then waits 1.5 s so a
//                              screenshot sees it drawn; `open:<title id>#<section>`
//                              opens the page's Game options at a section (graphics, game,
//                              files, developer, ordering, steam);
//                              `open:settings#<section>` shows a Settings section (accounts,
//                              graphics, downloads, controllers, storage, setup, about,
//                              developer; PlayportKit SettingsSection.named also takes
//                              account, steam, jit, memory, diagnostics, pairing, probes, logs);
//                              `open:licences` shows Settings › About › Licences,
//                              `open:licences#<prefix>` the files of the first component
//                              whose name starts with it, ignoring case (`open:licences#wine`;
//                              UI/LicencesView.swift)
//                              `open:black` shows Settings › Developer › Black screen
//                              (BlackScreen.swift), as its row does
//   probe:helper-exit | probe:helper-kill [-hold]
//                              Settings' helper-lifetime probe (HelperLifetimeProbe.swift):
//                              the run ends with ui-done, and the app ends itself 2 s later;
//                              -hold turns on its Helper holds on
//   probe:helper-report        Reads that probe's report back (at the next launch)
//   probe:pairing              Settings' on-device pairing experiment (iOS 27)
//   probe:pairing-cancel | probe:pairing-use
//                              Cancel, or use the completed pairing and check readiness
//   probe:relaunch             Settings' Restart Playport now (AppRestart), with no game: the
//                              run ends with ui-done, then the app asks CoreDevice to replace
//                              it. Last action
//   pad:<button>[+<button>...] Presses controller buttons (a b x y lb rb menu view up down left
//                              right), 250 ms apart, into the router a controller feeds
//                              (UI/Pad/PadRouter.swift), then waits 1 s for a screenshot;
//                              while the controller keyboard or a picker is up they are
//                              its presses (UI/Pad/PadModal.swift). A press that starts a
//                              Play (a game page's Play button) holds the run on the game,
//                              as play: does; actions after it do not run once Playport
//                              restarts after the game
//   wait:<seconds>             Waits that long (at most 600): after a play:, the game runs on
//   menu:open                  After a play: (the actions after it then run while the game runs):
//                              waits for the game's first frame (3 min at most), then holds the
//                              controller's Home button 0.8 s through HostIO's pad handling
//                              (HostIO.menuInput), which opens the in-game menu
//                              (UI/InGameMenuView.swift), and waits 1 s
//   menu:<row>                 In the menu: moves its ring to the row (resume, screenshot,
//                              overlay, controller, quit) and presses A, as a controller does;
//                              pad: presses go to the menu too while it is up. menu:quit waits
//                              for the game's end: Playport restarts, and the actions after it
//                              run in the new process, as after play:
//   set:<key>=<value>          Sets a UserDefaults key, as a Settings control does:
//                              true/false a Bool, an integer an Int, else a String
//                              (`set:metalHUD=true`)
//
// Each action ends with a `ui-action` event and the run with `ui-done` in
// run-events.jsonl (RunEvents.swift), which the driver reads.
//
// What settings:, hud: and set: change lasts for the driver's session
// (UI_SESSION) and is undone at the first launch outside it (DriverUndo.swift),
// unless UI_KEEP_SETTINGS=1.
//
// A title id is the catalogue's (`app-367520`), an app id Steam's (`367520`).
// Downloads log to steam-drive.log as `[ui] install` lines. Progress goes to s1-host.log
// as `ui:` lines, ending with `ui: done nonce=<TITLE_NONCE> ...` once every
// action has run (a play's own end is its `title: done` line). JIT comes from
// the built-in helper (JitProvider), as for any Play.

import Foundation
import HostIOKit
import GOGClientKit
import PlayportKit
import SteamClientKit
import SwiftUI

@MainActor
enum UIDriver {
    private static let env = ProcessInfo.processInfo.environment
    static let requested = env["S1_MODE"] == "ui"
    private static var started = false
    /// The actions after the one running: what a restart after a play hands on.
    private static var remaining: [String] = []

    private static func log(_ line: String) { WineHostRuntime.appendLog("ui: " + line) }

    /// Called when the product UI appears; runs the actions once.
    static func startIfRequested() {
        guard requested, !started else { return }
        started = true
        let actions = (env["UI_ACTIONS"] ?? "").split(separator: ",").map(String.init)
        log("S1_MODE=ui nonce=\(TitleMode.nonce) UI_ACTIONS=\(env["UI_ACTIONS"] ?? "unset")")
        AppRestart.shared.willRestart = { DriverContinuation.save(remaining: remaining) }
        AppRestart.shared.restartFailed = { DriverContinuation.drop() }
        // A marker a run pushed as the app was ended (its last action's) would let this run's
        // action of the same number go on before its screenshot: none is this run's yet.
        if stepped, let names = try? FileManager.default.contentsOfDirectory(atPath: WineHostRuntime.documents.path) {
            for n in names where n.hasPrefix("ui-step-") {
                try? FileManager.default.removeItem(at: WineHostRuntime.documents.appendingPathComponent(n))
            }
        }
        Task { @MainActor in
            let library = LibraryModel.shared
            // The first scan: the one AppShell starts on appear.
            while library.scanning || !library.scannedOnce { try? await Task.sleep(for: .milliseconds(100)) }
            // The opening animation (UI/AppOpening.swift) covers the shell until Home is drawn whole.
            while AppOpening.shared.covering { try? await Task.sleep(for: .milliseconds(100)) }
            log("library: " + library.catalog.titles.map { "\($0.id) \($0.name) [\($0.badge.rawValue)]" }.joined(separator: ", "))
            var done = 0
            for (i, action) in actions.enumerated() {
                remaining = Array(actions[(i + 1)...])
                let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return finish("action=\(action) refused: not <verb>:<id>") }
                let id = parts[1]
                if ["verify", "play", "uninstall", "settings"].contains(parts[0]), library.title(id) == nil {
                    return finish("action=\(action) refused: \(id) is not a catalogued title")
                }
                switch parts[0] {
                case "install" where id.hasPrefix("gog-"):
                    if let failure = await installGOG(String(id.dropFirst(4))) { return finish("action=\(action) failed: \(failure)") }
                case "install", "pause-resume":
                    guard let app = UInt32(id) else { return finish("action=\(action) refused: \(id) is not a Steam app id") }
                    if let failure = await install(app, pauseAt: parts[0] == "pause-resume" ? 0.25 : nil) {
                        return finish("action=\(action) failed: \(failure)")
                    }
                case "import":
                    if let failure = await importGame(id) { return finish("action=\(action) failed: \(failure)") }
                case "queue", "downloading":
                    guard let app = UInt32(id) else { return finish("action=\(action) refused: \(id) is not a Steam app id") }
                    if let failure = await (parts[0] == "queue" ? queue(app) : downloading(app)) {
                        return finish("action=\(action) failed: \(failure)")
                    }
                case "settings":
                    guard let json = env["UI_SETTINGS"],
                          let s = try? JSONDecoder().decode(LaunchSettings.self, from: Data(json.utf8)) else {
                        return finish("action=\(action) refused: UI_SETTINGS is not LaunchSettings JSON")
                    }
                    DriverUndo.willSetGame(id)
                    LaunchSettingsStore.shared.binding(for: id).wrappedValue = s
                    let e = LibraryModel.shared.title(id).map { LaunchSettingsStore.shared.effective(for: $0) }
                        ?? LaunchSettings.resolve(game: s, global: LaunchSettingsStore.shared.global)
                    log("settings \(id): screen=\(e.screen ?? "native") limit=\(e.frameLimit) graphics=\(e.graphics.rawValue) arguments=\(e.arguments) ordering=\(MemoryOrdering.Setting.allCases.compactMap { s in e.ordering[s].map { "\(s.rawValue)=\($0)" } }) maxInst=\(e.maxInst.map(String.init) ?? "profile") x87Reduced=\(e.x87Reduced.map { String($0) } ?? "profile") diskCache=\(e.diskCache.map { String($0) } ?? "default") runtime=\(e.runtime.keys.sorted().map { "\($0)=\(e.runtime[$0]!)" })")
                case "hud":
                    guard ["on", "off"].contains(id) else { return finish("action=\(action) refused: not hud:on or hud:off") }
                    DriverUndo.willSet(MetalHUD.key)
                    UserDefaults.standard.set(id == "on", forKey: MetalHUD.key)
                    log("hud: \(id)")
                case "open":
                    let nav = AppNavigation.shared
                    let parts = id.split(separator: "#", maxSplits: 1).map(String.init)
                    if parts.first == "black" {
                        BlackScreen.shared.show()
                    } else if parts.first == "licences" {
                        var pages: [LicencePage] = []
                        if parts.count > 1 {
                            guard case .success(let licences) = BundledLicences.loaded,
                                  let c = licences.components.first(where: { $0.name.lowercased().hasPrefix(parts[1]) })
                            else { return finish("action=\(action) refused: no bundled licence component starts with \(parts[1])") }
                            pages.append(.component(c.name))
                        }
                        nav.showLicences(pages)
                    } else if nav.open(parts.first ?? "") {
                        nav.pageSection = parts.count > 1 ? parts[1] : nil
                    } else if let title = parts.first, library.title(title) != nil {
                        nav.openTitle(title)
                        nav.pageSection = parts.count > 1 ? parts[1] : nil
                    } else {
                        return finish("action=\(action) refused: \(id) is not a screen or a catalogued title")
                    }
                    try? await Task.sleep(for: .milliseconds(1500))
                    log("open \(id)")
                case "pad":
                    // The presses a controller makes, into the same router (UI/Pad/PadRouter.swift),
                    // or the in-game menu's while it is up (HostIO feeds it the same presses).
                    let presses = id.split(separator: "+").map(String.init)
                    guard !presses.isEmpty, presses.allSatisfy({ NavButton(rawValue: $0) != nil }) else {
                        return finish("action=\(action) refused: not pad:<button>[+<button>...] with buttons "
                                      + NavButton.allCases.map(\.rawValue).joined(separator: " "))
                    }
                    if InGameMenu.shared.isOpen {
                        for p in presses {
                            InGameMenu.shared.press(NavButton(rawValue: p)!)
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        try? await Task.sleep(for: .milliseconds(1000))
                        log("pad \(id): \(InGameMenu.shared.summary)")
                        if let failure = await afterInGame(action, index: done + 1, next: actions[(i + 1)...]) {
                            return finish(failure)
                        }
                        if AppRestart.shared.restarting { return }
                        break
                    }
                    for p in presses {
                        PadRouter.shared.send(NavButton(rawValue: p)!)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    try? await Task.sleep(for: .milliseconds(1000))
                    log("pad \(id): focus \(PadFocus.shared.focused ?? "none"), page \(AppNavigation.shared.page.rawValue)"
                        + (AppNavigation.shared.settings ? " (settings, \(AppNavigation.shared.settingsSection.rawValue))" : "")
                        + (AppNavigation.shared.setup && !AppNavigation.shared.settings ? " (setup\(SetupState.shared.preview == nil ? "" : " preview"), \(SetupChecklist.summary(SetupState.shared.shown)))" : "")
                        + (AppNavigation.shared.signIn ? " (\(SteamAccountModel.current.map { SignInState.shared.summary($0) } ?? "signin"))" : "")
                        + (AppNavigation.shared.onGamePage ? " (game page\(AppNavigation.shared.gamePanels.map { ", " + $0.rawValue }.joined()))" : "")
                        + (PadModal.shared.summary.map { ", \($0)" } ?? "") + gamePageSettings() + globalSettings())
                    // A press that started a Play (a game page's Play, Home's card): the run follows the
                    // game as play: does, and ends with its title-done or pp ui's --until.
                    let launch = TitleLaunch.shared
                    if launch.running {
                        log("pad \(id): a Play started")
                        while launch.running { try? await Task.sleep(for: .milliseconds(250)) }
                        if AppRestart.shared.restarting {
                            RunEvents.emit("ui-action", ["action": action, "result": "ok", "index": done + 1, "restart": true])
                            log("pad \(id): the game ended; Playport restarts, and the actions after it do not run")
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(1500))   // the alert drawn, for a screenshot
                        log("pad \(id): the game ended without starting the runtime: \(launch.message?.title ?? "no message")"
                            + (launch.message?.step.map { " (failed at \(LaunchProgress.stepName($0)))" } ?? ""))
                    }
                case "wait":
                    guard let s = Int(id), (0...600).contains(s) else { return finish("action=\(action) refused: not wait:<seconds 0-600>") }
                    try? await Task.sleep(for: .seconds(s))
                    log("waited \(s) s" + (TitleLaunch.shared.running ? " (the game runs)" : ""))
                    if let failure = await afterInGame(action, index: done + 1, next: actions[(i + 1)...]) { return finish(failure) }
                    if AppRestart.shared.restarting { return }
                case "menu":
                    let launch = TitleLaunch.shared, menu = InGameMenu.shared
                    if id == "open" {
                        guard launch.running else { return finish("action=\(action) refused: no game is running") }
                        let deadline = Date().addingTimeInterval(180)
                        while launch.running, !launch.acceptsMenu || launch.step != .drawing, Date() < deadline {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        guard launch.acceptsMenu else { return finish("action=\(action) failed: the game did not draw a frame") }
                        // Home held, as a controller holds it, into HostIO's pad handling.
                        var home = PadInput()
                        home.home = true
                        HostIO.shared.menuInput(home)
                        try? await Task.sleep(for: .milliseconds(800))
                        HostIO.shared.menuInput(PadInput())
                        try? await Task.sleep(for: .milliseconds(1000))
                        guard menu.isOpen else { return finish("action=\(action) failed: the menu did not open") }
                    } else {
                        guard let item = QuickMenuItem(rawValue: id) else {
                            return finish("action=\(action) refused: not menu:open or menu:<row> with rows "
                                          + QuickMenuItem.allCases.map(\.rawValue).joined(separator: " "))
                        }
                        guard menu.isOpen else { return finish("action=\(action) refused: the in-game menu is not open") }
                        for down in QuickMenu.steps(from: menu.menu.ring, to: item) {
                            menu.press(down ? .down : .up)
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        menu.press(.a)
                        try? await Task.sleep(for: .milliseconds(item == .screenshot ? 2500 : 1000))
                    }
                    log("menu \(id): \(menu.summary)")
                    if let failure = await afterInGame(action, index: done + 1, next: actions[(i + 1)...]) { return finish(failure) }
                    if AppRestart.shared.restarting { return }
                case "set":
                    let kv = id.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2, !kv[0].isEmpty else { return finish("action=\(action) refused: not set:<key>=<value>") }
                    let value: Any = kv[1] == "true" ? true : kv[1] == "false" ? false : Int(kv[1]).map { $0 as Any } ?? kv[1]
                    DriverUndo.willSet(kv[0])
                    UserDefaults.standard.set(value, forKey: kv[0])
                    log("set \(kv[0]) = \(value)")
                case "jit":
                    let setup = JitSetup.shared
                    switch id {
                    case "setup": setup.begin()
                    case "pair": setup.begin(repair: true)
                    case "continue": setup.retry()
                    case "open-settings":
                        // The code appears once Bonjour starts (after any readiness check).
                        for _ in 0..<120 where OnDevicePairing.shared.code == nil {
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                        guard OnDevicePairing.shared.code != nil else { return finish("action=\(action) failed: no pairing code") }
                        OnDevicePairing.shared.openSettings()
                    case "cancel": setup.cancel()
                    case "wait":
                        while setup.isActive { try? await Task.sleep(for: .milliseconds(250)) }
                        guard setup.phase == .ready else { return finish("action=\(action) failed: setup did not complete") }
                    default: return finish("action=\(action) refused: unknown JIT setup action")
                    }
                    if id == "setup" || id == "pair" { try? await Task.sleep(for: .seconds(3)) }
                case "probe":
                    let probe = HelperLifetimeProbe.shared
                    switch id {
                    case "helper-exit", "helper-kill", "helper-exit-hold", "helper-kill-hold":
                        guard done + 1 == actions.count else { return finish("action=\(action) refused: it must be the last action") }
                        if let failure = await probe.run(id.hasPrefix("helper-exit") ? .exit : .kill, hold: id.hasSuffix("-hold")) {
                            return finish("action=\(action) failed: \(failure)")
                        }
                    case "relaunch":
                        guard done + 1 == actions.count else { return finish("action=\(action) refused: it must be the last action") }
                        // The driver's done first: when the request works, this process ends.
                        RunEvents.emit("ui-action", ["action": action, "result": "ok", "index": done + 1])
                        finish("ok actions=\(actions.count) (restart requested)")
                        AppRestart.shared.restart(notice: nil)
                        return
                    case "pairing":
                        _ = AppNavigation.shared.open("settings")
                        AppNavigation.shared.pageSection = "pairing"
                        // Existing credentials trigger a readiness check at launch.
                        // Wait for it rather than silently refusing the probe.
                        while BuiltInJitStatus.shared.busy { try? await Task.sleep(for: .milliseconds(250)) }
                        OnDevicePairing.shared.start()
                        guard OnDevicePairing.shared.busy else {
                            return finish("action=\(action) failed: \(OnDevicePairing.shared.status)")
                        }
                        try? await Task.sleep(for: .seconds(3))
                        log("on-device pairing probe: \(OnDevicePairing.shared.status)")
                    case "pairing-cancel":
                        OnDevicePairing.shared.stop()
                    case "pairing-use":
                        // pp ui relaunches the app. Keep pairing and use in this
                        // same run: credentials intentionally exist only in memory.
                        let pairing = OnDevicePairing.shared
                        while pairing.busy { try? await Task.sleep(for: .milliseconds(250)) }
                        guard pairing.hasNewPairing else {
                            return finish("action=\(action) failed: no completed pairing in this run")
                        }
                        pairing.useNewPairing()
                        while BuiltInJitStatus.shared.busy { try? await Task.sleep(for: .milliseconds(250)) }
                        guard BuiltInJitStatus.shared.status == "ready" else {
                            return finish("action=\(action) failed: generated pairing is not ready")
                        }
                    case let s where s.hasPrefix("settings-url-"):
                        guard let n = Int(s.dropFirst("settings-url-".count)), SettingsLink.probed.indices.contains(n) else {
                            return finish("action=\(action) refused: no such Settings link")
                        }
                        let opened = await UIApplication.shared.open(SettingsLink.probed[n])
                        log("settings link \(n) \(SettingsLink.probed[n].absoluteString): opened=\(opened)")
                    case "helper-report":
                        log("probe report: \(await probe.report())")
                    default:
                        return finish("action=\(action) refused: unknown probe")
                    }
                case "uninstall":
                    if let failure = await uninstall(id) { return finish("action=\(action) failed: \(failure)") }
                case "verify":
                    library.verify(id)
                    while library.verifying.contains(id) { try? await Task.sleep(for: .milliseconds(250)) }
                    if let v = library.title(id)?.lastVerification, library.verifyErrors[id] == nil {
                        log("verify \(id): \(v.files - v.bad)/\(v.files) OK, \(v.unlisted) unlisted")
                    } else {
                        return finish("action=\(action) failed: \(library.verifyErrors[id] ?? "no result")")
                    }
                case "play":
                    do {
                        guard try await library.play(id) else {
                            if case .cloud = PadModal.shared.content {
                                try? await Task.sleep(for: .milliseconds(1000))   // the screen drawn, for a screenshot
                                return finish("action=\(action) refused: \(PadModal.shared.summary ?? "cloud conflict"): "
                                              + "the Cloud save conflict screen asks which saves to keep")
                            }
                            return finish("action=\(action) refused: a launch is running or Playport needs a restart")
                        }
                        log("play \(id): started")
                    } catch {
                        return finish("action=\(action) failed: \(error)")
                    }
                    // Actions for the running game (wait:, menu:) go on while it runs.
                    if done + 1 < actions.count, !inGame(actions[i + 1]) {
                        let launch = TitleLaunch.shared
                        while launch.running { try? await Task.sleep(for: .milliseconds(250)) }
                        if AppRestart.shared.restarting {
                            // The restarted process runs the rest (DriverContinuation, saved as it asks).
                            RunEvents.emit("ui-action", ["action": action, "result": "ok", "index": done + 1, "restart": true])
                            log("play \(id): ended; Playport restarts, and the new process goes on")
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(1500))   // the alert drawn, for a screenshot
                        log("play \(id): ended without starting the runtime: \(launch.message?.title ?? "no message")"
                            + (launch.message?.step.map { " (failed at \(LaunchProgress.stepName($0)))" } ?? ""))
                    }
                default:
                    return finish("action=\(action) refused: unknown action")
                }
                done += 1
                RunEvents.emit("ui-action", ["action": action, "result": "ok", "index": done])
                if stepped { await waitForStep(done) }
            }
            finish("ok actions=\(actions.count)")
        }
    }

    /// An action that acts on the running game, which a play: does not wait past.
    static func inGame(_ action: String) -> Bool {
        action.hasPrefix("menu:") || action.hasPrefix("wait:") || (action.hasPrefix("pad:") && InGameMenu.shared.isOpen)
    }

    /// After an action for the running game: when the actions after it are not
    /// for the game (or menu:quit ended it), wait for the game's end as play:
    /// does. At a restart, the ui-action is sent here and the caller returns;
    /// nil to go on, else the run's failure.
    private static func afterInGame(_ action: String, index: Int, next: ArraySlice<String>) async -> String? {
        let launch = TitleLaunch.shared
        let quit = action == "menu:quit"
        guard launch.running, quit || (next.first.map { !inGame($0) } ?? false) else { return nil }
        while launch.running { try? await Task.sleep(for: .milliseconds(250)) }
        if AppRestart.shared.restarting {
            RunEvents.emit("ui-action", ["action": action, "result": "ok", "index": index, "restart": true])
            log("\(action): the game ended; Playport restarts, and the new process goes on")
            return nil
        }
        try? await Task.sleep(for: .milliseconds(1500))
        log("\(action): the game ended without a restart: \(launch.message?.title ?? "no message")")
        return nil
    }

    /// The UI's install (and, with `pauseAt`, its Pause and Resume); nil when
    /// the title reached the library, else why not.
    private static func install(_ app: UInt32, pauseAt: Double?) async -> String? {
        guard let steam = SteamAccountModel.current else { return "no Steam model" }
        for _ in 0..<600 where steam.state.account == nil || { if case .restoring = steam.state { return true }; return false }() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard case .signedIn = steam.state else { return "Steam is not signed in (\(steam.state))" }
        let installs = steam.installs
        let name = steam.games.first { $0.id == app }?.info.name ?? "app \(app)"
        let started = Date()
        log("install \(app) \(name): started")
        installs.install(app, name: name)
        if let pauseAt {
            while let j = installs.jobs[.steam(app)], j.isRunning || j.phase == .queued, (j.fraction ?? 0) < pauseAt {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let j = installs.jobs[.steam(app)], j.isRunning else { return "ended before \(Int(pauseAt * 100))% (\(phase(installs.jobs[.steam(app)])))" }
            installs.pause(app)
            while installs.jobs[.steam(app)]?.isRunning == true { try? await Task.sleep(for: .milliseconds(100)) }
            let staged = TitleInstaller(layout: installs.layout, session: nil, log: .silent).hasStage(appID: app)
            log("install \(app): paused at \(j.detail ?? "?"); phase=\(phase(installs.jobs[.steam(app)])) stage kept=\(staged)")
            guard staged, installs.jobs[.steam(app)]?.phase == .paused(nil) else { return "pause did not keep a resumable stage" }
            installs.resume(app)
            // Until the resumed run's first progress: where the kept stage put it.
            while let p = installs.jobs[.steam(app)]?.phase, p == .queued || p == .preparing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            log("install \(app): resumed at \(installs.jobs[.steam(app)]?.detail ?? "?") (\(phase(installs.jobs[.steam(app)])))")
        }
        var lastLog = Date()
        while let j = installs.jobs[.steam(app)] {
            if case let .paused(reason) = j.phase { return "paused: \(reason ?? "no reason")" }
            if Date().timeIntervalSince(lastLog) > 30 {
                lastLog = Date()
                log("install \(app): \(j.status) \(j.detail ?? "")")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let library = LibraryModel.shared
        for _ in 0..<600 where library.catalog.titles.first(where: { $0.appID == app }) == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let t = library.catalog.titles.first(where: { $0.appID == app }) else { return "done, but not in the library" }
        log(String(format: "install \(app): in the library as \(t.id) [\(t.badge.rawValue)] build=\(t.buildID.map(String.init) ?? "?") "
                    + "size=\(t.sizeBytes ?? 0) exe=\(t.executable ?? "none") after %.0f s", Date().timeIntervalSince(started)))
        return nil
    }

    /// Add a game with `path` (under Documents) as the picked item; nil once it is in the library.
    private static func importGame(_ path: String) async -> String? {
        guard !path.split(separator: "/").contains(".."), let installs = SteamAccountModel.current?.installs else {
            return "not a path under Documents, or no download queue"
        }
        let url = WineHostRuntime.documents.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return "Documents/\(path) is not there" }
        let started = Date()
        log("import \(path): picked")
        if let refusal = await GameImports.shared.picked(url) { return "refused: \(refusal)" }
        guard let job = installs.order.first(where: { $0.kind == .import && $0.record.source == url.lastPathComponent }) else {
            return "no import job queued"
        }
        let key = job.key, folder = job.name
        var lastLog = Date()
        while let j = installs.jobs[key] {
            if case let .paused(reason) = j.phase { return "paused: \(reason ?? "no reason")" }
            if Date().timeIntervalSince(lastLog) > 15 {
                lastLog = Date()
                log("import \(path): \(j.status) \(j.detail ?? "")")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let library = LibraryModel.shared
        let find = { library.catalog.titles.first { $0.installDir.lowercased() == folder.lowercased() } }
        for _ in 0..<600 where find() == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let t = find() else { return "done, but C:\\Games\\\(folder) is not in the library" }
        log(String(format: "import \(path): in the library as \(t.id) [\(t.badge.rawValue)] source=\(t.source.rawValue) "
                    + "store=\(t.store.rawValue) size=\(t.sizeBytes ?? 0) exe=\(t.executable ?? "none") after %.1f s",
                   Date().timeIntervalSince(started)))
        return nil
    }

    /// The GOG page's Install (or Update) of `spec` (`<id>` or `<id>@<build>`); nil once the build is in the library.
    private static func installGOG(_ spec: String) async -> String? {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let pid = parts[0], build = parts.count > 1 ? parts[1] : nil
        let gog = GOGAccount.shared
        for _ in 0..<300 where gog.state == .unknown { try? await Task.sleep(for: .milliseconds(100)) }
        guard gog.state == .signedIn else { return "GOG is not signed in" }
        if gog.games.isEmpty { await gog.loadGames() }
        guard let installs = SteamAccountModel.current?.installs else { return "no download queue" }
        let key = StoreGameKey(store: .gog, id: pid)
        let name = gog.game(pid)?.title ?? "GOG \(pid)"
        let before = LibraryModel.shared.title(key.titleID)?.storeVersion
        let installed = before != nil
        let started = Date()
        log("install gog-\(spec) \(name): started" + (installed ? " (an update)" : ""))
        gog.install(pid, name: name, kind: installed ? .update : .install, build: build)
        var lastLog = Date()
        while let j = installs.jobs[key] {
            if case let .paused(reason) = j.phase { return "paused: \(reason ?? "no reason")" }
            if Date().timeIntervalSince(lastLog) > 15 {
                lastLog = Date()
                log("install gog-\(pid): \(j.status) \(j.detail ?? "")")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let library = LibraryModel.shared
        for _ in 0..<600 where [nil, before].contains(library.title(key.titleID)?.storeVersion) && build != before {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let t = library.title(key.titleID) else { return "done, but not in the library" }
        await gog.checkUpdate(pid)
        log(String(format: "install gog-\(pid): in the library as \(t.id) [\(t.badge.rawValue)] build=\(t.storeVersion ?? "?") "
                    + "newest=\(gog.newest[pid] ?? "?") size=\(t.sizeBytes ?? 0) exe=\(t.executable ?? "none") after %.0f s",
                   Date().timeIntervalSince(started)))
        return nil
    }

    /// The Install button's call, then on at once; nil when the job is in the queue.
    private static func queue(_ app: UInt32) async -> String? {
        guard let steam = SteamAccountModel.current else { return "no Steam model" }
        for _ in 0..<600 where steam.games.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let installs = steam.installs
        let name = steam.games.first { $0.id == app }?.info.name ?? "app \(app)"
        installs.install(app, name: name)
        guard installs.jobs[.steam(app)] != nil else { return "no job queued" }
        log("queue \(app) \(name): \(queueLine(installs))")
        return nil
    }

    /// Until the queue runs `app` with progress; nil when it does.
    private static func downloading(_ app: UInt32) async -> String? {
        guard let installs = SteamAccountModel.current?.installs else { return "no Steam model" }
        let started = Date()
        while Date().timeIntervalSince(started) < 120 {
            if let j = installs.jobs[.steam(app)], j.phase == .downloading, j.progress != nil {
                log(String(format: "downloading \(app): %@ after %.1f s; queue: %@", j.detail ?? "?",
                           Date().timeIntervalSince(started), queueLine(installs)))
                return nil
            }
            if installs.jobs[.steam(app)] == nil { return "no job for \(app) (\(queueLine(installs)))" }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return "not downloading after 120 s (\(queueLine(installs)))"
    }

    private static func queueLine(_ installs: Downloads) -> String {
        let jobs = installs.order.map { "\($0.appID) \($0.kind.rawValue) \(phase($0))" }
        return (jobs.isEmpty ? "empty" : jobs.joined(separator: ", ")) + (installs.blocked.map { " (\($0))" } ?? "")
    }

    /// On a game page: the game's own launch settings, as its options saved them.
    private static func gamePageSettings() -> String {
        let nav = AppNavigation.shared
        guard nav.onGamePage, case let .title(id)? = nav.gamePath.last else { return "" }
        let s = LaunchSettingsStore.shared.settings(for: id)
        let json = (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        return ", settings \(id) \(s.isEmpty ? "{}" : json)"
    }

    /// In Settings › Graphics: the global launch settings, as its rows saved them.
    private static func globalSettings() -> String {
        let nav = AppNavigation.shared
        guard nav.settings, nav.settingsSection == .graphics else { return "" }
        let s = LaunchSettingsStore.shared.global
        let json = (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        return ", global \(s.isEmpty ? "{}" : json)"
    }

    private static func phase(_ j: Downloads.Job?) -> String { j.map { "\($0.phase)" } ?? "none" }

    /// The Uninstall button's call; nil when the folder, record and catalogue entry are gone.
    private static func uninstall(_ id: String) async -> String? {
        let library = LibraryModel.shared
        guard let t = library.title(id) else { return "not catalogued" }
        library.uninstall(id)
        while library.removing.contains(id) { try? await Task.sleep(for: .milliseconds(100)) }
        if let e = library.removeErrors[id] { return e }
        let layout = LibraryModel.paths.layout
        let folder = FileManager.default.fileExists(atPath: layout.gamesRoot.appendingPathComponent(t.installDir).path)
        let record = t.appID.map { FileManager.default.fileExists(atPath: layout.receiptFile(appID: $0).path) } ?? false
        let stage = t.appID.map { TitleInstaller(layout: layout, session: nil, log: .silent).hasStage(appID: $0) } ?? false
        log("uninstall \(id): folder present=\(folder) record present=\(record) stage present=\(stage) catalogued=\(library.title(id) != nil)")
        return folder || record || stage || library.title(id) != nil ? "something was left behind" : nil
    }

    /// UI_STEP=1 (the driver's --shot-each-action): after action n, wait until the
    /// driver has taken its screenshot and pushed Documents/ui-step-<n>, at most 90 s.
    private static let stepped = env["UI_STEP"] == "1"

    private static func waitForStep(_ n: Int) async {
        let url = WineHostRuntime.documents.appendingPathComponent("ui-step-\(n)")
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func finish(_ outcome: String) {
        log("done nonce=\(TitleMode.nonce) \(outcome)")
        RunEvents.emit("ui-done", ["outcome": outcome])
    }
}
