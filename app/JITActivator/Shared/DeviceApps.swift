// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct DeveloperApp: Identifiable {
    let name: String
    let id: String
    var isPlayport: Bool { id == "dev.playport.app" || id == "dev.poshagator.playport" }
}

final class AppServiceResult {
    var apps: [DeveloperApp] = []
    var lastError = "Сервис приложений не ответил. Проверьте встроенный VPN."
}

let appEntry: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { name, identifier, context in
    guard let name, let identifier, let context else { return }
    let result = Unmanaged<AppServiceResult>.fromOpaque(context).takeUnretainedValue()
    result.apps.append(DeveloperApp(name: String(cString: name), id: String(cString: identifier)))
}

let appLog: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { line, context in
    guard let line, let context else { return }
    let text = String(cString: line)
    if text.contains("failed:") || text == "bad host address" {
        Unmanaged<AppServiceResult>.fromOpaque(context).takeUnretainedValue().lastError = text
    }
}
