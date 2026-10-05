// SPDX-License-Identifier: GPL-3.0-or-later
// Where a Play's JIT comes from (decision 0051; docs/ARCHITECTURE.md, "JIT
// activation"). Each method ends in the same universal brk #0xf00d protocol
// (wine_host_jit_pool_acquire); only what attaches the debugger differs:
//
// - builtIn: the app's own helper extension (PlayportJIT.appex) with the
//   pairing Playport keeps. The default.
// - stikDebug: Play opens StikDebug (stikdebug://enable-jit) with this
//   process's bundle ID and PID and StikDebug's own universal.js, then waits.
// - external: Play only waits for a debugger, from whatever the player uses:
//   LiveContainer's "Launch with JIT", SideStore, StikDebug started by hand.
//   Its script must be universal.js (or one speaking the same protocol).
//
// Inside LiveContainer the helper extension cannot run (LiveContainer starts
// no app extension), so builtIn is not offered there and a stored builtIn
// reads as external: a launch LiveContainer made with JIT already has its
// debugger attached.

import Foundation

public enum JitMethod: String, CaseIterable, Sendable {
    case builtIn, stikDebug, external

    /// The UserDefaults key the choice is stored under.
    public static let key = "jit.method"

    /// The script StikDebug runs: its own copy of the universal protocol.
    public static let stikDebugScript = "universal.js"

    /// What Settings offers: no built-in helper inside LiveContainer.
    public static func choices(inLiveContainer: Bool) -> [JitMethod] {
        inLiveContainer ? [.stikDebug, .external] : allCases
    }

    /// The stored choice, or the default; never one this environment cannot run.
    public static func effective(stored: String?, inLiveContainer: Bool) -> JitMethod {
        let m = stored.flatMap(JitMethod.init(rawValue:)) ?? .builtIn
        return choices(inLiveContainer: inLiveContainer).contains(m) ? m : .external
    }

    /// Whether JIT needs Playport's own pairing and LocalDevVPN (the setup checklist's first two steps).
    public var usesPairing: Bool { self == .builtIn }
    /// Whether the method needs LocalDevVPN's tunnel (StikDebug reaches the phone through it too).
    public var usesTunnel: Bool { self != .external }

    public var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .stikDebug: "StikDebug"
        case .external: "Another app"
        }
    }

    /// The picker's grey text at the row's right.
    public var detail: String {
        switch self {
        case .builtIn: "Playport's own helper"
        case .stikDebug: "Play opens StikDebug"
        case .external: "Play waits for it"
        }
    }

    /// StikDebug's request (StikJIT INTEGRATION.md, "Configure the JIT methods"):
    /// the bundle ID to return to, the PID to attach to, and the script.
    public static func stikDebugURL(bundleID: String, pid: Int32) -> URL? {
        var c = URLComponents()
        c.scheme = "stikdebug"
        c.host = "enable-jit"
        c.queryItems = [URLQueryItem(name: "bundle-id", value: bundleID),
                        URLQueryItem(name: "pid", value: String(pid)),
                        URLQueryItem(name: "script-name", value: stikDebugScript)]
        return c.url
    }
}
