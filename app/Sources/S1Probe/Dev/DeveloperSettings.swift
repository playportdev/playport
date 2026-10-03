// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer, dev builds only (decision 0009): the diagnostics a
// game's next launch runs with (Diagnostics.swift), the memory simulations
// (MemoryLimit), the on-device pairing experiment (iOS 27), the probes
// (HelperLifetimeProbe.swift), the logs and the wine_host ABI. Every control
// is a row on the ring; a choice opens a list picker. The workstation sets
// the same keys with `pp ui --action set:KEY=VALUE` (decision 0012).

import PlayportKit
import SwiftUI
import WineHost

struct DeveloperSettings: View {
    @AppStorage(GPUCapture.key) private var frame = 0
    @AppStorage(Diagnostics.passProfileKey) private var passProfile = false
    @AppStorage(Diagnostics.cpuProfileKey) private var cpuProfile = false
    @AppStorage(MetalValidation.key) private var validation = MetalValidation.Level.off.rawValue
    @AppStorage(RuntimeCounters.key) private var countersOff = false
    @AppStorage(SharedMemoryBroker.key) private var helperOwnedMemory = false
    @AppStorage(SharedMemoryBroker.guestKey) private var helperOwnedGuestMemory = false
    @AppStorage(MemoryLimit.simulatedKey) private var simulated = 0
    @AppStorage(MemoryLimit.simulatedPoolKey) private var simulatedPool = 0
    @ObservedObject private var sharedMemory = SharedMemoryProbe.shared
    @ObservedObject private var probe = HelperLifetimeProbe.shared
    @ObservedObject private var restart = AppRestart.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var builtIn = BuiltInJitStatus.shared
    @State private var hold = false

    var body: some View {
        diagnostics
        memory
        if #available(iOS 27.0, *) { pairingProbe }
        probes
        logs
        SettingsInfoRow(id: "dev:abi", title: "wine_host ABI", value: "\(wine_host_abi_version())")
    }

    // MARK: diagnostics

    @ViewBuilder private var diagnostics: some View {
        PadSectionHeader(text: "Diagnostics").id("diagnostics")
        choice("dev:gpuCapture", "GPU capture", subtitle: "A frame as a Metal .gputrace in the game's folder",
               value: frame == 0 ? "Off" : "Frame \(frame)",
               options: [PadOption(id: "0", label: "Off")] + GPUCapture.frames.map { PadOption(id: "\($0)", label: "Frame \($0)") },
               selected: "\(frame)", note: "From Playport's next start; it costs every frame while on.") { frame = Int($0) ?? 0 }
        SettingsSwitchRow(id: "dev:passProfile", title: "GPU time per pass", subtitle: "[pass-prof] lines in the log",
                          on: $passProfile)
        SettingsSwitchRow(id: "dev:cpuProfile", title: "CPU sampling", subtitle: "[wprof] lines in the log", on: $cpuProfile)
        let levels: [(MetalValidation.Level, String)] = [(.off, "Off"), (.api, "API"), (.shaders, "API and shaders"),
                                                         (.stop, "API, stop at the first error")]
        choice("dev:validation", "Metal validation", subtitle: "Errors go to the device log",
               value: levels.first { $0.0.rawValue == validation }?.1 ?? validation,
               options: levels.map { PadOption(id: $0.0.rawValue, label: $0.1) }, selected: validation,
               note: "From Playport's next start; it costs CPU and GPU time.") { validation = $0 }
        SettingsSwitchRow(id: "dev:counters", title: "Runtime counters", subtitle: "Off from Playport's next start, as a release build",
                          on: Binding(get: { !countersOff }, set: { countersOff = !$0 }))
    }

    // MARK: memory

    @ViewBuilder private var memory: some View {
        PadSectionHeader(text: "Memory").id("memory")
        SettingsSwitchRow(id: "dev:helperMemory", title: "Extra FEX RAM (experiment)",
                          subtitle: "Next Play: helper-owned data, not extra physical RAM", on: $helperOwnedMemory)
        SettingsSwitchRow(id: "dev:helperGuestMemory", title: "Extra guest RAM (experiment)",
                          subtitle: "Next Play: up to 2 GiB of live large guest data backing", on: $helperOwnedGuestMemory)
        // 2 GB refuses every tested game; 3.3 GB is what a copy without the entitlement gets.
        let limits = Self.choices([2048, 3379, 4096], with: simulated)
        choice("dev:simulatedLimit", "Simulated limit", subtitle: "What every Play is checked against",
               value: simulated > 0 ? MemoryNeed.format(mb: simulated) : "Off",
               options: [PadOption(id: "0", label: "Off")] + limits.map { PadOption(id: "\($0)", label: MemoryNeed.format(mb: $0)) },
               selected: "\(simulated)", note: nil) { simulated = Int($0) ?? 0 }
        // Below Hollow Knight's high-water marks, so a Play runs the pool out (docs/evidence/2026-09-28-jit-pool.md).
        let pools = Self.choices([128, 256, 512], with: simulatedPool)
        choice("dev:simulatedPool", "Simulated JIT memory", subtitle: "What every Play gets",
               value: simulatedPool > 0 ? MemoryNeed.format(mb: simulatedPool) : "Off",
               options: [PadOption(id: "0", label: "Off")] + pools.map { PadOption(id: "\($0)", label: MemoryNeed.format(mb: $0)) },
               selected: "\(simulatedPool)", note: nil) { simulatedPool = Int($0) ?? 0 }
    }

