// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation
import StikJIT
import UIKit

final class ActivatorModel: ObservableObject {
    @Published private(set) var apps: [DeveloperApp] = []
    @Published private(set) var busy = false
    @Published private(set) var canCancel = false
    @Published private(set) var hasPairing = false
    @Published private(set) var status = "Выберите приложение, чтобы активировать JIT."
    @Published private(set) var error: String?
    @Published private(set) var activatedID: String?
    @Published var showSetup = false
    private let queue = DispatchQueue(label: "playport.jit-activator", qos: .userInitiated)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var operationID: UUID?
    private let tunnel = EmbeddedTunnel()
    private var expiredOperation: UUID?
    private var jitWorker: JITWorker?
    private static let ddi = DDIPaths.default(in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StikJIT"))

    init() {
        do { hasPairing = try PairingStore.load() != nil }
        catch { self.error = error.localizedDescription }
        showSetup = !hasPairing
    }

    func importPairing(_ result: Result<URL, Error>) {
        guard !busy else { return }
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= 1_048_576 else {
                throw ActivatorFailure(detail: "Выберите pairing-файл этого iPhone размером до 1 МБ.")
            }
            try PairingStore.save(data)
            hasPairing = true
            error = nil
            status = "Pairing-файл сохранён. Подключите встроенный VPN и обновите список."
        } catch { self.error = error.localizedDescription }
    }

    func connectVPN() { refresh() }

    func refresh() {
        perform(initial: "Проверка iPhone и загрузка приложений…", background: false) { data, file, update in
            try Self.prepare(file, update: update)
            let result = AppServiceResult()
            let code = data.withUnsafeBytes { bytes in
                playport_list_developer_apps(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, "10.7.0.1",
                    appEntry, appLog, Unmanaged.passUnretained(result).toOpaque())
            }
            guard code == 0 else { throw ActivatorFailure(detail: result.lastError) }
            let ownID = Bundle.main.bundleIdentifier
            let apps = result.apps.filter { $0.id != ownID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return Outcome(apps: apps, message: apps.isEmpty ? "Приложений для отладки не найдено." : "Нажмите приложение, чтобы открыть его и активировать JIT.")
        }
    }

    func activate(_ app: DeveloperApp) {
        perform(initial: "Подготовка JIT для \(app.name)…", background: true) { data, file, update in
            try Self.prepare(file, update: update)
            return Outcome(target: app, pairing: data, message: "Запуск JIT helper…")
        }
    }

    func cancelActivation() {
        jitWorker?.cancel("Активация JIT отменена. Если приложение перестало отвечать, закройте и откройте его.")
    }

    private struct Outcome {
        var apps: [DeveloperApp]? = nil
        var target: DeveloperApp? = nil
        var pairing: Data? = nil
        var message: String
    }
    private func perform(initial: String, background: Bool,
                         work: @escaping (Data, URL, @escaping (String) -> Void) throws -> Outcome) {
        guard !busy else { return }
        guard hasPairing else { showSetup = true; return }
        if !tunnel.isConnected {
            busy = true
            error = nil
            status = "Подключение встроенного VPN… Разрешите VPN, если iOS спросит."
            tunnel.connect { result in
                self.busy = false
                switch result {
                case .success: self.perform(initial: initial, background: background, work: work)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            return
        }
        let id = UUID()
        expiredOperation = nil
        operationID = id
        busy = true
        error = nil
        activatedID = nil
        status = initial
        if background {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Activate JIT") { [weak self] in
                guard let self else { return }
                self.expiredOperation = id
                let message = "Истекло время фоновой активации. Если приложение перестало отвечать, закройте и откройте его перед повторной попыткой."
                self.error = message
                self.jitWorker?.cancel(message)
                self.endBackgroundTask()
            }
        }
        queue.async {
            let outcome: Result<Outcome, Error>
            do {
                guard let data = try PairingStore.load() else { throw ActivatorFailure(detail: "Импортируйте pairing-файл.") }
                outcome = .success(try PairingStore.withFile(data) { file in
                    try work(data, file) { message in
                        DispatchQueue.main.async { if self.operationID == id { self.status = message } }
                    }
                })
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard self.operationID == id else { return }
                guard self.expiredOperation != id else {
                    self.finishOperation(id, result: .failure(ActivatorFailure(detail: self.error ?? "Активация остановлена.")))
                    return
                }
                switch outcome {
                case .success(let value):
                    if let target = value.target, let pairing = value.pairing {
                        self.openWorker(for: target, pairing: pairing, operation: id)
                    } else {
                        if let apps = value.apps { self.apps = apps; self.showSetup = false }
                        self.status = value.message
                        self.finishOperation(id, result: .success(()))
                    }
                case .failure(let failure): self.finishOperation(id, result: .failure(failure))
                }
            }
        }
    }

    private func openWorker(for target: DeveloperApp, pairing: Data, operation id: UUID) {
        let worker = JITWorker()
        jitWorker = worker
        canCancel = true
        status = "Запуск JIT helper…"
        worker.open(progress: { message in
            if self.operationID == id { self.status = message }
        }, ready: {
            guard self.operationID == id, self.expiredOperation != id else { return }
            self.status = "Открываем \(target.name)…"
            worker.enable(bundleIdentifier: target.id, pairing: pairing, playport: target.isPlayport)
        }, completion: { result in
            self.finishOperation(id, result: result, target: target)
        })
    }

    private func finishOperation(_ id: UUID, result: Result<Void, Error>, target: DeveloperApp? = nil) {
        guard operationID == id else { return }
        operationID = nil
        jitWorker = nil
        busy = false
        canCancel = false
        endBackgroundTask()
        let outcome: Result<Void, Error> = expiredOperation == id
            ? .failure(ActivatorFailure(detail: error ?? "Истекло время фоновой активации.")) : result
        switch outcome {
        case .success:
            if let target {
                activatedID = target.id
                status = "JIT активирован для \(target.name). После закрытия приложения активируйте его снова."
            }
        case .failure(let error): self.error = error.localizedDescription
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    private static func prepare(_ file: URL, update: @escaping (String) -> Void) throws {
        switch StikJIT.prepareDevice(pairingFile: file, paths: ddi, progress: { update(describe($0)) }) {
        case .ready: return
        case .unreachable(let reason):
            throw ActivatorFailure(detail: "Нет подключения к iPhone. Подключите встроенный VPN. \(reason)")
        case .preparationFailed(let reason): throw ActivatorFailure(detail: "Не удалось подготовить iPhone. \(reason)")
        @unknown default: throw ActivatorFailure(detail: "Неизвестное состояние подготовки iPhone. Обновите активатор.")
        }
    }

    private static func describe(_ stage: StikJIT.PreparationStage) -> String {
        switch stage {
        case .checkingReachability: return "Проверка подключения к iPhone…"
        case .checkingDDI: return "Проверка образа разработчика…"
        case .downloadingDDI(let fraction, _): return "Загрузка образа разработчика: \(Int(fraction * 100))%"
        case .mountingDDI(let fraction): return "Подключение образа разработчика: \(Int(fraction * 100))%"
        case .verifyingDDI: return "Проверка образа разработчика…"
        case .ready: return "iPhone готов."
        @unknown default: return "Подготовка iPhone…"
        }
    }
}
