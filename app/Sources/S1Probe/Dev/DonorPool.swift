// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer › Memory › Donor pool (dev builds only; decision 0012:
// `pp ui --action set:donorPoolMB=4096`). When on, a Play takes a pool of that
// size from JIT helpers that then end, after the JIT activation and before
// Wine starts, and puts it behind madeira-unix 0148's guest hooks
// (SharedMemory/GuestPool.m): Wine's fresh large RW guest commits are backed
// by it, charged to no process (docs/evidence/2026-10-14-donor-memory.md).
// Nothing touches the pool here: its pages are resident only once the game
// uses them, and physical RAM is the wall (docs/evidence/2026-10-14-donor-memory-scale.md),
// so the pool is capped by what jetsam's level says is free. Any failure
// leaves the Play on ordinary memory.
import Foundation
import SharedMemory

enum DonorPool {
    static let key = "donorPoolMB"
    /// Off and the sizes Settings offers, in MiB.
    static let sizes = [0, 2048, 4096, 6144]
    /// The pool leaves jetsam this much of the phone's memory, in percent: the stop rule of
    /// the step-2 rounds (SharedMemoryProbe.levelFloor).
    static let levelFloor = 15

    private static func log(_ text: String) { WineHostRuntime.appendLog("donor-pool: " + text) }

    /// Takes and installs the pool the setting asks for; once per process (the runtime starts once).
    static func install() {
        let asked = UserDefaults.standard.integer(forKey: key)
        guard asked > 0 else { return }
        guard sizes.contains(asked) else { log("setting \(asked) MiB is not one of \(sizes); ordinary memory"); return }
        let system = pp_memory_system()
        let level = system["level"]?.intValue ?? -1
        let physicalMB = Int(ProcessInfo.processInfo.physicalMemory >> 20)
        guard level >= 0 else { log("asked_mb=\(asked): memorystatus level unreadable; ordinary memory"); return }
        let capMB = max(0, (level - levelFloor) * physicalMB / 100) / 256 * 256
        let target = min(asked, capMB)
        log("asked_mb=\(asked) cap_mb=\(capMB) (level \(level)% less \(levelFloor)% of \(physicalMB) MiB) target_mb=\(target) "
            + SharedMemoryProbe.describe(pp_memory_snapshot()))
        guard target > 0 else { log("no room for a pool; ordinary memory"); return }
        let t0 = Date()
        let rounds = SharedMemoryProbe.donorRounds(mb: target, touch: false) { log($0) }
        let granted = rounds.regions.reduce(0) { $0 + Int($1.byteCount >> 20) }
        let seconds = String(format: "%.2f", Date().timeIntervalSince(t0))
        // A donor that did not end would keep its objects charged to itself: no pool then.
        guard !rounds.stop.contains("did not end"), granted > 0 else {
            log("no pool: granted_mb=\(granted) stop=\"\(rounds.stop)\" after \(seconds) s; ordinary memory")
            return
        }
        guard pp_guest_pool_install(rounds.regions, { line in WineHostRuntime.appendLog(String(cString: line)) }) else {
            log("install refused (\(rounds.regions.count) objects); ordinary memory")
            return
        }
        log("installed granted_mb=\(granted) objects=\(rounds.regions.count) donors=\(rounds.pids.count) "
            + "stop=\"\(rounds.stop)\" in \(seconds) s " + SharedMemoryProbe.describe(pp_memory_snapshot())
            + " " + SharedMemoryProbe.system())
        startPeriodicReport()
    }

    /// Seconds between the stats lines while the pool is installed (the title runs in this
    /// process, which ends with it: decision 0029).
    static let reportInterval = 30
    nonisolated(unsafe) private static var reportTimer: DispatchSourceTimer?

    /// A stats line every reportInterval seconds from the install on, on a utility queue: it
    /// takes only the pool's own lock to copy its counters, never Wine's.
    private static func startPeriodicReport() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var ticks = 0
        timer.schedule(deadline: .now() + .seconds(reportInterval), repeating: .seconds(reportInterval))
        timer.setEventHandler {
            ticks += 1
            report("install+\(ticks * reportInterval)s")
        }
        reportTimer = timer
        timer.resume()
    }

    /// report at the first frame, and 8 s after it (inside a `--until first-frame+10` run);
    /// the periodic lines (startPeriodicReport) follow longer runs.
    static func reportFirstFrame() {
        report("first frame")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { report("first frame+8s") }
    }

    /// One line of the pool's counters and the app's footprint (at the first frame, say).
    static func report(_ when: String) {
        let s = pp_guest_pool_stats()
        guard (s["objects"]?.intValue ?? 0) > 0 else { return }
        func mb(_ k: String) -> UInt64 { (s[k]?.uint64Value ?? 0) >> 20 }
        func n(_ k: String) -> UInt64 { s[k]?.uint64Value ?? 0 }
        let app = pp_memory_snapshot()
        let footprint = (app["footprint"]?.uint64Value ?? 0) >> 20, available = (app["available"]?.uint64Value ?? 0) >> 20
        let fields: [String] = [
            "pool_mb=\(mb("bytes"))", "served=\(n("served"))", "served_mb=\(mb("served_bytes"))", "live_mb=\(mb("live"))",
            "resident_mb=\(mb("resident_bytes"))", "compressed_mb=\(mb("swapped_bytes"))", "leases=\(n("leases"))",
            "released_mb=\(mb("released_bytes"))", "detaches=\(n("detaches"))", "detached_mb=\(mb("detached_bytes"))",
            "resets=\(n("resets"))", "retired=\(n("retired"))", "refused=\(n("refused"))",
            "unmatched_mb=\(mb("unmatched_bytes"))", "map_failures=\(n("map_failures"))",
            "purge_ms_total=\(n("purge_ms_total"))", "purge_ms_max=\(n("purge_ms_max"))",
            "stale_mb=\(mb("stale_bytes"))", "reuses=\(n("reuses"))", "zeroed_mb=\(mb("zeroed_bytes"))",
            "zero_ms_total=\(n("zero_ms_total"))", "zero_us_max=\(n("zero_us_max"))",
            "purges_pending=\(n("purges_pending"))",
            "app_footprint_mb=\(footprint)", "app_available_mb=\(available)",
        ]
        log("stats at \(when): " + fields.joined(separator: " "))
    }
}
