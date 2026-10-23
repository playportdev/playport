// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import StikJIT
import Darwin

@objc(PlayportActivatorJITHelper)
final class JITWorkerExtension: NSObject, NSExtensionRequestHandling, ActivatorJITHelping {
    private let queue = DispatchQueue(label: "playport.jit-activator.worker", qos: .userInitiated)
    private let fileLock = NSLock()
    private var pairingDirectory: URL?
    private var context: NSExtensionContext?
    private var connection: NSXPCConnection?
    private var host: JITHost?
    private static let ddi = DDIPaths.default(in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StikJIT"))

    func beginRequest(with context: NSExtensionContext) {
        NSLog("Playport JIT worker: beginRequest pid=%d", getpid())
        guard let item = context.inputItems.first as? NSExtensionItem,
              let endpoint = item.userInfo?[jitHelperEndpointKey] as? NSXPCListenerEndpoint else {
            context.cancelRequest(withError: NSError(domain: "PlayportJITWorker", code: 1))
            return
        }
        self.context = context
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.exportedInterface = NSXPCInterface(with: ActivatorJITHelping.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: JITHost.self)
        connection.invalidationHandler = { [weak self] in self?.cancel() }
        connection.interruptionHandler = { [weak self] in self?.cancel() }
        connection.resume()
        NSLog("Playport JIT worker: XPC resumed pid=%d", getpid())
        self.connection = connection
        host = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.cancel() } as? JITHost
        host?.helperLog("JIT helper подключён.")
    }

    func enableJIT(bundleIdentifier: String, pairingFile: Data, playportScript: Bool, reply: @escaping (String?) -> Void) {
        queue.async {
            do {
                try self.withPairingFile(pairingFile) { file in
                    self.host?.helperLog("Открываем приложение…")
                    let result = AppServiceResult()
                    let pid = pairingFile.withUnsafeBytes { bytes in
                        playport_launch_app(bytes.bindMemory(to: UInt8.self).baseAddress, pairingFile.count, "10.7.0.1", bundleIdentifier,
                            appLog, Unmanaged.passUnretained(result).toOpaque())
                    }
                    guard pid > 0, pid <= UInt32(Int32.max) else {
                        throw NSError(domain: "PlayportJITWorker", code: 3, userInfo: [NSLocalizedDescriptionKey: result.lastError])
                    }
                    let script: StikJIT.Script
                    if playportScript {
                        guard let url = Bundle.main.url(forResource: "playport-universal", withExtension: "js") else {
                            throw NSError(domain: "PlayportJITWorker", code: 2, userInfo: [NSLocalizedDescriptionKey: "В JIT helper отсутствует скрипт Playport."])
                        }
                        script = .custom(url)
                    } else { script = .universal }
                    try StikJIT.enableJIT(targetPID: Int32(pid), pairingFile: file, ddiPaths: Self.ddi, script: script,
                        preparationProgress: { self.host?.helperLog(Self.describe($0)) },
                        progress: { self.host?.helperLog($0) })
                }
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    // The cancellation message is serviced by XPC, never by the possibly blocked JIT queue.
    func cancel() {
        removePairingDirectory()
        _exit(0)
    }

    private func withPairingFile<T>(_ data: Data, body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("pairing.plist")
        fileLock.lock()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete])
            pairingDirectory = directory
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            fileLock.unlock()
            removePairingDirectory()
            throw error
        }
        fileLock.unlock()
        defer { removePairingDirectory() }
        return try body(file)
    }

    private func removePairingDirectory() {
        fileLock.lock()
        defer { fileLock.unlock() }
        if let directory = pairingDirectory { try? FileManager.default.removeItem(at: directory) }
        pairingDirectory = nil
    }

    private static func describe(_ stage: StikJIT.PreparationStage) -> String {
        switch stage {
        case .checkingReachability: return "Проверка подключения к iPhone…"
        case .checkingDDI: return "Проверка образа разработчика…"
        case .downloadingDDI(let fraction, _): return "Загрузка образа разработчика: \(Int(fraction * 100))%"
        case .mountingDDI(let fraction): return "Подключение образа разработчика: \(Int(fraction * 100))%"
        case .verifyingDDI: return "Проверка образа разработчика…"
        case .ready: return "Активация JIT…"
        @unknown default: return "Подготовка JIT…"
        }
    }
}
