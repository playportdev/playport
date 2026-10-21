// SPDX-License-Identifier: GPL-3.0-or-later
// The player's launch settings (Settings tab and a game's page): the guest's
// screen, a frame rate limit, the graphics backend and, for one game, extra
// command-line arguments, which steam_api it loads, FEX's x86 memory
// ordering over the game's profile, FEX's block size and x87 precision (FEXProfile).
// A game's own value wins over the global one, which wins over the defaults:
// 720 rows at 60 FPS on Vulkan (`defaultScreen`, `defaultFrameLimit`, GraphicsBackend.default),
// with LaunchSettings.everyGame's services, pool, loader, Steam client and runtime keys
// (decision 0153). A cohort title's screen (LaunchPlan.screen) no longer sets it (decision 0034). Native and no limit are a
// choice in Settings or on a game's page. A limit of 0 runs presents free, with
// no vsync lock (TitleScreen.swift).

import Foundation
import SteamClientKit

public struct LaunchSettings: Codable, Equatable, Sendable {
    /// A screen spec (LaunchPlan.validScreen): the resolution, `native` or rows (`720`), in the
    /// aspect ratio's shape; an old `WxH` or `4:3` is that size whatever the aspect ratio; nil inherits.
    public var screen: String?
    /// The screen's shape, a ScreenAspect raw value (`phone`, `16:9`, `16:10`, `4:3`); nil inherits.
    public var aspect: String?
    /// Frames per second at most; 0 for no limit, nil inherits.
    public var frameLimit: Int?
    /// Which layer runs Direct3D; nil inherits.
    public var graphics: GraphicsBackend?
    /// Added to the game's command line, after any the tested configuration
    /// gives it (per game only), as the player typed them: split by
    /// LaunchSettings.splitArguments. `-DX12`, `-force-d3d12` and the like.
    public var arguments: String
    /// The Steam API emulator or the game's own steam_api (per game only); nil
    /// is the emulator (SteamAPISwap).
    public var steamAPI: SteamAPISwap.Mode?
    /// Sync the game's saves with Steam Cloud (per game only); nil is on.
    public var cloudSync: Bool?
    /// FEX's memory ordering, each switch over the game's profile (per game
    /// only; FEXProfile.launch).
    public var ordering: MemoryOrdering
    /// The most x86 instructions FEX translates as one block (FEX `MaxInst`,
    /// per game only); nil takes the game's profile, Proton's global 500 unless
    /// its entry sets one (decision 0055). FEXProfile.blockSizes are the ones offered.
    public var maxInst: Int?
    /// x87 at 64-bit rather than 80-bit precision (FEX `X87ReducedPrecision`, per
    /// game only); nil takes the game's profile (FEXProfile.defaultX87Reduced).
    public var x87Reduced: Bool?
    /// FEX's disk cache of translated code (FEX `DiskCache`, per game only); nil
    /// takes the default, on (FEXProfile.defaultDiskCache, decision 0056).
    public var diskCache: Bool?
    /// madeira.cfg keys over the game's own (per game only; a dev build's), as typed:
    /// `key=value` items split at spaces (`vram-mb=1024 totalphys=6144 inproc-sync=1`).
    /// LaunchSettings.runtimeKeys parses them; TitleConfig writes them after the title's.
    public var runtime: String
    /// The game's environment variables and Vulkan layers' options (per game only; a dev
    /// build's, decisions 0060 and 0137), as typed: items split at spaces, each `NAME=value`
    /// for any variable or a DXVK option (`dxvk.tilerMode=False`), which goes into
    /// DXVK_CONFIG. LaunchSettings.graphicsEnvironment parses them.
    public var graphicsOptions: String
    /// Start Windows services for the game (services.exe, Wine's SCM, and the services it
    /// starts; per game only, decision 0107): a launcher that installs and uses one. Nil is off.
    public var windowsServices: Bool?
    /// The game's JIT pool in MiB (per game only, the compatibility table's; decision 0108):
    /// a launcher's many processes outgrow JitPool.minimumMB. Nil is the default pool.
    public var jitPoolMB: Int?
    /// The Khronos Vulkan loader in place of Wine's vulkan-1.dll (per game only, decision 0131):
    /// a game whose own Vulkan layer (RDR2's Social Club) must load, which Wine's does not do.
    /// A dev build's game page and `set:` change it; a release build shows no row, so the
    /// compatibility table decides. Nil is off: Wine's own.
    public var khronosVulkanLoader: Bool?
    /// End the publisher launcher a game's Play starts, its whole tree but never the game or a
    /// process under it, once the game has signed in, or before that near the memory limit
    /// (decision 0130, amending 0125): the compatibility table's alone. over() takes it from the game's
    /// compatibility default and never from a person's settings, so no saved value, `set:`
    /// or `--settings` reaches it, and no page shows it. Nil is off.
    public var endLauncherAfterSignIn: Bool?

