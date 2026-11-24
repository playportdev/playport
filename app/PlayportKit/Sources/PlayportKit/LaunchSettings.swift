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
    /// Playport's Steam client, the Steam API emulator or the game's own
    /// steam_api (per game only); nil inherits the compatibility default, then
    /// every game's `.client` (decision 0153), and is the emulator only when
    /// neither sets one (SteamAPISwap).
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
    /// x87 at 64-bit rather than 80-bit precision (per game only); nil takes the game's profile.
    public var x87Reduced: Bool?
    /// FEX's disk cache of translated code (per game only); nil takes the default, on.
    public var diskCache: Bool?
    /// madeira.cfg keys over the game's own (per game only; a dev build's), as typed:
    /// `key=value` items split at spaces. LaunchSettings.runtimeKeys parses them.
    public var runtime: String
    /// The game's environment variables and Vulkan layers' options (per game only), as typed.
    public var graphicsOptions: String
    /// Start Windows services for the game (per game only): a launcher that installs and uses one.
    public var windowsServices: Bool?
    /// Use the Khronos Vulkan loader in place of Wine's vulkan-1.dll (per game only).
    public var khronosVulkanLoader: Bool?
    /// End the publisher launcher a game's Play starts once the game has signed in.
    public var endLauncherAfterSignIn: Bool?

    public init(screen: String? = nil, aspect: String? = nil, frameLimit: Int? = nil, graphics: GraphicsBackend? = nil,
                arguments: String = "", steamAPI: SteamAPISwap.Mode? = nil,
                cloudSync: Bool? = nil, ordering: MemoryOrdering = MemoryOrdering(), maxInst: Int? = nil,
                x87Reduced: Bool? = nil, diskCache: Bool? = nil, runtime: String = "", graphicsOptions: String = "",
                windowsServices: Bool? = nil, khronosVulkanLoader: Bool? = nil,
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
        self.khronosVulkanLoader = khronosVulkanLoader
        self.endLauncherAfterSignIn = endLauncherAfterSignIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect)
        frameLimit = try c.decodeIfPresent(Int.self, forKey: .frameLimit)
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
        khronosVulkanLoader = try c.decodeIfPresent(Bool.self, forKey: .khronosVulkanLoader)
        endLauncherAfterSignIn = try c.decodeIfPresent(Bool.self, forKey: .endLauncherAfterSignIn)
    }

    public var isEmpty: Bool {
        screen == nil && aspect == nil && frameLimit == nil && graphics == nil
            && arguments.trimmingCharacters(in: .whitespaces).isEmpty && steamAPI == nil && cloudSync == nil
            && ordering.isEmpty && maxInst == nil && x87Reduced == nil && diskCache == nil
            && runtime.trimmingCharacters(in: .whitespaces).isEmpty
            && graphicsOptions.trimmingCharacters(in: .whitespaces).isEmpty && windowsServices == nil
            && khronosVulkanLoader == nil
    }

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

    public static let everyGame = LaunchSettings(
        steamAPI: .client,
        runtime: "env.MADEIRA_X64_CS_FASTPATH=1 env.MADEIRA_FEX_BATCH2=1 env.PLAYPORT_SC_BLOCK_CRASHPAD=1 "
            + "env.FEX_HOSTFEATURES=disableafp env.MADEIRA_FEX_AFPOFF_FPCR=fiz avail-phys-cef-mb=300",
        windowsServices: true, khronosVulkanLoader: true, endLauncherAfterSignIn: true)

    public static func overEveryGame(_ compat: LaunchSettings?) -> LaunchSettings {
        var s = (compat ?? LaunchSettings()).over(everyGame)
        s.runtime = compat?.runtime ?? ""
        s.endLauncherAfterSignIn = compat?.endLauncherAfterSignIn ?? everyGame.endLauncherAfterSignIn
        return s
    }

    public static let everyGameKeys: [String: String] = runtimeKeys(everyGame.runtime) ?? [:]

    public static func releaseRuntime(compat: LaunchSettings?) -> [String: String] {
        runtimeKeys(compat?.runtime ?? "") ?? [:]
    }

    public static func releaseSteamAPI(compat: LaunchSettings?) -> SteamAPISwap.Mode {
        overEveryGame(compat).steamAPI ?? .emulated
    }

    public static func runtimeKeys(_ line: String) -> [String: String]? {
        guard let items = runtimeItems(line), (try? TitleConfig.validate(items)) != nil else { return nil }
        return items
    }

    public static func unusedRuntimeKeysNote(_ line: String) -> String? {
        do {
            guard let items = runtimeItems(line) else { return "Not key=value items: not used" }
            try TitleConfig.validate(items)
            return nil
        } catch LaunchPlanError.refusedKey(let key) {
            return "\(key) \(TitleConfig.refusal(key)) (no per-game memory keys): not used"
        } catch {
            return "Not key=value items: not used"
        }
    }

    private static func runtimeItems(_ line: String) -> [String: String]? {
        var out: [String: String] = [:]
        for item in splitArguments(line) {
            guard let eq = item.firstIndex(of: "=") else { return nil }
            out[String(item[..<eq])] = String(item[item.index(after: eq)...])
        }
        return out
    }

    public static let graphicsVariables = ["DXVK_CONFIG", "VKD3D_CONFIG", "MESA_KK_DEBUG",
                                           "MESA_KK_EXPERIMENTAL", "MESA_KK_DISABLE_WORKAROUNDS"]
    public static let dxvkSections = ["dxvk", "dxgi", "d3d11", "d3d10", "d3d9", "d3d8"]

    static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic)
        else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

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

    public struct Effective: Equatable, Sendable {
        public var screen: String?
        public var aspect: ScreenAspect
        public var frameLimit: Int
        public var graphics: GraphicsBackend
        public var arguments: [String]
        public var steamAPI: SteamAPISwap.Mode
        public var ordering: MemoryOrdering
        public var maxInst: Int?
        public var x87Reduced: Bool?
        public var diskCache: Bool?
        public var runtime: [String: String]
        public var graphicsEnvironment: [String: String]
        public var windowsServices: Bool
        public var khronosVulkanLoader: Bool
        public var endLauncherAfterSignIn: Bool

        public init(screen: String?, aspect: ScreenAspect = .phone, frameLimit: Int, graphics: GraphicsBackend = .default,
                    arguments: [String] = [], steamAPI: SteamAPISwap.Mode = .emulated,
                    ordering: MemoryOrdering = MemoryOrdering(), maxInst: Int? = nil,
                    x87Reduced: Bool? = nil, diskCache: Bool? = nil, runtime: [String: String] = [:],
                    graphicsEnvironment: [String: String] = [:], windowsServices: Bool = false,
                    khronosVulkanLoader: Bool = false, endLauncherAfterSignIn: Bool = false) {
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
            self.khronosVulkanLoader = khronosVulkanLoader
            self.endLauncherAfterSignIn = endLauncherAfterSignIn
        }

        public var runtimeOverlays: String? {
            GraphicsBackend.runtimeOverlays(graphics: graphics, khronosVulkanLoader: khronosVulkanLoader)
        }

        public var guestScreen: String? { aspect.spec(level: screen) }

        public func config(over base: [String: String]) -> [String: String] {
            LaunchSettings.everyGameKeys.merging(base) { _, title in title }.merging(runtime) { _, own in own }
        }
    }

    public static let defaultScreen = "720"
    public static let defaultFrameLimit = 60

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
                         windowsServices: game?.windowsServices ?? false,
                         khronosVulkanLoader: game?.khronosVulkanLoader ?? false,
                         endLauncherAfterSignIn: game?.endLauncherAfterSignIn ?? false)
    }

    public static let screenPresets = ["native", "1080", "900", "720", "540"]

    public static func frameLimits(maxRate: Int) -> [Int] {
        [30, 40, 60].filter { $0 < maxRate && maxRate % $0 == 0 }
    }
}

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case dxmt
    case vulkan

    public static let `default`: GraphicsBackend = .vulkan

    public var runtimeOverlay: String? {
        switch self {
        case .dxmt: nil
        case .vulkan: "vulkan"
        }
    }

    public static let khronosVulkanLoaderOverlay = "vulkan-loader"

    public static func runtimeOverlays(graphics: GraphicsBackend, khronosVulkanLoader: Bool) -> String? {
        let list = [graphics.runtimeOverlay, khronosVulkanLoader ? khronosVulkanLoaderOverlay : nil].compactMap { $0 }
        return list.isEmpty ? nil : list.joined(separator: ",")
    }

    /// Environment this backend's launches start with. DXMT enables its MetalFX
    /// spatial swapchain path; Vulkan disables DXVK's tiler mode (decision 0066).
    public var runtimeEnvironment: [String: String] {
        switch self {
        case .dxmt: [
            "DXMT_METALFX_SPATIAL_SWAPCHAIN": "1",
            "DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=2.0;",
        ]
        case .vulkan: ["DXVK_CONFIG": "dxvk.tilerMode = False"]
        }
    }

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

public enum ScreenAspect: String, CaseIterable, Sendable {
    case phone
    case wide16x9 = "16:9"
    case wide16x10 = "16:10"
    case standard4x3 = "4:3"

    public var ratio: (Int, Int)? {
        switch self {
        case .phone: nil
        case .wide16x9: (16, 9)
        case .wide16x10: (16, 10)
        case .standard4x3: (4, 3)
        }
    }

    public func spec(level: String?) -> String? {
        guard let (w, h) = ratio else { return level }
        let l = level?.lowercased() ?? "native"
        guard l == "native" || Int(l) != nil else { return level }
        return "\(w):\(h)@\(l)"
    }
}
