// SPDX-License-Identifier: GPL-3.0-or-later
// The donor pool's rounds (decision 0153: dev and release builds; DonorPool): JIT helpers
// that allocate purgeable RAM objects, hand them over as Mach send rights, then end, leaving
// the objects charged to no process (docs/evidence/2026-10-14-donor-memory.md). Settings ›
// Developer's memory probes (Dev/SharedMemoryProbe.swift) use the same rounds.
import Foundation
import JITHelperXPC
import PlayportKit
import SharedMemory

enum DonorRounds {
    /// The objects' fill pattern, as the helper's own verification reads it.
    static let seed: UInt64 = 0x504c4159504f5254
    static func log(_ text: String) { WineHostRuntime.appendLog("memory-broker: " + text) }

    /// Whether pid is gone: kill(pid, 0) fails with ESRCH (EPERM means it exists but is not ours).
    static func waitForExit(pid: Int32, seconds: Double) -> (gone: Bool, errno: Int32) {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let rc = kill(pid, 0)
            let code = rc == 0 ? 0 : errno
            if code == ESRCH || Date() >= deadline { return (code == ESRCH, code) }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }


    /// Allocates mb MiB from the helper in chunkMB objects, each fully written and verified here
    /// unless touch is false (the pool at Play: its pages stay unresident until the game uses them).
    /// lowMemory is asked before each object: its reason stops the allocation. Returns the failure, or nil.
    static func allocate(mb: Int, purgeable: Bool, chunkMB: Int = 64, proxy: JITHelping,
                                             into regions: inout [PPMemoryRegion], touch: Bool = true,
                                             lowMemory: () -> String? = { nil }) -> String? {
        var allocated = 0
        while allocated < mb {
            if let low = lowMemory() {
                log("allocation stopped at \(allocated) MiB: \(low)")
                return "Allocated \(allocated) MiB; stopped: \(low)"
            }
            let chunk = min(chunkMB, mb - allocated)
            let token = UInt64(regions.count + 1)
            let replied = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var received: PPMemoryRegion?
            nonisolated(unsafe) var failure: String?
            proxy.memoryAllocate(bytes: UInt64(chunk) << 20, token: token, purgeable: purgeable) { region, _, why in
                received = region; failure = why; replied.signal()
            }
            guard replied.wait(timeout: .now() + 10) == .success, let region = received else {
                log("allocation refused at \(allocated) MiB: \(failure ?? "timeout")")
                return "Allocated \(allocated) MiB; \(failure ?? "helper timeout")"
            }
            regions.append(region)
            allocated += chunk
            guard touch else { continue }
            guard pp_memory_fill(region, seed + token), pp_memory_verify(region, seed + token) else {
                return "Host data verification failed"
            }
            if allocated % 512 == 0 || allocated == mb {
                log("host touched_mb=\(allocated) " + describe(pp_memory_snapshot()))
                log("object token=\(token) pages=\(region.pageCounts())")
            }
        }
        return nil
    }


    // runDonors' rule (step 2): a donor gives its available memory less donorMarginMB, in
    // donorChunkMB objects; the app keeps appMarginMB of its own limit. Before every object the
    // phone must have systemFloorMB free, inactive, speculative or purgeable (a share of its
    // RAM, DonorPoolSizing.spareFloorMB), jetsam's level at least levelFloor percent, and no
    // pressure warning: the pool is real RAM, and stopping here is cheaper than jetsam ending a
    // process.
    static let donorChunkMB = 256, donorMarginMB = 512, appMarginMB = 512, maxDonors = 8
    static let systemFloorMB = UInt64(DonorPoolSizing.spareFloorMB(
        physicalMB: Int(ProcessInfo.processInfo.physicalMemory >> 20)))
    static let levelFloor = Int64(DonorPoolSizing.levelFloor)

    static func mib(_ n: NSNumber?) -> UInt64 { (n?.uint64Value ?? 0) >> 20 }

    /// The phone's memory in MiB (pp_memory_system), for the log.
    static func system() -> String {
        let s = pp_memory_system()
        let counts = ["free", "active", "inactive", "speculative", "wired", "purgeable", "compressor", "compressed_data"]
            .map { "sys_\($0)_mb=\(mib(s[$0]))" }
        let events = ["compressions", "decompressions", "swapins", "swapouts"].map { "sys_\($0)=\(s[$0]?.uint64Value ?? 0)" }
        return (["sys_kr=\(s["kr"]?.int64Value ?? -1)"] + counts + events
                + ["sys_level=\(s["level"]?.int64Value ?? -1)", "sys_pressure=\(s["pressure"]?.int64Value ?? -1)"]).joined(separator: " ")
    }

    /// Why the phone is too low on memory for another object, or nil.
    static func systemLow() -> String? {
        let s = pp_memory_system()
        let level = s["level"]?.int64Value ?? -1, pressure = s["pressure"]?.int64Value ?? -1
        let spare = mib(s["free"]) + mib(s["inactive"]) + mib(s["speculative"]) + mib(s["purgeable"])
        if pressure >= 2 { return "system pressure level \(pressure)" }
        if level >= 0, level < levelFloor { return "memorystatus level \(level)% < \(levelFloor)%" }
        if spare < systemFloorMB { return "system spare \(spare) MiB < \(systemFloorMB) MiB" }
        return nil
    }

    static func appMB(_ key: String) -> UInt64 { mib(pp_memory_snapshot()[key]) }