    public init(screen: String? = nil, aspect: String? = nil, frameLimit: Int? = nil, graphics: GraphicsBackend? = nil,
                arguments: String = "", steamAPI: SteamAPISwap.Mode? = nil,
                cloudSync: Bool? = nil, ordering: MemoryOrdering = MemoryOrdering(), maxInst: Int? = nil,
                x87Reduced: Bool? = nil, diskCache: Bool? = nil, runtime: String = "", graphicsOptions: String = "",
                windowsServices: Bool? = nil, jitPoolMB: Int? = nil, khronosVulkanLoader: Bool? = nil,
                endLauncherAfterSignIn: Bool? = nil) {
        self.screen = screen
        self.aspect = aspect
        self.frameLimit = frameLimit
        self.graphics = graphics
        self.arguments = arguments
        self.steamAPI = steamAPI
        self.cloudSync = cloudSync
        self.ordering = ordering
        self.maxInst = maxInst
        self.x87Reduced = x87Reduced
        self.diskCache = diskCache
        self.runtime = runtime
        self.graphicsOptions = graphicsOptions
        self.windowsServices = windowsServices
        self.jitPoolMB = jitPoolMB
        self.khronosVulkanLoader = khronosVulkanLoader
        self.endLauncherAfterSignIn = endLauncherAfterSignIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect)
        frameLimit = try c.decodeIfPresent(Int.self, forKey: .frameLimit)
        // A backend this build does not know (saved by a newer one) inherits
        // rather than losing the rest of the settings.
        graphics = try c.decodeIfPresent(String.self, forKey: .graphics).flatMap(GraphicsBackend.init(rawValue:))
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        steamAPI = try c.decodeIfPresent(String.self, forKey: .steamAPI).flatMap(SteamAPISwap.Mode.init(rawValue:))
        cloudSync = try c.decodeIfPresent(Bool.self, forKey: .cloudSync)
        ordering = try c.decodeIfPresent(MemoryOrdering.self, forKey: .ordering) ?? MemoryOrdering()
        maxInst = try c.decodeIfPresent(Int.self, forKey: .maxInst)
        x87Reduced = try c.decodeIfPresent(Bool.self, forKey: .x87Reduced)
        diskCache = try c.decodeIfPresent(Bool.self, forKey: .diskCache)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? ""
        graphicsOptions = try c.decodeIfPresent(String.self, forKey: .graphicsOptions) ?? ""
        windowsServices = try c.decodeIfPresent(Bool.self, forKey: .windowsServices)
        jitPoolMB = try c.decodeIfPresent(Int.self, forKey: .jitPoolMB)
        khronosVulkanLoader = try c.decodeIfPresent(Bool.self, forKey: .khronosVulkanLoader)
        endLauncherAfterSignIn = try c.decodeIfPresent(Bool.self, forKey: .endLauncherAfterSignIn)
    }

    /// Whether a person set nothing; endLauncherAfterSignIn, which no person sets, does not count.
    public var isEmpty: Bool {
        screen == nil && aspect == nil && frameLimit == nil && graphics == nil
            && arguments.trimmingCharacters(in: .whitespaces).isEmpty && steamAPI == nil && cloudSync == nil
            && ordering.isEmpty && maxInst == nil && x87Reduced == nil && diskCache == nil
            && runtime.trimmingCharacters(in: .whitespaces).isEmpty
            && graphicsOptions.trimmingCharacters(in: .whitespaces).isEmpty && windowsServices == nil
            && jitPoolMB == nil && khronosVulkanLoader == nil
    }

    /// Arguments as a command line splits them: at spaces, except inside
    /// double quotes, which are removed.
    public static func splitArguments(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, any = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); any = true }
            else if ch == " " && !quoted { if any { out.append(cur) }; cur = ""; any = false }
            else { cur.append(ch); any = true }
        }
        if any { out.append(cur) }
        return out
    }

    /// What every game launches with unless its compatibility default or a person's choice for it
    /// says otherwise (decision 0153): Red Dead Redemption 2's settings, which work, made everyone's,
    /// as the base under each title's compatibility default (overEveryGame). Each acts only where its
    /// trigger exists: Windows services start the service manager, which runs only the services a
    /// game installed; the launcher's end needs a publisher's launcher (PublisherLauncher.startedBy);
    /// the Khronos loader loads only the layers a game asks for; Playport's Steam client serves only a
    /// Steam app; `env.PLAYPORT_SC_BLOCK_CRASHPAD=1` refuses only Rockstar's and Chromium's crash
    /// reporters. The backend is GraphicsBackend.default, below Settings' own choice. The runtime keys
    /// merge by key (keyItems), so a game's `env.MADEIRA_FEX_BATCH2=0` turns one off. RDR2's
    /// `env.FEX_HOSTFEATURES=disableafp` stays its own: Hollow Knight draws black without AFP.
    public static let everyGame = LaunchSettings(
        steamAPI: .client,
        runtime: "jumbo-mb=8960 env.PLAYPORT_VK_HEAP_MB=3072 env.MADEIRA_FASTSYNC_SEM=1 "
            + "env.MADEIRA_X64_CS_FASTPATH=1 env.MADEIRA_FEX_BATCH2=1 env.PLAYPORT_SC_BLOCK_CRASHPAD=1",
        windowsServices: true, jitPoolMB: 896, khronosVulkanLoader: true, endLauncherAfterSignIn: true)

    /// A title's compatibility default (nil for none) over everyGame: each setting the title's
    /// entry has wins; the launcher's end is the entry's, else everyGame's. The runtime keys stay the
    /// entry's own: everyGame's go under the title's madeira.cfg keys too (Effective.config), so a
    /// cohort title's `jumbo-mb=32768` keeps its value.
    public static func overEveryGame(_ compat: LaunchSettings?) -> LaunchSettings {
        var s = (compat ?? LaunchSettings()).over(everyGame)
        s.runtime = compat?.runtime ?? ""
        s.endLauncherAfterSignIn = compat?.endLauncherAfterSignIn ?? everyGame.endLauncherAfterSignIn
        return s
    }

    /// everyGame's runtime keys, the lowest level of a launch's madeira.cfg keys (Effective.config).
    public static let everyGameKeys: [String: String] = runtimeKeys(everyGame.runtime) ?? [:]

    /// The runtime keys a release build launches with (decision 0126): the game's compatibility
    /// default's, never a person's (a dev build's Runtime keys row); everyGame's go under them and
    /// the title's own in Effective.config (decision 0153).
    public static func releaseRuntime(compat: LaunchSettings?) -> [String: String] {
        runtimeKeys(compat?.runtime ?? "") ?? [:]
    }

    /// The Steam API a release build launches a Steam app with (decisions 0115, 0153): the game's
    /// compatibility default's, else everyGame's, never a person's.
    public static func releaseSteamAPI(compat: LaunchSettings?) -> SteamAPISwap.Mode {
        overEveryGame(compat).steamAPI ?? .emulated
    }

    /// Runtime keys as typed (`vram-mb=1024 inproc-sync=1`): `key=value` items at spaces,
    /// a later item for a key winning. nil when an item has no `=` or TitleConfig refuses it.
    public static func runtimeKeys(_ line: String) -> [String: String]? {
        var out: [String: String] = [:]
        for item in splitArguments(line) {
            guard let eq = item.firstIndex(of: "=") else { return nil }
            out[String(item[..<eq])] = String(item[item.index(after: eq)...])
        }
        return (try? TitleConfig.validate(out)) == nil ? nil : out
    }

    /// The list variables a game's Graphics options join when repeated (decision 0060):
    /// DXVK's and vkd3d-proton's option strings and KosmicKrisp's debug, experimental and
    /// workaround switches. Any other variable may be set too (decision 0137); repeated,
    /// its last item wins.
    public static let graphicsVariables = ["DXVK_CONFIG", "VKD3D_CONFIG", "MESA_KK_DEBUG",
                                           "MESA_KK_EXPERIMENTAL", "MESA_KK_DISABLE_WORKAROUNDS"]
    /// The sections of a DXVK option an item may name without DXVK_CONFIG= (dxvk.conf's).
    public static let dxvkSections = ["dxvk", "dxgi", "d3d11", "d3d10", "d3d9", "d3d8"]

    /// An environment variable name: `[A-Za-z_][A-Za-z0-9_]*`.
    static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic)
        else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

    /// Graphics options as typed (`dxvk.tilerMode=False VKD3D_CONFIG=one_time_submit`):
    /// items at spaces (double quotes keep spaces), each `NAME=value` for any variable (NAME
    /// `[A-Za-z_][A-Za-z0-9_]*`) or `section.option=value` for DXVK. DXVK options join
    /// DXVK_CONFIG with `;`, as DXVK splits it; another of graphicsVariables repeated joins
    /// with `,`, as vkd3d-proton and Mesa split theirs; any other variable repeated takes its
    /// last value. nil when an item is neither.
    public static func graphicsEnvironment(_ line: String) -> [String: String]? {
        var out: [String: String] = [:]
        func add(_ name: String, _ value: String) {
            guard !value.isEmpty else { return }
            guard graphicsVariables.contains(name) else { out[name] = value; return }
            out[name] = out[name].map { $0 + (name == "DXVK_CONFIG" ? ";" : ",") + value } ?? value
        }
        for item in splitArguments(line) {
            guard let eq = item.firstIndex(of: "="), eq != item.startIndex else { return nil }
            let name = String(item[..<eq]), value = String(item[item.index(after: eq)...])
            if isVariableName(name) {
                add(name, value)
            } else if let dot = name.firstIndex(of: "."), dxvkSections.contains(String(name[..<dot])),
                      name.index(after: dot) < name.endIndex {
                add("DXVK_CONFIG", "\(name) = \(value)")
            } else {
                return nil
            }
        }
        return out
    }

    /// What one launch uses.
    public struct Effective: Equatable, Sendable {
        /// The resolution spec; nil for the panel's native pixels.
        public var screen: String?
        /// The screen's shape.
        public var aspect: ScreenAspect
        /// 0 for no limit.
        public var frameLimit: Int
        public var graphics: GraphicsBackend
        public var arguments: [String]
        public var steamAPI: SteamAPISwap.Mode
        /// The game's own ordering switches; FEXProfile.launch puts them over its profile.
        public var ordering: MemoryOrdering
        /// The game's own block size, nil for its profile's (FEXProfile.launch).
        public var maxInst: Int?
        /// The game's own x87 precision, nil for its profile's (FEXProfile.launch).
        public var x87Reduced: Bool?
        /// The game's own disk cache choice, nil for the default (FEXProfile.launch).
        public var diskCache: Bool?
        /// madeira.cfg keys over the title's own (config(over:)); empty for none.
        public var runtime: [String: String]
        /// The Vulkan layers' variables from the game's Graphics options; empty for none.
        public var graphicsEnvironment: [String: String]
        /// Windows services for the game (decision 0107).
        public var windowsServices: Bool
        /// The game's JIT pool in MiB (decision 0108); nil for the default (JitPool.sizeMB).
        public var jitPoolMB: Int?
        /// The Khronos Vulkan loader in place of Wine's vulkan-1.dll (decision 0131).
        public var khronosVulkanLoader: Bool
        /// End the launcher the game's Play starts at the game's sign-in (decision 0130).
        public var endLauncherAfterSignIn: Bool

        public init(screen: String?, aspect: ScreenAspect = .phone, frameLimit: Int, graphics: GraphicsBackend = .default,
                    arguments: [String] = [], steamAPI: SteamAPISwap.Mode = .emulated,
                    ordering: MemoryOrdering = MemoryOrdering(), maxInst: Int? = nil,
                    x87Reduced: Bool? = nil, diskCache: Bool? = nil, runtime: [String: String] = [:],
                    graphicsEnvironment: [String: String] = [:], windowsServices: Bool = false,
                    jitPoolMB: Int? = nil, khronosVulkanLoader: Bool = false, endLauncherAfterSignIn: Bool = false) {
            self.screen = screen
            self.aspect = aspect
            self.frameLimit = frameLimit
            self.graphics = graphics
            self.arguments = arguments
            self.steamAPI = steamAPI
            self.ordering = ordering
            self.maxInst = maxInst
            self.x87Reduced = x87Reduced
            self.diskCache = diskCache
            self.runtime = runtime
            self.graphicsEnvironment = graphicsEnvironment
            self.windowsServices = windowsServices
            self.jitPoolMB = jitPoolMB
            self.khronosVulkanLoader = khronosVulkanLoader
            self.endLauncherAfterSignIn = endLauncherAfterSignIn
        }

        /// PLAYPORT_DLL_OVERLAY for this launch (wine_host.c, dll_overlay.h).
        public var runtimeOverlays: String? {
            GraphicsBackend.runtimeOverlays(graphics: graphics, khronosVulkanLoader: khronosVulkanLoader)
        }

        /// The guest screen's spec for HostIOKit Display.guestSize: the resolution in the shape
        /// (ScreenAspect.spec(level:)); an old `WxH` or `4:3` resolution as it is.
        public var guestScreen: String? { aspect.spec(level: screen) }

        /// The title's madeira.cfg keys (its cohort entry's) with these over them, all over
        /// every game's runtime keys (LaunchSettings.everyGameKeys, decision 0153).
        public func config(over base: [String: String]) -> [String: String] {
            LaunchSettings.everyGameKeys.merging(base) { _, title in title }.merging(runtime) { _, own in own }
        }
    }

    /// A screen and a limit nobody set: 720 rows at 60 FPS. On the reference phone
    /// Hollow Knight holds 60 there for ten minutes at 2.8 W for the whole phone,
    /// with no thermal pressure, where native and free-running fall to 76 FPS on the
    /// E cores (docs/evidence/2026-09-29-hk-gameplay-baseline.md).
    public static let defaultScreen = "720"
    public static let defaultFrameLimit = 60

    /// The game's value, else the global one, else the defaults (720 rows,
    /// 60 FPS, Vulkan (decision 0153; before it, only for an i386 executable, 0047, or
    /// DX12, 0044)). `game` is a person's own over overEveryGame's (LaunchSettingsStore). Explicit graphics choices still win. `arguments` are the title's
    /// base arguments, before the player's; they do not move an i386 title off Vulkan,
    /// since DXMT has no i386 build. Invalid values are skipped as if unset.
    public static func resolve(game: LaunchSettings?, global: LaunchSettings,
                               importsDirect3D12: Bool = false, i386: Bool = false,
                               arguments: [String] = []) -> Effective {
        let screen = [game?.screen, global.screen, defaultScreen].lazy.compactMap { $0 }
            .first(where: LaunchPlan.validScreen)
        let limit = [game?.frameLimit, global.frameLimit].lazy.compactMap { $0 }.first { $0 >= 0 } ?? defaultFrameLimit
        let dx12 = Direct3D12.requested(arguments: arguments + splitArguments(game?.arguments ?? ""),
                                       imported: importsDirect3D12)
        let graphics = game?.graphics ?? global.graphics ?? (dx12 || i386 ? .vulkan : .default)
        let aspect = [game?.aspect, global.aspect].lazy.compactMap { $0.flatMap(ScreenAspect.init(rawValue:)) }.first ?? .phone
        return Effective(screen: screen, aspect: aspect, frameLimit: limit, graphics: graphics,
                         arguments: splitArguments(game?.arguments ?? ""), steamAPI: game?.steamAPI ?? .emulated,
                         ordering: game?.ordering ?? MemoryOrdering(),
                         maxInst: game?.maxInst.flatMap { FEXProfile.validBlockSize($0) ? $0 : nil },
                         x87Reduced: game?.x87Reduced, diskCache: game?.diskCache,
                         runtime: runtimeKeys(game?.runtime ?? "") ?? [:],
                         graphicsEnvironment: graphicsEnvironment(game?.graphicsOptions ?? "") ?? [:],
                         windowsServices: game?.windowsServices ?? false, jitPoolMB: game?.jitPoolMB,
                         khronosVulkanLoader: game?.khronosVulkanLoader ?? false,
                         endLauncherAfterSignIn: game?.endLauncherAfterSignIn ?? false)
    }

    /// The resolutions the pickers offer, the same in every aspect ratio, as screen specs;
    /// the phone keeps those it can show.
    public static let screenPresets = ["native", "1080", "900", "720", "540"]

    /// The limits the pickers offer for a panel refreshing at most `maxRate` times a
    /// second: the rates that divide it evenly, so each frame stays up equally long.
    public static func frameLimits(maxRate: Int) -> [Int] {
        [30, 40, 60].filter { $0 < maxRate && maxRate % $0 == 0 }
    }
}

