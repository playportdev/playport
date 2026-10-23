// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

@main
struct ActivatorApp: App {
    @StateObject private var model = ActivatorModel()
    var body: some Scene {
        WindowGroup {
            ActivatorView(model: model)
                .onOpenURL { url in
                    if url.isFileURL { model.importPairing(.success(url)) }
                }
        }
    }
}

struct ActivatorView: View {
    @ObservedObject var model: ActivatorModel
    @State private var importing = false
    @State private var search = ""
    private var visibleApps: [DeveloperApp] {
        model.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.error == nil ? model.status : "Не удалось выполнить действие")
                                .font(.headline)
                            if let error = model.error { Text(error).font(.subheadline).foregroundStyle(.red).textSelection(.enabled) }
                        }
                    } icon: {
                        if model.busy { ProgressView() }
                        else { Image(systemName: model.error != nil ? "exclamationmark.triangle.fill" : model.activatedID != nil ? "checkmark.circle.fill" : "bolt.fill")
                                .foregroundStyle(model.error != nil ? .orange : .blue) }
                    }
                    .padding(.vertical, 6)
                    if model.canCancel { Button("Отменить активацию", role: .cancel, action: model.cancelActivation) }
                }
                Section {
                    if model.apps.isEmpty {
                        ContentUnavailableView {
                            Label("Выберите приложение", systemImage: "app.badge")
                        } description: {
                            Text(model.hasPairing ? "Подключите встроенный VPN, чтобы загрузить приложения этого iPhone." : "Сначала импортируйте pairing-файл этого iPhone и разрешите встроенный VPN.")
                        } actions: {
                            Button(model.hasPairing ? "Загрузить приложения" : "Настроить") {
                                if model.hasPairing { model.refresh() } else { model.showSetup = true }
                            }.disabled(model.busy)
                        }
                    } else {
                        ForEach(visibleApps) { app in
                            Button { model.activate(app) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: app.isPlayport ? "gamecontroller.fill" : "app.fill")
                                        .font(.title2).foregroundStyle(.blue).frame(width: 32)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(app.name).font(.headline).foregroundStyle(.primary)
                                        Text(app.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: model.activatedID == app.id ? "checkmark.circle.fill" : "bolt.circle.fill")
                                        .font(.title2).foregroundStyle(model.activatedID == app.id ? .green : .blue)
                                }.padding(.vertical, 5)
                            }.disabled(model.busy)
                        }
                    }
                } header: { Text("Приложения") } footer: {
                    Text("Показаны приложения для отладки. На iOS 26 приложение должно поддерживать JIT-активатор. Произвольным приложениям из App Store выдать JIT нельзя.")
                }
            }
            .navigationTitle("Jit activator")
            .searchable(text: $search, prompt: "Найти приложение")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSetup = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Настройка")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.busy).accessibilityLabel("Обновить приложения")
                }
            }
            .sheet(isPresented: $model.showSetup) { setup }
        }
    }

    private var setup: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Включите режим разработчика в настройках iPhone: Конфиденциальность и безопасность → Режим разработчика.", systemImage: "iphone")
                } header: { Text("1. Режим разработчика") }
                Section {
                    Label(model.hasPairing ? "Pairing-файл сохранён в связке ключей" : "Нужен pairing-файл этого iPhone", systemImage: model.hasPairing ? "checkmark.shield.fill" : "key.fill")
                    Button(model.hasPairing ? "Заменить pairing-файл" : "Импортировать pairing-файл") { importing = true }
                        .disabled(model.busy)
                } header: { Text("2. Связать iPhone") } footer: {
                    Text("Создайте RemotePairing-файл для этого iPhone на компьютере и выберите его в Файлах. Файл хранится только на этом устройстве.")
                }
                Section {
                    Button("Подключить VPN и загрузить приложения", action: model.connectVPN)
                        .disabled(model.busy || !model.hasPairing)
                    if model.busy { ProgressView(model.status) }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                } header: { Text("3. Встроенный VPN") } footer: {
                    Text("Разрешите добавление VPN. Он соединяет активатор с этим же iPhone; интернет-трафик через него не проходит. Первая подготовка может загрузить образ разработчика.")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], onCompletion: model.importPairing)
            .navigationTitle("Настройка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { model.showSetup = false } } }
        }
    }
}
