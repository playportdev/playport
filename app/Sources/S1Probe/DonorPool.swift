// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Graphics › Donor memory, in dev and release builds, Auto unless set (decision 0153,
// amending 0105; `pp ui --action set:donorPoolMB=auto`, `off`, or in a dev build a fixed size such
// as 4096). When on, a Play takes a pool from JIT helpers that then end (DonorRounds), after the
// JIT activation and before Wine starts, and puts it behind madeira-unix 0148's guest hooks
// (SharedMemory/GuestPool.m): Wine's fresh RW guest commits (a host page or more, 0150) are backed
// by it, charged to no process (docs/evidence/2026-10-14-donor-memory.md).
// Nothing touches the pool here: its pages are resident only once the game
// uses them, and physical RAM is the wall (docs/evidence/2026-10-14-donor-memory-scale.md),
// so Auto takes the phone's tier's pool (decision 0105) and a fixed size is capped by what
// jetsam's level says is free (PlayportKit DonorPoolSizing, PLA-351). A phone the pool is not
// offered on (DonorPoolSizing.offered) gets none.
// During play the pool stops growing when the phone runs low (watchGrowth). Any failure
// leaves the Play on ordinary memory. A release build logs the install and the pressure
// changes, not the periodic stats.
import Foundation
import PlayportKit
import SharedMemory

enum DonorPool {
    static let key = "donorPoolMB"

    private static func log(_ text: String) { WineHostRuntime.appendLog("donor-pool: " + text) }

    /// The setting as stored (Settings writes an Int; the driver's set: may write "auto"); Auto
    /// when never set (decision 0153).
    static var setting: DonorPoolSizing.Setting {
        guard let stored = UserDefaults.standard.object(forKey: key) else { return .auto }
        return DonorPoolSizing.Setting(stored: stored)
    }

    /// The phone now, for DonorPoolSizing: the app's available memory and footprint, RAM, jetsam's level.
    private static func reading() -> DonorPoolSizing.Reading {
        let app = pp_memory_snapshot()
        return DonorPoolSizing.Reading(availableMB: Int((app["available"]?.uint64Value ?? 0) >> 20),
                                       footprintMB: Int((app["footprint"]?.uint64Value ?? 0) >> 20),
                                       physicalMB: Int(ProcessInfo.processInfo.physicalMemory >> 20),
                                       level: pp_memory_system()["level"]?.intValue ?? -1)
    }

    /// What install took, for the Play's memory plan (PlayportKit MemoryPlan): the pool
    /// granted, 0 for none.
    struct Installed {
        var poolMB = 0
    }

