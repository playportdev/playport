// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Launchers (docs/plans/2026-10-12-launchers.md, Where a launcher lives in the UI): one
// row per publisher's launcher (PlayportKit PublisherLauncher) with Open, a launch whose title is
// the launcher itself, started standalone in the shared prefix with the launcher's own play
// settings (Windows services, its JIT pool, its backend). Dev builds only until a launcher passes
// Stage 1 (SettingsSection.all). A launcher the prefix does not record, or whose executable is not
// in the folder it records, reads "Not installed" and has no Open. The driver's
// `open-launcher:ID` calls the same LauncherOpen.open.

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
        let fex = FEXProfile.launch(appID: nil, exe: exe, ordering: MemoryOrdering())
        guard TitleLaunch.shared.start(title: l.name, titleID: l.titleID, exe: exe, args: l.arguments,
                                       graphics: l.graphics, fex: fex, windowsServices: l.windowsServices,
                                       jitPoolMB: l.jitPoolMB) else { return false }
        log("open \(l.id) on \(l.graphics.rawValue): \(exe) \(l.arguments.joined(separator: " "))")
        return true
    }
}

struct LaunchersSettings: View {
    @ObservedObject private var launch = TitleLaunch.shared
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
