// SPDX-License-Identifier: GPL-3.0-or-later
// The XPC contract between the app and its JIT helper extension
// (PlugIns/PlayportJIT.appex, docs/ARCHITECTURE.md, "Built-in JIT"). The app
// starts the helper with an NSExtension request whose input item carries an
// anonymous listener's endpoint under jitHelperEndpointKey; the helper
// connects back, exports JITHelping and calls JITHost for progress.

import Foundation
#if !PLAYPORT_RELEASE
import SharedMemory
#endif

public let jitHelperEndpointKey = "PlayportJITEndpoint"

/// The work the helper does for the app, one call at a time on its serial queue.
/// pairingFile is the RP pairing file's bytes: the helper cannot read the app's
/// Documents, and a free team has no App Group, so the bytes travel over XPC.
@objc(PlayportJITHelping)
public protocol JITHelping {
    /// StikJIT's enableJIT for targetPID with Playport's universal protocol
    /// script (playport-universal.js): prepares the device if needed
    /// (reachability, DDI mount), attaches, serves the target's brk #0xf00d
    /// calls and detaches. The reply's argument is nil on success,
    /// or the error.
    func enableJIT(targetPID: Int32, pairingFile: Data, reply: @escaping (String?) -> Void)
    /// StikJIT's prepareDevice: the readiness (`ready`, `unreachable`,
    /// `not ready`), the reason when not ready, and TXM (`present`, `absent`, `unknown`).
    func prepare(pairingFile: Data, reply: @escaping (String, String?, String) -> Void)
    /// Deletes the cached Developer Disk Image files; the next preparation downloads them again.
    func resetDDI(reply: @escaping (String?) -> Void)
    #if !PLAYPORT_RELEASE
    /// Dev builds: the helper-lifetime probe (docs/evidence, multigame
    /// alternatives, probe 0). Starts a ticker that appends a line every
    /// intervalMs to a file in the helper's own Library and to NSLog, notes when
    /// this connection is invalidated (the host gone), then runs one
    /// prepareDevice to see whether a device-service call still works. Replies
    /// at once with the helper's PID; the ticker stops by itself after capS.
    /// hold: the helper also takes its own xpc transaction and ignores SIGTERM
    /// (logging it), to see whether that keeps it alive once the host is gone.
    func lifetimeProbe(intervalMs: Int, capS: Int, hold: Bool, pairingFile: Data, reply: @escaping (Int32) -> Void)
    /// A bounded non-executable RAM object owned by this helper, transported as a Mach send right.
    func memoryAllocate(bytes: UInt64, token: UInt64, reply: @escaping (PPMemoryRegion?, NSDictionary, String?) -> Void)
    func memoryReport(seed: UInt64, verify: Bool, reply: @escaping (NSDictionary, Bool) -> Void)
    func memoryRelease(reply: @escaping (NSDictionary) -> Void)
    /// Dev builds: the last probe's file, deleted as it is read (empty if none).
    func lifetimeReport(reply: @escaping (String) -> Void)
    #endif
}

/// What the app hears from the helper while a call runs.
@objc(PlayportJITHost)
public protocol JITHost {
    func helperLog(_ line: String)
}
