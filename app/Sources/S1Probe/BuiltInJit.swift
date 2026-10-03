// SPDX-License-Identifier: GPL-3.0-or-later
// Built-in JIT (docs/ARCHITECTURE.md, "Built-in JIT"): the app's own helper
// extension, PlugIns/PlayportJIT.appex, attaches to this process through the
// phone's debugserver with StikJIT and serves the universal brk #0xf00d
// protocol, so a Home Screen launch needs no second app and no app switch.
//
// There is no public API that starts an arbitrary extension, so JitHelper uses
// NSExtension's private methods, looked up at run time:
//   +extensionWithIdentifier:error:           the helper, by its bundle ID
//   -beginExtensionRequestWithInputItems:error: start it; the input item carries
//                                             an anonymous NSXPCListener's endpoint
//   -pidForRequestIdentifier:                 its PID, for the log
//   -_kill:                                   end it once the call is done
// A private method can change in any iOS release; that risk is accepted for a
// sideloaded app (docs/DEVICE.md, "JIT activation").
//
// What the user provides once per phone: the RP pairing file, imported in
// Settings › Setup check (or dropped at Documents/StikJIT/pairingFile.plist),
// and LocalDevVPN connected. The app keeps the file in its Keychain and deletes
// the Documents copy, so an update or reinstall under the same team needs no
// computer (docs/DEVICE.md, "JIT activation"). The Developer Disk Image is
// downloaded and mounted by StikJIT itself, once per boot.

import Foundation
import JITHelperXPC
#if !PLAYPORT_RELEASE
import SharedMemory
#endif
import ObjectiveC
import os
import Security
import SteamClientKit
import SwiftUI

enum BuiltInJit {
    enum Failure: Error, CustomStringConvertible {
        case notBundled
        case noGetTaskAllow
        case noPairingFile
        case spi(String)
        case noConnection
        case helper(String)
        case helperGone
        case cancelled

        var description: String {
            switch self {
            case .notBundled: "the JIT helper extension is not in the app bundle"
            case .noGetTaskAllow: "this install has no get-task-allow; reinstall it with a development signature"
            case .noPairingFile: "no pairing file: import one in Settings › Setup check"
            case .spi(let what): "starting the JIT helper failed: \(what)"
            case .noConnection: "the JIT helper did not connect within 5 s"
            case .helper(let error): "JIT helper: \(error)"
            case .helperGone: "the JIT helper went away before it replied"
            case .cancelled: "the JIT helper call was cancelled"
            }
        }
    }

    /// A drop point only: a file found here is moved into the Keychain.
    static var pairingFileURL: URL {
        WineHostRuntime.documents.appendingPathComponent("StikJIT/pairingFile.plist")
    }

    /// The pairing file's home: a this-device-only, unsynchronised Keychain item
    /// in the app's own access group. Keychain items outlive the app's
    /// container, so a reinstall under the same team finds it again.
    private static let store = KeychainSecretStore(service: "dev.playport.app.jit")
    private static let storeKey = "rp-pairing-file"
    private static let storeLock = NSLock()

    /// No dropped-file adoption and no swallowed Keychain errors during setup.
    static func storedPairingData() throws -> Data? {
        try storeLock.withLock { try store.read(storeKey).map { Data($0.value) } }
    }

