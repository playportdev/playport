// SPDX-License-Identifier: GPL-3.0-or-later
// The JIT helper extension (docs/ARCHITECTURE.md, "Built-in JIT"). A process
// cannot attach a debugger to itself: debugserver suspends every thread of the
// target on each stop, including the one that would answer. So the app starts
// this extension, a second process in its own bundle, and the extension runs
// StikJIT (MPL-2.0, embedded unmodified in its Frameworks/) against the app's
// PID through the phone's own debugserver, over LocalDevVPN's loopback tunnel.
// StikJIT runs Playport's own protocol script, playport-universal.js (GPL-3.0-
// or-later, app/PlayportJIT/), from the extension's bundle; the framework's
// bundled scripts are not staged (build/stages/stikjit.sh).
//
// The extension is declared under a borrowed system extension point with a
// FALSEPREDICATE activation rule (PlayportJIT-Info.plist), so nothing but the
// app can start it. StikJIT's calls block; they run one at a time on one
// serial queue, as its integration guide requires.

import Foundation
import JITHelperXPC
import StikJIT
#if !PLAYPORT_RELEASE
import SharedMemory
#endif

@objc(PlayportJITHelper)
final class JITHelper: NSObject, NSExtensionRequestHandling, JITHelping {
    private let queue = DispatchQueue(label: "playport.jit-helper", qos: .userInitiated)
    private var context: NSExtensionContext?
    private var connection: NSXPCConnection?
    private var host: JITHost?

    /// The DDI cache, in the extension's own Library: it survives app updates
    /// and needs no download again until reset.
    private static let ddi = DDIPaths.default(
        in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("StikJIT"))

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let endpoint = item.userInfo?[jitHelperEndpointKey] as? NSXPCListenerEndpoint else {
            context.cancelRequest(withError: NSError(domain: "PlayportJIT", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the request carries no listener endpoint"]))
            return
        }
        self.context = context
        let c = NSXPCConnection(listenerEndpoint: endpoint)
        c.exportedInterface = NSXPCInterface(with: JITHelping.self)
        c.exportedObject = self
        c.remoteObjectInterface = NSXPCInterface(with: JITHost.self)
        c.resume()
        connection = c
        host = c.remoteObjectProxyWithErrorHandler { _ in } as? JITHost
        say("helper pid \(getpid()) connected")
    }

    func enableJIT(targetPID: Int32, pairingFile: Data, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            say("enableJIT pid \(targetPID)")
            guard let script = Bundle.main.url(forResource: "playport-universal", withExtension: "js") else {
                say("enableJIT failed: playport-universal.js is not in the helper extension")
                reply("playport-universal.js is not in the helper extension")
                return
            }
            do {
                try withPairingFile(pairingFile) { url in
                    try StikJIT.enableJIT(targetPID: targetPID, pairingFile: url, ddiPaths: Self.ddi, script: .custom(script),
                                          preparationProgress: { self.say("prepare: \(Self.describe($0))") },
                                          progress: { self.say($0) })
                }
                say("enableJIT done")
                reply(nil)
            } catch {
                say("enableJIT failed: \(error.localizedDescription)")
                reply(error.localizedDescription)
            }
        }
    }

    func prepare(pairingFile: Data, reply: @escaping (String, String?, String) -> Void) {
        queue.async { [self] in
            do {
                let readiness = try withPairingFile(pairingFile) { url in
                    StikJIT.prepareDevice(pairingFile: url, paths: Self.ddi) { self.say("prepare: \(Self.describe($0))") }
                }
                switch readiness {
                case .ready(let state):
                    let txm = state.isTXMPresent.map { $0 ? "present" : "absent" } ?? "unknown"
                    say("ready, TXM \(txm)")
                    reply("ready", nil, txm)
                case .unreachable(let reason):
                    say("unreachable: \(reason)")
                    reply("unreachable", reason, "unknown")
                case .preparationFailed(let reason):
                    say("not ready: \(reason)")
                    reply("not ready", reason, "unknown")
                }
            } catch {
                reply("not ready", error.localizedDescription, "unknown")
            }
        }
    }

