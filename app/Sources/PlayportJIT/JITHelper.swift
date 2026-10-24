// SPDX-License-Identifier: GPL-3.0-or-later
// The JIT helper extension (docs/ARCHITECTURE.md, "Built-in JIT"). A process
// cannot attach a debugger to itself: debugserver suspends every thread of the
// target on each stop, including the one that would answer. So the app starts
// this extension, a second process in its own bundle, and the extension runs
// StikJIT (MPL-2.0, source-built with Playport patches) against the app's
// PID through the phone's own debugserver, over LocalDevVPN's loopback tunnel.
// StikJIT runs Playport's own protocol script, playport-universal.js (GPL-3.0-
// or-later, app/PlayportJIT/), from the extension's bundle; the framework's
// bundled scripts are not staged (build/stages/stikjit.sh).
//
// The extension is declared under a borrowed system extension point with a
// FALSEPREDICATE activation rule (PlayportJIT-Info.plist). Its anonymous XPC
// endpoint is passed by the app; this is not a caller-signature check. StikJIT's calls block; they run one at a time on one
// serial queue, as its integration guide requires.

import Foundation
import JITHelperXPC
import JITKit
import Relaunch
import StikJIT
import Security

private final class PairingResult {
    let helper: JITHelper
    var data: Data?
    init(_ helper: JITHelper) { self.helper = helper }
}

@objc(PlayportJITHelper)
final class JITHelper: NSObject, NSExtensionRequestHandling, JITHelping {
    private let queue = DispatchQueue(label: "playport.jit-helper", qos: .userInitiated)
    private var context: NSExtensionContext?
    private var connection: NSXPCConnection?
    private var host: JITHost?
    private let vault = PairingVault()

    /// The DDI cache, in the extension's own Library: it survives app updates
    /// and needs no download again until reset.
    private static let ddi = DDIPaths.default(
        in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("StikJIT"))

