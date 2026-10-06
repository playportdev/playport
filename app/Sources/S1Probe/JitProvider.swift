// SPDX-License-Identifier: GPL-3.0-or-later
// The one call a launch makes for its JIT pool (docs/ARCHITECTURE.md, JIT
// activation). wine_host_jit_pool_acquire waits for any debugger that speaks
// the universal brk #0xf00d protocol. Where that debugger comes from is the
// player's JIT method (PlayportKit JitMethod, decision 0051):
// - built-in, the default: the app's own helper extension runs StikJIT against
//   this process with the pairing file the app holds (BuiltInJit.swift,
//   docs/DEVICE.md, "JIT activation"); no second app, no app switch;
// - StikDebug: Play opens stikdebug://enable-jit for this PID with StikDebug's
//   universal.js, and StikDebug comes back to Playport;
// - another app: Play only waits, for LiveContainer's Launch with JIT,
//   SideStore, or StikDebug started by hand.
// A debugger already attached (LiveContainer's Launch with JIT attaches before
// the app runs) is used whatever the method. No workstation attaches any more
// (decision 0011).
//
// Progress goes to the app log (AppLog) as `jit:` lines, with the app's foreground and
// background transitions while it waits.

import Foundation
import os
import PlayportKit
import UIKit
import WineHost

@_silgen_name("csops")
func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

enum JitProvider {
    struct Pool {
        let rx: UnsafeMutableRawPointer
        let rw: UnsafeMutableRawPointer
        let size: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case builtIn(BuiltInJit.Failure)
        case stikDebug(String)
        case acquire(Int32)

        var description: String {
            switch self {
            case .builtIn(let f): return "built-in JIT: \(f)"
            case .stikDebug(let why): return "StikDebug: \(why)"
            case .acquire(let rc): return "wine_host_jit_pool_acquire -> \(rc)"
            }
        }
    }

    /// LiveContainer runs Playport inside its own process and starts no app
    /// extension, so the built-in helper cannot run (StikJIT INTEGRATION.md, "LiveContainer").
    static let inLiveContainer = getenv("LC_HOME_PATH") != nil

    /// The player's choice (Settings › Setup check), or the default for where Playport runs.
    static var method: JitMethod {
        JitMethod.effective(stored: UserDefaults.standard.string(forKey: JitMethod.key), inLiveContainer: inLiveContainer)
    }

    static var debuggerAttached: Bool {
        var flags: UInt32 = 0
        return csops(getpid(), 0, &flags, MemoryLayout<UInt32>.size) == 0 && flags & 0x1000_0000 != 0
    }

    /// Blocks until the pool is blessed and the debugger has detached, or fails.
    /// Never call it on the main thread.
    static func acquire(size: Int, wait: TimeInterval) throws -> Pool {
        precondition(!Thread.isMainThread, "JitProvider.acquire blocks; call it off the main thread")
        let t0 = Date()
        let logPath = AppLog.path
        var observers: [NSObjectProtocol] = []
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        var helper: HelperOutcome?
        let method = Self.method
        log("method \(method.rawValue)" + (inLiveContainer ? " (in LiveContainer)" : ""))
        if debuggerAttached {
            log("debugger already attached; \(method.label) not asked")
        } else {
            observers = watchTransitions(since: t0)
            switch method {
            case .builtIn: helper = try requestBuiltIn(wait: wait, since: t0)
            case .stikDebug: try requestStikDebug()
            case .external:
                log(String(format: "waiting up to %.0f s for a debugger from another app (universal.js)", wait))
            }
        }
        let left = max(0, wait - Date().timeIntervalSince(t0))
        var rx: UnsafeMutableRawPointer?, rw: UnsafeMutableRawPointer?
        let rc = wine_host_jit_pool_acquire(logPath, size, Int32(left * 1000), &rx, &rw)
        log(String(format: "acquire(%d MiB) -> %d after %.2f s", size >> 20, rc,
                   Date().timeIntervalSince(t0)))
        if let helper {
            // The helper replies after its detach, which follows the pool's
            // last brk; its error explains a failed acquire. One still busy
            // after that is cancelled, so it never attaches to this launch late.
            if helper.done.wait(timeout: .now() + 10) == .timedOut {
                helper.cancelled.withLock { $0 = true }
                log("built-in helper has not replied 10 s after the acquire; cancelled")
            } else if let f = helper.failure {
                log("built-in helper: \(f)")
                if rc != 0 { throw Failure.builtIn(f) }
            } else {
                log(String(format: "built-in helper finished after %.2f s", Date().timeIntervalSince(t0)))
            }
        }
        guard rc == 0, let rx, let rw else { throw Failure.acquire(rc) }
        // StikDebug (or the player) switched apps for the attach: the runtime
        // starts once Playport is in front again, never in the background.
        if method != .builtIn { waitUntilActive(since: t0) }
        return Pool(rx: rx, rw: rw, size: size)
    }

