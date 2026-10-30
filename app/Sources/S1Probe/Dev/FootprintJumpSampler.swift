// SPDX-License-Identifier: GPL-3.0-or-later
// Dev builds only: the footprint-jump sampler (PLA-476). Run l9's last `[proc-mem]` sample came
// 9.9 s before its load step, and its 320 MB excess over d1 had no line to attribute it. From a
// launch's start to its end, every 250 ms this reads the app's phys footprint, and when
// PlayportKit's FootprintJumpTrigger fires (near the limit: +300 MB over the last firing, or
// +300 MB in one tick) it logs, cheapest first, so a sample inside a load step survives a kill
// that cuts the walk (run l10 lost its in-step sample that way):
// 1. on the tick's queue, one `title: [fp-sample]` line: TASK_VM_INFO's fields beyond the
//    runtime's `[footprint]` line, and, when this process may read it, its memory ledger
//    (MemoryLedger), which holds phys_footprint's terms TASK_VM_INFO lacks
//    (alternate_accounting, iokit_mapped, page_table);
// 2. off it, a donor-pool stats line `at footprint N MB` (DonorPool.report), so the donor-backed
//    term is current;
// 3. then a forced `[proc-mem]` walk headed `footprint N MB` (wine_host_process_memory_log),
//    and a `[fp-sample] … walk N ms` line once it ends.
// A jump while the last walk still runs logs line 1 only (FootprintJumpTrigger.Firing.walks).
// The ledger is probed once at the start; its return code is logged, and a refusal leaves it out.

import Foundation
import HostIO
import MemoryLedger
import PlayportKit
import WineHost

final class FootprintJumpSampler: @unchecked Sendable {
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "footprint-jump.tick", qos: .utility))
    private let work = DispatchQueue(label: "footprint-jump.work", qos: .utility)
    private let lock = NSLock()
    private var trigger = FootprintJumpTrigger()
    private var busy = false
    private var ledgerReadable = false
    private let start = Date()

    private static func log(_ line: String) { WineHostRuntime.appendLog("title: " + line) }

    /// Starts the ticks; stop() ends them.
    static func start() -> FootprintJumpSampler {
        let s = FootprintJumpSampler()
        s.work.async { s.probeLedger() }
        s.timer.schedule(deadline: .now() + .milliseconds(FootprintJumpTrigger.tickMS),
                         repeating: .milliseconds(FootprintJumpTrigger.tickMS), leeway: .milliseconds(20))
        s.timer.setEventHandler { s.tick() }
        s.timer.resume()
        log("[fp-sample] armed at the limit less \(FootprintJumpTrigger.armBelowLimitMB) MB: a sample at "
            + "+\(FootprintJumpTrigger.levelStepMB) MB over the last (\(Int(FootprintJumpTrigger.spacingS)) s apart) "
            + "or +\(FootprintJumpTrigger.jumpMB) MB in one \(FootprintJumpTrigger.tickMS) ms tick")
        return s
    }

    func stop() { timer.cancel() }

    private func probeLedger() {
        var report = [CChar](repeating: 0, count: 1024)
        let rc = pp_memory_ledger_self(&report, report.count)
        lock.lock(); ledgerReadable = rc == 0; lock.unlock()
        Self.log("[fp-sample] ledger probe rc=\(rc)" + (rc == 0 ? " " + String(cString: report) : ""))
    }

    private func tick() {
        var m = host_memory()
        guard host_memory_read(&m) == 0 else { return }
        let footprint = Int(m.footprint >> 20)
        let limit = m.available > 0 ? Int((m.available + m.footprint) >> 20) : nil
        let elapsed = Date().timeIntervalSince(start)
        lock.lock()
        let firing = trigger.tick(at: elapsed, footprintMB: footprint, limitMB: limit, busy: busy)
        if firing?.walks == true { busy = true }
        let readable = ledgerReadable
        lock.unlock()
        guard let firing else { return }
        logCheapLine(footprintMB: footprint, firing: firing, elapsed: elapsed, ledgerReadable: readable)
        guard firing.walks else { return }
        work.async { [self] in
            DonorPool.report("footprint \(footprint) MB")
            let t0 = Date()
            wine_host_process_memory_log("footprint \(footprint) MB", 1)
            Self.log(String(format: "[fp-sample] footprint %d MB (%@) walk %.0f ms", footprint,
                            firing.reason.rawValue, Date().timeIntervalSince(t0) * 1000))
            lock.lock(); busy = false; lock.unlock()
        }
    }

    private func logCheapLine(footprintMB: Int, firing: FootprintJumpTrigger.Firing, elapsed: TimeInterval,
                              ledgerReadable: Bool) {
        var ledger = ""
        if ledgerReadable {
            var report = [CChar](repeating: 0, count: 1024)
            if pp_memory_ledger_self(&report, report.count) == 0 { ledger = " ledger: " + String(cString: report) }
        }
        Self.log(String(format: "[fp-sample] footprint %d MB (%@%@) at +%.2f s: ", footprintMB, firing.reason.rawValue,
                        firing.walks ? "" : ", no walk: the last still runs", elapsed) + Self.vmInfo() + ledger)
    }

    /// TASK_VM_INFO's fields in MB, those the runtime's `[footprint]` line does not carry included.
    private static func vmInfo() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "task_info \(kr)" }
        func mb(_ v: UInt64) -> String { String(v >> 20) }
        func mb(_ v: Int64) -> String { String(v >> 20) }
        let fields: [(String, String)] = [
            ("phys", mb(info.phys_footprint)), ("resident", mb(info.resident_size)), ("device", mb(info.device)),
            ("internal", mb(info.internal)), ("external", mb(info.external)), ("reusable", mb(info.reusable)),
            ("compressed", mb(info.compressed)),
            ("purgeable_volatile_pmap", mb(info.purgeable_volatile_pmap)),
            ("purgeable_volatile_resident", mb(info.purgeable_volatile_resident)),
            ("purgeable_volatile_virtual", mb(info.purgeable_volatile_virtual)),
            ("ledger_purgeable_volatile", mb(info.ledger_purgeable_volatile + info.ledger_purgeable_volatile_compressed)),
            ("ledger_purgeable_nonvolatile",
             mb(info.ledger_purgeable_nonvolatile + info.ledger_purgeable_novolatile_compressed)),
            ("graphics", mb(info.ledger_tag_graphics_footprint + info.ledger_tag_graphics_footprint_compressed)),
            ("graphics_nofootprint",
             mb(info.ledger_tag_graphics_nofootprint + info.ledger_tag_graphics_nofootprint_compressed)),
            ("network", mb(info.ledger_tag_network_nonvolatile + info.ledger_tag_network_nonvolatile_compressed)),
            ("network_volatile", mb(info.ledger_tag_network_volatile + info.ledger_tag_network_volatile_compressed)),
            ("media", mb(info.ledger_tag_media_footprint + info.ledger_tag_media_footprint_compressed)),
            ("media_nofootprint", mb(info.ledger_tag_media_nofootprint + info.ledger_tag_media_nofootprint_compressed)),
            ("neural", mb(info.ledger_tag_neural_footprint + info.ledger_tag_neural_footprint_compressed)),
            ("neural_nofootprint",
             mb(info.ledger_tag_neural_nofootprint + info.ledger_tag_neural_nofootprint_compressed)),
            ("limit_remaining", mb(info.limit_bytes_remaining)), ("decompressions", String(info.decompressions)),
        ]
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
