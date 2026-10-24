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
// Pairing is generated and stored inside the helper's separate Keychain
// group. Legacy imports migrate before runtime and require a clean restart;
// ordinary prepare/JIT/relaunch calls return no credential bytes.

import Foundation
import JITHelperXPC
import ObjectiveC
import os
import PlayportKit
import Security
import SteamClientKit
import SwiftUI

enum BuiltInJit {
    enum Failure: LocalizedError, CustomStringConvertible {
        case notBundled
        case liveContainer
        case noGetTaskAllow
        case noPairingFile
        case spi(String)
        case noConnection
        case helper(String)
        case helperGone
        case cancelled

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .notBundled: "the JIT helper extension is not in the app bundle"
            case .liveContainer: "the JIT helper cannot run inside LiveContainer: choose StikDebug or Another app in Settings › Setup check"
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

    /// The helper never ran, or went away: the app could not start it, reach it, or it died.
    /// The extension is missing from the bundle when a re-signer or SideStore removed it.
    static func didNotRun(_ failure: Failure) -> Bool {
        switch failure {
        case .notBundled, .spi, .noConnection, .helperGone: true
        case .helper(let why): why.hasPrefix("XPC:")
        default: false
        }
    }

    /// PlugIns/PlayportJIT.appex is in the app bundle (a re-signer can strip it).
    static var helperBundled: Bool {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PlayportJIT.appex") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A drop point only: a file found here is moved into the Keychain.
    static var pairingFileURL: URL {
        WineHostRuntime.documents.appendingPathComponent("StikJIT/pairingFile.plist")
    }

    // Legacy main-process store, read only during migration before runtime.
    private static let legacyStore = KeychainSecretStore(service: "dev.playport.app.jit")
    private static let storeKey = "rp-pairing-file"
    private static let revisionCacheKey = "jit.helperPairingRevision"
    private static let credentialBoundary = OSAllocatedUnfairLock(initialState: (runtime: false, exposed: false))
    static var needsCredentialRestart: Bool { credentialBoundary.withLock { $0.exposed } }
    static var mayHandleCredentials: Bool { credentialBoundary.withLock { !$0.runtime } }
    static func legacyCredentialsPresent() throws -> Bool {
        try legacyStore.protection(storeKey) != nil || FileManager.default.fileExists(atPath: pairingFileURL.path)
    }
    static func beginRuntime() -> Bool {
        // Independent of the selected JIT provider and process-local flags.
        guard (try? legacyCredentialsPresent()) == false else { return false }
        return credentialBoundary.withLock { state in
            guard !state.exposed else { return false }
            state.runtime = true
            return true
        }
    }
    private static func willReadCredentials() throws {
        try credentialBoundary.withLock { state in
            guard !state.runtime else { throw Failure.helper("Restart Playport before importing pairing credentials") }
            state.exposed = true
        }
    }
    static var hasPairingFile: Bool { UserDefaults.standard.string(forKey: revisionCacheKey) != nil }

    private static func cacheRevision(_ revision: String?) {
        UserDefaults.standard.set(revision, forKey: revisionCacheKey)
    }

    /// Only metadata crosses back from the helper. A legacy import makes this
    /// process permanently ineligible to initialize the game runtime.
    static func storedPairingRevision(repair: Bool = false) async throws -> String? {
        var revision = try await revisionOperation { helper, reply in helper.pairingStatus(reply: reply) }
        if !repair, try legacyStore.protection(storeKey) != nil {
            try willReadCredentials()
            if let data = try legacyStore.read(storeKey) {
                revision = try await revisionOperation { helper, reply in
                    helper.adoptLegacyPairing(data: Data(data.value), reply: reply)
                }
                try legacyStore.delete(storeKey)
            } else {
                revision = try await revisionOperation { helper, reply in helper.pairingStatus(reply: reply) }
            }
        }
        if !repair, FileManager.default.fileExists(atPath: pairingFileURL.path) {
            try willReadCredentials()
            let data = try Data(contentsOf: pairingFileURL)
            revision = try await revisionOperation { helper, reply in
                helper.adoptLegacyPairing(data: data, reply: reply)
            }
            try FileManager.default.removeItem(at: pairingFileURL)
        }
        cacheRevision(revision)
        return revision
    }

    static func commitGeneratedPairing(_ token: String, replacing expected: String?) async throws {
        let revision = try await revisionOperation { helper, reply in
            helper.commitPairing(candidate: token, replacing: expected, reply: reply)
        }
        // Explicit successful repair may replace a different legacy record.
        // No game can initialize while either old location still exists.
        try legacyStore.delete(storeKey)
        if FileManager.default.fileExists(atPath: pairingFileURL.path) {
            try FileManager.default.removeItem(at: pairingFileURL)
        }
        cacheRevision(revision)
    }

    static func importPairingFile(from source: URL) async throws {
        try willReadCredentials()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        let expected = try await revisionOperation { helper, reply in helper.pairingStatus(reply: reply) }
        let revision = try await revisionOperation { helper, reply in
            helper.importPairing(data: data, replacing: expected, reply: reply)
        }
        cacheRevision(revision)
    }

    static func pair(pin: String, cancelled: OSAllocatedUnfairLock<Bool>,
                     advertise: @escaping @Sendable (String, Data, UInt16) -> Void) async throws -> String {
        guard mayHandleCredentials else { throw Failure.helper("Restart Playport before pairing") }
        guard let token = try await revisionOperation(cancelled: { cancelled.withLock { $0 } }, advertise: advertise,
            { helper, reply in helper.pair(pin: pin, reply: reply) }) else { throw Failure.noPairingFile }
        return token
    }

    static func discardPairing(_ token: String) {
        queue.async {
            _ = withHelper(log: BuiltInJitStatus.log, cancelled: { false }) { helper, reply in
                helper.discardPairing(candidate: token) { error in reply(error.map(Failure.helper)) }
            }
        }
    }

    private static func revisionOperation(cancelled: @escaping @Sendable () -> Bool = { false },
        advertise: (@Sendable (String, Data, UInt16) -> Void)? = nil,
        _ call: @escaping @Sendable (JITHelping, @escaping @Sendable (String?, String?) -> Void) -> Void) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let value = OSAllocatedUnfairLock<String?>(initialState: nil)
                let failure = withHelper(log: BuiltInJitStatus.log, cancelled: cancelled, advertise: advertise) { helper, reply in
                    call(helper) { revision, error in
                        value.withLock { $0 = revision }
                        reply(error.map(Failure.helper))
                    }
                }
                if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume(returning: value.withLock { $0 }) }
            }
        }
    }

    static func requestRelaunch(log: @escaping @Sendable (String) -> Void) -> String? {
        queue.sync {
            withHelper(log: log, cancelled: { false }) { helper, reply in
                helper.relaunch { error in reply(error.map(Failure.helper)) }
            }?.description
        }
    }

    #if !PLAYPORT_RELEASE
    static func checkIsolation() async throws {
        _ = try await revisionOperation { helper, reply in
            helper.isolationProbe { group, error in
                guard let group, error == nil else { reply(nil, error ?? "No helper group"); return }
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "dev.playport.helper.isolation-probe",
                    kSecAttrAccount as String: "read-boundary", kSecAttrAccessGroup as String: group,
                    kSecAttrSynchronizable as String: false, kSecReturnData as String: true]
                var value: CFTypeRef?
                let result = SecItemCopyMatching(query as CFDictionary, &value)
                let denied = result == errSecMissingEntitlement || result == errSecItemNotFound
                helper.clearIsolationProbe { cleanup in
                    reply(nil, cleanup ?? (denied ? nil : "Main could read the helper item, or denial was inconclusive (\(result))"))
                }
            }
        }
    }
    #endif

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
                helper.enableJIT(targetPID: getpid()) { error in
                    reply(error.map(Failure.helper))
                }
            })
        }
    }

    /// StikJIT's device preparation: the readiness indicator.
    static func prepare(candidate: String? = nil, cancelled: OSAllocatedUnfairLock<Bool>? = nil,
                        log: @escaping @Sendable (String) -> Void,
                        done: @escaping @Sendable (_ status: String, _ reason: String?, _ txm: String, _ helperDidNotRun: Bool) -> Void) {
        queue.async {
            let result = OSAllocatedUnfairLock<(String, String?, String)>(initialState: ("not ready", nil, "unknown"))
            nonisolated(unsafe) var neverRan = false
            if let failure = withHelper(log: log,
                                        cancelled: { enablePending() || (cancelled?.withLock { $0 } ?? false) }, { helper, reply in
                helper.prepare(candidate: candidate) { status, reason, txm in
                    result.withLock { $0 = (status, reason, txm) }
                    reply(nil)
                }
            }) {
                if case .cancelled = failure {
                    result.withLock { $0 = ("not checked", nil, "unknown") }
                } else {
                    result.withLock { $0 = ("not ready", failure.description, "unknown") }
                    neverRan = didNotRun(failure)
                }
            }
            let final = result.withLock { $0 }
            done(final.0, final.1, final.2, neverRan)
        }
    }

    static func resetDDI(log: @escaping @Sendable (String) -> Void, done: @escaping @Sendable (Failure?) -> Void) {
        queue.async {
            done(withHelper(log: log, cancelled: enablePending) { helper, reply in
                helper.resetDDI { error in reply(error.map(Failure.helper)) }
            })
        }
    }

    /// Starts the helper, runs one call, waits for its reply, ends the helper.
    /// Returns .cancelled, ending the helper, once `cancelled` holds.
    /// Blocks the calling (serial) queue; never the main thread.
    private static func withHelper(log: @escaping @Sendable (String) -> Void,
                                   cancelled: () -> Bool,
                                   advertise: (@Sendable (String, Data, UInt16) -> Void)? = nil,
                                   _ call: (JITHelping, @escaping @Sendable (Failure?) -> Void) throws -> Void) -> Failure? {
        guard !JitProvider.inLiveContainer else { return .liveContainer }
        guard hasGetTaskAllow else { return .noGetTaskAllow }
        guard !cancelled() else { return .cancelled }
        let helper: JitHelper
        do {
            helper = try JitHelper.start(log: log)
        } catch let f as Failure {
            return f
        } catch {
            return .spi("\(error)")
        }
        helper.advertisement = advertise
        defer { helper.stop() }
        let replied = DispatchSemaphore(value: 0)
        let completion = OSAllocatedUnfairLock(initialState: (finished: false, outcome: Failure?.none))
        let finish: @Sendable (Failure?) -> Void = { failure in
            let won = completion.withLock { state in
                guard !state.finished else { return false }
                state.finished = true
                state.outcome = failure
                return true
            }
            if won { replied.signal() }
        }
        let proxy = helper.proxy { error in finish(.helper("XPC: \(error.localizedDescription)")) }
        do {
            try call(proxy, finish)
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
                finish(.cancelled)
                return completion.withLock { $0.outcome }
            }
            if Date() >= deadline { finish(.helper("no reply in 600 s")); break }
        }
        return completion.withLock { $0.outcome }
    }
}

