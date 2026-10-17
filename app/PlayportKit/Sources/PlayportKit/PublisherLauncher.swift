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
    /// How long its Open goes on after the pool ran out (JitPool.exhaustionGrace for a game).
    public let exhaustionGrace: TimeInterval

    /// The launch's title id (TitleLaunch), apart from every store's game ids.
    public var titleID: String { "launcher-" + id }

    /// The Rockstar Games Launcher. Its installer writes `InstallFolder` in the 32-bit view;
    /// `PlayRDR2.exe` reads the same value (Stage R). Started with no `-steamAppId`: in Steam mode
    /// it wants a Steam client before its sign-in page (run `20261016T010049`). Rockstar Service
    /// runs under services.exe, and the launcher with it needs the 896 MiB pool (decision 0108).
    /// A Social Club child that runs the pool out does not end the Open for 240 s (decision 0112):
    /// the browser and its renderers go on after an optional child cannot start.
    public static let rockstar = PublisherLauncher(
        id: "rockstar", name: "Rockstar Games Launcher",
        installKey: #"Software\Wow6432Node\Rockstar Games\Launcher"#, installValue: "InstallFolder",
        executable: "Launcher.exe", arguments: [], windowsServices: true, jitPoolMB: 896, graphics: .vulkan,
        exhaustionGrace: 240)

    public static let all: [PublisherLauncher] = [rockstar]

    public static func named(_ id: String) -> PublisherLauncher? { all.first { $0.id == id } }

    /// What an Open takes from the settings saved under `titleID` (a dev build's, as a game's
    /// Play takes its own: the driver's `--settings launcher-ID:JSON`, the Launchers page's
    /// Runtime keys row): the runtime keys and FEX's inputs. Windows services, the pool and the
    /// backend stay this table's.
    public struct OpenSettings: Equatable, Sendable {
        /// madeira.cfg keys, `env.NAME` among them (LaunchCoordinator exports those).
        public var config: [String: String] = [:]
        public var ordering = MemoryOrdering()
        public var maxInst: Int?
        public var x87Reduced: Bool?
        public var diskCache: Bool?

        public init(config: [String: String] = [:], ordering: MemoryOrdering = MemoryOrdering(), maxInst: Int? = nil,
                    x87Reduced: Bool? = nil, diskCache: Bool? = nil) {
            self.config = config
            self.ordering = ordering
            self.maxInst = maxInst
            self.x87Reduced = x87Reduced
            self.diskCache = diskCache
        }
    }

    /// The saved settings' runtime keys and FEX inputs, read as a game's are
    /// (LaunchSettings.resolve: unparsable keys and a block size FEX cannot take are unset).
    public static func openSettings(saved: LaunchSettings?) -> OpenSettings {
        let e = LaunchSettings.resolve(game: saved, global: LaunchSettings())
        return OpenSettings(config: e.runtime, ordering: e.ordering, maxInst: e.maxInst,
                            x87Reduced: e.x87Reduced, diskCache: e.diskCache)
    }

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
