// SPDX-License-Identifier: GPL-3.0-or-later
// Settings → Developer → Probes. No runtime, store session or real credentials.
import AuthProbe
import Foundation
import SwiftUI

@MainActor
final class NativeAuthProbe: ObservableObject {
    static let shared = NativeAuthProbe()
    @Published private(set) var busy = false
    @Published private(set) var status: String?

    func run() async -> String? {
        guard !busy else { return "native authentication probe is already running" }
        busy = true
        status = "Checking native authentication…"
        let result = await Task.detached(priority: .utility) {
            var buffer = [CChar](repeating: 0, count: 1024)
            let rc = playport_native_auth_probe(&buffer, buffer.count)
            return (rc, String(cString: buffer))
        }.value
        status = result.1
        WineHostRuntime.appendLog(result.1)
        busy = false
        return result.0 == 0 ? nil : result.1
    }
}