/// One running helper extension and its XPC connection.
final class JitHelper: NSObject, NSXPCListenerDelegate, JITHost, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let connected = DispatchSemaphore(value: 0)
    var advertisement: (@Sendable (String, Data, UInt16) -> Void)?
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
        c.resume()
        connection = c
        connected.signal()
        return true
    }

    func helperLog(_ line: String) { log("helper: " + line) }
    func pairingAdvertisement(identifier: String, records: Data, port: UInt16) {
        advertisement?(identifier, records, port)
    }
}

/// What Settings › Setup check shows.
@MainActor
final class BuiltInJitStatus: ObservableObject {
    static let shared = BuiltInJitStatus()

    private init() {
        Task {
            do { pairingFile = try await BuiltInJit.storedPairingRevision() != nil }
            catch { detail = String(describing: error) }
        }
    }

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
    /// Why the last check was "not ready", sorted into a class a player can act on.
    @Published private(set) var failureReason: JitFailureReason?
    @Published private(set) var busy = false
    private var checkedThisLaunch = false

    /// Once per launch, when a pairing file is present: mounts the DDI early, so
    /// a title's enable does not wait for the download.
    func checkOnce() {
        guard JitProvider.method == .builtIn, !checkedThisLaunch, pairingFile, LocalDevVPN.tunnelUp, !JitSetup.shared.presented else { return }
        checkedThisLaunch = true
        check()
    }

