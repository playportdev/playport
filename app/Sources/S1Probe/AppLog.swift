// SPDX-License-Identifier: GPL-3.0-or-later
// The app's one log file, in the container's Documents (which the Files app
// does not show). Everything writes to it: the app's own lines (this file),
// HostIO's (host_log.c), and once wine_host_init has pointed stderr at it,
// the runtime's.
//
//   dev      s1-host.log, appended across launches; the workstation drivers
//            move it aside before a launch, pull it and parse it
//            (docs/DEVICE.md). Bounded only against a runaway: at launch a
//            log over WINE_HOST_DEV_LOG_CAP (256 MiB, log_cap.h) becomes
//            s1-host.prev.log; within a session the runtime's lines past
//            the cap are counted, not written (wine_host.c's log_cap_thread),
//            while the app's own lines go on to twice the cap.
//   release  playport.log (decision 0009). At launch a log over half the
//            limit becomes playport.previous.log, replacing the older one;
//            within a session the log stops at the limit: these appends and
//            host_log.c's check the size, and wine_host.c's watchdog cuts
//            the runtime's stderr off (wine_host_set_log_limit). So the two
//            files hold at most twice the limit.

import Foundation
import HostIO
import WineHost

enum AppLog {
    #if PLAYPORT_RELEASE
    static let name = "playport.log"
    static let previousName = "playport.previous.log"
    /// The most a session writes, runtime included.
    static let limit = 4 << 20
    #else
    static let name = "s1-host.log"
    static let previousName = "s1-host.prev.log"
    static let limit = WINE_HOST_DEV_LOG_CAP
    #endif

    /// Fixed at first use, in the app's init: wine_host_init later points HOME
    /// at the prefix, and FileManager's Documents with it.
    nonisolated static let url = WineHostRuntime.documents.appendingPathComponent(name)
    nonisolated static var path: String { url.path }

    private static let lock = NSLock()

    /// Once, in the app's init, before anything is logged.
    static func start() {
        #if PLAYPORT_RELEASE
        rotate(over: limit / 2)
        host_log_set_limit(limit)
        wine_host_set_log_limit(limit)
        #else
        rotate(over: limit)
        host_log_set_limit(2 * limit)
        #endif
    }

    /// At launch, a log over `bytes` becomes the previous log, replacing it
    /// (host_log_rotate, host_log.c).
    private static func rotate(over bytes: Int) {
        let previous = url.deletingLastPathComponent().appendingPathComponent(previousName)
        host_log_rotate(path, previous.path, bytes)
    }

    /// One line, from any thread. Before wine_host_init this is the only
    /// writer; after it, the runtime appends to the same file.
    /// Through host_log (host_log.c): once wine_host_init has made fd 2 the log,
    /// a line written to the file directly from Swift can be lost (the game's
    /// `first frame` mark was); through stderr it arrives. The release limit is
    /// host_log's (host_log_set_limit in start()).
    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        host_log(path, line)
    }
}
