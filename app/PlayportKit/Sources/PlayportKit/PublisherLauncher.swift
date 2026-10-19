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
    /// Environment over the backend's for its Open, in LaunchSettings.graphicsEnvironment's form
    /// (DXVK_CONFIG joins the backend's after `;`); a game's launch never takes it.
    public let graphicsEnvironment: [String: String]
    /// madeira.cfg keys (`env.NAME` among them) its Open runs with; a key saved under its title
    /// id replaces the same key here (openSettings).
    public let runtime: [String: String]
    /// Catalogue ids of games whose Play starts this launcher (a Steam copy's own start
    /// executable runs it): their Play inherits its Open's grace, graphics environment and
    /// runtime keys, under the game's own (decision 0115; `startingGame`).
    public let games: [String]
    /// The launcher's own saved window settings, relative to the prefix user's profile folder:
    /// a dev build's Settings › Launchers row and the driver's `forget-launcher-window:ID` delete
    /// this one file (forgetWindowSettings). Nil when Playport knows none.
    public let windowSettingsFile: String?
    /// The line the games in `games` log once they signed in through this launcher. A Play whose
    /// compatibility entry ends the launcher (LaunchSettings.endLauncherAfterSignIn) ends it when
    /// this line comes, or before it near the memory limit (decision 0130, LauncherEndTrigger); nil
    /// for a launcher with none. Which processes end is the session root's (app/SessionRoot/launcher_end.h).
    public let signIn: GameSignIn?

    /// The launch's title id (TitleLaunch), apart from every store's game ids.
    public var titleID: String { "launcher-" + id }

    /// The Rockstar Games Launcher. Its installer writes `InstallFolder` in the 32-bit view;
    /// `PlayRDR2.exe` reads the same value (Stage R). Started with no `-steamAppId`: in Steam mode
    /// it wants a Steam client before its sign-in page (run `20261016T010049`). Rockstar Service
    /// runs under services.exe, and the launcher with it needs the 896 MiB pool (decision 0108).
    /// A Social Club child that runs the pool out does not end the Open for 240 s (decision 0112):
    /// the browser and its renderers go on after an optional child cannot start.
    /// Its Direct3D device query starts DXVK and vkd3d-proton in the launcher; one DXVK compiler
    /// thread and no DXVK or vkd3d-proton disk cache (so no writer threads) leave more of FEX's
    /// host band to Social Club's threads (decision 0114). FEX's self-modifying-code checks are
    /// off (`env.FEX_SMCCHECKS=none`): with them on, Social Club's CEF crashed and the pool's tail
    /// passed 560 MB (run `20261018T095302`; decision 0116).
    public static let rockstar = PublisherLauncher(
        id: "rockstar", name: "Rockstar Games Launcher",
        installKey: #"Software\Wow6432Node\Rockstar Games\Launcher"#, installValue: "InstallFolder",
        executable: "Launcher.exe", arguments: [], windowsServices: true, jitPoolMB: 896, graphics: .vulkan,
        exhaustionGrace: 240,
        graphicsEnvironment: ["DXVK_CONFIG": "dxvk.numCompilerThreads = 1", "DXVK_SHADER_CACHE": "0",
                              "VKD3D_SHADER_CACHE_PATH": "0"],
        runtime: ["env.FEX_SMCCHECKS": "none"],
        // Red Dead Redemption 2's Steam copy: PlayRDR2.exe starts Launcher.exe -steamAppId=1174180.
        games: ["app-1174180"],
        // With it the main window logs "Using saved geometry"; without it "Centering on monitor",
        // the prefix otherwise the same (PLA-401, desktop runs s1 and r2-nosettings).
        windowSettingsFile: "AppData/Local/Rockstar Games/Launcher/settings_user.dat",
        // RDR2's Social Club log: `Signed in online to profile …` at each of the game's sign-ins
        // (desktop prefix, read with the profiles redacted; decision 0124).
        signIn: GameSignIn(log: "Documents/Rockstar Games/Social Club/socialclub.log",
                           line: "Signed in online to profile"))

    public static let all: [PublisherLauncher] = [rockstar]

    public static func named(_ id: String) -> PublisherLauncher? { all.first { $0.id == id } }

    /// The launcher a game's Play starts, nil for a game that starts no launcher Playport knows.
    public static func startedBy(game titleID: String) -> PublisherLauncher? { all.first { $0.games.contains(titleID) } }

    /// What a game's Play through this launcher runs with (decision 0115): its Open's runtime keys
    /// and graphics environment under the game's (a game's key of the same name wins; DXVK_CONFIG's
    /// items join, the launcher's first), and its Open's exhaustion grace.
    public func startingGame(_ e: LaunchSettings.Effective) -> (settings: LaunchSettings.Effective, exhaustionGrace: TimeInterval) {
        var s = e
        s.runtime = runtime.merging(e.runtime) { _, game in game }
        s.graphicsEnvironment = graphicsEnvironment.merging(e.graphicsEnvironment) { _, game in game }
        if let l = graphicsEnvironment["DXVK_CONFIG"], let g = e.graphicsEnvironment["DXVK_CONFIG"], l != g {
            s.graphicsEnvironment["DXVK_CONFIG"] = l + ";" + g
        }
        return (s, exhaustionGrace)
    }

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

    /// The saved settings' runtime keys over this launcher's `runtime`, and their FEX inputs, read
    /// as a game's are (LaunchSettings.resolve: unparsable keys and a block size FEX cannot take
    /// are unset). With nothing saved, an Open runs this table's keys.
    public func openSettings(saved: LaunchSettings?) -> OpenSettings {
        let e = LaunchSettings.resolve(game: saved, global: LaunchSettings())
        return OpenSettings(config: runtime.merging(e.runtime) { _, saved in saved }, ordering: e.ordering, maxInst: e.maxInst,
                            x87Reduced: e.x87Reduced, diskCache: e.diskCache)
    }

    /// Deletes `windowSettingsFile` under `profile` (the prefix's `drive_c/users/<user>`) and no
    /// other file: true when it was there and is gone, false when there was nothing to delete.
    public func forgetWindowSettings(profile: URL) throws -> Bool {
        guard let rel = windowSettingsFile else { return false }
        let file = rel.split(separator: "/").reduce(profile) { $0.appendingPathComponent(String($1)) }
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        try FileManager.default.removeItem(at: file)
        return true
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
