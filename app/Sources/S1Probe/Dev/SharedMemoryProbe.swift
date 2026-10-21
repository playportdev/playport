// SPDX-License-Identifier: GPL-3.0-or-later
// Settings' explicit, bounded experiment. This is real anonymous RAM, not a
// disk-backed file, purgable cache, or virtual-address reservation.
import Foundation
import JITHelperXPC
import Metal
import PlayportKit
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

    /// The donor variant (H1, docs/plans/finished.md#guest-ram-from-donor-processes step 1): the helper
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

    /// The totals Settings and the driver offer for runDonors (docs/plans/finished.md#guest-ram-from-donor-processes step 2).
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
    /// address as the hooks do (VM_FLAGS_OVERWRITE at an offset), and zeroes 64 MiB parts of
    /// object 1, refilled, four ways (memset, MADV_ZERO, MADV_FREE_REUSABLE plus memset, and
    /// MADV_FREE_REUSABLE alone). The
    /// `pool-zero` lines.
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

    /// Graphics memory in the pool (step 5, PLA-354): one donor gives 1 GiB untouched and ends;
    /// the app makes four shared-storage Metal buffers with no copy over the objects' own views,
    /// writes object 1 on the CPU, then on the GPU copies buffer 1 to buffer 2 and fills buffers 3
    /// and 4, reads them back on the CPU, does the same with a 64 MiB buffer over a range of
    /// object 4 mapped at a fixed address (as the guest hooks map), and ends with the control:
    /// four ordinary shared buffers of the same size, filled on the GPU. Each step logs the
    /// footprint, the graphics ledgers and Metal's allocated size (`pool-gpu` lines).
    func runPoolGPU() async -> Bool {
        guard !busy else { return false }
        while BuiltInJitStatus.shared.busy { try? await Task.sleep(for: .milliseconds(100)) }
        busy = true
        status = "Measuring Metal buffers in the pool…"
        let result = await withCheckedContinuation { done in
            BuiltInJit.queue.async { done.resume(returning: Self.measurePoolGPU()) }
        }
        status = result.1
        busy = false
        return result.0
    }

    private nonisolated static func measurePoolGPU() -> (Bool, String) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            log("pool-gpu RESULT FAIL no Metal device")
            return (false, "Pool GPU: no Metal device")
        }
        log("pool-gpu start " + DonorRounds.describe(pp_memory_snapshot()) + " " + DonorRounds.system())
        let rounds = DonorRounds.donorRounds(mb: 4 * DonorRounds.donorChunkMB, touch: false, donors: 1, log: log)
        let objects = rounds.regions
        guard objects.count == 4 else {
            log("pool-gpu RESULT FAIL donors gave \(objects.count) objects: \(rounds.stop)")
            return (false, "Pool GPU: donors gave \(objects.count) objects; \(rounds.stop)")
        }
        let result = poolGPU(device: device, queue: queue, objects: objects, donors: rounds.pids.count)
        // Every buffer over the objects ended inside poolGPU, before the objects unmap here.
        withExtendedLifetime(objects) {}
        return result
    }

    /// measurePoolGPU's buffers and readings; the objects outlive every buffer made here.
    private nonisolated static func poolGPU(device: MTLDevice, queue: MTLCommandQueue, objects: [PPMemoryRegion],
                                            donors: Int) -> (Bool, String) {
        let chunk = DonorRounds.donorChunkMB << 20
        struct Reading { var footprint: Int64; var graphics: Int64; var graphicsNoFootprint: Int64; var metal: Int64 }
        func read(_ name: String) -> Reading {
            Thread.sleep(forTimeInterval: 1)
            let s = pp_memory_snapshot()
            func mb(_ k: String) -> Int64 { Int64(bitPattern: s[k]?.uint64Value ?? 0) >> 20 }
            let r = Reading(footprint: mb("footprint"), graphics: mb("graphics"),
                            graphicsNoFootprint: mb("graphics_nofootprint"), metal: Int64(device.currentAllocatedSize >> 20))
            log("pool-gpu point=\(name) app_footprint_mb=\(r.footprint) graphics_mb=\(r.graphics) "
                + "graphics_nofootprint_mb=\(r.graphicsNoFootprint) metal_allocated_mb=\(r.metal) "
                + "purgeable_nonvolatile_mb=\(mb("purgeable_nonvolatile")) available_mb=\(mb("available")) "
                + "resident_mb=\(objects.map { ($0.pageCounts()["resident"]?.uint64Value ?? 0) >> 20 })")
            return r
        }
        /// One blit pass; whether it completed, with its error for the log.
        func blit(_ name: String, _ encode: (MTLBlitCommandEncoder) -> Void) -> Bool {
            autoreleasepool {
                guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeBlitCommandEncoder() else {
                    log("pool-gpu blit=\(name) no command buffer")
                    return false
                }
                let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                encode(encoder)
                encoder.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
                let ms = String(format: "%.2f", Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6)
                log("pool-gpu blit=\(name) status=\(commands.status.rawValue) ms=\(ms) "
                    + "error=\(commands.error.map { String(describing: $0) } ?? "none")")
                return commands.status == .completed
            }
        }
        log("pool-gpu donors=\(donors) objects=\(objects.count) chunk_mb=\(DonorRounds.donorChunkMB) page=\(getpagesize())")
        let base = read("untouched")
        var views: [UnsafeMutableRawPointer] = []
        for object in objects {
            guard let view = try? object.map() else {
                log("pool-gpu RESULT FAIL an object did not map")
                return (false, "Pool GPU: an object did not map")
            }
            views.append(view)
        }
        _ = read("mapped")

        // The pool's buffers: no copy over each object's own view.
        var buffers = views.map {
            device.makeBuffer(bytesNoCopy: $0, length: chunk, options: .storageModeShared, deallocator: nil)
        }
        log("pool-gpu nocopy_created=\(buffers.filter { $0 != nil }.count)/\(buffers.count) "
            + "allocated_mb=\(buffers.map { ($0?.allocatedSize ?? 0) >> 20 }) "
            + "contents_match=\(zip(buffers, views).allSatisfy { $0?.contents() == $1 })")
        guard buffers.allSatisfy({ $0 != nil }) else {
            log("pool-gpu RESULT FAIL Metal refused a no-copy buffer over a pool object")
            return (false, "Pool GPU: Metal refused a no-copy buffer over pool memory")
        }
        var pool = buffers.map { $0! }
        let created = read("nocopy_created")
        let filled = pp_memory_fill(objects[0], seed + 1)
        let cpu = read("cpu_filled_object1")
        let gpuOK = blit("pool") { e in
            e.copy(from: pool[0], sourceOffset: 0, to: pool[1], destinationOffset: 0, size: chunk)
            e.fill(buffer: pool[2], range: 0..<chunk, value: 0x5A)
            e.fill(buffer: pool[3], range: 0..<chunk, value: 0xC3)
        }
        let gpu = read("gpu_written")
        let copied = pp_memory_verify(objects[1], seed + 1)
        let fill3 = pp_memory_reads_byte(views[2], UInt64(chunk), 0x5A)
        let fill4 = pp_memory_reads_byte(views[3], UInt64(chunk), 0xC3)
        log("pool-gpu read cpu_filled=\(filled) gpu_completed=\(gpuOK) copy_reads_back=\(copied) "
            + "fill_reads_back=\(fill3 && fill4)")

        // A range view as the guest hooks map one: 64 MiB of object 4 at offset 64 MiB over a fresh reservation.
        let span = 64 << 20
        var reservation: vm_address_t = 0
        var rangeOK = false, rangeMade = false
        if vm_allocate(mach_task_self_, &reservation, vm_size_t(span), VM_FLAGS_ANYWHERE) == KERN_SUCCESS,
           let at = UnsafeMutableRawPointer(bitPattern: UInt(reservation)) {
            let kr = pp_memory_map_range(objects[3], UInt64(span), UInt64(span), at)
            if kr == 0, let range = device.makeBuffer(bytesNoCopy: at, length: span, options: .storageModeShared,
                                                       deallocator: nil) {
                rangeMade = true
                let done = blit("range") { e in e.fill(buffer: range, range: 0..<span, value: 0x77) }
                rangeOK = done && pp_memory_reads_byte(views[3] + span, UInt64(span), 0x77)
                    && pp_memory_reads_byte(views[3], UInt64(span), 0xC3)
                    && pp_memory_reads_byte(views[3] + 2 * span, UInt64(chunk - 2 * span), 0xC3)
            } else {
                log("pool-gpu range map_kr=\(kr)")
            }
            vm_deallocate(mach_task_self_, reservation, vm_size_t(span))
        }
        log("pool-gpu range nocopy_created=\(rangeMade) reads_back_in_object=\(rangeOK)")
        _ = read("range_done")
        buffers.removeAll()
        pool.removeAll()
        let released = read("nocopy_released")

        // The control: ordinary shared buffers of the same size, filled on the GPU.
        let controls = (0..<objects.count).compactMap { _ in device.makeBuffer(length: chunk, options: .storageModeShared) }
        let controlCreated = read("control_created")
        let controlOK = controls.count == objects.count && blit("control") { e in
            for (i, b) in controls.enumerated() { e.fill(buffer: b, range: 0..<chunk, value: UInt8(0x10 + i)) }
        }
        let controlGPU = read("control_gpu_written")
        let controlRead = controlOK && controls.enumerated().allSatisfy {
            pp_memory_reads_byte($1.contents(), UInt64(chunk), UInt8(0x10 + $0))
        }
        let pass = filled && gpuOK && copied && fill3 && fill4 && rangeOK && controlRead
        let poolFootprint = gpu.footprint - base.footprint, poolGraphics = gpu.graphics - base.graphics
        let controlFootprint = controlGPU.footprint - released.footprint
        let controlGraphics = controlGPU.graphics - released.graphics
        log("pool-gpu RESULT \(pass ? "PASS" : "FAIL") buffers_mb=\(objects.count * DonorRounds.donorChunkMB) "
            + "nocopy_footprint_delta_mb=\(poolFootprint) nocopy_graphics_delta_mb=\(poolGraphics) "
            + "nocopy_created_footprint_delta_mb=\(created.footprint - base.footprint) "
            + "cpu_touch_footprint_delta_mb=\(cpu.footprint - created.footprint) "
            + "nocopy_metal_allocated_delta_mb=\(gpu.metal - base.metal) "
            + "control_footprint_delta_mb=\(controlFootprint) control_graphics_delta_mb=\(controlGraphics) "
            + "control_created_footprint_delta_mb=\(controlCreated.footprint - released.footprint) "
            + "control_metal_allocated_delta_mb=\(controlGPU.metal - released.metal) control_read=\(controlRead) "
            + "copy=\(copied) fill=\(fill3 && fill4) range=\(rangeOK) " + DonorRounds.describe(pp_memory_snapshot()))
        return (pass, "Pool GPU \(pass ? "PASS" : "FAIL"): no-copy +\(poolFootprint) MiB footprint "
                + "(graphics +\(poolGraphics)), control +\(controlFootprint) MiB (graphics +\(controlGraphics))")
    }

    private nonisolated static func measurePoolZero() -> (Bool, String) {
        let chunk = UInt64(DonorRounds.donorChunkMB) << 20
        func fp() -> Int64 { Int64(bitPattern: pp_memory_snapshot()["footprint"]?.uint64Value ?? 0) >> 20 }
        func resident(_ r: PPMemoryRegion) -> UInt64 { (r.pageCounts()["resident"]?.uint64Value ?? 0) >> 20 }
        func ms(_ t0: UInt64) -> String { String(format: "%.2f", Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6) }
        log("pool-zero start " + DonorRounds.describe(pp_memory_snapshot()) + " " + DonorRounds.system())
        let rounds = DonorRounds.donorRounds(mb: 4 * DonorRounds.donorChunkMB, touch: false, log: log)
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
        log("pool-zero memset bytes_mb=\(DonorRounds.donorChunkMB) memset_ms=\(String(format: "%.2f", Double(clearNS) / 1e6)) "
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

        // 5: zeroing part of an object (the pool's reuse of a freed range, step 4): object 1 refilled,
        // then 64 MiB each by memset, madvise(MADV_ZERO), MADV_FREE_REUSABLE plus memset, and
        // MADV_FREE_REUSABLE alone (does it give freed pool pages back without a purge?).
        let partialFilled = pp_memory_fill(objects[0], seed + 5)
        var partialZero = partialFilled
        for (method, name) in [(0, "memset"), (1, "madv_zero"), (2, "reusable_memset"), (3, "reusable_only")] {
            let offset = UInt64(method) * span
            let before = resident(objects[0])
            var err: Int32 = 0
            let ns = pp_memory_zero_range(objects[0], offset, span, Int32(method), &err)
            let after = resident(objects[0])   // before the read below faults pages back in
            let zero = ns >= 0 && pp_memory_is_zero(objects[0], offset, span)
            if method == 0 { partialZero = partialZero && zero }
            log("pool-zero partial method=\(name) bytes_mb=\(span >> 20) rc=\(ns < 0 ? "errno \(err)" : "0") "
                + "ms=\(String(format: "%.2f", Double(max(ns, 0)) / 1e6)) reads_zero=\(zero) "
                + "resident_mb_before=\(before) resident_mb_after=\(after)")
        }
        let pass = filled1 && zero1 && filled2 && kr2 == 0 && zero2 && kr3 == 0 && mapped && inRange && outsideZero
            && partialZero
        log("pool-zero RESULT \(pass ? "PASS" : "FAIL") chunk_mb=\(chunk >> 20) touch_delta_mb=\(fp1 - fp0) "
            + "memset_ms=\(String(format: "%.2f", Double(clearNS) / 1e6)) purge_ms=\(purgeMS) retouch_delta_mb=\(fp2b - fp2) "
            + DonorRounds.describe(pp_memory_snapshot()))
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
        log("donor point=\(name) verify=\(verified) purgeable_state=\(purgeState) \(counts) " + DonorRounds.describe(state))
        return ((state["footprint"] as? NSNumber)?.uint64Value ?? 0, verified)
    }

    private nonisolated static func measureDonor(mb: Int, purgeable: Bool) -> (Bool, String) {
        let kind = variant(purgeable)
        log("donor start variant=\(kind) requested_mb=\(mb)")
        let mapped = UInt64(mb) << 20
        var regions: [PPMemoryRegion] = []
        defer {
            regions.removeAll()
            log("donor released variant=\(kind) " + DonorRounds.describe(pp_memory_snapshot()))
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
            log("donor helper baseline " + DonorRounds.describe(state)); baseline.signal()
        }
        guard baseline.wait(timeout: .now() + 10) == .success, helperPID > 0 else { return (false, "Helper report timed out") }
        if let failure = DonorRounds.allocate(mb: mb, purgeable: purgeable, proxy: proxy, into: &regions) { return (false, failure) }
        let mappedPoint = point("after_map", regions)
        guard mappedPoint.verified else { return (false, "Data verification failed after mapping") }
        let checked = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var helperOK = false
        proxy.memoryReport(seed: seed, verify: true) { state, ok in
            helperOK = ok
            log("donor helper before_stop verify=\(ok) " + DonorRounds.describe(state))
            checked.signal()
        }
        guard checked.wait(timeout: .now() + 90) == .success, helperOK else {
            return (false, "Helper data verification failed or timed out")
        }
        helper.stop()
        stopped = true
        let died = Date()
        let exit = DonorRounds.waitForExit(pid: helperPID, seconds: 5)
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

    /// runDonors' pool, held after the probe; touched only on BuiltInJit.queue.
    private nonisolated(unsafe) static var pool: [PPMemoryRegion] = []

    private nonisolated static func measureDonors(mb: Int) -> (Bool, String) {
        pool.removeAll()
        log("donors start target_mb=\(mb) variant=purgeable chunk_mb=\(DonorRounds.donorChunkMB) donor_margin_mb=\(DonorRounds.donorMarginMB) "
            + DonorRounds.describe(pp_memory_snapshot()) + " " + DonorRounds.system())
        let (regions, pids, stop, lastDeath, _) = DonorRounds.donorRounds(mb: mb, touch: true, log: log)
        let mapped = regions.reduce(0) { $0 + Int($1.byteCount >> 20) }
        let total = mapped
        log("donors rounds_done=\(pids.count) total_mb=\(total) target_mb=\(mb) stop=\"\(stop)\"")
        let wait = 60 - Date().timeIntervalSince(lastDeath)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let at60 = point("donors_dead_60s", regions)
        log("donors system_60s " + DonorRounds.system())

        // The app's own limit, with the pool held: ordinary memory, 256 MiB at a time.
        var ordinary: [UnsafeMutableRawPointer] = []
        let step = UInt64(DonorRounds.donorChunkMB) << 20
        var appStop = "app margin"
        while true {
            let available = DonorRounds.appMB("available")
            if available < UInt64(DonorRounds.donorChunkMB + DonorRounds.appMarginMB) { appStop = "app available \(available) MiB"; break }
            if let low = DonorRounds.systemLow() { appStop = low; break }
            guard let block = pp_memory_ordinary(step, seed &+ 0x1000 &+ UInt64(ordinary.count)) else {
                appStop = "vm_allocate refused"; break
            }
            ordinary.append(block)
            log("donors app_limit ordinary_mb=\(ordinary.count * DonorRounds.donorChunkMB) app_footprint_mb=\(DonorRounds.appMB("footprint")) "
                + "app_available_mb=\(DonorRounds.appMB("available")) " + DonorRounds.system())
        }
        let taken = ordinary.count * DonorRounds.donorChunkMB
        log("donors app_limit_done ordinary_mb=\(taken) stop=\"\(appStop)\" " + DonorRounds.describe(pp_memory_snapshot()) + " " + DonorRounds.system())
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
        log("donors pool_verify total_mb=\(total) verified=\(result.verified) " + DonorRounds.system())
        return (result.verified, "Pool \(total) MiB verified \(result.verified)")
    }

    private nonisolated static func measure(mb: Int) -> (Bool, String) {
        log("start requested_mb=\(mb) nofootprint_control=\(pp_memory_nofootprint_control())")
        log("host baseline " + DonorRounds.describe(pp_memory_snapshot()))
        do {
            // The control uses the exact same object type, but owned by this app.
            try autoreleasepool {
                var error: NSError?
                guard let control = pp_memory_create(64 << 20, 0, &error), pp_memory_fill(control, seed) else {
                    throw NSError(domain: "MemoryBroker", code: 1, userInfo: [NSLocalizedDescriptionKey: "local control failed"])
                }
                log("host local_64MiB " + DonorRounds.describe(pp_memory_snapshot()))
            }
            log("host control_released " + DonorRounds.describe(pp_memory_snapshot()))
            let helper = try JitHelper.start(log: log)
            defer { helper.stop() }
            var regions: [PPMemoryRegion] = []
            defer { regions.removeAll() }
            let proxy = helper.proxy { error in log("XPC error: \(error.localizedDescription)") }
            let baseline = DispatchSemaphore(value: 0)
            proxy.memoryReport(seed: seed, verify: false) { state, _ in
                log("helper baseline " + DonorRounds.describe(state)); baseline.signal()
            }
            guard baseline.wait(timeout: .now() + 10) == .success else { return (false, "Helper report timed out") }
            if let failure = DonorRounds.allocate(mb: mb, purgeable: false, proxy: proxy, into: &regions) { return (false, failure) }
            let allocated = mb
            let checked = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var helperOK = false
            proxy.memoryReport(seed: seed, verify: true) { state, ok in
                helperOK = ok
                log("helper after_shared verify=\(ok) " + DonorRounds.describe(state))
                checked.signal()
            }
            guard checked.wait(timeout: .now() + 90) == .success, helperOK else {
                return (false, "Helper data verification failed or timed out")
            }
            Thread.sleep(forTimeInterval: 5)
            guard regions.allSatisfy({ pp_memory_verify($0, seed + $0.token) }) else {
                return (false, "Retained data verification failed")
            }
            log("host retained_mb=\(allocated) " + DonorRounds.describe(pp_memory_snapshot()))
            regions.removeAll()
            // Release the original helper handles too, before measuring reclamation.
            let released = DispatchSemaphore(value: 0)
            proxy.memoryRelease { state in
                log("helper released " + DonorRounds.describe(state)); released.signal()
            }
            guard released.wait(timeout: .now() + 10) == .success else { return (false, "Release timed out") }
            log("host released " + DonorRounds.describe(pp_memory_snapshot()))
            log("PASS verified_mb=\(allocated) both_processes=true retained_s=5")
            return (true, "Verified \(allocated) MiB shared RAM in both processes")
        } catch {
            log("failed: \(error.localizedDescription)")
            return (false, error.localizedDescription)
        }
    }
}
