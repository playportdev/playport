// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// All lifecycle state lives on the main queue. Native JIT runs only in the helper process.
final class JITWorker: NSObject, NSXPCListenerDelegate, JITHost {
    private let listener = NSXPCListener.anonymous()
    private var request: JITExtensionRequest?
    private var connection: NSXPCConnection?
    private var deadline: DispatchWorkItem?
    private var killDeadline: DispatchWorkItem?
    private var ending: Result<Void, Error>?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var progress: ((String) -> Void)?
    private var ready: (() -> Void)?

    /// Opens and handshakes while the activator is still foreground.
    func open(progress: @escaping (String) -> Void, ready: @escaping () -> Void,
              completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        self.progress = progress
        self.ready = ready
        listener.delegate = self
        listener.resume()
        do {
            guard let plugins = Bundle.main.builtInPlugInsURL else { throw ActivatorFailure(detail: "JIT helper отсутствует в сборке.") }
            request = try JITExtensionRequest(bundle: plugins.appendingPathComponent("PlayportJITWorker.appex"), endpoint: listener.endpoint)
            setDeadline(seconds: 5, message: "JIT helper не подключился за 5 секунд. Повторите попытку.")
        } catch { finish(.failure(error)) }
    }

    /// The helper owns both target launch and JIT under the same cancellation boundary.
    func enable(bundleIdentifier: String, pairing: Data, playport: Bool) {
        guard completion != nil, ending == nil, let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.cancel("JIT helper: \(error.localizedDescription)") }
        } as? ActivatorJITHelping
        guard let proxy else { cancel("JIT helper не предоставил интерфейс активации."); return }
        setDeadline(seconds: 25, message: "Приложение не ответило на активацию JIT за 25 секунд. Возможно, оно не поддерживает этот протокол. Закройте и откройте его перед повторной попыткой.")
        proxy.enableJIT(bundleIdentifier: bundleIdentifier, pairingFile: pairing, playportScript: playport) { error in
            DispatchQueue.main.async {
                if let error { self.stop(.failure(ActivatorFailure(detail: error))) }
                else { self.stop(.success(())) }
            }
        }
    }

    func cancel(_ message: String) { stop(.failure(ActivatorFailure(detail: message))) }

    private func setDeadline(seconds: Double, message: String) {
        deadline?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.cancel(message) }
        deadline = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func stop(_ result: Result<Void, Error>) {
        guard completion != nil, ending == nil else { return }
        ending = result
        ready = nil
        deadline?.cancel()
        if let connection {
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? ActivatorJITHelping
            proxy?.cancel()
        } else {
            // No native work was sent before the connection existed.
            request?.terminate()
            finish(result)
            return
        }
        // cancel() exits on the helper's XPC handler, not its blocked serial worker queue.
        // Do not locally invalidate the connection: remote interruption/invalidation confirms the worker ended.
        let kill = DispatchWorkItem { [weak self] in self?.request?.terminate() }
        killDeadline = kill
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: kill)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: JITHost.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: ActivatorJITHelping.self)
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.finish(self.ending ?? .failure(ActivatorFailure(detail: "JIT helper завершился без результата. Закройте и откройте целевое приложение перед повторной попыткой.")))
            }
        }
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.finish(self.ending ?? .failure(ActivatorFailure(detail: "JIT helper завершился без результата. Закройте и откройте целевое приложение перед повторной попыткой.")))
            }
        }
        connection.resume()
        DispatchQueue.main.async {
            guard self.connection == nil, self.completion != nil else { connection.invalidate(); return }
            self.connection = connection
            if self.ending != nil {
                (connection.remoteObjectProxyWithErrorHandler { _ in } as? ActivatorJITHelping)?.cancel()
                return
            }
            self.deadline?.cancel()
            let ready = self.ready
            self.ready = nil
            ready?()
        }
        return true
    }

    func helperLog(_ line: String) {
        DispatchQueue.main.async { if self.ending == nil { self.progress?(line) } }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        ready = nil
        deadline?.cancel()
        killDeadline?.cancel()
        request?.close()
        request = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        listener.invalidate()
        progress = nil
        completion(result)
    }
}
