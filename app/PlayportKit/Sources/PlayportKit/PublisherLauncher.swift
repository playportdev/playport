// SPDX-License-Identifier: GPL-3.0-or-later
// A publisher's launcher Playport opens from Settings › Launchers (docs/plans/2026-10-12-launchers.md,
// Where a launcher lives in the UI): a launch whose title is the launcher itself, started standalone
// in the shared prefix. The compatibility table is keyed by a game's title id, so a launcher's play
// settings (Windows services, decision 0107; its JIT pool, decision 0108; the backend, decision 0100)
// live here. The launcher's own installer records its folder in the prefix's registry, which is
// where Playport finds it: no install, no folder, no Open.

import Foundation

public struct PublisherLauncher: Equatable, Sendable, Identifiable {
    /// The driver's and the launch's name for it (`open-launcher:rockstar`).
    public let id: String
    public let name: String
    /// The key, in the prefix's system hive, holding the install folder its installer wrote.
    public let installKey: String
    public let installValue: String
    /// The executable in that folder, started with `arguments` (standalone, never a store's mode).
    public let executable: String
    public let arguments: [String]
    public let windowsServices: Bool
    /// The JIT pool its play asks for (JitPool.size grants it under a large enough memory limit).
    public let jitPoolMB: Int?
    public let graphics: GraphicsBackend

    /// The launch's title id (TitleLaunch), apart from every store's game ids.
    public var titleID: String { "launcher-" + id }

    /// The Rockstar Games Launcher. Its installer writes `InstallFolder` in the 32-bit view;
    /// `PlayRDR2.exe` reads the same value (Stage R). Started with no `-steamAppId`: in Steam mode
    /// it wants a Steam client before its sign-in page (run `20261016T010049`). Rockstar Service
    /// runs under services.exe, and the launcher with it needs the 896 MiB pool (decision 0108).
    public static let rockstar = PublisherLauncher(
        id: "rockstar", name: "Rockstar Games Launcher",
        installKey: #"Software\Wow6432Node\Rockstar Games\Launcher"#, installValue: "InstallFolder",
        executable: "Launcher.exe", arguments: [], windowsServices: true, jitPoolMB: 896, graphics: .vulkan)

    public static let all: [PublisherLauncher] = [rockstar]

    public static func named(_ id: String) -> PublisherLauncher? { all.first { $0.id == id } }

    /// The executable's DOS path from the system hive's text (system.reg), or nil when the install
    /// folder is not recorded, or is not an absolute path on drive C (the only drive in the prefix).
    public func executablePath(systemHive text: String) -> String? {
        guard var folder = PrefixRegistryFile.string(inHive: text, key: installKey, name: installValue) else { return nil }
        while folder.hasSuffix("\\") || folder.hasSuffix("/") { folder.removeLast() }
        let lower = folder.lowercased()
        guard lower.hasPrefix(#"c:\"#) || lower.hasPrefix("c:/"), folder.count > 3 else { return nil }
        return folder + "\\" + executable
    }
}
