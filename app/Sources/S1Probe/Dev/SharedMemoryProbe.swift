// SPDX-License-Identifier: GPL-3.0-or-later
// Settings' explicit, bounded experiment. This is real anonymous RAM, not a
// disk-backed file, purgable cache, or virtual-address reservation.
import Foundation
import JITHelperXPC
import SharedMemory
import SwiftUI

@MainActor
final class SharedMemoryProbe: ObservableObject {
    static let shared = SharedMemoryProbe()
    @Published private(set) var busy = false
    @Published private(set) var status = "Not measured"
    private nonisolated static let seed: UInt64 = 0x504c4159504f5254
    private nonisolated static func log(_ text: String) { WineHostRuntime.appendLog("memory-broker: " + text) }

    func run(mb: Int) async -> Bool {
        guard !busy, [64, 2048, 4096].contains(mb) else { return false }
        while BuiltInJitStatus.shared.busy { try? await Task.sleep(for: .milliseconds(100)) }
        busy = true
        status = "Measuring \(mb) MiB…"
        let result = await withCheckedContinuation { done in
            BuiltInJit.queue.async { done.resume(returning: Self.measure(mb: mb)) }
        }
        status = result.1
        busy = false
        return result.0
    }

    /// The donor variant (H1, docs/plans/2026-10-12-donor-memory.md step 1): the helper
    /// allocates and the app maps and verifies as in run(mb:), then the helper is
    /// ended while the app keeps its mappings. purgeable picks the helper's object kind.
    func runDonor(mb: Int, purgeable: Bool) async -> Bool {
        guard !busy, [2048, 4096].contains(mb) else { return false }
        while BuiltInJitStatus.shared.busy { try? await Task.sleep(for: .milliseconds(100)) }
        busy = true
        status = "Measuring donor \(Self.variant(purgeable)) \(mb) MiB…"
        let result = await withCheckedContinuation { done in
            BuiltInJit.queue.async { done.resume(returning: Self.measureDonor(mb: mb, purgeable: purgeable)) }
        }
        status = result.1
        busy = false
        return result.0
    }

    /// The totals Settings and the driver offer for runDonors (docs/plans/2026-10-12-donor-memory.md step 2).
    static let donorTotals = [6144, 8192, 10240]

    /// Several donors, one after another (step 2): each round starts a fresh helper process,
    /// takes purgeable objects up to its available memory less a margin, and ends it, until mb MiB
    /// are mapped here, a donor has nothing to give, or the phone runs low. Then the pool is
    /// verified 60 s after the last donor died, and the app takes ordinary memory up to its own
    /// limit less a margin while holding it. The pool stays mapped until the next run or the
    /// app's exit (verifyPool). True when mb MiB were mapped and verified throughout.
    func runDonors(mb: Int) async -> Bool {
        guard !busy, Self.donorTotals.contains(mb) else { return false }
        while BuiltInJitStatus.shared.busy { try? await Task.sleep(for: .milliseconds(100)) }
        busy = true
        status = "Measuring \(mb) MiB from donors…"
        let result = await withCheckedContinuation { done in
            BuiltInJit.queue.async { done.resume(returning: Self.measureDonors(mb: mb)) }
        }
        status = result.1
        busy = false
        return result.0
    }

    /// Reads the pool runDonors left mapped (after the app was in the background, say).
    func verifyPool() async -> Bool {
        guard !busy else { return false }
        busy = true
        status = "Verifying the donor pool…"
        let result = await withCheckedContinuation { done in
            BuiltInJit.queue.async { done.resume(returning: Self.verifyHeldPool()) }
        }
        status = result.1
        busy = false
        return result.0
    }

    /// How a pool at Play can give zero pages again (step 3): one donor gives 1 GiB untouched and
    /// ends; then the app touches object 1 (who pays for pages first touched after the donor died),
    /// clears it with memset, purges object 2 after touching it and touches it again (does the
    /// purge move the charge?), purges untouched object 3, and maps a range of object 4 at a fixed
    /// address as the hooks do (VM_FLAGS_OVERWRITE at an offset). The `pool-zero` lines.
    func runPoolZero() async -> Bool {
        guard !busy else { return false }
        while BuiltInJitStatus.shared.busy { try? await Task.sleep(for: .milliseconds(100)) }
        busy = true
        status = "Measuring pool zeroing…"
        let result = await withCheckedContinuation { done in
            BuiltInJit.queue.async { done.resume(returning: Self.measurePoolZero()) }
        }
        status = result.1
        busy = false
        return result.0
    }

