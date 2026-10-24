// SPDX-License-Identifier: GPL-3.0-or-later
// The XPC contract between the app and its JIT helper extension
// (PlugIns/PlayportJIT.appex, docs/ARCHITECTURE.md, "Built-in JIT"). The app
// starts the helper with an NSExtension request whose input item carries an
// anonymous listener's endpoint under jitHelperEndpointKey; the helper
// connects back, exports JITHelping and calls JITHost for progress.

import Foundation

public let jitHelperEndpointKey = "PlayportJITEndpoint"

/// The work the helper does for the app, one call at a time on its serial queue.
/// Pairing keys stay in the helper's separate Keychain group. The app receives
/// only nonsecret revisions and candidate tokens; no operation exports a key.
@objc(PlayportJITHelping)
public protocol JITHelping {
    /// StikJIT's enableJIT for targetPID with Playport's universal protocol
    /// script (playport-universal.js): prepares the device if needed
    /// (reachability, DDI mount), attaches, serves the target's brk #0xf00d
    /// calls and detaches. The reply's argument is nil on success,
    /// or the error.
    func enableJIT(targetPID: Int32, reply: @escaping (String?) -> Void)
    /// StikJIT's prepareDevice: the readiness (`ready`, `unreachable`,
    /// `not ready`), the reason when not ready, and TXM (`present`, `absent`, `unknown`).
    func prepare(candidate: String?, reply: @escaping (String, String?, String) -> Void)
    func pairingStatus(reply: @escaping (String?, String?) -> Void)
    func pair(pin: String, reply: @escaping (String?, String?) -> Void)
    func commitPairing(candidate: String, replacing revision: String?, reply: @escaping (String?, String?) -> Void)
    func discardPairing(candidate: String, reply: @escaping (String?) -> Void)
    /// Explicit legacy import/migration. The importing process must restart
    /// before runtime initialization; ordinary launches never pass credentials.
    func importPairing(data: Data, replacing revision: String?, reply: @escaping (String?, String?) -> Void)
    func adoptLegacyPairing(data: Data, reply: @escaping (String?, String?) -> Void)
    func relaunch(reply: @escaping (String?) -> Void)
    /// Deletes the cached Developer Disk Image files; the next preparation downloads them again.
    func resetDDI(reply: @escaping (String?) -> Void)
    #if !PLAYPORT_RELEASE
    /// Synthetic item only: proves that the main process cannot read this
    /// helper's default group without exposing actual pairing credentials.
    func isolationProbe(reply: @escaping (String?, String?) -> Void)
    func clearIsolationProbe(reply: @escaping (String?) -> Void)
    /// Dev builds: the helper-lifetime probe (docs/evidence, multigame
    /// alternatives, probe 0). Starts a ticker that appends a line every
    /// intervalMs to a file in the helper's own Library and to NSLog, notes when
    /// this connection is invalidated (the host gone), then runs one
    /// prepareDevice to see whether a device-service call still works. Replies
    /// at once with the helper's PID; the ticker stops by itself after capS.
    /// hold: the helper also takes its own xpc transaction and ignores SIGTERM
    /// (logging it), to see whether that keeps it alive once the host is gone.
    func lifetimeProbe(intervalMs: Int, capS: Int, hold: Bool, reply: @escaping (Int32) -> Void)
    /// Dev builds: the last probe's file, deleted as it is read (empty if none).
    func lifetimeReport(reply: @escaping (String) -> Void)
    #endif
}

/// What the app hears from the helper while a call runs.
@objc(PlayportJITHost)
public protocol JITHost {
    func helperLog(_ line: String)
    func pairingAdvertisement(identifier: String, records: Data, port: UInt16)
}
