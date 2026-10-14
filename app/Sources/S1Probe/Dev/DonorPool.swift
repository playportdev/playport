// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer › Memory › Donor pool (dev builds only; decision 0012:
// `pp ui --action set:donorPoolMB=auto`, or a fixed size such as 4096). When on, a Play
// takes a pool from JIT helpers that then end, after the JIT activation and before
// Wine starts, and puts it behind madeira-unix 0148's guest hooks
// (SharedMemory/GuestPool.m): Wine's fresh RW guest commits (a host page or more, 0150) are backed
// by it, charged to no process (docs/evidence/2026-10-14-donor-memory.md).
// Nothing touches the pool here: its pages are resident only once the game
// uses them, and physical RAM is the wall (docs/evidence/2026-10-14-donor-memory-scale.md),
// so Auto asks for what the phone can give beyond the app's own limit, and a fixed size
// is capped by what jetsam's level says is free (PlayportKit DonorPoolSizing, PLA-351).
// Any failure leaves the Play on ordinary memory.
import Foundation
import PlayportKit
import SharedMemory

enum DonorPool {
    static let key = "donorPoolMB"

    private static func log(_ text: String) { WineHostRuntime.appendLog("donor-pool: " + text) }

    /// The setting as stored (Settings writes an Int; the driver's set: may write "auto").
    static var setting: DonorPoolSizing.Setting { DonorPoolSizing.Setting(stored: UserDefaults.standard.object(forKey: key)) }

    /// The phone now, for DonorPoolSizing: the app's available memory and footprint, RAM, jetsam's level.
    private static func reading() -> DonorPoolSizing.Reading {
        let app = pp_memory_snapshot()
        return DonorPoolSizing.Reading(availableMB: Int((app["available"]?.uint64Value ?? 0) >> 20),
                                       footprintMB: Int((app["footprint"]?.uint64Value ?? 0) >> 20),
                                       physicalMB: Int(ProcessInfo.processInfo.physicalMemory >> 20),
                                       level: pp_memory_system()["level"]?.intValue ?? -1)
    }

    /// Takes and installs the pool the setting asks for; once per process (the runtime starts once).
    /// It runs after the JIT activation, seconds after the Play, so the limit read here is the one
    /// Game Mode gives (MemoryLimit; the check before Play waits for it only when it refuses).
    static func install() {
        let setting = setting
        guard setting != .off else { return }
        let r = reading()
        let decision = DonorPoolSizing.decide(setting, r)
        /// The `donor-pool: auto` line: L, P, RAM, the donor's limit, the target and why (PLA-351).
        func autoLine(donorMB: Int?, target: Int, reason: String) {
            guard setting == .auto else { return }
            log("auto L_mb=\(r.limitMB) P_mb=\(r.phoneMB) ram_mb=\(r.physicalMB) level=\(r.level) "
                + "footprint_mb=\(r.footprintMB) donor_limit_mb=\(donorMB.map(String.init) ?? "unknown") "
                + "target_mb=\(target) reason=\"\(reason)\"")
        }
        log("setting=\(setting == .auto ? "auto" : "\(setting.stored)") target_mb=\(decision.targetMB) "
            + "reason=\"\(decision.reason)\" spare_floor_mb=\(DonorPoolSizing.spareFloorMB(physicalMB: r.physicalMB)) "
            + SharedMemoryProbe.describe(pp_memory_snapshot()) + " " + SharedMemoryProbe.system())
        guard decision.targetMB > 0 else {
            // No pool; one fresh helper's available memory still records this phone's donor limit.
            let donor = setting == .auto && DonorPoolSizing.offered(physicalMB: r.physicalMB)
                ? SharedMemoryProbe.donorLimitMB { log($0) } : nil
            autoLine(donorMB: donor, target: 0, reason: decision.reason)
            log("no room for a pool; ordinary memory")
            return
        }
        let t0 = Date()
        let rounds = SharedMemoryProbe.donorRounds(mb: decision.targetMB, touch: false, gateFirstDonor: true) { log($0) }
        let granted = rounds.regions.reduce(0) { $0 + Int($1.byteCount >> 20) }
        let seconds = String(format: "%.2f", Date().timeIntervalSince(t0))
        // A donor that did not end would keep its objects charged to itself: no pool then.
        guard !rounds.stop.contains("did not end"), granted > 0 else {
            autoLine(donorMB: rounds.firstDonorMB, target: 0, reason: decision.reason + "; " + rounds.stop)
            log("no pool: granted_mb=\(granted) stop=\"\(rounds.stop)\" after \(seconds) s; ordinary memory")
            return
        }
        autoLine(donorMB: rounds.firstDonorMB, target: decision.targetMB, reason: decision.reason)
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
            "resident_mb=\(mb("resident_bytes"))", "compressed_mb=\(mb("swapped_bytes"))",
            "released_mb=\(mb("released_bytes"))", "detaches=\(n("detaches"))", "detached_mb=\(mb("detached_bytes"))",
            "resets=\(n("resets"))", "retired=\(n("retired"))", "refused=\(n("refused"))",
            "unmatched_mb=\(mb("unmatched_bytes"))", "map_failures=\(n("map_failures"))",
            "purge_ms_total=\(n("purge_ms_total"))", "purge_ms_max=\(n("purge_ms_max"))",
            "stale_mb=\(mb("stale_bytes"))", "reuses=\(n("reuses"))", "zeroed_mb=\(mb("zeroed_bytes"))",
            "zero_ms_total=\(n("zero_ms_total"))", "zero_us_max=\(n("zero_us_max"))",
            "purges_pending=\(n("purges_pending"))", "back_ms_total=\(n("back_ms_total"))",
            "back_us_max=\(n("back_us_max"))", "releases=\(n("releases"))",
            "release_ms_total=\(n("release_ms_total"))", "release_us_max=\(n("release_us_max"))",
            "app_footprint_mb=\(footprint)", "app_available_mb=\(available)",
        ]
        log("stats at \(when): " + fields.joined(separator: " "))
    }
}
