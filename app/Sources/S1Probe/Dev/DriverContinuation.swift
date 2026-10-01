// SPDX-License-Identifier: GPL-3.0-or-later
// Dev builds only: a driven run goes on across Playport's restart after a game
// (AppRestart, decision 0029). `pp ui --action play:A --action play:B` plays A,
// Playport restarts itself, and the new process plays B under the same run.
//
// Just before the restart request, the UI driver's variables (the run's nonce,
// its session, the settings flags, the scripted pad) and the actions left after
// the play that ended go to Documents/ui-continue.json. The new process, in the
// app's init before anything reads its environment, puts them back into its
// environment and deletes the file: UIDriver, RunEvents, DriverUndo, TitleMode
// and the pad then see the run they belong to. It is a continuation of the
// driver's own session, not a way in for anything else (decision 0012): nothing
// is written when no actions are left, a file older than a minute or written by
// this same process is dropped, and a failed restart deletes it.

import Foundation

enum DriverContinuation {
    /// The variables tools/ui.py gives a driven launch (ui_env).
    private static let keys = ["S1_MODE", "TITLE_NONCE", "UI_SETTINGS", "UI_STEP", "UI_SESSION",
                               "UI_KEEP_SETTINGS", "HIO_VPAD"]
    private static let url = WineHostRuntime.documents.appendingPathComponent("ui-continue.json")
    private static let maxAgeMs: Int64 = 60_000
    private static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
    private static func log(_ line: String) { WineHostRuntime.appendLog("ui: " + line) }

    private struct Record: Codable {
        var writtenMs: Int64
        var pid: Int32
        var env: [String: String]
        var actions: [String]
    }

    /// Before a restart in a driven run: the actions left, if any.
    static func save(remaining actions: [String]) {
        let env = ProcessInfo.processInfo.environment
        guard env["S1_MODE"] == "ui", !actions.isEmpty else { return }
        let r = Record(writtenMs: nowMs, pid: getpid(), env: env.filter { keys.contains($0.key) }, actions: actions)
        do {
            try JSONEncoder().encode(r).write(to: url, options: .atomic)
            log("continuing after the restart: \(actions.joined(separator: ","))")
        } catch {
            log("continuation not written: \(error)")
        }
    }

    /// A restart that failed: the run goes on here, or not at all.
    static func drop() { try? FileManager.default.removeItem(at: url) }

    /// The app's init, first: a driven run this process continues.
    static func adoptAtStart() {
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard ProcessInfo.processInfo.environment["S1_MODE"] == nil,
              let r = try? JSONDecoder().decode(Record.self, from: data) else { return }
        let age = nowMs - r.writtenMs
        guard r.pid != getpid(), age >= 0, age < maxAgeMs else {
            log("dropped an old or foreign continuation (pid \(r.pid), \(age) ms)")
            return
        }
        for (k, v) in r.env where keys.contains(k) { setenv(k, v, 1) }
        setenv("UI_ACTIONS", r.actions.joined(separator: ","), 1)
        log("continuing pid \(r.pid)'s run in pid \(getpid()), \(age) ms later: UI_ACTIONS=\(r.actions.joined(separator: ","))")
    }
}