    /// Opens StikDebug with this process's request. Opening it only says iOS
    /// took the request; the attach is what wine_host_jit_pool_acquire waits for.
    private static func requestStikDebug() throws {
        guard let bundle = Bundle.main.bundleIdentifier,
              let url = JitMethod.stikDebugURL(bundleID: bundle, pid: getpid()) else {
            throw Failure.stikDebug("no bundle identifier for the request")
        }
        log("asking StikDebug to attach to pid \(getpid()) (\(bundle), \(JitMethod.stikDebugScript))")
        let opened = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok: Bool?
        DispatchQueue.main.async {
            UIApplication.shared.open(url) { ok = $0; opened.signal() }
        }
        guard opened.wait(timeout: .now() + 10) == .success else { throw Failure.stikDebug("iOS did not open it within 10 s") }
        guard ok == true else { throw Failure.stikDebug("it is not installed") }
    }

    /// Waits up to 60 s for the app to be active.
    private static func waitUntilActive(since t0: Date) {
        let deadline = Date() + 60
        var logged = false
        while Date() < deadline {
            let active = DispatchQueue.main.sync { UIApplication.shared.applicationState == .active }
            if active { break }
            if !logged {
                log(String(format: "pool ready at +%.2f s; waiting for Playport to be in front", Date().timeIntervalSince(t0)))
                logged = true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if logged { log(String(format: "in front at +%.2f s", Date().timeIntervalSince(t0))) }
    }

    private final class HelperOutcome: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        var failure: BuiltInJit.Failure?
    }

    /// Starts the helper's enable, then waits until the debugger is attached or
    /// the helper has failed: a failure before the attach ends the launch at
    /// once instead of after the whole wait.
    private static func requestBuiltIn(wait: TimeInterval, since t0: Date) throws -> HelperOutcome {
        let outcome = HelperOutcome()
        log("asking the built-in helper to attach to pid \(getpid())")
        BuiltInJit.requestEnable(cancelled: outcome.cancelled, log: { log($0) }) { failure in
            outcome.failure = failure
            outcome.done.signal()
        }
        while !debuggerAttached && Date().timeIntervalSince(t0) < wait {
            if outcome.done.wait(timeout: .now() + 0.05) == .success {
                outcome.done.signal()   // the acquire's wait below consumes it again
                if !debuggerAttached, let f = outcome.failure {
                    log("\(f)")
                    throw Failure.builtIn(f)
                }
                break
            }
        }
        return outcome
    }

    /// The app's own view of any switch away and back while it waits.
    private static func watchTransitions(since t0: Date) -> [NSObjectProtocol] {
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "resign active"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.didBecomeActiveNotification, "active"),
        ]
        return names.map { name, label in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                log(String(format: "app %@ at +%.2f s (debugger %@)", label, Date().timeIntervalSince(t0),
                           debuggerAttached ? "attached" : "not attached"))
            }
        }
    }

    private static func log(_ line: String) { WineHostRuntime.appendLog("jit: " + line) }
}