    private nonisolated static func measurePoolZero() -> (Bool, String) {
        let chunk = UInt64(donorChunkMB) << 20
        func fp() -> Int64 { Int64(bitPattern: pp_memory_snapshot()["footprint"]?.uint64Value ?? 0) >> 20 }
        func resident(_ r: PPMemoryRegion) -> UInt64 { (r.pageCounts()["resident"]?.uint64Value ?? 0) >> 20 }
        func ms(_ t0: UInt64) -> String { String(format: "%.2f", Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6) }
        log("pool-zero start " + describe(pp_memory_snapshot()) + " " + system())
        let rounds = donorRounds(mb: 4 * donorChunkMB, touch: false, log: log)
        let objects = rounds.regions
        guard objects.count == 4 else { return (false, "Pool zero: donors gave \(objects.count) objects; \(rounds.stop)") }
        Thread.sleep(forTimeInterval: 2)
        let fp0 = fp()
        log("pool-zero untouched donors=\(rounds.pids.count) stop=\"\(rounds.stop)\" app_footprint_mb=\(fp0) "
            + "resident_mb=\(objects.map(resident))")

        // 1: first touch after the donor died, then memset.
        var t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let filled1 = pp_memory_fill(objects[0], seed + 1)
        let fillMS = ms(t0)
        let fp1 = fp()
        let clearNS = pp_memory_clear(objects[0])
        let zero1 = pp_memory_is_zero(objects[0], 0, chunk)
        log("pool-zero touch filled=\(filled1) fill_ms=\(fillMS) app_footprint_mb=\(fp1) footprint_delta_mb=\(fp1 - fp0) "
            + "resident_mb=\(resident(objects[0]))")
        log("pool-zero memset bytes_mb=\(donorChunkMB) memset_ms=\(String(format: "%.2f", Double(clearNS) / 1e6)) "
            + "reads_zero=\(zero1) resident_mb_after=\(resident(objects[0])) app_footprint_mb=\(fp())")

        // 2: purge a touched object (its own view stays mapped, as Wine's may), then touch it again.
        let filled2 = pp_memory_fill(objects[1], seed + 2)
        let fp2 = fp()
        t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let kr2 = pp_memory_empty(objects[1])
        let purgeMS = ms(t0)
        let resident2 = resident(objects[1])
        let zero2 = pp_memory_is_zero(objects[1], 0, chunk)
        let state2 = pp_memory_purgeable_state(objects[1])
        _ = pp_memory_fill(objects[1], seed + 3)
        let fp2b = fp()
        log("pool-zero purge filled=\(filled2) kr=\(kr2) purge_ms=\(purgeMS) resident_mb_after=\(resident2) reads_zero=\(zero2) "
            + "state_after=\(state2) footprint_before_mb=\(fp2) footprint_after_retouch_mb=\(fp2b) "
            + "retouch_delta_mb=\(fp2b - fp2) resident_mb_retouched=\(resident(objects[1]))")

        // 3: purge an object nothing touched.
        t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let kr3 = pp_memory_empty(objects[2])
        log("pool-zero purge_untouched kr=\(kr3) purge_ms=\(ms(t0)) reads_zero=\(pp_memory_is_zero(objects[2], 0, chunk))")

        // 4: the hooks' mapping: 64 MiB at offset 64 MiB over a fixed, ordinary reservation.
        let span: UInt64 = 64 << 20
        var address: vm_address_t = 0
        var mapped = false, inRange = false, outsideZero = false
        if vm_allocate(mach_task_self_, &address, vm_size_t(span), VM_FLAGS_ANYWHERE) == KERN_SUCCESS,
           let at = UnsafeMutableRawPointer(bitPattern: UInt(address)) {
            let kr = pp_memory_map_range(objects[3], span, span, at)
            mapped = kr == 0
            if mapped {
                pp_memory_fill_address(at, span, seed + 4)
                inRange = pp_memory_verify_range(objects[3], span, span, seed + 4)
                outsideZero = pp_memory_is_zero(objects[3], 0, span) && pp_memory_is_zero(objects[3], 2 * span, chunk - 2 * span)
            } else {
                log("pool-zero map_range kr=\(kr)")
            }
            vm_deallocate(mach_task_self_, address, vm_size_t(span))
        }
        log("pool-zero map_range mapped=\(mapped) visible_at_offset=\(inRange) rest_untouched=\(outsideZero) "
            + "resident_mb=\(resident(objects[3]))")
        let pass = filled1 && zero1 && filled2 && kr2 == 0 && zero2 && kr3 == 0 && mapped && inRange && outsideZero
        log("pool-zero RESULT \(pass ? "PASS" : "FAIL") chunk_mb=\(chunk >> 20) touch_delta_mb=\(fp1 - fp0) "
            + "memset_ms=\(String(format: "%.2f", Double(clearNS) / 1e6)) purge_ms=\(purgeMS) retouch_delta_mb=\(fp2b - fp2) "
            + describe(pp_memory_snapshot()))
        return (pass, "Pool zero \(pass ? "PASS" : "FAIL"): memset \(String(format: "%.0f", Double(clearNS) / 1e6)) ms, "
                + "purge \(purgeMS) ms, touch +\(fp1 - fp0) MiB, retouch +\(fp2b - fp2) MiB")
    }

