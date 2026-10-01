// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer › Probes. Checks the software guest memory contract on
// this phone, not game compatibility. No Wine, JIT, game files or guest code.
import Foundation
import Guest32Experiment
import SwiftUI

@MainActor
final class Guest32Probe: ObservableObject {
    static let shared = Guest32Probe()
    @Published private(set) var busy = false
    @Published private(set) var status = "Memory only; no game code runs"

    private struct Result: Sendable {
        let ok: Bool
        let summary: String
        let log: String
    }

    @discardableResult
    func run() async -> Bool {
        guard !busy else { return false }
        guard !TitleLaunch.shared.running, !TitleLaunch.shared.spent else {
            status = "Restart Playport before the memory experiment"
            return false
        }
        busy = true
        status = "Checking the software memory window…"
        let result = await Task.detached(priority: .utility) {
            let report = g32_probe_native()
            let ok = report.failures == 0 && report.checks == 36
            return Result(ok: ok,
                          summary: "\(report.checks - report.failures)/\(report.checks) checks; \(report.host_page / 1024) KiB host pages; no guest code",
                          log: "guest32: memory-probe \(ok ? "ok" : "failed") checks=\(report.checks) failures=\(report.failures) "
                            + "host_page=\(report.host_page) backing_a=0x\(String(report.backing_a, radix: 16)) "
                            + "backing_b=0x\(String(report.backing_b, radix: 16)) guest_execution=none")
        }.value
        status = result.summary
        busy = false
        AppLog.append(result.log)
        return result.ok
    }
}