/// The layer that turns a game's Direct3D into Metal (decision 0014).
public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    /// DXMT: Direct3D 10 and 11 straight to Metal. What every tested game runs on.
    case dxmt
    /// DXVK (Direct3D 8 to 11) and vkd3d-proton (Direct3D 12) on Vulkan, on
    /// KosmicKrisp, Mesa's Vulkan driver on Metal.
    case vulkan

    /// Every game's backend unless Settings or its page says otherwise (decision 0153,
    /// LaunchSettings.everyGame); DXMT stays a choice.
    public static let `default`: GraphicsBackend = .vulkan

    /// The directory under the runtime whose <arch>-windows builtins go
    /// before the runtime's own for this backend (WINEDLLPATH); nil for none.
    public var runtimeOverlay: String? {
        switch self {
        case .dxmt: nil
        case .vulkan: "vulkan"
        }
    }

    /// The runtime directory of the Khronos Vulkan loader (decision 0131): its vulkan-1.dll
    /// and winevulkan's ICD manifest, linked into system32 after the backend's set.
    public static let khronosVulkanLoaderOverlay = "vulkan-loader"

    /// PLAYPORT_DLL_OVERLAY for a launch: the runtime directories whose <arch>-windows sets go
    /// over the runtime's own, in order (a later one's file wins), comma-separated: the
    /// backend's, then the Khronos Vulkan loader's. Nil for none.
    public static func runtimeOverlays(graphics: GraphicsBackend, khronosVulkanLoader: Bool) -> String? {
        let list = [graphics.runtimeOverlay, khronosVulkanLoader ? khronosVulkanLoaderOverlay : nil].compactMap { $0 }
        return list.isEmpty ? nil : list.joined(separator: ",")
    }

    /// Environment this backend's launches start with.
    ///
    /// None for DXMT. Vulkan turns DXVK's tiler mode off (decision 0066): on
    /// KosmicKrisp it recorded each render pass into a secondary command buffer
    /// that the driver copied and replayed on DXVK's frame thread, for no GPU time
    /// saved. DXVK still picks its own compiler thread count (decision 0024).
    public var runtimeEnvironment: [String: String] {
        switch self {
        case .dxmt: [:]
        case .vulkan: ["DXVK_CONFIG": "dxvk.tilerMode = False"]
        }
    }

    /// The backend's environment with a game's Graphics options over it (decision
    /// 0060): an option's variable replaces the backend's, except DXVK_CONFIG, where
    /// the options follow the backend's after `;`, so DXVK takes an option's value for
    /// a key both name and keeps the backend's others.
    public func environment(graphicsOptions options: [String: String]) -> [String: String] {
        var env = runtimeEnvironment
        for (name, value) in options {
            if name == "DXVK_CONFIG", let own = env[name] {
                env[name] = own + ";" + value
            } else {
                env[name] = value
            }
        }
        return env
    }
}