    private nonisolated static func variant(_ purgeable: Bool) -> String { purgeable ? "purgeable" : "tagged" }

    /// The page counts of every object, summed (kr is the first failure, or 0).
    private nonisolated static func pages(_ regions: [PPMemoryRegion]) -> String {
        var kr: UInt64 = 0, resident: UInt64 = 0, dirty: UInt64 = 0, swapped: UInt64 = 0
        for region in regions {
            let counts = region.pageCounts()
            let code = counts["kr"]?.uint64Value ?? 0
            if kr == 0 { kr = code }
            resident += counts["resident"]?.uint64Value ?? 0
            dirty += counts["dirty"]?.uint64Value ?? 0
            swapped += counts["swapped"]?.uint64Value ?? 0
        }
        return "pages_kr=\(kr) pages_resident=\(resident) pages_dirty=\(dirty) pages_swapped=\(swapped)"
    }

    /// One time point: the app's footprint and limit, the objects' page counts, then a full read.
    private nonisolated static func point(_ name: String, _ regions: [PPMemoryRegion]) -> (footprint: UInt64, verified: Bool) {
        let state = pp_memory_snapshot()
        let counts = pages(regions)
        let verified = regions.allSatisfy { pp_memory_verify($0, seed + $0.token) }
        let purgeState = regions.first.map { pp_memory_purgeable_state($0) } ?? -1
        log("donor point=\(name) verify=\(verified) purgeable_state=\(purgeState) \(counts) " + describe(state))
        return ((state["footprint"] as? NSNumber)?.uint64Value ?? 0, verified)
    }

