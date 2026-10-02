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
            var allocated = 0
            while allocated < mb {
                let chunk = min(64, mb - allocated)
                let token = UInt64(regions.count + 1)
                let replied = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var received: PPMemoryRegion?
                nonisolated(unsafe) var failure: String?
                proxy.memoryAllocate(bytes: UInt64(chunk) << 20, token: token) { region, _, why in
                    received = region; failure = why; replied.signal()
                }
                guard replied.wait(timeout: .now() + 10) == .success, let region = received else {
                    log("allocation refused at \(allocated) MiB: \(failure ?? "timeout")")
                    return (false, "Allocated \(allocated) MiB; \(failure ?? "helper timeout")")
                }
                regions.append(region)
                guard pp_memory_fill(region, seed + token), pp_memory_verify(region, seed + token) else {
                    return (false, "Host data verification failed")
                }
                allocated += chunk
                if allocated % 512 == 0 || allocated == mb {
                    log("host touched_mb=\(allocated) " + describe(pp_memory_snapshot()))
                    log("object token=\(token) pages=\(region.pageCounts())")
                }
            }
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
