// SPDX-License-Identifier: GPL-3.0-or-later
// Playport restarts itself after every game that used the runtime (decision
// 0029; docs/ARCHITECTURE.md, "Restarting after a game"). A process runs one
// Wine session, one JIT pool and whatever threads a game left behind; rather
// than reset them, the next game gets a new process. The app asks the phone's
// CoreDevice app service, over LocalDevVPN with the pairing file the JIT
// section keeps, to launch this bundle with terminateExisting (Sources/Relaunch).
// The service ends this process and starts a new one, and it finishes the
// request after its sender is gone (docs/evidence/2026-09-29-coredevice-relaunch-without-client.md).
//
// - Only in front: a restart asked for while the app is in the background waits
//   until it is active again, so the new process does not take the screen.
// - Documents/restart.json records the request (its time, this PID, and why the
//   game did not end cleanly, if it did not). The new process logs the gap as a
//   `restart:` line, shows the reason once as an alert over the library, and
//   deletes the file. A record older than a minute, or this process's own, is dropped.
// - With LocalDevVPN's tunnel down, Playport turns it on first and sends the
//   request once it is back in front (LocalDevVPN.swift).
// - If the request fails (LocalDevVPN off, no pairing file), this process
//   stays: the reason, and the one before it, show as an alert, and the game's
//   page offers Close Playport. It plays nothing more (decision 0030).
// - Inside LiveContainer, or with no pairing (JIT from another app, decision
//   0051), there is no request: CoreDevice would launch LiveContainer, not
//   Playport, and the request needs the pairing. The alert asks the player to
//   close Playport and launch it again (with JIT), and the page offers Close Playport.
// - After a title's prerequisites ran and left the game too little JIT pool (decisions 0084,
//   0094) the record also carries the Play
//   (PlayportKit PlayContinuation): the screen across the restart names the game, and the
//   new process, once its library is ready, starts that game as the same Play with no
//   prerequisites and no second restart (continuePlay).

import Foundation
import PlayportKit
import SwiftUI

@MainActor
final class AppRestart: ObservableObject {
    static let shared = AppRestart()

    /// Between asking and this process's end: the UI shows a black screen, no text (RootView).
    @Published private(set) var restarting = false
    /// The Play the restart continues (decision 0084): set in the old process as it asks,
    /// and in the new one from its record until the game's launch starts; the screen
    /// across the restart shows it (PlayContinuingScreen). Nil for none.
    @Published private(set) var continuing: PlayContinuation? = AppRestart.continuingAtLaunch
    private var continued = false
    private var waiting: Record?
    /// LocalDevVPN was opened once for this restart: the request goes next, tunnel or not.
    private var askedVPN = false

    #if !PLAYPORT_RELEASE
    /// Dev builds: the UI driver's continuation (Dev/DriverContinuation.swift),
    /// written before the request and dropped if it fails.
    /// Whether the restart continues a Play (the driven run then goes on in the new process).
    var willRestart: ((Bool) -> Void)?
    var restartFailed: (() -> Void)?
    #endif

    nonisolated static let host = "10.7.0.1"
    private nonisolated static let url = WineHostRuntime.documents.appendingPathComponent("restart.json")
    private nonisolated static let maxAgeMs: Int64 = 60_000
    private nonisolated static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
    nonisolated static func log(_ line: String) { WineHostRuntime.appendLog("restart: " + line) }

    struct Record: Codable {
        var requestedMs: Int64
        var pid: Int32
        var notice: LaunchMessage?
        /// The Play the new process continues after its prerequisites (decision 0084); nil for none.
        var continuing: PlayContinuation?
    }

    /// After a game, or after a title's prerequisites with the Play to continue: restart now,
    /// or once the app is in front again.
    func restart(notice: LaunchMessage?, continuing next: PlayContinuation? = nil) {
        let r = Record(requestedMs: Self.nowMs, pid: getpid(), notice: notice, continuing: next)
        if let why = Self.cannotRestart {
            Self.log("not asked: \(why)")
            #if !PLAYPORT_RELEASE
            restartFailed?()
            #endif
            let how = JitProvider.inLiveContainer
                ? "To play again, close Playport and launch it again from LiveContainer with JIT."
                : "To play again, close Playport and open it again."
            let game = notice.map { "\n\n\($0.title): \($0.text)" } ?? ""
            TitleLaunch.shared.message = LaunchMessage(title: "Close Playport to play again", text: how + game)
            return
        }
        restarting = true
        continuing = next
        if UIApplication.shared.applicationState == .active {
            send(r)
        } else {
            Self.log("waiting until Playport is in front")
            waiting = r
        }
    }

    /// Why Playport cannot restart itself here, or nil.
    static var cannotRestart: String? {
        if JitProvider.inLiveContainer { return "Playport runs inside LiveContainer" }
        if !BuiltInJit.hasPairingFile { return "no pairing (JIT from \(JitProvider.method.label))" }
        return nil
    }

