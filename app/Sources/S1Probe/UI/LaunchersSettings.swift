// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Launchers (docs/plans/2026-10-12-launchers.md, Where a launcher lives in the UI): one
// row per publisher's launcher (PlayportKit PublisherLauncher) with Open, a launch whose title is
// the launcher itself, started standalone in the shared prefix with the launcher's own play
// settings (Windows services, its JIT pool, its backend). Dev builds only until a launcher passes
// Stage 1 (SettingsSection.all). A launcher the prefix does not record, or whose executable is not
// in the folder it records, reads "Not installed" and has no Open. The driver's
// `open-launcher:ID` calls the same LauncherOpen.open. Dev builds take the runtime keys and FEX's
// inputs saved under the launcher's title id (`launcher-rockstar`), as a game's Play does.

import Foundation
import PlayportKit
import SwiftUI
import WineHost

@MainActor
enum LauncherOpen {
    static func log(_ line: String) { WineHostRuntime.appendLog("launcher: " + line) }

    /// The executable's DOS path when the launcher is installed in the prefix: the folder its
    /// installer recorded (system.reg, as the runtime last saved it), and the file in it.
    nonisolated static func installedPath(_ l: PublisherLauncher, prefix: URL) -> String? {
        let hive = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        guard let dos = l.executablePath(systemHive: hive) else { return nil }
        var tp = title_path()
        var msg = [CChar](repeating: 0, count: 512)
        return title_path_resolve(prefix.path, dos, &tp, &msg, msg.count) == 0 ? dos : nil
    }

    #if !PLAYPORT_RELEASE
    /// Deletes the launcher's saved window settings file in the prefix user's profile (a dev
    /// build's Launchers row and `forget-launcher-window:ID`). Nil on success, else the failure.
    static func forgetWindowSettings(_ l: PublisherLauncher) -> String? {
        let profile = WineHostRuntime.shared.prefixURL.appendingPathComponent("drive_c/users/playport")
        do {
            let removed = try l.forgetWindowSettings(profile: profile)
            log("forget-window \(l.id): \(removed ? "removed" : "absent") \(l.windowSettingsFile ?? "none")")
            return nil
        } catch {
            log("forget-window \(l.id): not removed \(l.windowSettingsFile ?? "none") (\(error))")
            return "\(error)"
        }
    }
    #endif

    /// Open: the setup checks a Play runs, then TitleLaunch with the launcher's settings. False
    /// when a launch is running or spent, setup was cancelled, or the launcher is not installed.
    static func open(_ l: PublisherLauncher) async -> Bool {
        guard !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return false }
        guard SetupState.shared.beforePlay(steamGame: false) else { return false }
        guard await JitSetup.shared.ensureReady() else { return false }
        guard !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return false }
        let prefix = WineHostRuntime.shared.prefixURL
        guard let exe = await Task.detached(priority: .userInitiated, operation: { installedPath(l, prefix: prefix) }).value else {
            log("open \(l.id): not installed (no \(l.installValue) under \(l.installKey), or no \(l.executable) in it)")
            return false
        }
        // Windows services (decision 0107): RpcSs's entry and the SCM's start timeout, topped up
        // as for a game's play.
        if l.windowsServices {
            do {
                try PrefixRegistryFile(prefix: prefix).add(WindowsServices.rpcss + [WindowsServices.startTimeout])
                log("open \(l.id): Windows services on; RpcSs's service entry and the start timeout topped up in the prefix")
            } catch {
                log("open \(l.id): RpcSs's service entry and the start timeout not written (\(error))")
            }
        }
        await Task.detached(priority: .userInitiated) { EmulatorCache.keepWithinBudget { log in
            WineHostRuntime.appendLog("launcher: " + log)
        } }.value
        // The settings saved under the launcher's title id over its own runtime keys: runtime keys
        // and FEX's inputs, a dev build's as for a game's Play (decision 0034); the player's app
        // runs the launcher's own.
        let defaults = l.openSettings(saved: nil)
        #if PLAYPORT_RELEASE
        let saved = defaults
        #else
        let saved = l.openSettings(saved: LaunchSettingsStore.shared.settings(for: l.titleID))
        #endif
        if saved != defaults {
            log("open \(l.id): saved settings runtime=\(saved.config.keys.sorted().map { "\($0)=\(saved.config[$0]!)" }) "
                + "ordering=\(MemoryOrdering.Setting.allCases.compactMap { s in saved.ordering[s].map { "\(s.rawValue)=\($0)" } }) "
                + "maxInst=\(saved.maxInst.map(String.init) ?? "profile") x87Reduced=\(saved.x87Reduced.map { String($0) } ?? "profile") "
                + "diskCache=\(saved.diskCache.map { String($0) } ?? "default")")
        }
        let fex = FEXProfile.launch(appID: nil, exe: exe, ordering: saved.ordering, maxInst: saved.maxInst,
                                    x87Reduced: saved.x87Reduced, diskCache: saved.diskCache)
        guard TitleLaunch.shared.start(title: l.name, titleID: l.titleID, exe: exe, args: l.arguments, config: saved.config,
                                       graphics: l.graphics, graphicsEnvironment: l.graphicsEnvironment,
                                       fex: fex, windowsServices: l.windowsServices,
                                       jitPoolMB: l.jitPoolMB, exhaustionGrace: l.exhaustionGrace) else { return false }
        log("open \(l.id) on \(l.graphics.rawValue): \(exe) \(l.arguments.joined(separator: " "))")
        return true
    }
}

