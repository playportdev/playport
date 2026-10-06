// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira's fastsync, ported as patches/wine-unix 0015-0017 and
// madeira-unix 0081 (decision 0054): in-process event and semaphore cells a
// wait spins and parks on for at most 2 ms before it goes to the wineserver.
// Wine reads MADEIRA_FASTSYNC once per session, so the app sets it before the
// runtime starts, as Madeira's app does (its WineProcessBridge.m). It is
// launch environment the app sets, not an entry point (decision 0012).
// Madsync stays off (decision 0023).

import Foundation

enum Fastsync {
    #if !PLAYPORT_RELEASE
    /// Settings › Developer: fastsync off from Playport's next start, for the
    /// on/off measurement (`set:dev.fastsyncOff=true`).
    static let offKey = "dev.fastsyncOff"
    #endif

    static var on: Bool {
        #if PLAYPORT_RELEASE
        return true
        #else
        return !UserDefaults.standard.bool(forKey: offKey)
        #endif
    }

    /// Before the runtime starts: `auto` arms the in-process wake path once a
    /// process does more than 20000 event, semaphore and wait operations in 10 s.
    static func apply(log: (String) -> Void) {
        let value = on ? "auto" : "0"
        setenv("MADEIRA_FASTSYNC", value, 1)
        log("session: MADEIRA_FASTSYNC=\(value)")
    }
}