    /// Commit only the record we just verified, without replacing an intervening
    /// import. A first setup inserts atomically; explicit repair compares its old record.
    static func commitGeneratedPairing(_ data: Data, replacing expected: Data?) throws {
        guard let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              (p["public_key"] as? Data)?.count == 32, (p["private_key"] as? Data)?.count == 32,
              (p["alt_irk"] as? Data)?.count == 16, let identifier = p["identifier"] as? String, !identifier.isEmpty else {
            throw Failure.helper("generated pairing record is invalid")
        }
        try storeLock.withLock {
            let current = try store.read(storeKey).map { Data($0.value) }
            guard current == expected else { throw Failure.helper("pairing changed during setup; try again") }
            if expected != nil {
                try store.write(storeKey, Secret([UInt8](data)))
            } else {
                let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: store.service, kSecAttrAccount as String: storeKey,
                    kSecAttrSynchronizable as String: false,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: data]
                guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
                    throw Failure.helper("could not insert pairing in the Keychain")
                }
            }
        }
    }

    static var hasPairingFile: Bool { (try? pairingData()) != nil }

    /// Copies a picked pairing file into the Keychain, replacing any earlier
    /// one. It is a secret: its contents are never logged.
    static func importPairingFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try keep(try Data(contentsOf: source), named: source.lastPathComponent)
    }

    #if !PLAYPORT_RELEASE
    /// The on-device probe never writes credentials to Documents or the log.
    static func storeGeneratedPairing(_ data: Data) throws {
        try keep(data, named: "on-device pairing")
    }
    #endif

    private static func keep(_ data: Data, named name: String) throws {
        guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw Failure.helper("\(name) is not a property list")
        }
        try storeLock.withLock { try store.write(storeKey, Secret([UInt8](data))) }
    }

    /// Moves a file dropped at pairingFileURL into the Keychain. A bad file is
    /// left in place, and the Keychain copy, if any, stays in use.
    private static func adoptDroppedFile() {
        guard let data = try? Data(contentsOf: pairingFileURL) else { return }
        do {
            try keep(data, named: pairingFileURL.lastPathComponent)
            try? FileManager.default.removeItem(at: pairingFileURL)
            BuiltInJitStatus.log("pairing file moved from Documents to the Keychain")
        } catch {
            BuiltInJitStatus.log("pairing file in Documents not adopted: \(error)")
        }
    }

    /// CS_GET_TASK_ALLOW in this process's code-signing flags: without it
    /// debugserver refuses the attach, so there is no point starting the helper.
    static var hasGetTaskAllow: Bool {
        var flags: UInt32 = 0
        return csops(getpid(), 0, &flags, MemoryLayout<UInt32>.size) == 0 && flags & 0x4 != 0
    }

    /// One helper call at a time: a readiness check and a title's enable never
    /// overlap (nor a dev build's helper-lifetime probe, Dev/HelperLifetimeProbe.swift).
    static let queue = DispatchQueue(label: "playport.builtin-jit")

    /// Title enables queued or waiting to start. A readiness call gives way to
    /// them: it is cancelled rather than making a title wait for it.
    private static let pendingEnables = OSAllocatedUnfairLock(initialState: 0)
    private static let enablePending: @Sendable () -> Bool = { pendingEnables.withLock { $0 > 0 } }

    /// Starts the helper and asks it to enable JIT for this process. Returns at
    /// once; `done` gets nil or the error when the helper finishes (after the
    /// detach), or a failure to start. The caller waits for CS_DEBUGGED and
    /// runs the brk protocol (wine_host_jit_pool_acquire) meanwhile, and sets
    /// `cancelled` once it stops waiting: a call not yet started never starts,
    /// and a running helper is ended.
    static func requestEnable(cancelled: OSAllocatedUnfairLock<Bool>,
                              log: @escaping @Sendable (String) -> Void,
                              done: @escaping @Sendable (Failure?) -> Void) {
        pendingEnables.withLock { $0 += 1 }
        queue.async {
            pendingEnables.withLock { $0 -= 1 }
            done(withHelper(log: log, cancelled: { cancelled.withLock { $0 } }) { helper, reply in
                helper.enableJIT(targetPID: getpid(), pairingFile: try pairingData()) { error in
                    reply(error.map(Failure.helper))
                }
            })
        }
    }

    /// StikJIT's device preparation: the readiness indicator.
    static func prepare(pairingFile: Data? = nil, cancelled: OSAllocatedUnfairLock<Bool>? = nil,
                        log: @escaping @Sendable (String) -> Void,
                        done: @escaping @Sendable (_ status: String, _ reason: String?, _ txm: String) -> Void) {
        queue.async {
            nonisolated(unsafe) var result: (String, String?, String) = ("not ready", nil, "unknown")
            if let failure = withHelper(log: log, pairingFileProvided: pairingFile != nil,
                                        cancelled: { enablePending() || (cancelled?.withLock { $0 } ?? false) }, { helper, reply in
                helper.prepare(pairingFile: try pairingFile ?? pairingData()) { status, reason, txm in
                    result = (status, reason, txm)
                    reply(nil)
                }
            }) {
                if case .cancelled = failure {
                    result = ("not checked", nil, "unknown")
                } else {
                    result = ("not ready", failure.description, "unknown")
                }
            }
            done(result.0, result.1, result.2)
        }
    }

    static func resetDDI(log: @escaping @Sendable (String) -> Void, done: @escaping @Sendable (Failure?) -> Void) {
        queue.async {
            done(withHelper(log: log, cancelled: enablePending) { helper, reply in
                helper.resetDDI { error in reply(error.map(Failure.helper)) }
            })
        }
    }

    static func pairingData() throws -> Data {
        adoptDroppedFile()
        guard let data = try? store.read(storeKey) else { throw Failure.noPairingFile }
        return Data(data.value)
    }

    /// Starts the helper, runs one call, waits for its reply, ends the helper.
    /// Returns .cancelled, ending the helper, once `cancelled` holds.
    /// Blocks the calling (serial) queue; never the main thread.
    private static func withHelper(log: @escaping @Sendable (String) -> Void,
                                   pairingFileProvided: Bool = false, cancelled: () -> Bool,
                                   _ call: (JITHelping, @escaping @Sendable (Failure?) -> Void) throws -> Void) -> Failure? {
        guard hasGetTaskAllow else { return .noGetTaskAllow }
        guard pairingFileProvided || hasPairingFile else { return .noPairingFile }
        guard !cancelled() else { return .cancelled }
        let helper: JitHelper
        do {
            helper = try JitHelper.start(log: log)
        } catch let f as Failure {
            return f
        } catch {
            return .spi("\(error)")
        }
        defer { helper.stop() }
        let replied = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Failure?
        let proxy = helper.proxy { error in
            outcome = .helper("XPC: \(error.localizedDescription)")
            replied.signal()
        }
        do {
            try call(proxy) { failure in
                outcome = failure
                replied.signal()
            }
        } catch let f as Failure {
            return f
        } catch {
            return .helper("\(error)")
        }
        // StikJIT's own steps time out (its 5 s connection timeout, the
        // download), and the connection's error handler fires if the helper
        // dies. The cap only frees the queue if the helper hangs (a first DDI
        // download is the slowest step); stop() then ends it.
        let deadline = Date() + 600
        while replied.wait(timeout: .now() + 0.25) == .timedOut {
            if cancelled() {
                log("helper call cancelled; ending the helper")
                return .cancelled
            }
            if Date() >= deadline { return .helper("no reply in 600 s") }
        }
        return outcome
    }
}