    private static func choices(_ base: [Int], with current: Int) -> [Int] {
        current > 0 && !base.contains(current) ? (base + [current]).sorted() : base
    }

    // MARK: on-device pairing (iOS 27)

    @ViewBuilder private var pairingProbe: some View {
        PadSectionHeader(text: "On-device pairing (experiment)").id("pairing")
        PadRow(id: "set:dev:pairing", title: "Pair this iPhone (experiment)", subtitle: pairing.status,
               value: pairing.code, hint: "Pair") {
            guard !pairing.busy, !builtIn.busy, !JitSetup.shared.presented else { return }
            pairing.start()
        }
        if pairing.storedNewPairing { SettingsInfoRow(id: "dev:pairingReadiness", title: "Readiness", value: builtIn.readiness) }
        if pairing.busy { PadRow(id: "set:dev:pairingCancel", title: "Cancel pairing", hint: "Cancel") { pairing.stop() } }
        if pairing.hasNewPairing {
            PadRow(id: "set:dev:pairingUse", title: "Use new pairing", hint: "Use") { if !builtIn.busy { pairing.useNewPairing() } }
        }
    }

    // MARK: probes

    @ViewBuilder private var probes: some View {
        PadSectionHeader(text: "Probes").id("probes")
        PadRow(id: "set:dev:memoryStatus", title: "Extra RAM: read usage", subtitle: sharedMemory.status, hint: "Read") {
            if !sharedMemory.busy { Task { await sharedMemory.reportRuntime() } }
        }
        ForEach([64, 2048, 4096], id: \.self) { mb in
            PadRow(id: "set:dev:memoryBroker:\(mb)", title: "Shared RAM: \(mb) MiB", subtitle: sharedMemory.status, hint: "Measure") {
                if !sharedMemory.busy { Task { _ = await sharedMemory.run(mb: mb) } }
            }
        }
        PadRow(id: "set:dev:helperExit", title: "Helper lifetime: end by exit", subtitle: probe.status, hint: "Run") {
            if !probe.busy { Task { _ = await probe.run(.exit, hold: hold) } }
        }
        PadRow(id: "set:dev:helperKill", title: "Helper lifetime: end by SIGKILL", hint: "Run") {
            if !probe.busy { Task { _ = await probe.run(.kill, hold: hold) } }
        }
        SettingsSwitchRow(id: "dev:helperHold", title: "Helper holds on", subtitle: "Own transaction, ignores SIGTERM", on: $hold)
        PadRow(id: "set:dev:helperReport", title: "Helper lifetime: read the report", hint: "Read") {
            if !probe.busy { Task { _ = await probe.report() } }
        }
        PadRow(id: "set:dev:restart", title: "Restart Playport now", subtitle: "What Playport does after a game, with no game",
               hint: "Restart") {
            if !restart.restarting, !probe.busy { restart.restart(notice: nil) }
        }
    }

    // MARK: logs

    @ViewBuilder private var logs: some View {
        PadSectionHeader(text: "Logs").id("logs")
        let urls = Self.logs
        if urls.isEmpty { SettingsInfoRow(id: "dev:nologs", title: "No logs yet") }
        ForEach(urls, id: \.self) { url in
            PadRow(id: "set:dev:log:\(url.lastPathComponent)", title: url.lastPathComponent, accessory: .chevron, hint: "Share") {
                ProblemReport.present([url])
            }
        }
    }

    /// The host log, the Steam log and any title's player log (a `-logFile C:\...` argument).
    private static var logs: [URL] {
        let fm = FileManager.default
        let driveC = LibraryModel.paths.games.deletingLastPathComponent()
        let players = ((try? fm.contentsOfDirectory(at: driveC, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ([AppLog.url, SteamLog.url] + players).filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: pieces

    /// A row whose value comes from a list picker.
    private func choice(_ id: String, _ title: String, subtitle: String?, value: String, options: [PadOption], selected: String,
                        note: String?, choose: @escaping (String) -> Void) -> some View {
        PadRow(id: "set:" + id, title: title, subtitle: subtitle, value: value, accessory: .chevron, hint: "Change") {
            PadModal.shared.picker(title: title, context: "Settings · Developer", note: note, options: options,
                                   selected: selected, choose: choose)
        }
    }
}