    /// The donor rounds of runDonors and of the pool at Play (DonorPool): each round starts a fresh
    /// helper, takes purgeable donorChunkMB objects up to its available memory less donorMarginMB
    /// (and what mb still needs), ends it and waits until it is gone; until mb MiB are mapped, a
    /// donor has nothing to give or does not end, or the phone runs low (systemLow, asked before
    /// every round and object; at Play too, though untouched objects take no RAM, PLA-351).
    /// gateFirstDonor: no pool when the first donor's own limit is under
    /// DonorPoolSizing.minimumDonorMB. touch fills and verifies every object here as it arrives.
    /// firstDonorMB is the first donor's available memory, or nil when none reported. At most
    /// `donors` rounds (Auto takes one: its pool is capped by the first donor's grant).
    static func donorRounds(mb: Int, touch: Bool, gateFirstDonor: Bool = false, donors: Int = maxDonors,
                                        log: @escaping @Sendable (String) -> Void)
        -> (regions: [PPMemoryRegion], pids: [Int32], stop: String, lastDeath: Date, firstDonorMB: Int?) {
        var firstDonorMB: Int?
        var regions: [PPMemoryRegion] = []
        var pids: [Int32] = []
        var stop = "target reached"
        var lastDeath = Date()
        var mapped: Int { regions.reduce(0) { $0 + Int($1.byteCount >> 20) } }
        let rounds = max(1, min(donors, maxDonors))
        for round in 1...rounds where mapped < mb {
            if let low = systemLow() { stop = "before donor \(round): \(low)"; break }
            let helper: JitHelper
            do { helper = try JitHelper.start(log: log) } catch {
                stop = "donor \(round) did not start: \(error.localizedDescription)"; break
            }
            let proxy = helper.proxy { error in log("XPC error: \(error.localizedDescription)") }
            let baseline = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var report: NSDictionary = [:]
            proxy.memoryReport(seed: seed, verify: false) { state, _ in report = state; baseline.signal() }
            guard baseline.wait(timeout: .now() + 10) == .success,
                  let pid = (report["pid"] as? NSNumber)?.int32Value, pid > 0 else {
                helper.stop()
                stop = "donor \(round) report timed out"; break
            }
            let available = Int(((report["available"] as? NSNumber)?.uint64Value ?? 0) >> 20)
            if round == 1 { firstDonorMB = available }
            if round == 1, gateFirstDonor, let small = DonorPoolSizing.donorTooSmall(availableMB: available) {
                log("donors round=1 donor_pid=\(pid) donor_available_mb=\(available)")
                helper.stop()
                _ = waitForExit(pid: pid, seconds: 5)
                stop = "donor 1: \(small)"; break
            }
            let grant = min(mb - mapped, max(0, available - donorMarginMB) / donorChunkMB * donorChunkMB)
            log("donors round=\(round) donor_pid=\(pid) fresh=\(!pids.contains(pid)) donor_available_mb=\(available) "
                + "donor_footprint_mb=\(mib(report["footprint"] as? NSNumber)) grant_mb=\(grant)")
            pids.append(pid)
            guard grant > 0 else {
                helper.stop()
                stop = "donor \(round) has nothing to give (\(available) MiB available)"; break
            }
            let before = mapped
            let failure = allocate(mb: grant, purgeable: true, chunkMB: donorChunkMB, proxy: proxy, into: &regions,
                                   touch: touch, lowMemory: systemLow)
            helper.stop()
            let died = Date()
            let exit = waitForExit(pid: pid, seconds: 5)
            lastDeath = Date()
            log("donors round=\(round) donor_pid=\(pid) granted_mb=\(mapped - before) total_mb=\(mapped) gone=\(exit.gone) "
                + "kill0_errno=\(exit.errno) after_ms=\(Int(lastDeath.timeIntervalSince(died) * 1000)) "
                + "app_footprint_mb=\(appMB("footprint")) app_available_mb=\(appMB("available")) " + system())
            if let failure { stop = "donor \(round): \(failure)"; break }
            guard exit.gone else { stop = "donor \(round) (pid \(pid)) did not end"; break }
        }
        if mapped < mb, stop == "target reached" { stop = rounds == 1 ? "one donor's grant" : "\(rounds) donors gave too little" }
        return (regions, pids, stop, lastDeath, firstDonorMB)
    }

    /// A fresh helper's available memory in MiB (it maps nothing), or nil: the donor limit the
    /// pool's auto line records when it takes no pool.
    static func donorLimitMB(log: @escaping @Sendable (String) -> Void) -> Int? {
        guard let helper = try? JitHelper.start(log: log) else { return nil }
        let proxy = helper.proxy { error in log("XPC error: \(error.localizedDescription)") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var report: NSDictionary = [:]
        proxy.memoryReport(seed: seed, verify: false) { state, _ in report = state; done.signal() }
        let answered = done.wait(timeout: .now() + 10) == .success
        helper.stop()
        let pid = (report["pid"] as? NSNumber)?.int32Value ?? 0
        if pid > 0 { _ = waitForExit(pid: pid, seconds: 5) }
        guard answered, pid > 0 else { return nil }
        return Int(((report["available"] as? NSNumber)?.uint64Value ?? 0) >> 20)
    }


    static func describe(_ value: Any) -> String {
        let state = value as? [String: NSNumber] ?? [:]
        return ["pid", "kr", "footprint", "resident", "compressed", "internal", "external", "available"].map {
            "\($0)=\((state[$0] as? NSNumber)?.uint64Value ?? 0)"
        }.joined(separator: " ")
    }
}