struct LaunchersSettings: View {
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var launchSettings = LaunchSettingsStore.shared
    /// Each launcher's executable when installed; absent until read.
    @State private var installed: [String: String?] = [:]

    var body: some View {
        ForEach(PublisherLauncher.all) { l in
            let path = installed[l.id] ?? nil
            let read = installed[l.id] != nil
            PadRow(id: "set:launcher-" + l.id, title: l.name,
                   subtitle: read ? (path == nil ? "Not installed" : "Installed") : "…",
                   hint: path != nil && !launch.running ? "Open" : "") {
                guard path != nil, !launch.running else { return }
                Task { _ = await LauncherOpen.open(l) }
            }
        }
        #if !PLAYPORT_RELEASE
        // A game page's Runtime keys row, for the launchers' title ids (`env.FEX_SMCCHECKS=none`).
        ForEach(PublisherLauncher.all) { l in
            let runtime = launchSettings.binding(for: l.titleID)
            let keys = runtime.wrappedValue.runtime.trimmingCharacters(in: .whitespaces)
            PadRow(id: "set:launcher-" + l.id + "-runtime", title: "Runtime keys",
                   subtitle: keys.isEmpty || LaunchSettings.runtimeKeys(keys) != nil ? l.name : "Not key=value items: not used",
                   value: keys.isEmpty ? "None" : keys, accessory: .chevron, changed: !keys.isEmpty, style: .plain,
                   reset: keys.isEmpty ? nil : { runtime.wrappedValue.runtime = "" }) {
                PadModal.shared.keyboard(title: "Runtime keys", text: runtime.wrappedValue.runtime,
                                         placeholder: "For example env.FEX_SMCCHECKS=none",
                                         maxLength: 200) { runtime.wrappedValue.runtime = $0 }
            }
        }
        // Deletes the launcher's own saved window settings file (PublisherLauncher.windowSettingsFile),
        // as the driver's `forget-launcher-window:ID` does (PLA-401).
        ForEach(PublisherLauncher.all.filter { $0.windowSettingsFile != nil }) { l in
            PadRow(id: "set:launcher-" + l.id + "-forget-window", title: "Forget the launcher's saved window settings",
                   subtitle: l.name, style: .plain, hint: launch.running ? "" : "Forget") {
                guard !launch.running else { return }
                _ = LauncherOpen.forgetWindowSettings(l)
            }
        }
        #endif
        SettingsNote(text: "Open starts the launcher by itself, with no game.")
            .task {
                let prefix = WineHostRuntime.shared.prefixURL
                for l in PublisherLauncher.all {
                    let p = await Task.detached(priority: .utility) { LauncherOpen.installedPath(l, prefix: prefix) }.value
                    installed[l.id] = .some(p)
                }
            }
    }
}
