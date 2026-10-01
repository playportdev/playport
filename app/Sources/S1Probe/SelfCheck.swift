// SPDX-License-Identifier: GPL-3.0-or-later
// The runtime's start-up self-check (selfcheck.h, docs/ARCHITECTURE.md,
// "Start-up self-check"). A launch runs it twice: before the JIT is asked for
// (the host page size, the TEB's TSD slot mechanism), so a phone that breaks
// either is refused with nothing spent, and again once the pool is blessed
// (its placement, and a word written through the RW alias read back through
// RX), before the runtime starts on it. Each verdict is one
// `title: selfcheck: ...` line in the log, which `pp ui` puts in its result event.

import Foundation
import WineHost

enum SelfCheck {
    struct Verdict {
        /// "ok", or the assumption that failed ("page", "tsd", "pool-high", "alias", ...).
        let name: String
        /// The line the log gets: the verdict, then page=, tsd=, pool= and rw=.
        let report: String
        var ok: Bool { name == "ok" }
    }

    static func run(pool: JitProvider.Pool? = nil) -> Verdict {
        var buf = [CChar](repeating: 0, count: 512)
        let rc = wine_host_selfcheck(pool?.rx, pool?.rw, pool?.size ?? 0, &buf, buf.count)
        let report = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        WineHostRuntime.appendLog("title: selfcheck: " + report)
        return Verdict(name: String(cString: selfcheck_name(rc)), report: report)
    }

    /// The failed assumption a result line names (`selfcheck=<name>`), if any.
    static func failure(in line: String) -> String? {
        guard let r = line.range(of: "selfcheck=") else { return nil }
        return String(line[r.upperBound...].prefix { !$0.isWhitespace && $0 != ";" && $0 != "," })
    }

    /// What the alert says for a launch the self-check stopped (LaunchMessage).
    static func explanation(_ name: String) -> String {
        let what: String = switch name {
        case "page": "this device's memory page size is not the 16 KiB the JIT setup uses"
        case "tsd": "this iOS version keeps thread data where the runtime cannot find it"
        case "alias": "the JIT memory's writable view does not show in its executable view"
        default: "the JIT memory was placed where the runtime cannot use it"
        }
        return "Playport's start-up check failed: \(what). The log's selfcheck line has the details."
    }
}
