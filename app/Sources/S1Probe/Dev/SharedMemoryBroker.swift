// SPDX-License-Identifier: GPL-3.0-or-later
// Opt-in, dev-only backing for FEX's large data mappings, never its JIT code.
// No allocation is requested through an environment switch or a second tool.
import Foundation
import JITHelperXPC
import SharedMemory

final class SharedMemoryBroker {
    static let key = "helperOwnedFEXMemory"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var helper: JitHelper?
    nonisolated(unsafe) private static var mapped: UInt64 = 0
    nonisolated(unsafe) private static var calls: UInt64 = 0
    nonisolated(unsafe) private static var refused: UInt64 = 0
    private static func log(_ text: String) { WineHostRuntime.appendLog("memory-broker: " + text) }

    /// After the JIT helper has detached and stopped, before ntdll/FEX starts.
    static func install() {
        guard UserDefaults.standard.bool(forKey: key) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard helper == nil else { return }
        do {
            helper = try JitHelper.start(log: log)
            pp_memory_set_backing_provider { address, bytes, protection in
                autoreleasepool { SharedMemoryBroker.replace(address: address, bytes: bytes, protection: protection) }
            }
            log("runtime enabled: FEX data only, power-of-two 1..256 MiB, no executable, stacks or reserve-only mappings")
        } catch {
            log("runtime unavailable, ordinary memory retained: \(error)")
        }
    }

    private final class Response: @unchecked Sendable {
        let lock = NSLock()
        var region: PPMemoryRegion?
        var state: NSDictionary = [:]
        var error: String?
        func set(_ region: PPMemoryRegion?, _ state: NSDictionary, _ error: String?) {
            lock.lock(); defer { lock.unlock() }
            self.region = region; self.state = state; self.error = error
        }
    }

    private static func replace(address: UnsafeMutableRawPointer?, bytes: UInt64, protection: Int32) -> Int32 {
        guard let address, bytes >= 1 << 20, bytes <= 256 << 20, bytes & (bytes - 1) == 0, protection == 3 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard let helper else { return 0 }
        calls += 1
        let result = Response()
        let done = DispatchSemaphore(value: 0)
        let proxy = helper.proxy { error in
            result.set(nil, [:], error.localizedDescription); done.signal()
        }
        proxy.memoryAllocateForRuntime(bytes: bytes, token: calls) { region, state, error in
            result.set(region, state, error); done.signal()
        }
        let answered = done.wait(timeout: .now() + 3) == .success
        result.lock.lock()
        defer { result.lock.unlock() }
        guard answered, let region = result.region, pp_memory_map_backing(region, address, protection) else {
            refused += 1
            log("runtime fallback size=\(bytes) error=\(result.error ?? "map or timeout")")
            if !answered || result.state.count == 0 {
                // Do not stall every future allocation when the helper has gone.
                pp_memory_set_backing_provider(nil)
            }
            return 0
        }
        mapped += bytes
        if calls <= 4 || calls % 128 == 0 {
            let fp = (result.state["footprint"] as? NSNumber)?.uint64Value ?? 0
            log("runtime map count=\(calls) requested_mb=\(mapped >> 20) helper_footprint=\(fp) address=\(address) size=\(bytes)")
        }
        // Dropping region drops the app's send right, NOT the Wine-owned mapping.
        // The helper retained neither its handle nor a mapping. Wine's normal
        // unmap/decommit therefore reclaims this object's physical pages.
        return 1
    }

    static func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let helper else {
            let host = pp_memory_snapshot()
            log("runtime report disabled host_footprint=\(host["footprint"]?.uint64Value ?? 0)")
            return "Extra FEX RAM is not enabled in this process"
        }
        let result = Response()
        let done = DispatchSemaphore(value: 0)
        helper.proxy { error in
            result.set(nil, [:], error.localizedDescription); done.signal()
        }.memoryReport(seed: 0, verify: false) { state, _ in
            result.set(nil, state, nil); done.signal()
        }
        let answered = done.wait(timeout: .now() + 3) == .success
        result.lock.lock()
        defer { result.lock.unlock() }
        let host = pp_memory_snapshot()
        let helperFP = (result.state["footprint"] as? NSNumber)?.uint64Value ?? 0
        let helperAvailable = (result.state["available"] as? NSNumber)?.uint64Value ?? 0
        let text = "runtime report mappings=\(calls) requested_mb=\(mapped >> 20) refused=\(refused)"
            + " host_footprint=\(host["footprint"]?.uint64Value ?? 0)"
            + " helper_footprint=\(helperFP) helper_available=\(helperAvailable) answered=\(answered)"
        log(text)
        return "Extra FEX RAM: helper \(helperFP >> 20) MiB; app \((host["footprint"]?.uint64Value ?? 0) >> 20) MiB; \(refused) fallbacks"
    }
}