    /// RootView, when the scene becomes active.
    func sceneBecameActive() {
        guard let r = waiting else { return }
        waiting = nil
        send(r)
    }

    private func send(_ r: Record) {
        // The request goes over LocalDevVPN's tunnel: turn it on first (LocalDevVPN.swift).
        if !askedVPN, !LocalDevVPN.tunnelUp {
            askedVPN = true
            LocalDevVPN.connect { outcome in
                if outcome == .notInstalled {
                    AppRestart.shared.failed("LocalDevVPN is not installed", r)
                } else {
                    AppRestart.shared.send(r)
                }
            }
            return
        }
        do {
            try JSONEncoder().encode(r).write(to: Self.url, options: .atomic)
        } catch {
            Self.log("restart.json not written: \(error)")
        }
        #if !PLAYPORT_RELEASE
        willRestart?(r.continuing != nil)
        #endif
        Self.log("asking CoreDevice to restart pid \(getpid())" + (r.notice.map { ": \($0.title)" } ?? ""))
        Thread.detachNewThread {
            let failure = Self.request(started: r.requestedMs)
            DispatchQueue.main.async { MainActor.assumeIsolated { AppRestart.shared.failed(failure, r) } }
        }
    }

    /// The request returned: the service replied (this process should be gone
    /// by now) or it failed. Either way this process stays, and says so.
    private func failed(_ failure: String?, _ r: Record) {
        try? FileManager.default.removeItem(at: Self.url)
        #if !PLAYPORT_RELEASE
        restartFailed?()
        #endif
        restarting = false
        continuing = nil
        let why = failure ?? "the phone replied, but did not restart Playport"
        Self.log("failed: \(why)")
        #if PLAYPORT_RELEASE
        let detail = "Check that LocalDevVPN is connected. To play again, close Playport and reopen it from the Home Screen."
        #else
        let detail = "\(why). Check that LocalDevVPN is connected. To play again, close Playport and reopen it from the Home Screen."
        #endif
        let game = r.notice.map { "\n\n\($0.title): \($0.text)" } ?? ""
        TitleLaunch.shared.message = LaunchMessage(title: "Playport could not restart itself", text: detail + game)
    }

    private nonisolated static func request(started: Int64) -> String? {
        BuiltInJit.requestRelaunch { line in
            AppRestart.log("+\(AppRestart.nowMs - started) ms \(line)")
        }
    }

    /// This process replaced one that played a game (noteLaunch): the opening animation skips its intro.
    nonisolated(unsafe) private(set) static var isRestart = false
    /// The Play this process continues, from its restart record (noteLaunch).
    nonisolated(unsafe) private static var continuingAtLaunch: PlayContinuation?

    /// The app's init: whether this process is a restart, and what it has to say.
    /// Returns the record's notice, for the first screen's alert.
    nonisolated static func noteLaunch() -> LaunchMessage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let r = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        let age = nowMs - r.requestedMs
        guard r.pid != getpid(), age >= 0, age < maxAgeMs else {
            log("dropped an old or foreign restart.json (pid \(r.pid), \(age) ms)")
            return nil
        }
        log("new process pid \(getpid()), \(age) ms after pid \(r.pid) asked" + (r.notice.map { "; notice: \($0.title)" } ?? "")
            + (r.continuing.map { "; continuing the Play of \($0.title) (\($0.titleID))" } ?? ""))
        isRestart = true
        continuingAtLaunch = r.continuing
        return r.notice
    }

    /// The new process's UI appeared: the Play its restart continues (decision 0084), once its
    /// library is scanned and the opening is done, through the library's own Play with no
    /// prerequisites. One that does not start (a check, a sign-in) leaves the library, with
    /// an alert unless that check shows its own screen.
    func continuePlay() {
        guard let next = continuing, !continued, !restarting else { return }
        continued = true
        Task { @MainActor in
            let library = LibraryModel.shared
            while library.scanning || !library.scannedOnce { try? await Task.sleep(for: .milliseconds(100)) }
            while AppOpening.shared.covering { try? await Task.sleep(for: .milliseconds(100)) }
            Self.log("continuing the Play of \(next.title) (\(next.titleID)) after its prerequisites")
            var started = false
            do {
                started = try await library.play(next.titleID, epicOffline: next.epicOffline, continuing: true)
            } catch {
                Self.log("the Play of \(next.titleID) did not continue: \(error)")
            }
            continuing = nil
            guard !started else { return }
            Self.log("the Play of \(next.titleID) did not start in this process")
            if TitleLaunch.shared.message == nil, PadModal.shared.content == nil {
                TitleLaunch.shared.message = LaunchMessage(title: "\(next.title) did not start",
                                                           text: "Its prerequisites are installed. Press Play to start it.")
            }
        }
    }
}