    func resetDDI(reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                try StikJIT.resetCachedDDI(at: Self.ddi)
                say("DDI cache reset")
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    #if !PLAYPORT_RELEASE
    private var memoryRegions: [PPMemoryRegion] = []

    func memoryAllocate(bytes: UInt64, token: UInt64, reply: @escaping (PPMemoryRegion?, NSDictionary, String?) -> Void) {
        queue.async { [self] in
            // Refuse an arena whose reservation would consume the helper's last 128 MiB.
            let state = pp_memory_snapshot() as NSDictionary
            let available = (state["available"] as? NSNumber)?.uint64Value ?? 0
            let reserved = memoryRegions.reduce(UInt64(0)) { $0 + $1.byteCount }
            guard bytes > 0, reserved + bytes + (128 << 20) < available + ((state["footprint"] as? NSNumber)?.uint64Value ?? 0) else {
                reply(nil, state, "helper budget exhausted")
                return
            }
            var error: NSError?
            guard let region = pp_memory_create(bytes, token, &error) else {
                reply(nil, state, error?.localizedDescription ?? "memory create failed")
                return
            }
            memoryRegions.append(region)
            reply(region, pp_memory_snapshot() as NSDictionary, nil)
        }
    }

    func memoryAllocateForRuntime(bytes: UInt64, token: UInt64, reply: @escaping (PPMemoryRegion?, NSDictionary, String?) -> Void) {
        queue.async {
            let state = pp_memory_snapshot() as NSDictionary
            let available = (state["available"] as? NSNumber)?.uint64Value ?? 0
            guard bytes > 0, bytes <= 256 << 20, bytes + (128 << 20) < available else {
                reply(nil, state, "helper budget exhausted")
                return
            }
            var error: NSError?
            let region = pp_memory_create(bytes, token, &error)
            reply(region, state, error?.localizedDescription)
        }
    }

    func memoryReport(seed: UInt64, verify: Bool, reply: @escaping (NSDictionary, Bool) -> Void) {
        queue.async { [self] in
            let ok = !verify || memoryRegions.allSatisfy { pp_memory_verify($0, seed + $0.token) }
            reply(pp_memory_snapshot() as NSDictionary, ok)
        }
    }

    func memoryRelease(reply: @escaping (NSDictionary) -> Void) {
        queue.async { [self] in
            memoryRegions.removeAll()
            reply(pp_memory_snapshot() as NSDictionary)
        }
    }

    // The helper-lifetime probe (JITHelping.lifetimeProbe). Timestamps are the
    // wall clock in ms since 1970, the same clock the app logs its exit with.
    private static let probeURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("lifetime-probe.txt")
    private var probeTimer: DispatchSourceTimer?
    private var probeFile: FileHandle?
    private var hostGoneAt: Int64?
    // A lock, not DispatchQueue.sync: at -Onone a sync closure's escape check
    // embeds the source file's absolute path in the binary (verify-ipa.py, paths).
    private let probeLock = NSLock()

    private static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// One line to the probe file (unbuffered: a line written survives a SIGKILL) and to NSLog.
    private func probe(_ line: String, nslog: Bool = true) {
        probeLock.lock()
        let text = "\(Self.nowMs) pid=\(getpid()) \(line)\n"
        probeFile?.write(Data(text.utf8))
        probeLock.unlock()
        if nslog { NSLog("PlayportJIT: probe %@", line) }
    }

    /// The host's end, once: its time, and whether this was the first report of it.
    private func markHostGone() -> Bool {
        probeLock.lock()
        defer { probeLock.unlock() }
        guard hostGoneAt == nil else { return false }
        hostGoneAt = Self.nowMs
        return true
    }

    private var sinceHostGone: Int64? {
        probeLock.lock()
        defer { probeLock.unlock() }
        return hostGoneAt.map { Self.nowMs - $0 }
    }

    private var sigterm: DispatchSourceSignal?
    private var probeTransaction: AnyObject?

    func lifetimeProbe(intervalMs: Int, capS: Int, hold: Bool, pairingFile: Data, reply: @escaping (Int32) -> Void) {
        FileManager.default.createFile(atPath: Self.probeURL.path, contents: nil)
        probeLock.lock()
        probeFile = try? FileHandle(forWritingTo: Self.probeURL)
        probeLock.unlock()
        probe("start interval=\(intervalMs)ms cap=\(capS)s hold=\(hold)")
        if hold {
            // The idle-exit policy's own counter. Both calls are unavailable
            // to iOS code at compile time, so they are looked up at run time.
            if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_transaction_begin") {
                unsafeBitCast(f, to: (@convention(c) () -> Void).self)()
                probe("xpc_transaction_begin called")
            } else if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "os_transaction_create") {
                probeTransaction = unsafeBitCast(f, to: (@convention(c) (UnsafePointer<CChar>) -> Unmanaged<AnyObject>?).self)("playport.probe")?
                    .takeRetainedValue()
                probe("os_transaction_create: \(probeTransaction != nil)")
            } else {
                probe("no xpc transaction call found")
            }
            signal(SIGTERM, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            s.setEventHandler { self.probe("SIGTERM received (ignored)") }
            s.resume()
            sigterm = s
        }
        // Strong captures on purpose: the connection lets go of its exported
        // object when the host goes, and the probe must not end with it.
        let hostGone: (String) -> Void = { why in
            guard self.markHostGone() else { return }
            self.probe("host connection \(why)")
            // Can a device-service call still run once the host is gone?
            self.queue.async {
                self.probe("prepareDevice start")
                let result: String
                do {
                    let r = try self.withPairingFile(pairingFile) { url in
                        StikJIT.prepareDevice(pairingFile: url, paths: Self.ddi) { stage in
                            self.probe("prepareDevice: \(Self.describe(stage))")
                        }
                    }
                    switch r {
                    case .ready: result = "ready"
                    case .unreachable(let why): result = "unreachable: \(why)"
                    case .preparationFailed(let why): result = "not ready: \(why)"
                    }
                } catch {
                    result = "error: \(error.localizedDescription)"
                }
                self.probe("prepareDevice done: \(result)")
            }
        }
        connection?.invalidationHandler = { hostGone("invalidated") }
        connection?.interruptionHandler = { hostGone("interrupted") }
        let started = Self.nowMs
        var n = 0
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "playport.jit-helper.probe", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .milliseconds(5))
        t.setEventHandler {
            n += 1
            let since = self.sinceHostGone
            // NSLog every tick once the host is gone, else once a second.
            self.probe("tick \(n)\(since.map { " since-host-gone=\($0)ms" } ?? "")",
                       nslog: since != nil || n % max(1, 1000 / intervalMs) == 0)
            if Self.nowMs - started >= Int64(capS) * 1000 {
                self.probe("cap reached; ticker stops")
                self.probeTimer?.cancel()
                self.probeTimer = nil
                self.probeLock.lock()
                try? self.probeFile?.close()
                self.probeFile = nil
                self.probeLock.unlock()
            }
        }
        probeTimer = t
        t.resume()
        reply(getpid())
    }

    func lifetimeReport(reply: @escaping (String) -> Void) {
        let text = (try? String(contentsOf: Self.probeURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: Self.probeURL)
        reply(text)
    }
    #endif

    /// The pairing file lives only for the call, in the extension's temporary directory.
    private func withPairingFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    private func say(_ line: String) {
        NSLog("PlayportJIT: %@", line)
        host?.helperLog(line)
    }

    private static func describe(_ stage: StikJIT.PreparationStage) -> String {
        switch stage {
        case .checkingReachability: "checking the tunnel"
        case .checkingDDI: "checking the DDI mount"
        case .downloadingDDI(let fraction, let status): String(format: "downloading the DDI %.0f%% %@", fraction * 100, status)
        case .mountingDDI(let fraction): String(format: "mounting the DDI %.0f%%", fraction * 100)
        case .verifyingDDI: "verifying the DDI mount"
        case .ready: "device ready"
        }
    }
}