    func beginRequest(with context: NSExtensionContext) {
        do {
            // The previous pathname API could leave these after SIGKILL. The
            // new backend creates no files with this prefix.
            for url in try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                                                                   includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                if name.hasPrefix("pairing-"), name.hasSuffix(".plist"),
                   UUID(uuidString: String(name.dropFirst(8).dropLast(6))) != nil {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            context.cancelRequest(withError: NSError(domain: "PlayportJIT", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not remove legacy temporary pairing files"]))
            return
        }
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

    func enableJIT(targetPID: Int32, reply: @escaping (String?) -> Void) {
        guard let caller = connection?.processIdentifier, caller > 0, targetPID == caller else {
            reply("JIT is restricted to the connected host process")
            return
        }
        queue.async { [self] in
            say("enableJIT pid \(targetPID)")
            guard let script = Bundle.main.url(forResource: "playport-universal", withExtension: "js") else {
                say("enableJIT failed: playport-universal.js is not in the helper extension")
                reply("playport-universal.js is not in the helper extension")
                return
            }
            do {
                let pairingFile = try vault.credentials()
                try StikJIT.enableJIT(targetPID: targetPID, pairingFile: pairingFile, ddiPaths: Self.ddi, script: .custom(script),
                                     preparationProgress: { self.say("prepare: \(Self.describe($0))") },
                                     progress: { self.say($0) })
                say("enableJIT done")
                reply(nil)
            } catch {
                say("enableJIT failed: \(error.localizedDescription)")
                reply(error.localizedDescription)
            }
        }
    }

    func prepare(candidate: String?, reply: @escaping (String, String?, String) -> Void) {
        queue.async { [self] in
            do {
                let pairingFile = try vault.credentials(candidate: candidate)
                let readiness = StikJIT.prepareDevice(pairingFile: pairingFile, paths: Self.ddi) {
                    self.say("prepare: \(Self.describe($0))")
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
                @unknown default:
                    reply("not ready", "Unknown device readiness response", "unknown")
                }
            } catch { reply("not ready", error.localizedDescription, "unknown") }
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

    func pairingStatus(reply: @escaping (String?, String?) -> Void) {
        queue.async { [self] in
            do { reply(try vault.revision(), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func pair(pin: String, reply: @escaping (String?, String?) -> Void) {
        queue.async { [self] in
            let cancel = pairable_host_cancel_new()!
            defer { pairable_host_cancel_free(cancel) }
            let result = PairingResult(self)
            let context = Unmanaged.passUnretained(result).toOpaque()
            let error = pairable_host_accept_bonjour("Playport", pin, { identifier, records, port, context in
                guard let identifier, let records, let context else { return }
                let helper = Unmanaged<PairingResult>.fromOpaque(context).takeUnretainedValue().helper
                helper.host?.pairingAdvertisement(identifier: String(cString: identifier),
                    records: Data(String(cString: records).utf8), port: port)
            }, { bytes, count, context in
                guard let bytes, let context else { return }
                Unmanaged<PairingResult>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
            }, context, cancel)
            if let error {
                let message = "Pairing failed [\(error.pointee.code)/\(error.pointee.sub_code)]"
                idevice_error_free(error)
                reply(nil, message)
                return
            }
            do {
                guard let data = result.data else { throw PairingVault.Failure.invalid }
                reply(try vault.stage(data), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func commitPairing(candidate: String, replacing revision: String?, reply: @escaping (String?, String?) -> Void) {
        queue.async { [self] in
            do { reply(try vault.commit(candidate: candidate, replacing: revision), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func discardPairing(candidate: String, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do { try vault.discard(candidate: candidate); reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }

    func importPairing(data: Data, replacing revision: String?, reply: @escaping (String?, String?) -> Void) {
        queue.async { [self] in
            do { reply(try vault.importCredentials(data, replacing: revision), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func adoptLegacyPairing(data: Data, reply: @escaping (String?, String?) -> Void) {
        queue.async { [self] in
            do { reply(try vault.adoptLegacy(data), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func relaunch(reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                let data = try vault.credentials()
                let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                guard let bundle = Bundle(url: appURL)?.bundleIdentifier else { throw PairingVault.Failure.invalid }
                let result = data.withUnsafeBytes { bytes in
                    playport_relaunch(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                        "10.7.0.1", bundle, { line, context in
                            guard let line, let context else { return }
                            Unmanaged<JITHelper>.fromOpaque(context).takeUnretainedValue().say(String(cString: line))
                        }, Unmanaged.passUnretained(self).toOpaque())
                }
                reply(result == 0 ? nil : "Relaunch failed (step \(result))")
            } catch { reply(error.localizedDescription) }
        }
    }

    #if !PLAYPORT_RELEASE
    private static var isolationQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.playport.helper.isolation-probe",
         kSecAttrAccount as String: "read-boundary", kSecAttrSynchronizable as String: false]
    }

    func isolationProbe(reply: @escaping (String?, String?) -> Void) {
        queue.async {
            let query = Self.isolationQuery
            SecItemDelete(query as CFDictionary)
            let test = Data(UUID().uuidString.utf8)
            let attributes = query.merging([kSecValueData as String: test,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
                reply(nil, "Could not create synthetic helper item"); return
            }
            var request = query
            request[kSecReturnData as String] = true
            request[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
                  let value = result as? [String: Any], value[kSecValueData as String] as? Data == test,
                  let group = value[kSecAttrAccessGroup as String] as? String else {
                SecItemDelete(query as CFDictionary)
                reply(nil, "Helper could not read its synthetic item"); return
            }
            reply(group, nil)
        }
    }

    func clearIsolationProbe(reply: @escaping (String?) -> Void) {
        queue.async {
            let result = SecItemDelete(Self.isolationQuery as CFDictionary)
            reply(result == errSecSuccess || result == errSecItemNotFound ? nil : "Could not delete synthetic item")
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

    func lifetimeProbe(intervalMs: Int, capS: Int, hold: Bool, reply: @escaping (Int32) -> Void) {
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
                guard let pairingFile = try? self.vault.credentials() else {
                    self.probe("prepareDevice: no pairing in helper")
                    return
                }
                let r = StikJIT.prepareDevice(pairingFile: pairingFile, paths: Self.ddi) { stage in
                    self.probe("prepareDevice: \(Self.describe(stage))")
                }
                switch r {
                case .ready: result = "ready"
                case .unreachable(let why): result = "unreachable: \(why)"
                case .preparationFailed(let why): result = "not ready: \(why)"
                @unknown default: result = "unknown readiness response"
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
        @unknown default: "unknown preparation step"
        }
    }
}
