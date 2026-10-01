// SPDX-License-Identifier: GPL-3.0-or-later
// The app's one log file, in the container's Documents (which the Files app
// does not show). Everything writes to it: the app's own lines (this file),
// HostIO's (host_log.c), and once wine_host_init has pointed stderr at it,
// the runtime's.
//
//   dev      s1-host.log, appended across launches with no size limit; the
//            workstation drivers pull it and parse it (docs/DEVICE.md)
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
    #endif

    /// Fixed at first use, in the app's init: wine_host_init later points HOME
    /// at the prefix, and FileManager's Documents with it.
    nonisolated static let url = WineHostRuntime.documents.appendingPathComponent(name)
    nonisolated static var path: String { url.path }

    private static let lock = NSLock()

    /// Once, in the app's init, before anything is logged.
    static func start() {
        #if PLAYPORT_RELEASE
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > limit / 2 {
            let previous = url.deletingLastPathComponent().appendingPathComponent(previousName)
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        host_log_set_limit(limit)
        wine_host_set_log_limit(limit)
        #endif
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
