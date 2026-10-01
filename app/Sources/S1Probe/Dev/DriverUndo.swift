// SPDX-License-Identifier: GPL-3.0-or-later
// Dev builds only: the settings a driven run changes (UIDriver's set:, hud: and
// settings: actions) last for the driver's session, one hold of the
// workstation's device lock (UI_SESSION; tools/phonelib.py). Several agents
// share the one phone and its one container, so without this one agent's
// `set:metalHUD=true` or a game's launch arguments would ride along in the next
// agent's runs.
//
// The first change of a key (or of a game's launch settings) in a session
// records the value it had. The app's first launch outside that session (a
// driven launch of another session, or a Home Screen launch) puts every
// recorded value back before anything reads it, and logs
// `ui: undo session <id>: restored <keys>`. UI_KEEP_SETTINGS=1 (pp ui
// --keep-settings) keeps a run's changes: nothing is recorded for them. A
// driven launch without UI_SESSION records nothing either.

import Foundation
import PlayportKit

@MainActor
enum DriverUndo {
    private static let key = "uiDriver.undo"
    private static let env = ProcessInfo.processInfo.environment
    private static let session = env["UI_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
    private static let keep = env["UI_KEEP_SETTINGS"] == "1"

    /// ["session": id, "defaults": [key: the value it had], "unset": [keys it did not have],
    ///  "games": [title id: its LaunchSettings as JSON]]
    private static var record: [String: Any] {
        get { UserDefaults.standard.dictionary(forKey: key) ?? [:] }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }

    /// In the app's init, before anything reads a setting: undo another session's changes.
    static func restoreAtStart() {
        let r = record
        guard let owner = r["session"] as? String else {
            record = [:]
            return
        }
        if owner == session { return }
        let defaults = r["defaults"] as? [String: Any] ?? [:]
        let unset = r["unset"] as? [String] ?? []
        let games = r["games"] as? [String: Data] ?? [:]
        for (k, v) in defaults { UserDefaults.standard.set(v, forKey: k) }
        for k in unset { UserDefaults.standard.removeObject(forKey: k) }
        for (id, data) in games {
            LaunchSettingsStore.shared.binding(for: id).wrappedValue =
                (try? JSONDecoder().decode(LaunchSettings.self, from: data)) ?? LaunchSettings()
        }
        record = [:]
        let keys = defaults.keys.sorted() + unset.sorted() + games.keys.sorted().map { "settings:" + $0 }
        WineHostRuntime.appendLog("ui: undo session \(owner): restored \(keys.joined(separator: ", "))")
        RunEvents.emit("settings-restored", ["session": owner, "keys": keys])
    }

    /// Before a driven action sets the UserDefaults key `k`.
    static func willSet(_ k: String) {
        update { r in
            var d = r["defaults"] as? [String: Any] ?? [:]
            var u = r["unset"] as? [String] ?? []
            if keep {
                d[k] = nil
                u.removeAll { $0 == k }
            } else if d[k] == nil, !u.contains(k) {
                if let v = UserDefaults.standard.object(forKey: k) { d[k] = v } else { u.append(k) }
            }
            r["defaults"] = d
            r["unset"] = u
        }
    }

    /// Before a driven action saves the launch settings of the title `id`.
    static func willSetGame(_ id: String) {
        update { r in
            var g = r["games"] as? [String: Data] ?? [:]
            if keep {
                g[id] = nil
            } else if g[id] == nil, let data = try? JSONEncoder().encode(LaunchSettingsStore.shared.settings(for: id)) {
                g[id] = data
            }
            r["games"] = g
        }
    }

    private static func update(_ change: (inout [String: Any]) -> Void) {
        guard let session else { return }
        var r = record
        if r["session"] as? String != session { r = ["session": session] }
        change(&r)
        let empty = (r["defaults"] as? [String: Any] ?? [:]).isEmpty && (r["unset"] as? [String] ?? []).isEmpty
            && (r["games"] as? [String: Data] ?? [:]).isEmpty
        record = empty ? [:] : r
    }
}