    /// Whether pid is gone: kill(pid, 0) fails with ESRCH (EPERM means it exists but is not ours).
    private nonisolated static func waitForExit(pid: Int32, seconds: Double) -> (gone: Bool, errno: Int32) {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let rc = kill(pid, 0)
            let code = rc == 0 ? 0 : errno
            if code == ESRCH || Date() >= deadline { return (code == ESRCH, code) }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private nonisolated static func measureDonor(mb: Int, purgeable: Bool) -> (Bool, String) {
        let kind = variant(purgeable)
        log("donor start variant=\(kind) requested_mb=\(mb)")
        let mapped = UInt64(mb) << 20
        var regions: [PPMemoryRegion] = []
        defer {
            regions.removeAll()
            log("donor released variant=\(kind) " + describe(pp_memory_snapshot()))
        }
        _ = point("before", regions)
        let helper: JitHelper
        do { helper = try JitHelper.start(log: log) } catch {
            log("donor failed: \(error.localizedDescription)")
            return (false, error.localizedDescription)
        }
        var stopped = false
        defer { if !stopped { helper.stop() } }
        let proxy = helper.proxy { error in log("XPC error: \(error.localizedDescription)") }
        let baseline = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var helperPID: Int32 = 0
        proxy.memoryReport(seed: seed, verify: false) { state, _ in
            helperPID = (state["pid"] as? NSNumber)?.int32Value ?? 0
            log("donor helper baseline " + describe(state)); baseline.signal()
        }
        guard baseline.wait(timeout: .now() + 10) == .success, helperPID > 0 else { return (false, "Helper report timed out") }
        if let failure = allocate(mb: mb, purgeable: purgeable, proxy: proxy, into: &regions) { return (false, failure) }
        let mappedPoint = point("after_map", regions)
        guard mappedPoint.verified else { return (false, "Data verification failed after mapping") }
        let checked = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var helperOK = false
        proxy.memoryReport(seed: seed, verify: true) { state, ok in
            helperOK = ok
            log("donor helper before_stop verify=\(ok) " + describe(state))
            checked.signal()
        }
        guard checked.wait(timeout: .now() + 90) == .success, helperOK else {
            return (false, "Helper data verification failed or timed out")
        }
        helper.stop()
        stopped = true
        let died = Date()
        let exit = waitForExit(pid: helperPID, seconds: 5)
        log("donor helper_stopped pid=\(helperPID) gone=\(exit.gone) kill0_errno=\(exit.errno) after_ms=\(Int(Date().timeIntervalSince(died) * 1000))")
        var at5 = (footprint: UInt64(0), verified: false)
        var at60 = at5
        for (name, offset) in [("dead_5s", 5.0), ("dead_60s", 60.0)] {
            let wait = offset - Date().timeIntervalSince(died)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let result = point(name, regions)
            if offset == 5 { at5 = result } else { at60 = result }
        }
        let grown = Int64(bitPattern: at60.footprint &- mappedPoint.footprint)
        let pass = exit.gone && at60.verified && grown < Int64(mapped / 10)
        let verdict = pass ? "PASS" : "FAIL"
        log("donor H1 \(verdict) variant=\(kind) mapped_mb=\(mb) helper_gone=\(exit.gone) "
            + "footprint_after_map=\(mappedPoint.footprint) footprint_5s=\(at5.footprint) footprint_60s=\(at60.footprint) "
            + "grown_60s=\(grown) limit_10pct=\(mapped / 10) verify_5s=\(at5.verified) verify_60s=\(at60.verified)")
        return (true, "Donor \(kind) \(mb) MiB: H1 \(verdict), footprint +\(grown >> 20) MiB, verified \(at60.verified)")
    }

    /// Allocates mb MiB from the helper in chunkMB objects, each fully written and verified here
    /// unless touch is false (the pool at Play: its pages stay unresident until the game uses them).
    /// lowMemory is asked before each object: its reason stops the allocation. Returns the failure, or nil.
    private nonisolated static func allocate(mb: Int, purgeable: Bool, chunkMB: Int = 64, proxy: JITHelping,
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
    // phone must have systemFloorMB free, inactive, speculative or purgeable, jetsam's level at
    // least levelFloor percent, and no pressure warning: the pool is real RAM, and stopping
    // here is cheaper than jetsam ending a process.
    private nonisolated static let donorChunkMB = 256, donorMarginMB = 512, appMarginMB = 512, maxDonors = 8
    private nonisolated static let systemFloorMB: UInt64 = 1536, levelFloor: Int64 = 15
    /// runDonors' pool, held after the probe; touched only on BuiltInJit.queue.
    private nonisolated(unsafe) static var pool: [PPMemoryRegion] = []

    private nonisolated static func mib(_ n: NSNumber?) -> UInt64 { (n?.uint64Value ?? 0) >> 20 }

    /// The phone's memory in MiB (pp_memory_system), for the log.
    nonisolated static func system() -> String {
        let s = pp_memory_system()
        let counts = ["free", "active", "inactive", "speculative", "wired", "purgeable", "compressor", "compressed_data"]
            .map { "sys_\($0)_mb=\(mib(s[$0]))" }
        let events = ["compressions", "decompressions", "swapins", "swapouts"].map { "sys_\($0)=\(s[$0]?.uint64Value ?? 0)" }
        return (["sys_kr=\(s["kr"]?.int64Value ?? -1)"] + counts + events
                + ["sys_level=\(s["level"]?.int64Value ?? -1)", "sys_pressure=\(s["pressure"]?.int64Value ?? -1)"]).joined(separator: " ")
    }

    /// Why the phone is too low on memory for another object, or nil.
    private nonisolated static func systemLow() -> String? {
        let s = pp_memory_system()
        let level = s["level"]?.int64Value ?? -1, pressure = s["pressure"]?.int64Value ?? -1
        let spare = mib(s["free"]) + mib(s["inactive"]) + mib(s["speculative"]) + mib(s["purgeable"])
        if pressure >= 2 { return "system pressure level \(pressure)" }
        if level >= 0, level < levelFloor { return "memorystatus level \(level)% < \(levelFloor)%" }
        if spare < systemFloorMB { return "system spare \(spare) MiB < \(systemFloorMB) MiB" }
        return nil
    }

    private nonisolated static func appMB(_ key: String) -> UInt64 { mib(pp_memory_snapshot()[key]) }

    /// The donor rounds of runDonors and of the pool at Play (DonorPool): each round starts a fresh
    /// helper, takes purgeable donorChunkMB objects up to its available memory less donorMarginMB
    /// (and what mb still needs), ends it and waits until it is gone; until mb MiB are mapped, a
    /// donor has nothing to give or does not end, or the phone runs low (systemLow, asked before
    /// every object only when touch: untouched objects take no RAM). touch fills and verifies
    /// every object here as it arrives.
    nonisolated static func donorRounds(mb: Int, touch: Bool, log: @escaping @Sendable (String) -> Void)
        -> (regions: [PPMemoryRegion], pids: [Int32], stop: String, lastDeath: Date) {
        var regions: [PPMemoryRegion] = []
        var pids: [Int32] = []
        var stop = "target reached"
        var lastDeath = Date()
        var mapped: Int { regions.reduce(0) { $0 + Int($1.byteCount >> 20) } }
        for round in 1...maxDonors where mapped < mb {
            if touch, let low = systemLow() { stop = "before donor \(round): \(low)"; break }
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
                                   touch: touch, lowMemory: touch ? systemLow : { nil })
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
        if mapped < mb, stop == "target reached" { stop = "\(maxDonors) donors gave too little" }
        return (regions, pids, stop, lastDeath)
    }

    private nonisolated static func measureDonors(mb: Int) -> (Bool, String) {
        pool.removeAll()
        log("donors start target_mb=\(mb) variant=purgeable chunk_mb=\(donorChunkMB) donor_margin_mb=\(donorMarginMB) "
            + describe(pp_memory_snapshot()) + " " + system())
        let (regions, pids, stop, lastDeath) = donorRounds(mb: mb, touch: true, log: log)
        let mapped = regions.reduce(0) { $0 + Int($1.byteCount >> 20) }
        let total = mapped
        log("donors rounds_done=\(pids.count) total_mb=\(total) target_mb=\(mb) stop=\"\(stop)\"")
        let wait = 60 - Date().timeIntervalSince(lastDeath)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let at60 = point("donors_dead_60s", regions)
        log("donors system_60s " + system())

        // The app's own limit, with the pool held: ordinary memory, 256 MiB at a time.
        var ordinary: [UnsafeMutableRawPointer] = []
        let step = UInt64(donorChunkMB) << 20
        var appStop = "app margin"
        while true {
            let available = appMB("available")
            if available < UInt64(donorChunkMB + appMarginMB) { appStop = "app available \(available) MiB"; break }
            if let low = systemLow() { appStop = low; break }
            guard let block = pp_memory_ordinary(step, seed &+ 0x1000 &+ UInt64(ordinary.count)) else {
                appStop = "vm_allocate refused"; break
            }
            ordinary.append(block)
            log("donors app_limit ordinary_mb=\(ordinary.count * donorChunkMB) app_footprint_mb=\(appMB("footprint")) "
                + "app_available_mb=\(appMB("available")) " + system())
        }
        let taken = ordinary.count * donorChunkMB
        log("donors app_limit_done ordinary_mb=\(taken) stop=\"\(appStop)\" " + describe(pp_memory_snapshot()) + " " + system())
        for block in ordinary { pp_memory_ordinary_release(block, step) }
        let after = point("donors_after_app_limit", regions)
        pool = regions
        let pass = total >= mb && at60.verified && after.verified
        log("donors RESULT \(pass ? "PASS" : "FAIL") target_mb=\(mb) total_mb=\(total) donors=\(pids.count) "
            + "verify_60s=\(at60.verified) verify_after_app_limit=\(after.verified) app_ordinary_mb=\(taken) "
            + "stop=\"\(stop)\" app_stop=\"\(appStop)\"")
        return (pass, "Donors \(total)/\(mb) MiB from \(pids.count), verified \(at60.verified && after.verified), "
                + "app +\(taken) MiB; \(stop)")
    }

    private nonisolated static func verifyHeldPool() -> (Bool, String) {
        guard !pool.isEmpty else { return (false, "No donor pool is held") }
        let total = pool.reduce(0) { $0 + Int($1.byteCount >> 20) }
        let result = point("pool_verify", pool)
        log("donors pool_verify total_mb=\(total) verified=\(result.verified) " + system())
        return (result.verified, "Pool \(total) MiB verified \(result.verified)")
    }

    nonisolated static func describe(_ value: Any) -> String {
        let state = value as? [String: NSNumber] ?? [:]
        return ["pid", "kr", "footprint", "resident", "compressed", "internal", "external", "available"].map {
            "\($0)=\((state[$0] as? NSNumber)?.uint64Value ?? 0)"
        }.joined(separator: " ")
    }
    private nonisolated static func measure(mb: Int) -> (Bool, String) {
        log("start requested_mb=\(mb) nofootprint_control=\(pp_memory_nofootprint_control())")
        log("host baseline " + describe(pp_memory_snapshot()))
        do {
            // The control uses the exact same object type, but owned by this app.
            try autoreleasepool {
                var error: NSError?
                guard let control = pp_memory_create(64 << 20, 0, &error), pp_memory_fill(control, seed) else {
                    throw NSError(domain: "MemoryBroker", code: 1, userInfo: [NSLocalizedDescriptionKey: "local control failed"])
                }
                log("host local_64MiB " + describe(pp_memory_snapshot()))
            }
            log("host control_released " + describe(pp_memory_snapshot()))
            let helper = try JitHelper.start(log: log)
            defer { helper.stop() }
            var regions: [PPMemoryRegion] = []
            defer { regions.removeAll() }
            let proxy = helper.proxy { error in log("XPC error: \(error.localizedDescription)") }
            let baseline = DispatchSemaphore(value: 0)
            proxy.memoryReport(seed: seed, verify: false) { state, _ in
                log("helper baseline " + describe(state)); baseline.signal()
            }
            guard baseline.wait(timeout: .now() + 10) == .success else { return (false, "Helper report timed out") }
            if let failure = allocate(mb: mb, purgeable: false, proxy: proxy, into: &regions) { return (false, failure) }
            let allocated = mb
            let checked = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var helperOK = false
            proxy.memoryReport(seed: seed, verify: true) { state, ok in
                helperOK = ok
                log("helper after_shared verify=\(ok) " + describe(state))
                checked.signal()
            }
            guard checked.wait(timeout: .now() + 90) == .success, helperOK else {
                return (false, "Helper data verification failed or timed out")
            }
            Thread.sleep(forTimeInterval: 5)
            guard regions.allSatisfy({ pp_memory_verify($0, seed + $0.token) }) else {
                return (false, "Retained data verification failed")
            }
            log("host retained_mb=\(allocated) " + describe(pp_memory_snapshot()))
            regions.removeAll()
            // Release the original helper handles too, before measuring reclamation.
            let released = DispatchSemaphore(value: 0)
            proxy.memoryRelease { state in
                log("helper released " + describe(state)); released.signal()
            }
            guard released.wait(timeout: .now() + 10) == .success else { return (false, "Release timed out") }
            log("host released " + describe(pp_memory_snapshot()))
            log("PASS verified_mb=\(allocated) both_processes=true retained_s=5")
            return (true, "Verified \(allocated) MiB shared RAM in both processes")
        } catch {
            log("failed: \(error.localizedDescription)")
            return (false, error.localizedDescription)
        }
    }
}