    /// Generated records can be prepared in memory before replacing the Keychain.
    func check(candidate: String? = nil, cancelled: OSAllocatedUnfairLock<Bool>? = nil,
               then: (@MainActor (String) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        readiness = "checking…"
        status = "checking"
        detail = nil
        failureReason = nil
        BuiltInJit.prepare(candidate: candidate, cancelled: cancelled, log: Self.log) { status, reason, txm, neverRan in
            Task { @MainActor in
                let s = BuiltInJitStatus.shared
                let wasCancelled = cancelled?.withLock { $0 } ?? false
                s.status = wasCancelled ? "not checked" : status
                s.readiness = wasCancelled ? "not checked" : status == "ready" ? "ready (TXM \(txm))" : status
                s.detail = wasCancelled ? nil : reason
                if status == "not ready", !wasCancelled {
                    // The one line a release log keeps for a failed check (decision 0009).
                    let why = JitFailureReason(raw: reason, helperDidNotRun: neverRan)
                    s.failureReason = why
                    Self.log("check failed [\(why.logName)]: \(reason ?? "no reason")")
                }
                s.busy = false
                if s.status == "not checked" { s.checkedThisLaunch = false }
                then?(s.status)
            }
        }
    }

    func generatedPairingCommitted() { pairingFile = true }

    func importPairingFile(_ result: Result<URL, Error>) {
        guard !busy, BuiltInJit.mayHandleCredentials else { detail = "Restart Playport before importing pairing credentials"; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await BuiltInJit.importPairingFile(from: result.get())
                pairingFile = true
                readiness = "not checked"
                status = "not checked"
                detail = "Restarting Playport to clear imported credentials from memory."
                Self.log("pairing file imported into helper; clean restart required")
                AppRestart.shared.restart(notice: nil)
            } catch { detail = "import failed: \(error)" }
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
