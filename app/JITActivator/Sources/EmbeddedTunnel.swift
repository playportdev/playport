// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NetworkExtension

final class EmbeddedTunnel {
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var timeout: DispatchWorkItem?
    private var completion: ((Result<Void, Error>) -> Void)?
    var isConnected: Bool { manager?.connection.status == .connected }

    func connect(_ completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        let providerID = (Bundle.main.bundleIdentifier ?? "dev.poshagator.jitactivator") + ".Tunnel"
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error { self.finish(.failure(error)); return }
                let manager = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
                } ?? NETunnelProviderManager()
                self.manager = manager
                if manager.connection.status == .connected { self.finish(.success(())); return }
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = providerID
                configuration.serverAddress = "10.7.0.1"
                manager.protocolConfiguration = configuration
                manager.localizedDescription = "Playport JIT"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error { self.finish(.failure(error)); return }
                        manager.loadFromPreferences { error in
                            DispatchQueue.main.async {
                                if let error { self.finish(.failure(error)); return }
                                self.start(manager)
                            }
                        }
                    }
                }
            }
        }
    }

    private func start(_ manager: NETunnelProviderManager) {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange,
            object: manager.connection, queue: .main) { [weak self] _ in
                guard let self else { return }
                if manager.connection.status == .connected { self.finish(.success(())) }
                else if manager.connection.status == .invalid {
                    self.finish(.failure(ActivatorFailure(detail: "Не удалось создать VPN. Разрешите конфигурацию VPN в настройках iPhone.")))
                }
            }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(ActivatorFailure(detail: "Встроенный VPN не подключился. Разрешите VPN в настройках и повторите попытку.")))
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        do { try manager.connection.startVPNTunnel() }
        catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        let callback = completion
        completion = nil
        callback?(result)
    }
}