/// One running helper extension and its XPC connection.
final class JitHelper: NSObject, NSXPCListenerDelegate, JITHost, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let connected = DispatchSemaphore(value: 0)
    private let log: @Sendable (String) -> Void
    private var connection: NSXPCConnection?
    private var ext: NSObject?

    private init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// A start right after the previous helper was ended (the readiness check,
    /// then a title's enable) can be refused, or start a helper that never
    /// connects, while that one is torn down. So a start waits until half a
    /// second after the last helper ended, and a refused or unconnected start
    /// is tried up to three times; a helper normally connects in about 0.2 s.
    static func start(log: @escaping @Sendable (String) -> Void) throws -> JitHelper {
        let settle = lastStop.withLock { $0 }.map { 0.5 - Date().timeIntervalSince($0) } ?? 0
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        var attempt = 1
        while true {
            let helper = JitHelper(log: log)
            let failure: BuiltInJit.Failure
            do {
                try helper.launch()
                if helper.connected.wait(timeout: .now() + 5) == .success { return helper }
                failure = .noConnection
            } catch let f as BuiltInJit.Failure {
                failure = f
            } catch {
                helper.stop()
                throw error
            }
            helper.stop()
            switch failure {
            case .spi where attempt < 3, .noConnection where attempt < 3:
                log("\(failure); trying again")
                attempt += 1
                Thread.sleep(forTimeInterval: 0.5)
            default:
                throw failure
            }
        }
    }

    /// When the last helper was ended (stop), for the next start's wait.
    private static let lastStop = OSAllocatedUnfairLock<Date?>(initialState: nil)

    private func launch() throws {
        guard let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PlayportJIT.appex"),
              let identifier = Bundle(url: appex)?.bundleIdentifier else { throw BuiltInJit.Failure.notBundled }
        listener.delegate = self
        listener.resume()

        guard let cls: AnyClass = NSClassFromString("NSExtension") else { throw BuiltInJit.Failure.spi("no NSExtension class") }
        let create = NSSelectorFromString("extensionWithIdentifier:error:")
        guard let createIMP = class_getClassMethod(cls, create).map(method_getImplementation) else {
            throw BuiltInJit.Failure.spi("no +[NSExtension extensionWithIdentifier:error:]")
        }
        // NSError ** is autoreleasing: a plain UnsafeMutablePointer would release the callee's error once too often.
        typealias Create = @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSObject>?
        var error: NSError?
        guard let ext = unsafeBitCast(createIMP, to: Create.self)(cls, create, identifier as NSString, &error)?
            .takeUnretainedValue() else {
            throw BuiltInJit.Failure.spi("no extension \(identifier): \(error?.localizedDescription ?? "nil")")
        }
        self.ext = ext

        let item = NSExtensionItem()
        item.userInfo = [jitHelperEndpointKey: listener.endpoint]
        let begin = NSSelectorFromString("beginExtensionRequestWithInputItems:error:")
        guard let beginIMP = class_getInstanceMethod(type(of: ext), begin).map(method_getImplementation) else {
            throw BuiltInJit.Failure.spi("no -beginExtensionRequestWithInputItems:error:")
        }
        typealias Begin = @convention(c) (NSObject, Selector, NSArray, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSUUID>?
        guard let request = unsafeBitCast(beginIMP, to: Begin.self)(ext, begin, [item] as NSArray, &error)?
            .takeUnretainedValue() else {
            throw BuiltInJit.Failure.spi("request refused: \(error?.localizedDescription ?? "nil")")
        }

        let pidSel = NSSelectorFromString("pidForRequestIdentifier:")
        if let pidIMP = class_getInstanceMethod(type(of: ext), pidSel).map(method_getImplementation) {
            typealias PID = @convention(c) (NSObject, Selector, NSUUID) -> pid_t
            log("helper started, pid \(unsafeBitCast(pidIMP, to: PID.self)(ext, pidSel, request))")
        }
    }

    func proxy(onError: @escaping @Sendable (Error) -> Void) -> JITHelping {
        // start() returns only once the connection exists.
        connection!.remoteObjectProxyWithErrorHandler(onError) as! JITHelping
    }

    func stop() {
        Self.lastStop.withLock { $0 = Date() }
        connection?.invalidate()
        connection = nil
        if let ext {
            let kill = NSSelectorFromString("_kill:")
            if let killIMP = class_getInstanceMethod(type(of: ext), kill).map(method_getImplementation) {
                typealias Kill = @convention(c) (NSObject, Selector, Int32) -> Void
                unsafeBitCast(killIMP, to: Kill.self)(ext, kill, SIGKILL)
            }
            self.ext = nil
        }
        listener.invalidate()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard connection == nil else { return false }
        c.exportedInterface = NSXPCInterface(with: JITHost.self)
        c.exportedObject = self
        c.remoteObjectInterface = NSXPCInterface(with: JITHelping.self)
        #if !PLAYPORT_RELEASE
        c.remoteObjectInterface?.setClasses(NSSet(object: PPMemoryRegion.self) as! Set<AnyHashable>,
            for: #selector(JITHelping.memoryAllocate(bytes:token:reply:)), argumentIndex: 0, ofReply: true)
        #endif
        c.resume()
        connection = c
        connected.signal()
        return true
    }

    func helperLog(_ line: String) { log("helper: " + line) }
}

/// What Settings › Setup check shows.
@MainActor
final class BuiltInJitStatus: ObservableObject {
    static let shared = BuiltInJitStatus()

    #if !PLAYPORT_RELEASE
    func refreshPairingAfterProbe() {
        pairingFile = BuiltInJit.hasPairingFile
        checkedThisLaunch = false
        check()
    }
    #endif

    @Published private(set) var pairingFile = BuiltInJit.hasPairingFile
    @Published private(set) var readiness = "not checked"
    /// The helper's status, unformatted: "ready", "unreachable", "not ready",
    /// "not checked" or "checking" (a release build's Settings words it).
    @Published private(set) var status = "not checked"
    @Published private(set) var detail: String?
    @Published private(set) var busy = false
    private var checkedThisLaunch = false

    /// Once per launch, when a pairing file is present: mounts the DDI early, so
    /// a title's enable does not wait for the download.
    func checkOnce() {
        guard !checkedThisLaunch, pairingFile, LocalDevVPN.tunnelUp, !JitSetup.shared.presented else { return }
        checkedThisLaunch = true
        check()
    }

    /// Generated records can be prepared in memory before replacing the Keychain.
    func check(pairingFile data: Data? = nil, cancelled: OSAllocatedUnfairLock<Bool>? = nil,
               then: (@MainActor (String) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        readiness = "checking…"
        status = "checking"
        detail = nil
        BuiltInJit.prepare(pairingFile: data, cancelled: cancelled, log: Self.log) { status, reason, txm in
            Task { @MainActor in
                let s = BuiltInJitStatus.shared
                let wasCancelled = cancelled?.withLock { $0 } ?? false
                s.status = wasCancelled ? "not checked" : status
                s.readiness = wasCancelled ? "not checked" : status == "ready" ? "ready (TXM \(txm))" : status
                s.detail = wasCancelled ? nil : reason
                s.busy = false
                if s.status == "not checked" { s.checkedThisLaunch = false }
                then?(s.status)
            }
        }
    }

    func generatedPairingCommitted() { pairingFile = true }

    func importPairingFile(_ result: Result<URL, Error>) {
        do {
            try BuiltInJit.importPairingFile(from: result.get())
            pairingFile = true
            readiness = "not checked"
            status = "not checked"
            detail = nil
            Self.log("pairing file imported")
            check()
        } catch {
            detail = "import failed: \(error)"
        }
    }

    func resetDDI() {
        guard !busy else { return }
        busy = true
        detail = nil
        BuiltInJit.resetDDI(log: Self.log) { failure in
            Task { @MainActor in
                let s = BuiltInJitStatus.shared
                s.readiness = failure == nil ? "DDI cache reset; not checked" : s.readiness
                s.detail = failure?.description
                s.busy = false
                #if PLAYPORT_RELEASE
                // A player gets the check right away: the image downloads again.
                if failure == nil { s.check() }
                #endif
            }
        }
    }

    nonisolated static func log(_ line: String) { WineHostRuntime.appendLog("jit: " + line) }
}
