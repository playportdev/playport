// SPDX-License-Identifier: GPL-3.0-or-later
// The app's memory limit: the most iOS lets this process use before it ends
// it (jetsam), for the JIT pool, the runtime and the game together. It is
// os_proc_available_memory() (what is left) plus the phys footprint (what is
// used), read in C (HostIO host_memory.c), as DXMT's video budget reads it. The
// Increased Memory Limit entitlement raises it; a signer that drops the
// entitlement leaves about 3.3 GB (docs/DISTRIBUTION.md). It also moves: on the
// reference phone, with the entitlement, it is 6 GB at the app's start and 8 GB
// once iOS turns Game Mode on, a few seconds after the app comes to the front.
//
// Read at the app's start (a `memory:` line in the app log), by Settings
// (Setup check), and at every Play, which PlayportKit's MemoryNeed
// refuses or warns about before any JIT is spent (LaunchCoordinator), and
// which sizes the Play's JIT pool from it (PlayportKit JitPool). A dev
// build's Settings can simulate a lower limit (`simulatedKey`), so the
// low-limit path can be driven on a phone that has the entitlement, and a
// JIT pool of a given size (`simulatedPoolKey`), so running out of it can be.

import Foundation
import HostIO
import PlayportKit

enum MemoryLimit {
    struct Reading: Equatable, Sendable {
        /// Available plus footprint; nil when iOS reports no limit for the process.
        var limitMB: Int?
        var footprintMB: Int
        /// The phone's RAM.
        var physicalMB: Int
        /// Whether the signature carries increased-memory-limit; nil when it cannot be read.
        var entitled: Bool?
        /// A dev build's simulated limit, which Plays are checked against instead.
        var simulatedMB: Int?
        /// A dev build's simulated JIT pool size in MiB, which Plays get instead of the one the limit gives.
        var simulatedPoolMB: Int?

        /// The limit a Play is checked against.
        var effectiveMB: Int? { simulatedMB ?? limitMB }
    }

    static let entitlement = "com.apple.developer.kernel.increased-memory-limit"

    #if !PLAYPORT_RELEASE
    /// UserDefaults: a limit in MB that Plays are checked against instead of the real
    /// one; 0 or unset for none (Settings › Developer, the driver's `set:`).
    static let simulatedKey = "memoryLimitSimulatedMB"
    /// UserDefaults: a JIT pool in MiB that Plays get instead of the one the limit
    /// gives; 0 or unset for none (Settings › Developer, the driver's `set:`).
    static let simulatedPoolKey = "jitPoolSimulatedMB"
    #endif

    /// The JIT pool a Play gets under this reading, in MiB (a multiple of 16 KiB).
    static func poolMB(_ r: Reading) -> Int {
        r.simulatedPoolMB ?? JitPool.sizeMB(limitMB: r.effectiveMB)
    }

    static func read() -> Reading {
        var m = host_memory()
        _ = host_memory_read(&m)
        var simulated: Int?, simulatedPool: Int?
        #if !PLAYPORT_RELEASE
        simulated = UserDefaults.standard.integer(forKey: simulatedKey)
        if simulated == 0 { simulated = nil }
        simulatedPool = UserDefaults.standard.integer(forKey: simulatedPoolKey)
        if simulatedPool! <= 0 { simulatedPool = nil }
        #endif
        return Reading(limitMB: m.available > 0 ? Int((m.available + m.footprint) >> 20) : nil,
                       footprintMB: Int(m.footprint >> 20),
                       physicalMB: Int(ProcessInfo.processInfo.physicalMemory >> 20),
                       entitled: entitled, simulatedMB: simulated, simulatedPoolMB: simulatedPool)
    }

    /// A reading every 2 s until the task ends. The limit moves: Game Mode, which iOS turns
    /// on a few seconds after Playport comes to the front, raises it (6 GB to 8 GB on the
    /// reference phone).
    @MainActor static func follow(_ update: (Reading) -> Void) async {
        while !Task.isCancelled {
            update(read())
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Once, in the app's init.
    static func logAtStart() {
        let r = read()
        WineHostRuntime.appendLog("memory: limit \(r.limitMB.map { "\($0) MB" } ?? "not reported")"
            + " (footprint \(r.footprintMB) MB), phone \(r.physicalMB) MB, "
            + "increased-memory-limit \(r.entitled.map { $0 ? "yes" : "no" } ?? "unknown")"
            + (r.simulatedMB.map { "; simulated limit \($0) MB" } ?? ""))
    }

    /// The signature's increased-memory-limit (host_entitlement, through Security's SecTask).
    static let entitled: Bool? = {
        let r = host_entitlement(entitlement)
        return r < 0 ? nil : r == 1
    }()
}
