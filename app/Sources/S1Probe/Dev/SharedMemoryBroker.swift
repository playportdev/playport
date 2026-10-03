// SPDX-License-Identifier: GPL-3.0-or-later
// Opt-in, dev-only backing for FEX data and bounded fresh guest data, never JIT code.
// No allocation is requested through an environment switch or a second tool.
import Foundation
import JITHelperXPC
import SharedMemory

final class SharedMemoryBroker {
    static let key = "helperOwnedFEXMemory"
    static let guestKey = "helperOwnedGuestMemory"
    // Matches pp_guest_ranges.h's bound: at most 2 GiB of live mapped backing.
    private static let guestCap: UInt64 = 2 << 30
    nonisolated(unsafe) private static var fexEnabled = false
    nonisolated(unsafe) private static var guestEnabled = false
    nonisolated(unsafe) private static var guestMapped: UInt64 = 0
    nonisolated(unsafe) private static var guestLive: UInt64 = 0
    nonisolated(unsafe) private static var guestCalls: UInt64 = 0
    nonisolated(unsafe) private static var guestQuotaSaid = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var helper: JitHelper?
    nonisolated(unsafe) private static var mapped: UInt64 = 0
    nonisolated(unsafe) private static var calls: UInt64 = 0
    nonisolated(unsafe) private static var refused: UInt64 = 0
    private static func log(_ text: String) { WineHostRuntime.appendLog("memory-broker: " + text) }

    /// After the JIT helper has detached and stopped, before ntdll/FEX starts.
    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard helper == nil else { return }
        fexEnabled = UserDefaults.standard.bool(forKey: key)
        guestEnabled = UserDefaults.standard.bool(forKey: guestKey)
        guard fexEnabled || guestEnabled else { return }
        do {
            helper = try JitHelper.start(log: log)
            pp_memory_set_backing_provider { address, bytes, protection in
                autoreleasepool { SharedMemoryBroker.replace(address: address, bytes: bytes, protection: protection, guest: false) }
            }
            log("runtime enabled: fex=\(fexEnabled) guest=\(guestEnabled); guest quota=2048 MiB live mappings; no executable, images or reserve-only mappings")
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

    static func replaceGuest(address: UnsafeMutableRawPointer?, bytes: UInt64) -> Int32 {
        replace(address: address, bytes: bytes, protection: 3, guest: true)
    }

    static func releaseGuest(bytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if bytes > guestLive {
            log("guest lease mismatch: release=\(bytes) live=\(guestLive); disabling guest allocations")
            guestEnabled = false
            return
        }
        guestLive -= bytes
    }

    private static func replace(address: UnsafeMutableRawPointer?, bytes: UInt64, protection: Int32, guest: Bool) -> Int32 {
        guard let address, bytes > 0, bytes <= 256 << 20, protection == 3 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard let helper, guest ? guestEnabled : fexEnabled else { return 0 }
        if guest {
            let va = UInt64(UInt(bitPattern: address))
            guard bytes <= 64 << 20, va >= 0x7000000000, va < 0x7c00000000,
                  bytes <= 0x7c00000000 - va else { return 0 }
            guard bytes <= guestCap - guestLive else {
                if !guestQuotaSaid {
                    log("guest live quota reached; excess allocations stay ordinary until backing is released")
                    guestQuotaSaid = true
                }
                return 0
            }
        } else {
            guard bytes >= 1 << 20, bytes & (bytes - 1) == 0 else { return 0 }
        }
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
        defer { result.region = nil; result.lock.unlock() }
        guard answered, let region = result.region, pp_memory_map_backing(region, address, protection) else {
            refused += 1
            log("runtime fallback size=\(bytes) error=\(result.error ?? "map or timeout")")
            if !answered || result.state.count == 0 {
                // Do not stall every future allocation when the helper has gone.
                pp_memory_set_backing_provider(nil)
                fexEnabled = false; guestEnabled = false
            }
            return 0
        }
        mapped += bytes
        if guest { guestMapped += bytes; guestLive += bytes; guestCalls += 1 }
        if calls <= 4 || calls % 128 == 0 || (guest && guestCalls <= 8) {
            let fp = (result.state["footprint"] as? NSNumber)?.uint64Value ?? 0
            log("runtime map kind=\(guest ? "guest" : "fex") count=\(calls) requested_mb=\(mapped >> 20) helper_footprint=\(fp) address=\(address) size=\(bytes)")
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
        let text = "runtime report mappings=\(calls) requested_mb=\(mapped >> 20) refused=\(refused) guest_mappings=\(guestCalls) guest_requested_mb=\(guestMapped >> 20) guest_live_mb=\(guestLive >> 20)"
            + " host_footprint=\(host["footprint"]?.uint64Value ?? 0)"
            + " helper_footprint=\(helperFP) helper_available=\(helperAvailable) answered=\(answered)"
        log(text)
        return "Extra RAM: helper \(helperFP >> 20) MiB; app \((host["footprint"]?.uint64Value ?? 0) >> 20) MiB; \(refused) fallbacks"
            + (guestCalls > 0 ? "; guest backing \(guestLive >> 20) MiB live" : "")
    }
}
