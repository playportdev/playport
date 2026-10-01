// SPDX-License-Identifier: GPL-3.0-or-later
// Dev builds only: the helper-lifetime probe (probe 0 of the cold-relaunch
// research, .work/research/multigame-alternatives.md). A relaunch that the
// app's own JIT helper requests has to outlive the app: the helper is an
// NSExtension this app started. This measures for how long it does.
//
// run(.exit | .kill): starts the helper as a title's enable does, asks it for
// JITHelping.lifetimeProbe (a 50 ms ticker into a file in the helper's own
// Library; when its connection to this app goes, one prepareDevice; with
// hold, the helper also takes its own xpc transaction and ignores SIGTERM), leaves
// it running (no _kill:), lets it tick for 2 s, then ends this process with
// exit(0) or SIGKILL. The moment is kept in Documents/lifetime-probe-host.txt.
//
// report(): on the next launch, starts the helper again and reads that file
// back: the host's end, the helper's last tick after it, and what the
// prepareDevice after the host's end did, into s1-host.log as `jit: probe`
// lines; the whole file goes to Documents/lifetime-probe-<ms>.txt.
//
// Settings › Developer's probes (DeveloperSettings.swift) and the UI driver's probe: action (UIDriver.swift)
// call these.

import Foundation
import JITHelperXPC
import SwiftUI

@MainActor
final class HelperLifetimeProbe: ObservableObject {
    static let shared = HelperLifetimeProbe()

    enum End: String { case exit, kill }
    private enum Read { case text(String), failed(String) }

    @Published private(set) var status: String?
    @Published private(set) var busy = false

    private nonisolated static let interval = 50
    private nonisolated static let cap = 120
    private nonisolated static let grace = 2.0
    private nonisolated static let hostFile = WineHostRuntime.documents.appendingPathComponent("lifetime-probe-host.txt")
    /// The helper this run started: kept so nothing ends it but the host's end.
    nonisolated(unsafe) private static var helper: JitHelper?

    private nonisolated static func log(_ line: String) { WineHostRuntime.appendLog("jit: probe " + line) }
    private nonisolated static var nowMs: Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// Starts the helper's ticker; nil once it ticks, then this process ends
    /// `grace` seconds later. Else why it did not start.
    func run(_ end: End, hold: Bool = false) async -> String? {
        guard !busy else { return "a probe is running" }
        busy = true
        status = "starting the helper…"
        let failure: String? = await withCheckedContinuation { done in
            BuiltInJit.queue.async {
                done.resume(returning: Self.startTicker(hold: hold))
            }
        }
        if let failure {
            busy = false
            status = "failed: \(failure)"
            Self.log("failed: \(failure)")
            return failure
        }
        status = "helper ticking; Playport ends by \(end.rawValue) in \(Int(Self.grace)) s"
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.grace) {
            let ms = Self.nowMs
            try? Data("\(ms) \(end.rawValue) pid=\(getpid())\n".utf8).write(to: Self.hostFile, options: .atomic)
            Self.log("host \(end.rawValue) at \(ms) pid=\(getpid())")
            switch end {
            case .exit: exit(0)
            case .kill: kill(getpid(), SIGKILL)
            }
        }
        return nil
    }

    private nonisolated static func startTicker(hold: Bool) -> String? {
        guard BuiltInJit.hasGetTaskAllow else { return BuiltInJit.Failure.noGetTaskAllow.description }
        let pairing: Data
        do { pairing = try BuiltInJit.pairingData() } catch { return "\(error)" }
        let h: JitHelper
        do { h = try JitHelper.start(log: BuiltInJitStatus.log) } catch { return "\(error)" }
        helper = h
        let replied = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var pid: Int32 = 0
        nonisolated(unsafe) var xpcError: String?
        let proxy = h.proxy { error in
            xpcError = error.localizedDescription
            replied.signal()
        }
        proxy.lifetimeProbe(intervalMs: interval, capS: cap, hold: hold, pairingFile: pairing) { p in
            pid = p
            replied.signal()
        }
        guard replied.wait(timeout: .now() + 10) == .success else { return "the helper did not answer in 10 s" }
        if let xpcError { return "XPC: \(xpcError)" }
        log("helper pid \(pid) ticking every \(interval) ms (cap \(cap) s, hold \(hold)); host pid \(getpid())")
        return nil
    }

    /// Reads the last probe back; the summary, or why there is none.
    func report() async -> String {
        guard !busy else { return "a probe is running" }
        busy = true
        defer { busy = false }
        status = "reading the helper's report…"
        let text: Read = await withCheckedContinuation { done in
            BuiltInJit.queue.async {
                done.resume(returning: Self.readReport())
            }
        }
        let summary: String
        switch text {
        case .failed(let why): summary = "failed: \(why)"
        case .text(let t): summary = Self.summarize(t)
        }
        Self.log("report: \(summary)")
        status = summary
        return summary
    }

    private nonisolated static func readReport() -> Read {
        guard BuiltInJit.hasGetTaskAllow else { return .failed(BuiltInJit.Failure.noGetTaskAllow.description) }
        let h: JitHelper
        do { h = try JitHelper.start(log: BuiltInJitStatus.log) } catch { return .failed("\(error)") }
        defer { h.stop() }
        let replied = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: Read = .failed("no reply")
        let proxy = h.proxy { error in
            out = .failed("XPC: \(error.localizedDescription)")
            replied.signal()
        }
        proxy.lifetimeReport { text in
            out = .text(text)
            replied.signal()
        }
        guard replied.wait(timeout: .now() + 10) == .success else { return .failed("the helper did not answer in 10 s") }
        return out
    }

    /// The host's end against the helper's lines after it.
    private nonisolated static func summarize(_ text: String) -> String {
        guard !text.isEmpty else { return "the helper has no probe file" }
        let saved = WineHostRuntime.documents.appendingPathComponent("lifetime-probe-\(nowMs).txt")
        try? Data(text.utf8).write(to: saved)
        let lines = text.split(separator: "\n").map(String.init)
        let ms: (String) -> Int64? = { Int64($0.split(separator: " ").first ?? "") }
        // Everything but the ticks, and the first and last tick, into the log.
        let ticks = lines.filter { $0.contains(" tick ") }
        for l in lines where !l.contains(" tick ") || l == ticks.first || l == ticks.last { log("helper: \(l)") }
        let host = (try? String(contentsOf: hostFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, let hostMs = ms(host) else {
            return "no host end recorded; \(lines.count) lines, last: \(lines.last ?? "none"); file \(saved.lastPathComponent)"
        }
        try? FileManager.default.removeItem(at: hostFile)
        let last = lines.last.flatMap(ms) ?? hostMs
        let gone = lines.first { $0.contains("host connection") }
        let prepare = lines.last { $0.contains("prepareDevice done") }
        let capped = lines.contains { $0.contains("cap reached") }
        let sigterms = lines.filter { $0.contains("SIGTERM received") }.count
        return "host \(host); helper's last line \(last - hostMs) ms after it"
            + (capped ? " (it ran to its \(cap) s cap)" : "")
            + "; \(gone.map { "host connection lost \(ms($0).map { "\($0 - hostMs)" } ?? "?") ms after" } ?? "no host-connection line")"
            + "; \(prepare.map { "prepareDevice after the host: " + ($0.components(separatedBy: "prepareDevice done: ").last ?? "?") } ?? "no prepareDevice result")"
            + (sigterms > 0 ? "; \(sigterms) SIGTERM ignored" : "")
            + "; \(ticks.count) ticks; file \(saved.lastPathComponent)"
    }
}

