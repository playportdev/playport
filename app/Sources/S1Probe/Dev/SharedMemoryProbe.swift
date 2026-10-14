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

    /// Allocates mb MiB from the helper in 64 MiB objects, each fully written and verified here.
    /// Returns the failure, or nil.
    private nonisolated static func allocate(mb: Int, purgeable: Bool, proxy: JITHelping, into regions: inout [PPMemoryRegion]) -> String? {
        var allocated = 0
        while allocated < mb {
            let chunk = min(64, mb - allocated)
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
            guard pp_memory_fill(region, seed + token), pp_memory_verify(region, seed + token) else {
                return "Host data verification failed"
            }
            allocated += chunk
            if allocated % 512 == 0 || allocated == mb {
                log("host touched_mb=\(allocated) " + describe(pp_memory_snapshot()))
                log("object token=\(token) pages=\(region.pageCounts())")
            }
        }
        return nil
    }

    private nonisolated static func describe(_ value: Any) -> String {
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