    /// Takes and installs the pool the setting asks for; once per process (the runtime starts once).
    /// It runs after the JIT activation, seconds after the Play, so the limit read here is the one
    /// Game Mode gives (MemoryLimit; the check before Play waits for it only when it refuses).
    @discardableResult
    static func install() -> Installed {
        let setting = setting
        guard setting != .off else { return Installed() }
        let r = reading()
        var installed = Installed()
        let decision = DonorPoolSizing.decide(setting, r)
        /// The `donor-pool: auto` line: L, the tier, RAM, the donor's limit, the target and why
        /// (PLA-351).
        func autoLine(donorMB: Int?, target: Int, reason: String) {
            guard setting == .auto else { return }
            log("auto L_mb=\(r.limitMB) tier=\(r.tier.ramGB)GB tier_pool_mb=\(r.tier.poolMB) ram_mb=\(r.physicalMB) "
                + "level=\(r.level) footprint_mb=\(r.footprintMB) donor_limit_mb=\(donorMB.map(String.init) ?? "unknown") "
                + "target_mb=\(target) reason=\"\(reason)\"")
        }
        log("setting=\(setting == .auto ? "auto" : "\(setting.stored)") target_mb=\(decision.targetMB) "
            + "reason=\"\(decision.reason)\" spare_floor_mb=\(DonorPoolSizing.spareFloorMB(physicalMB: r.physicalMB)) "
            + DonorRounds.describe(pp_memory_snapshot()) + " " + DonorRounds.system())
        guard decision.targetMB > 0 else {
            // No pool; one fresh helper's available memory still records this phone's donor limit.
            let donor = setting == .auto && DonorPoolSizing.offered(physicalMB: r.physicalMB)
                ? DonorRounds.donorLimitMB { log($0) } : nil
            autoLine(donorMB: donor, target: 0, reason: decision.reason)
            log("no room for a pool; ordinary memory")
            return installed
        }
        let t0 = Date()
        // Auto takes one donor's grant at most (its limit less a margin: about 5.4 GiB on the
        // 12 GB phone); the fixed sizes keep taking more donors.
        let rounds = DonorRounds.donorRounds(mb: decision.targetMB, touch: false, gateFirstDonor: true,
                                                   donors: setting == .auto ? 1 : 8) { log($0) }
        let granted = rounds.regions.reduce(0) { $0 + Int($1.byteCount >> 20) }
        let seconds = String(format: "%.2f", Date().timeIntervalSince(t0))
        // A donor that did not end would keep its objects charged to itself: no pool then.
        guard !rounds.stop.contains("did not end"), granted > 0 else {
            autoLine(donorMB: rounds.firstDonorMB, target: 0, reason: decision.reason + "; " + rounds.stop)
            log("no pool: granted_mb=\(granted) stop=\"\(rounds.stop)\" after \(seconds) s; ordinary memory")
            return installed
        }
        autoLine(donorMB: rounds.firstDonorMB, target: decision.targetMB,
                 reason: decision.reason + (granted < decision.targetMB ? "; granted \(granted): \(rounds.stop)" : ""))
        guard pp_guest_pool_install(rounds.regions, { line in WineHostRuntime.appendLog(String(cString: line)) }) else {
            log("install refused (\(rounds.regions.count) objects); ordinary memory")
            return installed
        }
        log("installed granted_mb=\(granted) objects=\(rounds.regions.count) donors=\(rounds.pids.count) "
            + "stop=\"\(rounds.stop)\" in \(seconds) s " + DonorRounds.describe(pp_memory_snapshot())
            + " " + DonorRounds.system())
        #if !PLAYPORT_RELEASE
        startPeriodicReport()
        #endif
        watchGrowth(physicalMB: r.physicalMB)
        installed.poolMB = granted
        return installed
    }

    /// Seconds between the growth checks.
    static let growthCheckInterval = 2
    nonisolated(unsafe) private static var growthTimer: DispatchSourceTimer?

    /// Every growthCheckInterval seconds, on a utility queue, the phone's spare memory and
    /// jetsam's level decide whether the pool may grow (DonorPoolSizing.growthStop and
    /// growthResumes); a stopped pool backs new commits only with pages it has used before,
    /// so new memory is the app's own and jetsam sees it. One `donor-pool: pressure` line per
    /// change.
    private static func watchGrowth(physicalMB: Int) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var growing = true
        timer.schedule(deadline: .now() + .seconds(growthCheckInterval), repeating: .seconds(growthCheckInterval))
        timer.setEventHandler {
            let s = pp_memory_system()
            func mb(_ k: String) -> Int { Int((s[k]?.uint64Value ?? 0) >> 20) }
            let spare = mb("free") + mb("inactive") + mb("speculative") + mb("purgeable")
            let level = s["level"]?.intValue ?? -1
            let readings = "spare_mb=\(spare) level=\(level) pressure_level=\(s["pressure"]?.intValue ?? -1) "
                + "floor_mb=\(DonorPoolSizing.spareFloorMB(physicalMB: physicalMB))"
            if growing, let why = DonorPoolSizing.growthStop(spareMB: spare, level: level, physicalMB: physicalMB) {
                growing = false
                pp_guest_pool_set_growth(false)
                log("pressure: growth stopped (\(why)) " + readings)
                report("growth stop")
            } else if !growing, DonorPoolSizing.growthResumes(spareMB: spare, level: level, physicalMB: physicalMB) {
                growing = true
                pp_guest_pool_set_growth(true)
                log("pressure: growth resumed " + readings)
            }
        }
        growthTimer = timer
        timer.resume()
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

    /// One line of the pool's counters, the app's footprint and the phone's memory (at the first
    /// frame, say).
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
            "madv_zeroed_mb=\(mb("madv_zeroed_bytes"))", "madv_zero_ms_total=\(n("madv_zero_ms_total"))",
            "madv_failures=\(n("madv_failures"))", "growing=\(n("growing"))", "growth_refused=\(n("growth_refused"))",
            "app_footprint_mb=\(footprint)", "app_available_mb=\(available)",
        ]
        log("stats at \(when): " + fields.joined(separator: " ") + " " + DonorRounds.system())
    }
}
