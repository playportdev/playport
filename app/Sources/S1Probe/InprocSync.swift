// SPDX-License-Identifier: GPL-3.0-or-later
// In-process NT synchronisation: Wine's inproc_sync on Playport's ppsync
// (build/ppsync/README.md, patches/wine-unix 0045, madeira-unix 0220), on by
// default. ppsync reads PLAYPORT_PPSYNC once per session, so the app sets it
// before the runtime starts. It is launch environment the app sets, not an
// entry point (decision 0012). A title's runtime keys can still turn it off
// with inproc-sync=0.

import Foundation

enum InprocSync {
    #if !PLAYPORT_RELEASE
    /// Settings › Developer: in-process sync off from Playport's next start, for
    /// the on/off measurement (`set:dev.inprocSyncOff=true`).
    static let offKey = "dev.inprocSyncOff"
    #endif

    static var on: Bool {
        #if PLAYPORT_RELEASE
        return true
        #else
        return !UserDefaults.standard.bool(forKey: offKey)
        #endif
    }

    /// Before the runtime starts: 0 sends every wait back to the wineserver.
    static func apply(log: (String) -> Void) {
        let value = on ? "1" : "0"
        setenv("PLAYPORT_PPSYNC", value, 1)
        log("session: PLAYPORT_PPSYNC=\(value)")
    }
}