/// The shape of a game's screen (decision 0073), chosen beside the resolution: every shape
/// offers the same resolutions (Native, 1080p … 540p), each computed for the shape (HostIOKit
/// Display.guestSize), and a shape other than the panel's is aspect-fitted with bars. Some
/// games draw nothing on a screen wider than 16:9 (Super Meat Boy,
/// docs/evidence/2026-10-08-super-meat-boy.md).
public enum ScreenAspect: String, CaseIterable, Sendable {
    /// The panel's own shape (the default).
    case phone
    case wide16x9 = "16:9"
    case wide16x10 = "16:10"
    case standard4x3 = "4:3"

    /// Width to height; nil for the panel's.
    public var ratio: (Int, Int)? {
        switch self {
        case .phone: nil
        case .wide16x9: (16, 9)
        case .wide16x10: (16, 10)
        case .standard4x3: (4, 3)
        }
    }

    /// The guest screen spec for a resolution level (`native`, rows; nil is native) in this
    /// shape: the level itself for Phone, `W:H@level` for another (Display.guestSize). A level
    /// that is already a size (`WxH`, the old `4:3`) stays as it is.
    public func spec(level: String?) -> String? {
        guard let (w, h) = ratio else { return level }
        let l = level?.lowercased() ?? "native"
        guard l == "native" || Int(l) != nil else { return level }
        return "\(w):\(h)@\(l)"
    }
}
